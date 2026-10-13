defmodule Rollbax.Logger do
  @moduledoc """
  A `:logger` handler that reports crashes and exits to Rollbar.

  When a GenServer, a task or any other process crashes, Elixir logs it with the reason
  and the stacktrace in the `:crash_reason` metadata. This handler turns those events
  into Rollbar exceptions.

  It is installed by the `:rollbax` application when crash reports are enabled:

      config :rollbax, :enable_crash_reports, true

  `Rollbax.Logger` implements a mechanism of reporting based on *reporters*, which are modules
  that implement the `Rollbax.Reporter` behaviour. Every event received by `Rollbax.Logger` is
  run through a list of reporters and the behaviour is determined by the return value of each
  reporter's `c:Rollbax.Reporter.handle_event/2` callback:

    * when the callback returns a `Rollbax.Exception` struct, the exception is reported to Rollbar
      and no other reporters are called

    * when the callback returns a `Rollbax.Message` struct, the message is reported to Rollbar
      and no other reporters are called

    * when the callback returns `:next`, the reporter is skipped and Rollbax moves on to the next
      reporter

    * when the callback returns `:ignore`, the event is ignored and no more reporters are tried.

  An event no reporter turns into an exception is not reported.

  The list of reporters can be configured in the `:reporters` key in the `:rollbax` application
  configuration. By default this list only contains `Rollbax.Reporter.Standard` (see its
  documentation for more information). Rollbax also comes equipped with
  `Rollbax.Reporter.Messages`, which reports the errors logged without a crash behind them, and
  with a `Rollbax.Reporter.Silencing` reporter that doesn't report anything it receives. For examples on
  how to provide your own reporters, look at the source for `Rollbax.Reporter.Standard`.

  Events logged on another node never reach the reporters. Neither do the ones Rollbax logs
  itself, nor what the supervisor of the tasks posting its reports logs when one of them dies.

  ## Configuration

  The following reporting-related options can be used to configure the `:rollbax` application:

    * `:enable_crash_reports` (boolean) - when `true`, `Rollbax.Logger` is added as a `:logger`
      handler and the whole reporting flow described above is executed.

    * `:reporters` (list) - a list of modules implementing the `Rollbax.Reporter` behaviour.
      Defaults to `[Rollbax.Reporter.Standard]`.

  """

  @handler_id __MODULE__
  @reporting {__MODULE__, :reporting}

  @doc false
  @spec attach([module]) :: :ok | {:error, term}
  def attach(reporters) when is_list(reporters) do
    _ = :logger.remove_handler(@handler_id)

    :logger.add_handler(@handler_id, __MODULE__, %{level: :error, config: %{reporters: reporters}})
  end

  @doc false
  @spec detach() :: :ok | {:error, term}
  def detach() do
    :logger.remove_handler(@handler_id)
  end

  # :logger handler callback. It runs in the process that logged the event, and a handler
  # that raises is removed, so nothing a reporter does may escape from here.
  @doc false
  def log(%{level: level, meta: meta} = event, %{config: %{reporters: reporters}}) do
    if reportable?(meta) and not Process.get(@reporting, false) do
      # What a reporter logs while it handles an event must not come back here.
      Process.put(@reporting, true)

      try do
        run_reporters(reporters, level, event)
      catch
        _kind, _reason -> :ok
      after
        Process.delete(@reporting)
      end
    end

    :ok
  end

  defp reportable?(%{rollbax: false}), do: false
  defp reportable?(%{gl: gl}) when node(gl) != node(), do: false
  defp reportable?(%{pid: pid}) when is_pid(pid), do: not Rollbax.Client.own_process?(pid)
  defp reportable?(_meta), do: true

  defp run_reporters([reporter | rest], level, event) do
    case reporter.handle_event(level, event) do
      %Rollbax.Exception{} = exception ->
        Rollbax.report_exception(exception)

      %Rollbax.Message{} = message ->
        Rollbax.report_message(
          message.level,
          message.body,
          message.custom,
          message.occurrence_data
        )

      :next ->
        run_reporters(rest, level, event)

      :ignore ->
        :ok
    end
  end

  defp run_reporters([], _level, _event) do
    :ok
  end
end
