defmodule Rollbax.HTTPClientTest do
  use ExUnit.RollbaxCase

  require Logger

  alias Rollbax.Client

  defmodule RecordingClient do
    @behaviour Rollbax.HTTPClient

    # Tells the test what was posted and answers with what the test asked for. With
    # `hold: true` the request stays open until the test sends `:answer`, and with
    # `trap_exit: true` it outlives the supervisor of the tasks.
    @impl true
    def post(url, headers, body, options) do
      if options[:trap_exit], do: Process.flag(:trap_exit, true)
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

  describe "the :dedupe_window configuration" do
    defp posted_custom() do
      assert_receive {:posted, _task, _url, _headers, body}
      body |> IO.iodata_to_binary() |> Jason.decode!() |> get_in(["data", "custom"])
    end

    test "is off by default" do
      start_client([])
      :ok = emit()
      :ok = emit()

      assert_receive {:posted, _task, _url, _headers, _body}
      assert_receive {:posted, _task, _url, _headers, _body}
    end

    test "keeps a report like one just sent from being sent again" do
      start_client([], dedupe_window: 60_000)
      :ok = Client.emit(:error, System.system_time(:second), @body, %{attempt: 1}, %{})
      :ok = Client.emit(:error, System.system_time(:second), @body, %{attempt: 2}, %{})

      assert posted_custom() == %{"attempt" => 1}
      refute_receive {:posted, _task, _url, _headers, _body}
    end

    test "lets through a report with another level or another body" do
      start_client([], dedupe_window: 60_000)
      other_body = %{"message" => %{"body" => "something else"}}

      :ok = emit()
      :ok = Client.emit(:warning, System.system_time(:second), @body, %{}, %{})
      :ok = Client.emit(:error, System.system_time(:second), other_body, %{}, %{})

      for _ <- 1..3, do: assert_receive({:posted, _task, _url, _headers, _body})
    end

    test "once the window is over, sends the next one with the count of those left out" do
      start_client([], dedupe_window: 100)

      Enum.each(1..4, fn _ -> :ok = emit() end)
      assert posted_custom() == nil
      refute_receive {:posted, _task, _url, _headers, _body}

      :ok = emit()
      assert posted_custom() == %{"duplicates_dropped" => 3}
    end

    test "does not take a report the queue turned away for one that was sent" do
      client = start_client([hold: true], max_concurrency: 1, max_queue: 1, dedupe_window: 60_000)
      body = fn text -> %{"message" => %{"body" => text}} end

      emit_and_wait = fn text ->
        :ok = Client.emit(:error, System.system_time(:second), body.(text), %{}, %{})
        :sys.get_state(client)
      end

      capture_log(fn ->
        emit_and_wait.("a")
        emit_and_wait.("b")
        emit_and_wait.("turned away")

        assert_receive {:posted, first, _url, _headers, _body}
        send(first, :answer)
        assert_receive {:posted, second, _url, _headers, _body}
        send(second, :answer)
        await_client_idle()

        emit_and_wait.("turned away")
        assert_receive {:posted, third, _url, _headers, posted}
        send(third, :answer)

        assert posted |> IO.iodata_to_binary() |> Jason.decode!() |> get_in(["data", "body"]) ==
                 body.("turned away")
      end)
    end

    test "remembers a bounded number of reports" do
      client = start_client([], dedupe_window: 60_000)

      for n <- 1..1_100 do
        body = %{"message" => %{"body" => "report #{n}"}}
        :ok = Client.emit(:error, System.system_time(:second), body, %{}, %{})
        if rem(n, 100) == 0, do: :sys.get_state(client)
      end

      assert map_size(:sys.get_state(client).recent) == 1_000
    end

    test "when it must forget, forgets first what carries no count" do
      client = start_client([], dedupe_window: 50)

      for n <- 1..1_000 do
        body = %{"message" => %{"body" => "report #{n}"}}
        :ok = Client.emit(:error, System.system_time(:second), body, %{}, %{})
        if rem(n, 100) == 0, do: :sys.get_state(client)
      end

      # One more like the first, within the window: it is left out and counted.
      first = %{"message" => %{"body" => "report 1"}}
      :ok = Client.emit(:error, System.system_time(:second), first, %{}, %{})
      :sys.get_state(client)
      Process.sleep(80)

      # Every window is over. A new report makes room; the counted one stays.
      :ok = emit()
      recent = :sys.get_state(client).recent

      assert map_size(recent) == 2
      assert Enum.any?(recent, &match?({_key, {_expires_at, 1}}, &1))
    end

    for value <- [0, -5, "60000", :infinity] do
      test "refuses #{inspect(value)}" do
        assert_raise ArgumentError, ~r/:dedupe_window must be a number of milliseconds/, fn ->
          Client.dedupe_window(unquote(value))
        end
      end
    end
  end

  describe "when the client stops" do
    # The client is flushing once it sits in flush/2, which only terminate/2 calls.
    defp await_flushing(client, attempts \\ 100) do
      {:current_stacktrace, stacktrace} = Process.info(client, :current_stacktrace)

      cond do
        Enum.any?(stacktrace, &match?({Rollbax.Client, :flush, 2, _location}, &1)) -> :ok
        attempts == 0 -> flunk("the client did not start flushing")
        true -> Process.sleep(10) && await_flushing(client, attempts - 1)
      end
    end

    defp await_waiting(client, attempts \\ 100) do
      cond do
        Process.info(client, :status) == {:status, :waiting} -> :ok
        attempts == 0 -> flunk("the client did not start waiting")
        true -> Process.sleep(10) && await_waiting(client, attempts - 1)
      end
    end

    test "the reports it holds are given the flush timeout to leave" do
      client = start_client([hold: true], max_concurrency: 1, flush_timeout: 2_000)
      :ok = emit()
      :ok = emit()

      assert_receive {:posted, first, _url, _headers, _body}
      stopping = Task.async(fn -> GenServer.stop(client) end)
      await_flushing(client)

      send(first, :answer)
      assert_receive {:posted, second, _url, _headers, _body}
      send(second, :answer)

      assert Task.await(stopping) == :ok
    end

    test "a report still in its mailbox is sent too" do
      client = start_client([], flush_timeout: 2_000)

      :sys.suspend(client)
      :ok = emit()
      :ok = GenServer.stop(client)

      assert_receive {:posted, _task, _url, _headers, _body}
    end

    test "it gives up on them at the flush timeout, stops them and says how many were left" do
      client = start_client([hold: true], max_concurrency: 1, flush_timeout: 100)

      log =
        ExUnit.CaptureIO.capture_io(:user, fn ->
          :ok = emit()
          :ok = emit()
          assert_receive {:posted, task, _url, _headers, _body}
          monitor = Process.monitor(task)

          {microseconds, :ok} = :timer.tc(fn -> GenServer.stop(client) end)
          assert microseconds < 1_000_000
          assert_receive {:DOWN, ^monitor, :process, ^task, :killed}
          Logger.flush()
        end)

      assert log =~ "[error] (Rollbax) 2 reports were not sent before the client stopped"
    end

    test "it does not go past the flush timeout while reports keep arriving" do
      client =
        start_client([],
          flush_timeout: 100,
          before_send: fn data ->
            Process.sleep(30)
            data
          end
        )

      # Suspended, the client takes the fifty reports only once it is told to stop.
      log =
        ExUnit.CaptureIO.capture_io(:user, fn ->
          :sys.suspend(client)
          Enum.each(1..50, fn _ -> :ok = emit() end)

          {microseconds, :ok} = :timer.tc(fn -> GenServer.stop(client) end)
          assert microseconds < 1_000_000
          Logger.flush()
        end)

      assert log =~ ~r/\(Rollbax\) 4\d reports were not sent before the client stopped/
    end

    test "it gives up at once when the supervisor of its tasks is gone" do
      client =
        start_client([hold: true, trap_exit: true], max_concurrency: 1, flush_timeout: 5_000)

      log =
        ExUnit.CaptureIO.capture_io(:user, fn ->
          :ok = emit()
          :ok = emit()
          assert_receive {:posted, task, _url, _headers, _body}

          %{task_supervisor: task_supervisor} = :sys.get_state(client)
          client_monitor = Process.monitor(client)
          task_monitor = Process.monitor(task)
          Process.exit(task_supervisor, :kill)

          assert_receive {:DOWN, ^client_monitor, :process, ^client, _reason}, 1_000
          assert_receive {:DOWN, ^task_monitor, :process, ^task, :killed}
          Logger.flush()
        end)

      assert log =~ "[error] (Rollbax) 2 reports were not sent before the client stopped"
    end

    test "it counts what it could not post when that supervisor dies while it flushes" do
      client = start_client([hold: true], max_concurrency: 1, flush_timeout: 5_000)

      log =
        ExUnit.CaptureIO.capture_io(:user, fn ->
          :ok = emit()
          :ok = emit()
          assert_receive {:posted, task, _url, _headers, _body}

          %{task_supervisor: task_supervisor} = :sys.get_state(client)
          client_monitor = Process.monitor(client)
          spawn(fn -> GenServer.stop(client) end)
          await_flushing(client)
          await_waiting(client)

          # The client waits for an answer, past its look at the supervisor. It finds the
          # task dead first, and the report that was waiting has no supervisor to go through.
          :erlang.suspend_process(client)

          for pid <- [task, task_supervisor] do
            monitor = Process.monitor(pid)
            Process.exit(pid, :kill)
            assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}
          end

          :erlang.resume_process(client)

          assert_receive {:DOWN, ^client_monitor, :process, ^client, :normal}, 1_000
          Logger.flush()
        end)

      assert log =~ "[error] (Rollbax) the task posting a report exited: :killed"
      assert log =~ "[error] (Rollbax) 1 reports were not sent before the client stopped"
    end

    test "it does not wait when there is nothing left to send" do
      client = start_client([], flush_timeout: 5_000)

      {microseconds, :ok} = :timer.tc(fn -> GenServer.stop(client) end)
      assert microseconds < 1_000_000
    end
  end

  describe "the :flush_timeout configuration" do
    test "defaults to five seconds and takes zero" do
      assert Client.flush_timeout(nil) == 5_000
      assert Client.flush_timeout(0) == 0
    end

    for value <- [-1, "100", :infinity] do
      test "refuses #{inspect(value)}" do
        assert_raise ArgumentError, ~r/:flush_timeout must be a number of milliseconds/, fn ->
          Client.flush_timeout(unquote(value))
        end
      end
    end

    test "gives the supervisor a second more than the flush to stop the client" do
      assert %{shutdown: 3_500} = Client.child_spec(flush_timeout: 2_500)
    end
  end

  describe "the :code_version configuration" do
    test "is sent with every report" do
      start_client([], code_version: "1.4.2")
      :ok = emit()

      assert_receive {:posted, _task, _url, _headers, body}

      assert %{"data" => %{"code_version" => "1.4.2"}} =
               body |> IO.iodata_to_binary() |> Jason.decode!()
    end

    test "is left out when it is not set" do
      start_client([])
      :ok = emit()

      assert_receive {:posted, _task, _url, _headers, body}

      refute body
             |> IO.iodata_to_binary()
             |> Jason.decode!()
             |> Map.fetch!("data")
             |> Map.has_key?("code_version")
    end

    for value <- ["", 142, :v1] do
      test "refuses #{inspect(value)}" do
        assert_raise ArgumentError, ~r/:code_version must be a non-empty string/, fn ->
          Client.code_version(unquote(value))
        end
      end
    end
  end

  describe "the :before_send configuration" do
    defmodule Redactor do
      def redact(data), do: put_in(data, ["body", "message", "body"], "[redacted]")
    end

    test "takes a function or a {module, function} pair" do
      fun = fn data -> data end

      assert Client.before_send(nil) == nil
      assert Client.before_send(fun) == fun
      assert Client.before_send({Redactor, :redact}) == {Redactor, :redact}
    end

    test "refuses what cannot be called with a report" do
      assert_raise ArgumentError, ~r/Redactor.missing\/1 is not defined/, fn ->
        Client.before_send({Redactor, :missing})
      end

      assert_raise ArgumentError, ~r/must be a {module, function} tuple or a function/, fn ->
        Client.before_send(fn -> :ok end)
      end
    end

    test "sends what the callback returns in place of the report" do
      start_client([], before_send: {Redactor, :redact})
      :ok = emit()

      assert_receive {:posted, _task, _url, _headers, body}

      assert %{"access_token" => "token1", "data" => %{"body" => body}} =
               body |> IO.iodata_to_binary() |> Jason.decode!()

      assert body == %{"message" => %{"body" => "[redacted]"}}
    end

    test "hands the callback the data of the report, without the access token" do
      test = self()

      start_client([],
        before_send: fn data ->
          send(test, {:before_send, data})
          data
        end
      )

      :ok = emit()

      assert_receive {:before_send, data}
      assert %{"body" => @body, "environment" => "test", "level" => "error"} = data
      refute inspect(data) =~ "token1"
    end

    test "sends nothing when the callback returns nil" do
      start_client([], before_send: fn _data -> nil end)
      :ok = emit()

      refute_receive {:posted, _task, _url, _headers, _body}
    end

    test "sends nothing, and says so, when the callback raises" do
      start_client([], before_send: fn _data -> raise "cannot redact" end)

      log =
        capture_log(fn ->
          :ok = emit()
          refute_receive {:posted, _task, _url, _headers, _body}
        end)

      assert log =~ "[error] (Rollbax) dropped report: :before_send failed"
      assert log =~ "cannot redact"
    end

    test "sends nothing, and says so, when the callback returns something else" do
      start_client([], before_send: fn _data -> :ok end)

      log =
        capture_log(fn ->
          :ok = emit()
          refute_receive {:posted, _task, _url, _headers, _body}
        end)

      assert log =~ "(Rollbax) dropped report: :before_send returned :ok instead of a map or nil"
    end
  end

  describe "the :max_concurrency and :max_queue configurations" do
    test "default to twenty at once and a thousand waiting" do
      assert Client.limit(:max_concurrency, nil, 20) == 20
      assert Client.limit(:max_queue, nil, 1_000) == 1_000
    end

    for value <- [0, -1, 1.5, "10"] do
      test "refuse #{inspect(value)}" do
        assert_raise ArgumentError, ~r/:max_queue must be a positive integer/, fn ->
          Client.limit(:max_queue, unquote(value), 1_000)
        end
      end
    end

    test "decide how many reports are posted at once and how many wait" do
      client = start_client([hold: true], max_concurrency: 2, max_queue: 3)

      log =
        capture_log(fn ->
          # One at a time: reports that pile up in the mailbox are dropped before the
          # client sees them, which is not what this test is about.
          Enum.each(1..6, fn _ ->
            :ok = emit()
            :sys.get_state(client)
          end)

          tasks =
            for _ <- 1..2 do
              assert_receive {:posted, task, _url, _headers, _body}
              task
            end

          refute_receive {:posted, _task, _url, _headers, _body}
          assert %{waiting_count: 3} = :sys.get_state(client)

          Enum.each(tasks, &send(&1, :answer))

          for _ <- 1..3 do
            assert_receive {:posted, task, _url, _headers, _body}
            send(task, :answer)
          end
        end)

      assert log =~ "(Rollbax) dropped report: 3 reports are already waiting to be sent"
    end
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
