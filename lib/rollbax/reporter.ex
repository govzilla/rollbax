defmodule Rollbax.Reporter do
  @moduledoc """
  Behaviour to be implemented by Rollbax reporters that wish to report logged events to
  Rollbar. See `Rollbax.Logger` for more information.
  """

  @doc """
  Decides what to do with an event logged at `level`.

  `event` is the event as `:logger` hands it to its handlers: a map with the `:level`, the
  `:msg` and the `:meta` (metadata) of the event. Crashes carry the reason and the stacktrace
  in `event.meta.crash_reason`.
  """
  @callback handle_event(level :: :logger.level(), event :: :logger.log_event()) ::
              Rollbax.Exception.t() | Rollbax.Message.t() | :next | :ignore
end
