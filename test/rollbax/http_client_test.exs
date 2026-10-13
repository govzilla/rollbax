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

  defp start_client(options) do
    {:ok, _pid} =
      start_rollbax_client(
        "token1",
        "test",
        %{},
        "http://rollbar.test/item/",
        {RecordingClient, [test: self()] ++ options}
      )

    :ok
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

    assert capture_log(&emit/0) =~ "[error] (Rollbax) connection error: {:error, %RuntimeError{"

    :ok = emit()
    assert_receive {:posted, _task, _url, _headers, _body}
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

  test "the application refuses to start with the removed :proxy option" do
    Application.put_env(:rollbax, :proxy, "http://localhost:7004")
    on_exit(fn -> Application.delete_env(:rollbax, :proxy) end)

    assert_raise ArgumentError, ~r/:proxy is no longer supported/, fn ->
      Rollbax.start(:normal, [])
    end
  end
end
