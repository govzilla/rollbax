defmodule Rollbax.Reporter.Standard do
  @moduledoc """
  A `Rollbax.Reporter` that translates crashes and exits from processes to nicely-formatted
  Rollbar exceptions.

  It reports the events that carry a `:crash_reason` in their metadata, which is how Elixir
  logs a GenServer, a task or a plain process that terminated abnormally, and, from Elixir
  1.17 on, a state machine.
  Libraries that log their own crashes that way are reported too. Everything else is left to
  the next reporter.

  The logged message is sent as the `"log"` custom value. For a GenServer it holds the last
  message it received, and its state as well when the Logger level is `:debug`.
  """

  @behaviour Rollbax.Reporter

  # The longest logged message sent along with an exception.
  @max_log_bytes 8_000

  @impl true
  def handle_event(_level, %{meta: %{crash_reason: {reason, stacktrace}}} = event)
      when is_list(stacktrace) do
    log = logged_message(event)
    {class, message} = class_and_message(terminated(event, log), reason, stacktrace)

    %Rollbax.Exception{
      class: class,
      message: message,
      stacktrace: stacktrace,
      custom: custom(log)
    }
  end

  def handle_event(_level, _event) do
    :next
  end

  # What terminated. Elixir 1.19 and later hand the handler the report OTP logged, with its
  # label; earlier versions hand it the translated message, which opens by naming it.
  defp terminated(%{msg: {:report, %{label: label}}}, _log), do: terminated_by_label(label)
  defp terminated(_event, log), do: terminated_by_message(log)

  defp terminated_by_label({:gen_server, :terminate}), do: "GenServer terminating"
  defp terminated_by_label({Task.Supervisor, :terminating}), do: "Task terminating"
  defp terminated_by_label({:gen_statem, :terminate}), do: "State machine terminating"
  defp terminated_by_label({:gen_event, :terminate}), do: "gen_event handler terminating"
  defp terminated_by_label(_label), do: nil

  defp terminated_by_message("GenServer " <> _), do: "GenServer terminating"
  defp terminated_by_message("Task " <> _), do: "Task terminating"
  defp terminated_by_message(":gen_statem " <> _), do: "State machine terminating"
  defp terminated_by_message(":gen_event handler " <> _), do: "gen_event handler terminating"
  defp terminated_by_message("Process " <> _), do: "error in process"
  defp terminated_by_message(_log), do: nil

  defp class_and_message(terminated, reason, stacktrace) do
    case normalize(reason, stacktrace) do
      {:exception, exception} ->
        {with_detail(terminated, inspect(exception.__struct__)), Exception.message(exception)}

      :exit ->
        {terminated || "exit", Exception.format_exit(reason)}

      :stop ->
        {with_detail(terminated, "stop"), Exception.format_exit(reason)}
    end
  end

  defp normalize(reason, _stacktrace) when is_exception(reason), do: {:exception, reason}

  # An Erlang error that Elixir knows as an exception, such as `{:badmap, term}`, may arrive
  # as the bare reason. Anything else that comes with a stacktrace is an exit.
  defp normalize(reason, [_ | _] = stacktrace) do
    case Exception.normalize(:error, reason, stacktrace) do
      %ErlangError{} -> :exit
      exception -> {:exception, exception}
    end
  end

  # No stacktrace: the process was told to stop, or returned a stop of its own.
  defp normalize(_reason, []), do: :stop

  defp with_detail(nil, detail), do: detail
  defp with_detail(terminated, detail), do: terminated <> " (" <> detail <> ")"

  defp logged_message(%{msg: {:string, chardata}}), do: to_log(chardata)
  defp logged_message(%{msg: {:report, %{elixir_translation: chardata}}}), do: to_log(chardata)
  defp logged_message(_event), do: ""

  defp to_log(chardata) do
    IO.chardata_to_string(chardata)
  rescue
    _error -> ""
  end

  defp custom(""), do: %{}

  defp custom(log) when byte_size(log) > @max_log_bytes do
    %{"log" => truncate(binary_part(log, 0, @max_log_bytes)) <> " (truncated)"}
  end

  defp custom(log), do: %{"log" => log}

  # The cut may have fallen inside a character, whose first bytes are then dropped too.
  defp truncate(binary) do
    if String.valid?(binary) or binary == "" do
      binary
    else
      truncate(binary_part(binary, 0, byte_size(binary) - 1))
    end
  end
end
