Logger.configure(level: :info)
{:ok, _} = Application.ensure_all_started(:req)
{:ok, _} = Application.ensure_all_started(:bandit)
ExUnit.start()

defmodule ExUnit.RollbaxCase do
  use ExUnit.CaseTemplate

  using _ do
    quote do
      import unquote(__MODULE__)
    end
  end

  def start_rollbax_client(
        token,
        env,
        custom \\ %{},
        api_endpoint \\ "http://localhost:4004",
        http_client \\ nil
      ) do
    start_supervised(
      {Rollbax.Client,
       api_endpoint: api_endpoint,
       access_token: token,
       environment: env,
       enabled: true,
       custom: custom,
       http_client: http_client}
    )
  end

  def capture_log(fun) do
    ExUnit.CaptureIO.capture_io(:user, fn ->
      fun.()
      Process.sleep(200)
      Logger.flush()
    end)
  end

  def assert_performed_request() do
    assert_receive {:api_request, body}
    Jason.decode!(body)
  end
end

defmodule RollbarAPI do
  @behaviour Plug

  import Plug.Conn

  alias Plug.Conn

  @server {:rollbar_api, :server}

  def start(pid, port \\ 4004) do
    {:ok, server} =
      Bandit.start_link(plug: {__MODULE__, test: pid}, port: port, startup_log: false)

    Process.unlink(server)
    :persistent_term.put(@server, server)
    {:ok, server}
  end

  def stop() do
    Process.sleep(100)

    case :persistent_term.get(@server, nil) do
      nil ->
        :ok

      server ->
        :persistent_term.erase(@server)
        if Process.alive?(server), do: Supervisor.stop(server)
    end

    Process.sleep(100)
    :ok
  end

  def init(opts) do
    Keyword.fetch!(opts, :test)
  end

  def call(%Conn{method: "POST"} = conn, test) do
    {:ok, body, conn} = read_body(conn)
    Process.sleep(30)
    send(test, {:api_request, body})

    custom = Jason.decode!(body)["data"]["custom"]

    cond do
      custom["return_error?"] ->
        send_resp(conn, 400, ~s({"err": 1, "message": "that was a bad request"}))

      rate_limit_seconds = custom["rate_limit_seconds"] ->
        conn
        |> put_resp_header("X-Rate-Limit-Remaining-Seconds", rate_limit_seconds)
        |> send_resp(429, "{}")

      true ->
        send_resp(conn, 200, "{}")
    end
  end

  def call(conn, _test) do
    send_resp(conn, 404, "Not Found")
  end
end
