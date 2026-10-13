defmodule Rollbax.Reporter.Messages do
  @moduledoc """
  A `Rollbax.Reporter` that reports to Rollbar, as messages, the errors logged without a
  crash behind them: a plain `Logger.error("payment gateway unreachable")`.

  It is not among the default reporters. Put it after `Rollbax.Reporter.Standard`, which
  reports the crashes:

      config :rollbax,
        enable_crash_reports: true,
        reporters: [Rollbax.Reporter.Standard, Rollbax.Reporter.Messages]

  An event logged at `:error` becomes a Rollbar message of level `error`; one logged at
  `:critical`, `:alert` or `:emergency`, of level `critical`. The message is cut at 8,000
  bytes. Where the event was logged from is sent as the `"file"`, `"line"` and `"function"`
  custom values, when known; none of the other metadata of the event is.

  Every error the application and its libraries log goes to Rollbar this way, so it is worth
  pairing it with `:dedupe_window` (see `Rollbax`).
  """

  @behaviour Rollbax.Reporter

  @max_body_bytes 8_000

  @impl true
  def handle_event(_level, %{meta: %{crash_reason: _crash_reason}}), do: :next

  def handle_event(level, %{msg: msg, meta: meta}) do
    case body(msg) do
      "" ->
        :next

      body ->
        %Rollbax.Message{level: rollbar_level(level), body: body, custom: logged_from(meta)}
    end
  end

  defp rollbar_level(level) when level in [:critical, :alert, :emergency], do: :critical
  defp rollbar_level(_level), do: :error

  defp body({:string, chardata}), do: chardata |> to_text() |> cut()
  defp body({:report, %{elixir_translation: chardata}}), do: chardata |> to_text() |> cut()
  defp body({:report, report}), do: report |> inspect(limit: 50) |> cut()

  defp body({format, arguments}) when is_list(arguments) do
    format |> :io_lib.format(arguments) |> to_text() |> cut()
  rescue
    _error -> ""
  end

  defp body(_msg), do: ""

  defp to_text(chardata) do
    IO.chardata_to_string(chardata)
  rescue
    _error -> ""
  end

  defp cut(text) when byte_size(text) > @max_body_bytes do
    valid_prefix(binary_part(text, 0, @max_body_bytes)) <> " (truncated)"
  end

  defp cut(text), do: text

  # The cut may have fallen inside a character, whose first bytes are then dropped too.
  defp valid_prefix(binary) do
    if String.valid?(binary) or binary == "" do
      binary
    else
      valid_prefix(binary_part(binary, 0, byte_size(binary) - 1))
    end
  end

  defp logged_from(meta) do
    %{}
    |> put_file(meta)
    |> put_line(meta)
    |> put_function(meta)
  end

  defp put_file(custom, %{file: file}) when is_binary(file) or is_list(file),
    do: Map.put(custom, "file", to_text(file))

  defp put_file(custom, _meta), do: custom

  defp put_line(custom, %{line: line}) when is_integer(line), do: Map.put(custom, "line", line)
  defp put_line(custom, _meta), do: custom

  defp put_function(custom, %{mfa: {module, function, arity}})
       when is_atom(module) and is_atom(function) and is_integer(arity),
       do: Map.put(custom, "function", Exception.format_mfa(module, function, arity))

  defp put_function(custom, _meta), do: custom
end
