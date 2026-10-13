defmodule Rollbax.HTTPClientTest do
  use ExUnit.RollbaxCase

  alias Rollbax.Client

  defmodule RecordingClient do
    @behaviour Rollbax.HTTPClient

    # Tells the test what was posted and answers with what the test asked for. With
    # `hold: true` the request stays open until the test sends `:answer`.
    @impl true
    def post(url, headers, body, options) do
      send(Keyword.fetch!(options, :test), {:posted, self(), url, headers, body})

      if options[:hold] do
        receive do
          :answer -> :ok
        end
      end

      case Keyword.get(options, :answer, {:ok, 200, [], "{}"}) do
        :raise -> raise "the client failed"
        answer -> answer
      end
    end
  end

  defmodule NotAClient do
    def post(_url), do: :ok
  end

  @body %{"message" => %{"body" => "pass"}}

  defp start_client(options, extra \\ []) do
    {:ok, pid} =
      start_rollbax_client(
        "token1",
        "test",
        %{},
        "http://rollbar.test/item/",
        {RecordingClient, [test: self()] ++ options},
        extra
      )

    pid
  end

  defp emit(), do: Client.emit(:error, System.system_time(:second), @body, %{}, %{})

  test "reports are posted through the configured client" do
    start_client([])
    :ok = emit()

    assert_receive {:posted, _task, "http://rollbar.test/item/", headers, body}
    assert headers == [{"content-type", "application/json"}]
    assert %{"access_token" => "token1", "data" => %{"body" => @body}} = Jason.decode!(body)
  end

  test "a failure of the client is logged" do
    start_client(answer: {:error, :nxdomain})
    assert capture_log(&emit/0) =~ "[error] (Rollbax) connection error: :nxdomain"
  end

  test "a client that raises is logged and does not stop later reports" do
    start_client(answer: :raise)

    log =
      capture_log(fn ->
        :ok = emit()
        assert_receive {:posted, _task, _url, _headers, _body}
      end)

    assert log =~ "[error] (Rollbax) connection error: {:error, %RuntimeError{"

    quietly(fn ->
      :ok = emit()
      assert_receive {:posted, _task, _url, _headers, _body}
    end)
  end

  test "an answer whose body is not a binary is logged and does not stop later reports" do
    client = start_client(answer: {:ok, 200, [], %{"err" => 0}})

    log =
      capture_log(fn ->
        :ok = emit()
        assert_receive {:posted, _task, _url, _headers, _body}
      end)

    assert log =~ "[error] (Rollbax) the HTTP client returned an unexpected value"
    assert Process.alive?(client)

    quietly(fn ->
      :ok = emit()
      assert_receive {:posted, _task, _url, _headers, _body}
    end)
  end

  test "a report nobody answers is abandoned at the report timeout and frees its place" do
    client = start_client([hold: true], report_timeout: 100)

    log =
      capture_log(fn ->
        :ok = emit()
        assert_receive {:posted, task, _url, _headers, _body}
        monitor = Process.monitor(task)
        assert_receive {:DOWN, ^monitor, :process, ^task, _reason}, 2_000
      end)

    assert log =~ "[error] (Rollbax) connection error: no answer in 100 ms"
    assert :sys.get_state(client).in_flight == %{}
  end

  for seconds <- ["-1", "86401", "999999999999999999999", "soon", ""] do
    test "a rate limit of #{inspect(seconds)} seconds is not honoured" do
      header = {"x-rate-limit-remaining-seconds", unquote(seconds)}
      client = start_client(answer: {:ok, 429, [header], "{}"})

      capture_log(fn ->
        :ok = emit()
        assert_receive {:posted, _task, _url, _headers, _body}
      end)

      assert Process.alive?(client)
      refute :sys.get_state(client).rate_limited?
    end
  end

  test "only the timer of the latest rate limit lifts it" do
    header = {"x-rate-limit-remaining-seconds", "60"}
    client = start_client(answer: {:ok, 429, [header], "{}"})

    capture_log(fn ->
      :ok = emit()
      assert_receive {:posted, _task, _url, _headers, _body}
    end)

    assert %{rate_limited?: true, rate_limit_timer: {timer_id, _timer}} = :sys.get_state(client)

    send(client, {:lift_rate_limiting, make_ref()})
    assert :sys.get_state(client).rate_limited?

    send(client, {:lift_rate_limiting, timer_id})
    refute :sys.get_state(client).rate_limited?
  end

  test "a rate limit of zero seconds is lifted at once" do
    header = {"x-rate-limit-remaining-seconds", "0"}
    client = start_client(answer: {:ok, 429, [header], "{}"})

    capture_log(fn ->
      :ok = emit()
      assert_receive {:posted, _task, _url, _headers, _body}
    end)

    Process.sleep(50)
    refute :sys.get_state(client).rate_limited?
  end

  test "reports beyond what the client can hold are dropped before they reach its mailbox" do
    client = start_client(hold: true)
    :sys.suspend(client)

    Enum.each(1..1_500, fn _ -> :ok = emit() end)

    assert {:message_queue_len, 1_000} = Process.info(client, :message_queue_len)
    :sys.resume(client)
  end

  test "the rate limiting header is read whatever its case" do
    start_client(answer: {:ok, 429, [{"X-Rate-Limit-Remaining-Seconds", "60"}], "{}"})

    capture_log(fn ->
      :ok = emit()
      assert_receive {:posted, _task, _url, _headers, _body}
    end)

    assert capture_log(&emit/0) =~ "(Rollbax) ignored report due to rate limiting"
    refute_receive {:posted, _task, _url, _headers, _body}
  end

  test "only twenty reports are posted at once and the rest wait" do
    start_client(hold: true)
    Enum.each(1..25, fn _ -> :ok = emit() end)

    tasks =
      for _ <- 1..20 do
        assert_receive {:posted, task, _url, _headers, _body}
        task
      end

    refute_receive {:posted, _task, _url, _headers, _body}

    Enum.each(tasks, &send(&1, :answer))

    for _ <- 1..5 do
      assert_receive {:posted, task, _url, _headers, _body}
      send(task, :answer)
    end

    refute_receive {:posted, _task, _url, _headers, _body}
  end

  describe "the :http_client configuration" do
    test "defaults to the Req client" do
      assert Client.http_client(nil) == {Rollbax.HTTPClient.Req, []}
    end

    test "takes a module, with or without options" do
      assert Client.http_client(RecordingClient) == {RecordingClient, []}

      assert Client.http_client({RecordingClient, test: self()}) ==
               {RecordingClient, test: self()}
    end

    test "refuses a module that is not a client" do
      assert_raise ArgumentError, ~r/does not implement the Rollbax.HTTPClient behaviour/, fn ->
        Client.http_client(NotAClient)
      end
    end

    test "refuses a module that does not exist" do
      assert_raise ArgumentError, ~r/DoesNotExist is not available/, fn ->
        Client.http_client(DoesNotExist)
      end
    end

    test "refuses anything else" do
      assert_raise ArgumentError, ~r/must be a module or a {module, options} tuple/, fn ->
        Client.http_client("https://proxy")
      end
    end
  end

  test "the Req client reads headers with a list of values or with a single one" do
    assert Rollbax.HTTPClient.Req.headers_to_list(%{"a" => ["1", "2"], "b" => ["3"]}) ==
             [{"a", "1"}, {"a", "2"}, {"b", "3"}]

    assert Rollbax.HTTPClient.Req.headers_to_list([{"a", "1"}, {"b", "3"}]) ==
             [{"a", "1"}, {"b", "3"}]
  end

  test "the Req client sends the headers configured for it along with its own" do
    {:ok, _server} = RollbarAPI.start(self(), 4005)
    on_exit(&RollbarAPI.stop/0)

    body = Jason.encode!(%{"data" => %{"custom" => %{}}})
    options = [headers: [{"x-gateway-key", "secret"}, content_type: "text/plain"]]

    assert {:ok, 200, _headers, _body} =
             Rollbax.HTTPClient.Req.post(
               "http://localhost:4005",
               [{"content-type", "application/json"}],
               body,
               options
             )

    assert_receive {:api_request_headers, headers}
    assert {"x-gateway-key", "secret"} in headers
    assert for({"content-type", value} <- headers, do: value) == ["application/json"]
  end

  test "the Req client never decodes the body, whatever its options say" do
    {:ok, _server} = RollbarAPI.start(self(), 4005)
    on_exit(&RollbarAPI.stop/0)

    body = Jason.encode!(%{"data" => %{"custom" => %{}}})

    assert {:ok, 200, _headers, "{}"} =
             Rollbax.HTTPClient.Req.post("http://localhost:4005", [], body, decode_body: true)
  end

  test "an application that fails to start leaves no handler behind" do
    Application.put_env(:rollbax, :enabled, :log)
    Application.put_env(:rollbax, :enable_crash_reports, true)
    Application.put_env(:rollbax, :custom, :not_a_map)

    on_exit(fn ->
      Enum.each([:enabled, :enable_crash_reports, :custom], &Application.delete_env(:rollbax, &1))
    end)

    Process.flag(:trap_exit, true)

    quietly(fn ->
      assert {:error, _reason} = Rollbax.start(:normal, [])
    end)

    assert {:error, {:not_found, Rollbax.Logger}} = :logger.get_handler_config(Rollbax.Logger)
  end

  describe "the :report_timeout configuration" do
    test "defaults to a minute" do
      assert Client.report_timeout(nil) == 60_000
    end

    test "takes a positive number of milliseconds" do
      assert Client.report_timeout(250) == 250
    end

    for value <- [0, -1, "100", :infinity, 18_446_744_073_709_551_615] do
      test "refuses #{inspect(value)}" do
        assert_raise ArgumentError, ~r/:report_timeout must be a number of milliseconds/, fn ->
          Client.report_timeout(unquote(value))
        end
      end
    end
  end

  test "a failure that only looks like an exception is logged" do
    start_client(answer: {:error, %{__exception__: true}})
    assert capture_log(&emit/0) =~ "[error] (Rollbax) connection error: %{__exception__: true}"
  end

  test "abandoning a report does not wait for its task" do
    client = start_client([hold: true], report_timeout: 50)

    capture_log(fn ->
      :ok = emit()
      assert_receive {:posted, task, _url, _headers, _body}
      monitor = Process.monitor(task)
      assert_receive {:DOWN, ^monitor, :process, ^task, :killed}, 2_000
    end)

    {microseconds, _state} = :timer.tc(fn -> :sys.get_state(client) end)
    assert microseconds < 1_000_000
  end

  test "the application refuses to start with the removed :proxy option" do
    Application.put_env(:rollbax, :proxy, "http://localhost:7004")
    on_exit(fn -> Application.delete_env(:rollbax, :proxy) end)

    assert_raise ArgumentError, ~r/:proxy is no longer supported/, fn ->
      Rollbax.start(:normal, [])
    end
  end
end
