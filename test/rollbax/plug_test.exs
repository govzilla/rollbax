defmodule Rollbax.PlugTest do
  use ExUnit.RollbaxCase

  import Plug.Test, only: [conn: 2]

  setup_all do
    {:ok, _pid} = start_rollbax_client("token1", "test")
    :ok
  end

  setup do
    {:ok, _} = RollbarAPI.start(self())
    on_exit(&RollbarAPI.stop/0)
  end

  @stacktrace [{MyApp.Router, :call, 2, [file: ~c"lib/my_app/router.ex", line: 12]}]
  @error %{kind: :error, reason: %RuntimeError{message: "oops"}, stack: @stacktrace}

  defp request_conn() do
    :get
    |> conn("/orders/7?token=s3cr3t")
    |> Plug.Conn.put_req_header("accept", "text/html")
    |> Plug.Conn.put_req_header("authorization", "Bearer s3cr3t")
    |> Plug.Conn.put_req_header("cookie", "session=s3cr3t")
    |> Plug.Conn.put_req_header("x-api-key", "s3cr3t")
    |> Map.put(:remote_ip, {203, 0, 113, 7})
  end

  describe "report/3" do
    test "reports the error with the request it happened in" do
      :ok = Rollbax.Plug.report(request_conn(), @error)

      data = assert_performed_request()["data"]

      assert data["body"]["trace"]["exception"] == %{
               "class" => "RuntimeError",
               "message" => "oops"
             }

      assert data["request"] == %{
               "method" => "GET",
               "url" => "http://www.example.com/orders/7",
               "user_ip" => "203.0.113.7",
               "headers" => %{"accept" => "text/html", "x-api-key" => "s3cr3t"}
             }
    end

    test "sends the query string and the fetched parameters only when asked to" do
      conn = Plug.Conn.fetch_query_params(request_conn())
      :ok = Rollbax.Plug.report(conn, @error, query_string: true, params: true)

      request = assert_performed_request()["data"]["request"]

      assert request["query_string"] == "token=s3cr3t"
      assert request["params"] == %{"token" => "s3cr3t"}
      assert request["url"] == "http://www.example.com/orders/7"
    end

    test "leaves out the parameters that were not fetched" do
      :ok = Rollbax.Plug.report(request_conn(), @error, params: true)

      refute Map.has_key?(assert_performed_request()["data"]["request"], "params")
    end

    test "leaves out the headers it is told to" do
      :ok = Rollbax.Plug.report(request_conn(), @error, filter_headers: ["x-api-key"])

      assert assert_performed_request()["data"]["request"]["headers"] == %{
               "accept" => "text/html"
             }
    end

    test "takes custom and occurrence data, and a request of the caller's own" do
      :ok =
        Rollbax.Plug.report(request_conn(), @error,
          custom: %{"request_id" => "abc"},
          occurrence_data: %{"person" => %{"id" => "42"}, "request" => %{"url" => "/hidden"}}
        )

      data = assert_performed_request()["data"]

      assert data["custom"] == %{"request_id" => "abc"}
      assert data["person"] == %{"id" => "42"}
      assert data["request"] == %{"url" => "/hidden"}
    end

    test "reports exits and throws" do
      :ok =
        Rollbax.Plug.report(request_conn(), %{kind: :throw, reason: :oops, stack: @stacktrace})

      assert assert_performed_request()["data"]["body"]["trace"]["exception"] ==
               %{"class" => "throw", "message" => ":oops"}
    end
  end
end
