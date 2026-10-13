defmodule Rollbax.LoggerTest do
  use ExUnit.RollbaxCase

  require Logger

  defmodule RaisingReporter do
    @behaviour Rollbax.Reporter

    @impl true
    def handle_event(_level, _event), do: raise("the reporter failed")
  end

  defmodule LoggingReporter do
    @behaviour Rollbax.Reporter

    @impl true
    def handle_event(_level, %{meta: %{crash_reason: {reason, stacktrace}}}) do
      send(:logger_test, :reporter_called)
      Logger.error("the reporter saw a crash", crash_reason: {reason, stacktrace})
      :ignore
    end

    def handle_event(_level, _event), do: :next
  end

  defmodule RenamingReporter do
    @behaviour Rollbax.Reporter

    @impl true
    def handle_event(_level, %{meta: %{crash_reason: {_reason, stacktrace}}}) do
      %Rollbax.Exception{class: "renamed", message: "by a reporter", stacktrace: stacktrace}
    end

    def handle_event(_level, _event), do: :next
  end

  setup_all do
    {:ok, _pid} = start_rollbax_client("token1", "test")
    :ok
  end

  setup context do
    {:ok, _pid} = RollbarAPI.start(self())
    :ok = Rollbax.Logger.attach(context[:reporters] || [Rollbax.Reporter.Standard])

    on_exit(fn ->
      RollbarAPI.stop()
      Rollbax.Logger.detach()
    end)
  end

  test "GenServer terminating with an Elixir error" do
    defmodule Elixir.MyGenServer do
      use GenServer

      def init(args), do: {:ok, args}

      def handle_cast(:raise_elixir, _state) do
        Map.fetch!(Map.new(), :nonexistent_key)
      end
    end

    {:ok, gen_server} = GenServer.start(MyGenServer, {})

    data =
      quietly(fn ->
        GenServer.cast(gen_server, :raise_elixir)
        assert_performed_request()["data"]
      end)

    exception = data["body"]["trace"]["exception"]
    assert exception["class"] == "GenServer terminating (KeyError)"
    assert exception["message"] =~ "key :nonexistent_key not found in:"

    assert [frame] = find_frames_for_current_file(data["body"]["trace"]["frames"])
    assert frame["method"] == "MyGenServer.handle_cast/2"

    assert data["custom"]["log"] =~ "GenServer #{inspect(gen_server)} terminating"
    assert data["custom"]["log"] =~ "Last message: {:\"$gen_cast\", :raise_elixir}"
  after
    purge_module(MyGenServer)
  end

  test "GenServer terminating with an Erlang error" do
    defmodule Elixir.MyGenServer do
      use GenServer

      def init(args), do: {:ok, args}

      def handle_cast(:raise_erlang, state) do
        :maps.find(:a_key, [:not_a, %{}])
        {:noreply, state}
      end
    end

    {:ok, gen_server} = GenServer.start(MyGenServer, {})

    data =
      quietly(fn ->
        GenServer.cast(gen_server, :raise_erlang)
        assert_performed_request()["data"]
      end)

    exception = data["body"]["trace"]["exception"]
    assert exception["class"] == "GenServer terminating (BadMapError)"
    assert exception["message"] =~ "expected a map, got:"
    assert exception["message"] =~ "[:not_a, %{}]"

    assert [frame] = find_frames_for_current_file(data["body"]["trace"]["frames"])
    assert frame["method"] == "MyGenServer.handle_cast/2"
  after
    purge_module(MyGenServer)
  end

  test "GenServer terminating because of an exit" do
    defmodule Elixir.MyGenServer do
      use GenServer

      def init(args), do: {:ok, args}

      def handle_cast(:call_self, state) do
        GenServer.call(self(), {:call, :self})
        {:noreply, state}
      end
    end

    {:ok, gen_server} = GenServer.start(MyGenServer, {})

    data =
      quietly(fn ->
        GenServer.cast(gen_server, :call_self)
        assert_performed_request()["data"]
      end)

    exception = data["body"]["trace"]["exception"]
    assert exception["class"] == "GenServer terminating"
    assert exception["message"] =~ "exited in: GenServer.call(#{inspect(gen_server)}"
    assert exception["message"] =~ "process attempted to call itself"

    assert [frame] = find_frames_for_current_file(data["body"]["trace"]["frames"])
    assert frame["method"] == "MyGenServer.handle_cast/2"
  after
    purge_module(MyGenServer)
  end

  test "GenServer stopping" do
    defmodule Elixir.MyGenServer do
      use GenServer

      def init(args), do: {:ok, args}

      def handle_cast(:stop, state) do
        {:stop, :stop_reason, state}
      end
    end

    {:ok, gen_server} = GenServer.start(MyGenServer, {})

    data =
      quietly(fn ->
        GenServer.cast(gen_server, :stop)
        assert_performed_request()["data"]
      end)

    assert data["body"]["trace"]["exception"] == %{
             "class" => "GenServer terminating (stop)",
             "message" => ":stop_reason"
           }

    assert data["body"]["trace"]["frames"] == []
    assert data["custom"]["log"] =~ "Last message: {:\"$gen_cast\", :stop}"
  after
    purge_module(MyGenServer)
  end

  test "gen_event handler terminating" do
    defmodule Elixir.MyGenEventHandler do
      @behaviour :gen_event

      def init(state), do: {:ok, state}
      def terminate(_reason, _state), do: :ok
      def code_change(_old_vsn, state, _extra), do: {:ok, state}
      def handle_call(_request, state), do: {:ok, :ok, state}
      def handle_info(_message, state), do: {:ok, state}

      def handle_event(:raise_error, _state) do
        raise "oops"
      end
    end

    {:ok, manager} = :gen_event.start()
    :ok = :gen_event.add_handler(manager, MyGenEventHandler, {})

    data =
      quietly(fn ->
        :gen_event.notify(manager, :raise_error)
        assert_performed_request()["data"]
      end)

    assert data["body"]["trace"]["exception"] == %{
             "class" => "gen_event handler terminating (RuntimeError)",
             "message" => "oops"
           }

    assert [frame] = find_frames_for_current_file(data["body"]["trace"]["frames"])
    assert frame["method"] == "MyGenEventHandler.handle_event/2"
    assert data["custom"]["log"] =~ "MyGenEventHandler"
  after
    purge_module(MyGenEventHandler)
  end

  # Elixir translates the crash of a state machine from 1.17 on.
  @tag skip: Version.match?(System.version(), "< 1.17.0") and "needs Elixir 1.17"
  test "state machine terminating" do
    defmodule Elixir.MyStateMachine do
      @behaviour :gen_statem

      def callback_mode(), do: :state_functions
      def init(data), do: {:ok, :idle, data}

      def idle(:cast, :raise_error, _data) do
        :maps.find(:a_key, _not_a_map = [])
      end
    end

    {:ok, state_machine} = :gen_statem.start(MyStateMachine, {}, [])

    data =
      quietly(fn ->
        :gen_statem.cast(state_machine, :raise_error)
        assert_performed_request()["data"]
      end)

    exception = data["body"]["trace"]["exception"]
    assert exception["class"] == "State machine terminating (BadMapError)"
    assert exception["message"] =~ "expected a map, got:"

    assert [frame] = find_frames_for_current_file(data["body"]["trace"]["frames"])
    assert frame["method"] == "MyStateMachine.idle/3"
  after
    purge_module(MyStateMachine)
  end

  test "process raising an error" do
    capture_log(fn ->
      pid = spawn(fn -> raise "oops" end)

      data = assert_performed_request()["data"]

      assert data["body"]["trace"]["exception"] == %{
               "class" => "error in process (RuntimeError)",
               "message" => "oops"
             }

      assert [frame] = find_frames_for_current_file(data["body"]["trace"]["frames"])
      assert frame["method"] =~ ~r[anonymous fn(/0)? in Rollbax.LoggerTest]
      assert data["custom"]["log"] =~ "Process #{inspect(pid)} raised an exception"
    end)
  end

  test "task with anonymous function raising an error" do
    capture_log(fn ->
      {:ok, task} = Task.start(fn -> raise "oops" end)

      data = assert_performed_request()["data"]

      assert data["body"]["trace"]["exception"] == %{
               "class" => "Task terminating (RuntimeError)",
               "message" => "oops"
             }

      assert [frame] = find_frames_for_current_file(data["body"]["trace"]["frames"])
      assert frame["method"] =~ ~r[anonymous fn(/0)? in Rollbax.LoggerTest]

      assert data["custom"]["log"] =~
               "Task #{inspect(task)} started from #{inspect(self())} terminating"
    end)
  end

  test "task with mfa raising an error" do
    defmodule Elixir.MyModule do
      def raise_error(message), do: raise(message)
    end

    capture_log(fn ->
      {:ok, _task} = Task.start(MyModule, :raise_error, ["my message"])

      data = assert_performed_request()["data"]

      assert data["body"]["trace"]["exception"] == %{
               "class" => "Task terminating (RuntimeError)",
               "message" => "my message"
             }

      assert [frame] = find_frames_for_current_file(data["body"]["trace"]["frames"])
      assert frame["method"] == "MyModule.raise_error/1"
      assert data["custom"]["log"] =~ "Function: &MyModule.raise_error/1"
      assert data["custom"]["log"] =~ ~s(Args: ["my message"])
    end)
  after
    purge_module(MyModule)
  end

  describe "from Elixir 1.19 on, what identifies the process that crashed" do
    @describetag skip: Version.match?(System.version(), "< 1.19.0") and "needs Elixir 1.19"

    test "is sent for a GenServer, without its state" do
      defmodule Elixir.MyGenServer do
        use GenServer

        def init(args), do: {:ok, args}
        def handle_cast(:raise, _state), do: raise("oops")
      end

      {:ok, gen_server} = GenServer.start(MyGenServer, %{secret: "s3cr3t"}, name: :my_gen_server)

      custom =
        quietly(fn ->
          GenServer.cast(gen_server, :raise)
          assert_performed_request()["data"]["custom"]
        end)

      assert %{"name" => ":my_gen_server", "last_message" => ~s({:"$gen_cast", :raise})} = custom
      refute Map.has_key?(custom, "state")
      refute custom["log"] =~ "s3cr3t"
    after
      purge_module(MyGenServer)
    end

    test "is sent for a task" do
      defmodule Elixir.MyModule do
        def raise_error(message), do: raise(message)
      end

      custom =
        quietly(fn ->
          {:ok, task} = Task.start(MyModule, :raise_error, ["my message"])
          custom = assert_performed_request()["data"]["custom"]
          assert custom["name"] == inspect(task)
          custom
        end)

      assert %{
               "function" => "&MyModule.raise_error/1",
               "arguments" => ~s(["my message"]),
               "started_from" => started_from
             } = custom

      assert started_from == inspect(self())
    after
      purge_module(MyModule)
    end

    test "is sent for a state machine, without its state or its data" do
      defmodule Elixir.MyStateMachine do
        @behaviour :gen_statem

        def callback_mode(), do: :state_functions
        def init(data), do: {:ok, :idle, data}
        def idle(:cast, :raise_error, _data), do: raise("oops")
      end

      {:ok, state_machine} = :gen_statem.start(MyStateMachine, %{secret: "s3cr3t"}, [])

      custom =
        quietly(fn ->
          :gen_statem.cast(state_machine, :raise_error)
          assert_performed_request()["data"]["custom"]
        end)

      assert %{"name" => name, "last_event" => "{:cast, :raise_error}"} = custom
      assert name == inspect(state_machine)
      refute Map.has_key?(custom, "state")
      refute inspect(custom) =~ "s3cr3t"
    after
      purge_module(MyStateMachine)
    end

    test "is cut when it is long" do
      defmodule Elixir.MyGenServer do
        use GenServer

        def init(args), do: {:ok, args}
        def handle_cast({:raise, _payload}, _state), do: raise("oops")
      end

      {:ok, gen_server} = GenServer.start(MyGenServer, {})

      last_message =
        quietly(fn ->
          GenServer.cast(gen_server, {:raise, String.duplicate("a", 5_000)})
          assert_performed_request()["data"]["custom"]["last_message"]
        end)

      assert byte_size(last_message) == 1_000 + byte_size(" (truncated)")
    after
      purge_module(MyGenServer)
    end
  end

  test "a crash a library logs with its reason is reported under the exception's name" do
    capture_log(fn ->
      stacktrace = [{MyLibrary, :serve, 1, [file: ~c"lib/my_library.ex", line: 7]}]
      Logger.error("request failed", crash_reason: {%ArgumentError{message: "bad"}, stacktrace})

      data = assert_performed_request()["data"]

      assert data["body"]["trace"]["exception"] == %{
               "class" => "ArgumentError",
               "message" => "bad"
             }

      assert data["body"]["trace"]["frames"] == [
               %{
                 "filename" => "lib/my_library.ex",
                 "lineno" => 7,
                 "method" => "MyLibrary.serve/1"
               }
             ]

      assert data["custom"] == %{"log" => "request failed"}
    end)
  end

  test "a long logged message is cut" do
    capture_log(fn ->
      Logger.error(String.duplicate("a", 20_000), crash_reason: {:shutdown, []})

      log = assert_performed_request()["data"]["custom"]["log"]
      assert byte_size(log) == 8_000 + byte_size(" (truncated)")
      assert String.ends_with?(log, "a (truncated)")
    end)
  end

  test "a long logged message is cut by bytes, at the end of a character" do
    capture_log(fn ->
      # Three bytes each, so the cut at 8,000 bytes falls inside one.
      Logger.error(String.duplicate("€", 10_000), crash_reason: {:shutdown, []})

      log = assert_performed_request()["data"]["custom"]["log"]
      assert log == String.duplicate("€", 2_666) <> " (truncated)"
    end)
  end

  @tag reporters: [LoggingReporter]
  test "what a reporter logs does not come back to it" do
    Process.register(self(), :logger_test)

    capture_log(fn ->
      spawn(fn -> raise "oops" end)
      assert_receive :reporter_called
      refute_receive :reporter_called
    end)
  end

  test "an error logged without a crash reason is not reported" do
    capture_log(fn ->
      Logger.error("something went wrong")
      refute_receive {:api_request, _body}
    end)
  end

  test "what Rollbax logs itself is not reported" do
    capture_log(fn ->
      Logger.error("(Rollbax) connection error", rollbax: false, crash_reason: {:oops, []})
      refute_receive {:api_request, _body}
    end)
  end

  test "when the endpoint is down, no logs are reported" do
    :ok = RollbarAPI.stop()

    capture_log(fn ->
      spawn(fn -> raise "oops" end)
      refute_receive {:api_request, _body}
    end)
  end

  describe "with Rollbax.Reporter.Messages after the standard reporter" do
    @describetag reporters: [Rollbax.Reporter.Standard, Rollbax.Reporter.Messages]

    test "an error logged without a crash reason is reported as a message" do
      data =
        quietly(fn ->
          Logger.error("payment gateway unreachable")
          assert_performed_request()["data"]
        end)

      assert data["body"] == %{"message" => %{"body" => "payment gateway unreachable"}}
      assert data["level"] == "error"
      assert %{"file" => file, "line" => line, "function" => function} = data["custom"]
      assert file =~ "logger_test.exs"
      assert is_integer(line)
      assert function =~ "Rollbax.LoggerTest"
    end

    test "an event logged above error is reported as critical" do
      data =
        quietly(fn ->
          Logger.critical("disk full")
          assert_performed_request()["data"]
        end)

      assert data["level"] == "critical"
      assert data["body"] == %{"message" => %{"body" => "disk full"}}
    end

    test "a crash is still reported as an exception, by the standard reporter" do
      capture_log(fn ->
        spawn(fn -> raise "oops" end)

        assert %{"trace" => %{"exception" => %{"message" => "oops"}}} =
                 assert_performed_request()["data"]["body"]

        refute_receive {:api_request, _body}
      end)
    end

    test "a report logged as a map is reported inspected" do
      data =
        quietly(fn ->
          Logger.error(%{event: :import_failed, rows: 3})
          assert_performed_request()["data"]
        end)

      assert data["body"]["message"]["body"] =~ "import_failed"
    end

    test "a long message is cut" do
      body =
        quietly(fn ->
          Logger.error(String.duplicate("é", 6_000))
          assert_performed_request()["data"]["body"]["message"]["body"]
        end)

      assert body == String.duplicate("é", 4_000) <> " (truncated)"
    end

    test "none of the event's other metadata is sent" do
      custom =
        quietly(fn ->
          Logger.error("failed", user_token: "s3cr3t")
          assert_performed_request()["data"]["custom"]
        end)

      assert Map.keys(custom) -- ["file", "line", "function"] == []
    end

    test "what is logged below error is not reported" do
      capture_log(fn ->
        Logger.warning("slow response")
        refute_receive {:api_request, _body}
      end)
    end

    test "what Rollbax logs itself is not reported" do
      capture_log(fn ->
        Logger.error("(Rollbax) connection error", rollbax: false)
        refute_receive {:api_request, _body}
      end)
    end
  end

  @tag reporters: [Rollbax.Reporter.Silencing]
  test "reporters can skip events" do
    capture_log(fn ->
      spawn(fn -> raise "oops" end)
      refute_receive {:api_request, _body}
    end)
  end

  @tag reporters: [RenamingReporter, Rollbax.Reporter.Standard]
  test "the first reporter that returns an exception decides what is reported" do
    capture_log(fn ->
      spawn(fn -> raise "oops" end)

      assert assert_performed_request()["data"]["body"]["trace"]["exception"] == %{
               "class" => "renamed",
               "message" => "by a reporter"
             }
    end)
  end

  @tag reporters: [RaisingReporter]
  test "a reporter that raises does not remove the handler" do
    capture_log(fn ->
      spawn(fn -> raise "oops" end)
      refute_receive {:api_request, _body}
    end)

    assert {:ok, %{module: Rollbax.Logger}} = :logger.get_handler_config(Rollbax.Logger)
  end

  defp find_frames_for_current_file(frames) do
    current_file = Path.relative_to_cwd(__ENV__.file)
    Enum.filter(frames, &(&1["filename"] == current_file))
  end

  defp purge_module(module) do
    :code.delete(module)
    :code.purge(module)
  end
end
