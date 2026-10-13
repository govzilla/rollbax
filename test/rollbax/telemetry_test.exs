defmodule Rollbax.TelemetryTest do
  use ExUnit.RollbaxCase

  require Logger

  alias Rollbax.Client

  defmodule AnsweringClient do
    @behaviour Rollbax.HTTPClient

    @impl true
    def post(_url, _headers, _body, options) do
      if options[:hold] do
        receive do
          :answer -> :ok
        end
      end

      Keyword.fetch!(options, :answer)
    end
  end

  @body %{"message" => %{"body" => "pass"}}
  @events [
    [:rollbax, :report, :posted],
    [:rollbax, :report, :failed],
    [:rollbax, :report, :dropped]
  ]

  setup context do
    test = self()

    :telemetry.attach_many(
      context.test,
      @events,
      fn [:rollbax, :report, outcome], measurements, metadata, _config ->
        send(test, {outcome, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(context.test) end)
  end

  defp start_client(client_options, extra \\ []) do
    {:ok, pid} =
      start_rollbax_client(
        "token1",
        "test",
        %{},
        "http://rollbar.test/item/",
        {AnsweringClient, Keyword.put_new(client_options, :answer, {:ok, 200, [], "{}"})},
        extra
      )

    pid
  end

  defp emit(body \\ @body), do: Client.emit(:error, System.system_time(:second), body, %{}, %{})

  test "a report Rollbar answered is posted, with the status" do
    start_client([])
    quietly(&emit/0)

    assert_receive {:posted, %{count: 1}, %{status: 200}}
  end

  test "a report Rollbar refused is posted too, with its status" do
    start_client(answer: {:ok, 400, [], ~s({"err": 1, "message": "bad"})})
    quietly(&emit/0)

    assert_receive {:posted, %{count: 1}, %{status: 400}}
  end

  test "a report that got no answer has failed, with the reason" do
    start_client(answer: {:error, :nxdomain})
    quietly(&emit/0)

    assert_receive {:failed, %{count: 1}, %{reason: :nxdomain}}
  end

  test "a report abandoned at the report timeout has failed with :timeout" do
    start_client([hold: true], report_timeout: 50)
    quietly(&emit/0)

    assert_receive {:failed, %{count: 1}, %{reason: :timeout}}
  end

  test "a report made while rate limited is dropped" do
    header = {"x-rate-limit-remaining-seconds", "60"}
    start_client(answer: {:ok, 429, [header], "{}"})

    quietly(fn ->
      emit()
      assert_receive {:posted, %{count: 1}, %{status: 429}}
      emit()
    end)

    assert_receive {:dropped, %{count: 1}, %{reason: :rate_limited}}
  end

  test "a report that finds the queue full is dropped" do
    start_client([hold: true], max_concurrency: 1, max_queue: 1)

    # The first report is never answered, so there is no waiting for the client to settle.
    ExUnit.CaptureIO.capture_io(:user, fn ->
      Enum.each(1..3, fn _ -> emit() end)
      assert_receive {:dropped, %{count: 1}, %{reason: :queue_full}}
      Logger.flush()
    end)
  end

  test "a duplicate is dropped" do
    start_client([], dedupe_window: 60_000)

    quietly(fn ->
      emit()
      emit()
    end)

    assert_receive {:posted, %{count: 1}, %{status: 200}}
    assert_receive {:dropped, %{count: 1}, %{reason: :duplicate}}
  end

  test "a report :before_send keeps from being sent is dropped" do
    start_client([], before_send: fn _data -> nil end)
    quietly(&emit/0)

    assert_receive {:dropped, %{count: 1}, %{reason: :before_send}}
  end

  test "a report that cannot be encoded is dropped" do
    start_client([])
    quietly(fn -> emit(%{"message" => %{"body" => <<208>>}}) end)

    assert_receive {:dropped, %{count: 1}, %{reason: :invalid}}
  end

  test "the reports left when the client stops are dropped, in one event" do
    client = start_client([hold: true], max_concurrency: 1, flush_timeout: 50)

    ExUnit.CaptureIO.capture_io(:user, fn ->
      emit()
      emit()
      :ok = GenServer.stop(client)
      Logger.flush()
    end)

    assert_receive {:dropped, %{count: 2}, %{reason: :shutdown}}
  end
end
