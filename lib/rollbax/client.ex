defmodule Rollbax.Client do
  @moduledoc false

  # This GenServer keeps a pre-built bare-bones version of an exception (a
  # "draft") to be reported to Rollbar, which is then filled with the data
  # related to each specific exception when such exception is being
  # reported. It hands each report to a task that posts it through the
  # configured `Rollbax.HTTPClient`, and reads the task's result to log it
  # and to honour Rollbar's rate limiting. Only so many reports are posted
  # at once; the rest wait in a bounded queue.

  use GenServer

  require Logger

  alias Rollbax.Item

  @name __MODULE__
  @headers [{"content-type", "application/json"}]
  @max_reports_in_flight 20
  @max_reports_waiting 1_000

  ## GenServer state

  defstruct [
    :draft,
    :url,
    :enabled,
    :http_client,
    :task_supervisor,
    rate_limited?: false,
    in_flight: MapSet.new(),
    waiting: :queue.new(),
    waiting_count: 0
  ]

  ## Public API

  def start_link(config) do
    state = %__MODULE__{
      draft: Item.draft(config[:access_token], config[:environment], config[:custom]),
      url: config[:api_endpoint],
      enabled: config[:enabled],
      http_client: http_client(config[:http_client])
    }

    GenServer.start_link(__MODULE__, state, name: @name)
  end

  @doc """
  Returns the `{module, options}` pair for the `:http_client` configuration.
  """
  def http_client(nil), do: http_client(Rollbax.HTTPClient.Req)
  def http_client(module) when is_atom(module), do: http_client({module, []})

  def http_client({module, options}) when is_atom(module) and is_list(options) do
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        if function_exported?(module, :post, 4) do
          {module, options}
        else
          raise ArgumentError,
                ":http_client #{inspect(module)} does not implement the Rollbax.HTTPClient behaviour"
        end

      {:error, _reason} ->
        raise ArgumentError, http_client_not_loaded_message(module)
    end
  end

  def http_client(other) do
    raise ArgumentError,
          ":http_client must be a module or a {module, options} tuple, got: #{inspect(other)}"
  end

  defp http_client_not_loaded_message(Rollbax.HTTPClient.Req) do
    "the default :http_client, Rollbax.HTTPClient.Req, needs the :req dependency. " <>
      ~s(Add {:req, "~> 0.5"} to your dependencies or configure another :http_client)
  end

  defp http_client_not_loaded_message(module) do
    ":http_client #{inspect(module)} is not available"
  end

  def emit(level, timestamp, body, custom, occurrence_data)
      when is_atom(level) and is_integer(timestamp) and timestamp > 0 and is_map(body) and
             is_map(custom) and is_map(occurrence_data) do
    if pid = Process.whereis(@name) do
      event = {Atom.to_string(level), timestamp, body, custom, occurrence_data}
      GenServer.cast(pid, {:emit, event})
    else
      Logger.warning(
        "(Rollbax) Trying to report an exception but the :rollbax application has not been started",
        rollbax: false
      )
    end
  end

  ## GenServer callbacks

  @impl true
  def init(%__MODULE__{} = state) do
    Logger.metadata(rollbax: false)
    {:ok, task_supervisor} = Task.Supervisor.start_link()
    {:ok, %{state | task_supervisor: task_supervisor}}
  end

  @impl true
  def handle_cast({:emit, _event}, %{rate_limited?: true} = state) do
    Logger.info("(Rollbax) ignored report due to rate limiting")
    {:noreply, state}
  end

  def handle_cast({:emit, _event}, %{enabled: false} = state) do
    {:noreply, state}
  end

  def handle_cast({:emit, event}, %{enabled: :log} = state) do
    Logger.info(["(Rollbax) registered report.\n", event_to_chardata(event)])
    {:noreply, state}
  end

  def handle_cast({:emit, event}, %{enabled: true} = state) do
    case compose_json(state.draft, event) do
      {:ok, payload} ->
        {:noreply, post_or_enqueue(payload, state)}

      {:error, exception} ->
        Logger.error([
          "(Rollbax) failed to encode report below ",
          "for reason: ",
          Exception.message(exception),
          ?\n,
          event_to_chardata(event)
        ])

        {:noreply, state}
    end
  end

  @impl true
  def handle_info({ref, response}, %__MODULE__{} = state) when is_reference(ref) do
    if MapSet.member?(state.in_flight, ref) do
      Process.demonitor(ref, [:flush])
      state = handle_response(response, %{state | in_flight: MapSet.delete(state.in_flight, ref)})
      {:noreply, post_waiting(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %__MODULE__{} = state) do
    if MapSet.member?(state.in_flight, ref) do
      Logger.error("(Rollbax) the task posting a report exited: #{inspect(reason)}")
      {:noreply, post_waiting(%{state | in_flight: MapSet.delete(state.in_flight, ref)})}
    else
      {:noreply, state}
    end
  end

  def handle_info(:lift_rate_limiting, state) do
    {:noreply, %{state | rate_limited?: false}}
  end

  def handle_info(message, state) do
    Logger.info("(Rollbax) unexpected message: #{inspect(message)}")
    {:noreply, state}
  end

  ## Helper functions

  defp post_or_enqueue(payload, %__MODULE__{} = state) do
    cond do
      MapSet.size(state.in_flight) < @max_reports_in_flight ->
        post(payload, state)

      state.waiting_count < @max_reports_waiting ->
        %{
          state
          | waiting: :queue.in(payload, state.waiting),
            waiting_count: state.waiting_count + 1
        }

      true ->
        Logger.error(
          "(Rollbax) dropped report: #{@max_reports_waiting} reports are already waiting to be sent"
        )

        state
    end
  end

  defp post_waiting(%__MODULE__{rate_limited?: true, waiting_count: count} = state)
       when count > 0 do
    Logger.info("(Rollbax) ignored #{count} waiting reports due to rate limiting")
    %{state | waiting: :queue.new(), waiting_count: 0}
  end

  defp post_waiting(%__MODULE__{} = state) do
    case :queue.out(state.waiting) do
      {{:value, payload}, waiting} ->
        post(payload, %{state | waiting: waiting, waiting_count: state.waiting_count - 1})

      {:empty, _waiting} ->
        state
    end
  end

  defp post(payload, %__MODULE__{url: url, http_client: {module, options}} = state) do
    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        Logger.metadata(rollbax: false)
        request(module, url, payload, options)
      end)

    %{state | in_flight: MapSet.put(state.in_flight, task.ref)}
  end

  defp request(module, url, payload, options) do
    module.post(url, @headers, payload, options)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp compose_json(draft, event) do
    draft
    |> Item.compose(event)
    |> Jason.encode_to_iodata()
  end

  defp event_to_chardata({level, timestamp, body, custom, occurrence_data}) do
    [
      inspect(body),
      "\nLevel: ",
      level,
      "\nTimestamp: ",
      Integer.to_string(timestamp),
      "\nCustom data: ",
      inspect(custom),
      "\nOccurrence data: ",
      inspect(occurrence_data)
    ]
  end

  defp handle_response({:ok, status, headers, body}, state)
       when is_integer(status) and is_list(headers) do
    if status != 200 do
      Logger.error("(Rollbax) unexpected API status: #{status}")
    end

    Logger.debug("(Rollbax) API headers: #{inspect(headers)}")
    log_body(body)

    with 429 <- status,
         :ok <- schedule_rate_limit_lifting(headers) do
      %{state | rate_limited?: true}
    else
      _other -> state
    end
  end

  defp handle_response({:error, reason}, state) do
    Logger.error("(Rollbax) connection error: #{format_error(reason)}")
    state
  end

  defp handle_response(other, state) do
    Logger.error("(Rollbax) the HTTP client returned an unexpected value: #{inspect(other)}")
    state
  end

  defp log_body(body) do
    case Jason.decode(body) do
      {:ok, %{"err" => 1, "message" => message}} when is_binary(message) ->
        Logger.error("(Rollbax) API returned an error: #{inspect(message)}")

      {:ok, response} ->
        Logger.debug("(Rollbax) API response: #{inspect(response)}")

      {:error, _} ->
        Logger.error("(Rollbax) API returned malformed JSON: #{inspect(body)}")
    end
  end

  defp format_error(%{__exception__: true} = exception), do: Exception.message(exception)
  defp format_error(reason), do: inspect(reason)

  # It is possible that we receive multiple rate limited responses.
  # Ideally, we should schedule rate limit lifting only once.
  defp schedule_rate_limit_lifting(headers) do
    with remaining_seconds when is_binary(remaining_seconds) <- rate_limit_remaining(headers),
         {remaining_seconds, ""} <- Integer.parse(remaining_seconds) do
      Process.send_after(self(), :lift_rate_limiting, remaining_seconds * 1_000)
      :ok
    else
      _other -> :error
    end
  end

  defp rate_limit_remaining(headers) do
    Enum.find_value(headers, fn
      {name, value} when is_binary(name) ->
        if String.downcase(name) == "x-rate-limit-remaining-seconds", do: value

      _other ->
        nil
    end)
  end
end
