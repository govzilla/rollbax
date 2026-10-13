defmodule Rollbax.Telemetry do
  @moduledoc """
  The [`:telemetry`](https://hexdocs.pm/telemetry) events Rollbax emits about what becomes
  of each report.

  Every event has the measurement `:count`, the number of reports it speaks of.

    * `[:rollbax, :report, :posted]` - Rollbar answered a report. The metadata has the
      `:status` of the answer, which is not `200` when Rollbar refused the report.

    * `[:rollbax, :report, :failed]` - a report was posted and no answer came. The metadata
      has the `:reason`: what the HTTP client returned as the error, `:timeout` when the
      report was abandoned at `:report_timeout`, `{:exit, reason}` when the task posting it
      died, or `:unexpected_response`.

    * `[:rollbax, :report, :dropped]` - a report was not posted. The metadata has the
      `:reason`:

        * `:rate_limited` - Rollbar asked for no more reports for a while
        * `:queue_full` - too many reports were already waiting
        * `:duplicate` - a report like it was sent within `:dedupe_window`
        * `:before_send` - the `:before_send` callback returned `nil` or failed
        * `:invalid` - the report could not be encoded as JSON
        * `:shutdown` - the application stopped before the report left

  ## Example

      :telemetry.attach(
        "rollbax-dropped",
        [:rollbax, :report, :dropped],
        fn _event, %{count: count}, %{reason: reason}, _config ->
          MyApp.Metrics.increment("rollbax.dropped", count, tags: [reason: reason])
        end,
        nil
      )

  """

  @doc false
  def posted(status) when is_integer(status) do
    :telemetry.execute([:rollbax, :report, :posted], %{count: 1}, %{status: status})
  end

  @doc false
  def failed(reason) do
    :telemetry.execute([:rollbax, :report, :failed], %{count: 1}, %{reason: reason})
  end

  @doc false
  def dropped(reason, count \\ 1) when is_atom(reason) and is_integer(count) and count > 0 do
    :telemetry.execute([:rollbax, :report, :dropped], %{count: count}, %{reason: reason})
  end
end
