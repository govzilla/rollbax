defmodule Rollbax.Message do
  @moduledoc """
  A message a `Rollbax.Reporter` wants reported to Rollbar, as `Rollbax.report_message/4`
  would report it.
  """

  @type t :: %__MODULE__{
          level: :critical | :error | :warning | :info | :debug,
          body: String.t(),
          custom: map,
          occurrence_data: map
        }

  defstruct [
    :body,
    level: :error,
    custom: %{},
    occurrence_data: %{}
  ]
end
