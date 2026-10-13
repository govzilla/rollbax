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
  @default_max_concurrency 20
  @default_max_queue 1_000
  @max_queue_key {__MODULE__, :max_queue}
  @default_report_timeout 60_000
  @default_flush_timeout 5_000
  # The longest wait an Erlang timer takes, in milliseconds.
  @max_timer 4_294_967_295
  # The longest Rollbar may ask us to hold reports for, in seconds.
  @max_rate_limit_seconds 86_400

  ## GenServer state

  defstruct [
    :draft,
    :url,
    :enabled,
    :http_client,
    :task_supervisor,
    rate_limited?: false,
    rate_limit_timer: nil,
    report_timeout: @default_report_timeout,
    max_concurrency: @default_max_concurrency,
    max_queue: @default_max_queue,
    before_send: nil,
    flush_timeout: @default_flush_timeout,
    in_flight: %{},
    waiting: :queue.new(),
    waiting_count: 0
  ]

  ## Public API

  # The supervisor waits for the flush before it gives up on the client.
  def child_spec(config) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [config]},
      shutdown: flush_timeout(config[:flush_timeout]) + 1_000
    }
  end

  def start_link(config) do
    state = %__MODULE__{
      draft:
        Item.draft(
          config[:access_token],
          config[:environment],
          config[:custom],
          code_version(config[:code_version])
        ),
      url: config[:api_endpoint],
      enabled: config[:enabled],
      http_client: http_client(config[:http_client]),
      report_timeout: report_timeout(config[:report_timeout]),
      max_concurrency:
        limit(:max_concurrency, config[:max_concurrency], @default_max_concurrency),
      max_queue: limit(:max_queue, config[:max_queue], @default_max_queue),
      before_send: before_send(config[:before_send]),
      flush_timeout: flush_timeout(config[:flush_timeout])
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

  @doc """
  Returns the `:flush_timeout` configuration, in milliseconds.
  """
  def flush_timeout(nil), do: @default_flush_timeout

  def flush_timeout(timeout) when is_integer(timeout) and timeout in 0..@max_timer//1,
    do: timeout

  def flush_timeout(other) do
    raise ArgumentError,
          ":flush_timeout must be a number of milliseconds between 0 and #{@max_timer}, " <>
            "got: #{inspect(other)}"
  end

  @doc """
  Returns the `:code_version` configuration.
  """
  def code_version(nil), do: nil

  def code_version(code_version) when is_binary(code_version) and code_version != "",
    do: code_version

  def code_version(other) do
    raise ArgumentError, ":code_version must be a non-empty string, got: #{inspect(other)}"
  end

  @doc """
  Returns the `:before_send` configuration, or raises when it cannot be called.
  """
  def before_send(nil), do: nil
  def before_send(fun) when is_function(fun, 1), do: fun

  def before_send({module, function} = callback) when is_atom(module) and is_atom(function) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, 1) do
      callback
    else
      raise ArgumentError, ":before_send #{inspect(module)}.#{function}/1 is not defined"
    end
  end

  def before_send(other) do
    raise ArgumentError,
          ":before_send must be a {module, function} tuple or a function of one argument, " <>
            "got: #{inspect(other)}"
  end

  @doc """
  Returns the `:max_concurrency` or `:max_queue` configuration `value`, or `default`.
  """
  def limit(_name, nil, default), do: default
  def limit(_name, value, _default) when is_integer(value) and value > 0, do: value

  def limit(name, other, _default) do
    raise ArgumentError, "#{inspect(name)} must be a positive integer, got: #{inspect(other)}"
  end

  @doc """
  Returns the `:report_timeout` configuration, in milliseconds.
  """
  def report_timeout(nil), do: @default_report_timeout

  def report_timeout(timeout) when is_integer(timeout) and timeout in 1..@max_timer//1,
    do: timeout

  def report_timeout(other) do
    raise ArgumentError,
          ":report_timeout must be a number of milliseconds between 1 and #{@max_timer}, " <>
            "got: #{inspect(other)}"
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
      # In a storm of errors the reports that would only pile up in the mailbox are dropped
      # here, before they are copied to it. Callers racing each other may overshoot the
      # limit by a few reports.
      if mailbox_has_room?(pid) do
        event = {Atom.to_string(level), timestamp, body, custom, occurrence_data}
        GenServer.cast(pid, {:emit, event})
      else
        :ok
      end
    else
      Logger.warning(
        "(Rollbax) Trying to report an exception but the :rollbax application has not been started",
        rollbax: false
      )
    end
  end

  defp mailbox_has_room?(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, length} ->
        length < :persistent_term.get(@max_queue_key, @default_max_queue)

      nil ->
        true
    end
  end

  ## GenServer callbacks

  @impl true
  def init(%__MODULE__{} = state) do
    Logger.metadata(rollbax: false)
    # So that terminate/2 runs when the supervisor stops the client.
    Process.flag(:trap_exit, true)
    {:ok, task_supervisor} = Task.Supervisor.start_link()
    # Read by emit/5, which runs in the process reporting.
    :persistent_term.put(@max_queue_key, state.max_queue)
    {:ok, %{state | task_supervisor: task_supervisor}}
  end

  @impl true
  def handle_cast({:emit, event}, %__MODULE__{} = state) do
    {:noreply, emitted(state, event)}
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %__MODULE__{task_supervisor: pid} = state) do
    {:stop, reason, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(message, %__MODULE__{} = state) do
    case answered(state, message) do
      {:ok, state} ->
        {:noreply, state}

      :unknown ->
        Logger.info("(Rollbax) unexpected message: #{inspect(message)}")
        {:noreply, state}
    end
  end

  # Before the client stops it gives the reports it still holds the chance to leave.
  @impl true
  def terminate(_reason, %__MODULE__{enabled: true} = state) do
    deadline = System.monotonic_time(:millisecond) + state.flush_timeout
    state = state |> flush(deadline) |> settle()

    # What did not leave in time is given up on: the tasks still posting are stopped, and
    # the reports nobody got to are counted with the rest.
    Enum.each(state.in_flight, fn {_ref, {pid, _deadline_timer}} -> Process.exit(pid, :kill) end)
    pending = map_size(state.in_flight) + state.waiting_count + discard_emitted(0)

    if pending > 0 do
      Logger.error("(Rollbax) #{pending} reports were not sent before the client stopped")
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp flush(%__MODULE__{} = state, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      remaining <= 0 ->
        state

      map_size(state.in_flight) == 0 and state.waiting_count == 0 ->
        # Nothing is on its way: only a report still in the mailbox keeps the flush going.
        receive do
          {:"$gen_cast", {:emit, event}} -> state |> emitted(event) |> flush(deadline)
        after
          0 -> state
        end

      true ->
        receive do
          {:"$gen_cast", {:emit, event}} ->
            state |> emitted(event) |> flush(deadline)

          message ->
            case answered(state, message) do
              {:ok, state} -> flush(state, deadline)
              :unknown -> flush(state, deadline)
            end
        after
          remaining -> state
        end
    end
  end

  # Takes the answers that arrived while the flush was busy with something else, so the
  # reports they belong to are not counted as left behind.
  defp settle(%__MODULE__{} = state) do
    receive do
      {ref, response} when is_reference(ref) and is_map_key(state.in_flight, ref) ->
        {:ok, state} = pop_in_flight(state, ref)
        Process.demonitor(ref, [:flush])
        state |> handle_response(response) |> settle()
    after
      0 -> state
    end
  end

  defp discard_emitted(count) do
    receive do
      {:"$gen_cast", {:emit, _event}} -> discard_emitted(count + 1)
    after
      0 -> count
    end
  end

  ## What the client does with a report and with the answers to the ones it posted

  defp emitted(%__MODULE__{rate_limited?: true} = state, _event) do
    Logger.info("(Rollbax) ignored report due to rate limiting")
    state
  end

  defp emitted(%__MODULE__{enabled: false} = state, _event), do: state

  defp emitted(%__MODULE__{enabled: :log} = state, event) do
    Logger.info(["(Rollbax) registered report.\n", event_to_chardata(event)])
    state
  end

  defp emitted(%__MODULE__{enabled: true} = state, event) do
    with {:ok, item} <- compose(state.draft, event, state.before_send),
         {:ok, payload} <- Jason.encode_to_iodata(item) do
      post_or_enqueue(payload, state)
    else
      :drop ->
        state

      {:error, exception} ->
        Logger.error([
          "(Rollbax) failed to encode report below ",
          "for reason: ",
          Exception.message(exception),
          ?\n,
          event_to_chardata(event)
        ])

        state
    end
  end

  defp answered(%__MODULE__{} = state, {ref, response}) when is_reference(ref) do
    case pop_in_flight(state, ref) do
      {:ok, state} ->
        Process.demonitor(ref, [:flush])
        {:ok, state |> handle_response(response) |> post_waiting()}

      :error ->
        {:ok, state}
    end
  end

  defp answered(%__MODULE__{} = state, {:DOWN, ref, :process, _pid, reason}) do
    case pop_in_flight(state, ref) do
      {:ok, state} ->
        Logger.error("(Rollbax) the task posting a report exited: #{inspect(reason)}")
        {:ok, post_waiting(state)}

      :error ->
        {:ok, state}
    end
  end

  defp answered(%__MODULE__{} = state, {:request_deadline, ref}) do
    case state.in_flight do
      %{^ref => {pid, _deadline_timer}} ->
        Logger.error("(Rollbax) connection error: no answer in #{state.report_timeout} ms")
        Process.demonitor(ref, [:flush])
        # Killed outright: waiting for the task to shut down would hold every other report.
        Process.exit(pid, :kill)
        {:ok, post_waiting(%{state | in_flight: Map.delete(state.in_flight, ref)})}

      %{} ->
        {:ok, state}
    end
  end

  # Only the timer of the latest rate limit lifts it.
  defp answered(
         %__MODULE__{rate_limit_timer: {timer_id, _}} = state,
         {:lift_rate_limiting, timer_id}
       ) do
    {:ok, %{state | rate_limited?: false, rate_limit_timer: nil}}
  end

  defp answered(%__MODULE__{} = state, {:lift_rate_limiting, _timer_id}), do: {:ok, state}
  defp answered(%__MODULE__{}, _message), do: :unknown

  ## Helper functions

  defp post_or_enqueue(payload, %__MODULE__{} = state) do
    cond do
      map_size(state.in_flight) < state.max_concurrency ->
        post(payload, state)

      state.waiting_count < state.max_queue ->
        %{
          state
          | waiting: :queue.in(payload, state.waiting),
            waiting_count: state.waiting_count + 1
        }

      true ->
        Logger.error(
          "(Rollbax) dropped report: #{state.max_queue} reports are already waiting to be sent"
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

    deadline_timer =
      Process.send_after(self(), {:request_deadline, task.ref}, state.report_timeout)

    %{state | in_flight: Map.put(state.in_flight, task.ref, {task.pid, deadline_timer})}
  end

  defp pop_in_flight(%__MODULE__{} = state, ref) do
    case Map.pop(state.in_flight, ref) do
      {{_pid, deadline_timer}, in_flight} ->
        _ = Process.cancel_timer(deadline_timer)
        {:ok, %{state | in_flight: in_flight}}

      {nil, _in_flight} ->
        :error
    end
  end

  defp request(module, url, payload, options) do
    module.post(url, @headers, payload, options)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # `:before_send` sees the "data" of the item, never the access token next to it.
  defp compose(draft, event, before_send) do
    %{"data" => data} = item = Item.compose(draft, event)

    case apply_before_send(before_send, data) do
      {:ok, data} -> {:ok, %{item | "data" => data}}
      :drop -> :drop
    end
  end

  defp apply_before_send(nil, data), do: {:ok, data}

  defp apply_before_send(before_send, data) do
    case call_before_send(before_send, data) do
      %{} = data ->
        {:ok, data}

      drop when drop in [nil, false] ->
        :drop

      other ->
        Logger.error(
          "(Rollbax) dropped report: :before_send returned #{inspect(other)} instead of a map or nil"
        )

        :drop
    end
  catch
    # A report that could not be looked over is not sent.
    kind, reason ->
      Logger.error([
        "(Rollbax) dropped report: :before_send failed\n",
        Exception.format(kind, reason, __STACKTRACE__)
      ])

      :drop
  end

  defp call_before_send({module, function}, data), do: apply(module, function, [data])
  defp call_before_send(fun, data) when is_function(fun, 1), do: fun.(data)

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

  defp handle_response(state, {:ok, status, headers, body})
       when is_integer(status) and is_list(headers) and is_binary(body) do
    if status != 200 do
      Logger.error("(Rollbax) unexpected API status: #{status}")
    end

    Logger.debug("(Rollbax) API headers: #{inspect(headers)}")
    log_body(body)

    if status == 429, do: rate_limit(state, headers), else: state
  end

  defp handle_response(state, {:error, reason}) do
    Logger.error("(Rollbax) connection error: #{format_error(reason)}")
    state
  end

  defp handle_response(state, other) do
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

  defp format_error(exception) when is_exception(exception), do: Exception.message(exception)
  defp format_error(reason), do: inspect(reason)

  # Several rate limited responses may arrive in a row. Each one replaces the timer of the
  # one before, so the limit holds for as long as the latest response asked.
  defp rate_limit(%__MODULE__{} = state, headers) do
    with remaining_seconds when is_binary(remaining_seconds) <- rate_limit_remaining(headers),
         {seconds, ""} when seconds in 0..@max_rate_limit_seconds//1 <-
           Integer.parse(remaining_seconds) do
      cancel_rate_limit_timer(state.rate_limit_timer)
      timer_id = make_ref()
      timer = Process.send_after(self(), {:lift_rate_limiting, timer_id}, seconds * 1_000)
      %{state | rate_limited?: true, rate_limit_timer: {timer_id, timer}}
    else
      _other -> state
    end
  end

  defp cancel_rate_limit_timer({_timer_id, timer}), do: Process.cancel_timer(timer)
  defp cancel_rate_limit_timer(nil), do: :ok

  defp rate_limit_remaining(headers) do
    Enum.find_value(headers, fn
      {name, value} when is_binary(name) and is_binary(value) ->
        if String.downcase(name) == "x-rate-limit-remaining-seconds", do: value

      _other ->
        nil
    end)
  end
end
