defmodule Rollbax.HTTPClient do
  @moduledoc """
  Behaviour for the HTTP client Rollbax posts items to Rollbar with.

  Rollbax ships `Rollbax.HTTPClient.Req`, built on [Req](https://hexdocs.pm/req), and uses
  it by default. Any module implementing this behaviour can take its place:

      config :rollbax, http_client: MyApp.RollbarHTTPClient

  A client can also be given options, which Rollbax passes back to `c:post/4` on every
  request:

      config :rollbax, http_client: {Rollbax.HTTPClient.Req, receive_timeout: 5_000}

  ## Writing a client

  `c:post/4` is called from a task, never from the caller of `Rollbax.report/5`, so it is
  free to block until the response arrives. It must return the whole response, since
  Rollbax reads the status, the rate limiting header and the body of every one of them:

      defmodule MyApp.RollbarHTTPClient do
        @behaviour Rollbax.HTTPClient

        @impl true
        def post(url, headers, body, _options) do
          case MyApp.HTTP.post(url, headers, body) do
            {:ok, response} -> {:ok, response.status, response.headers, response.body}
            {:error, reason} -> {:error, reason}
          end
        end
      end

  """

  @type header() :: {name :: String.t(), value :: String.t()}

  @doc """
  Posts `body` to `url` and returns the response.

  `options` are the ones given next to the client in the `:http_client` configuration,
  or `[]` when there are none.
  """
  @callback post(url :: String.t(), headers :: [header()], body :: iodata(), options :: keyword()) ::
              {:ok, status :: 100..599, headers :: [header()], body :: binary()}
              | {:error, reason :: term()}
end
