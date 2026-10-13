if Code.ensure_loaded?(Req) do
  defmodule Rollbax.HTTPClient.Req do
    @moduledoc """
    The default `Rollbax.HTTPClient`, built on [Req](https://hexdocs.pm/req).

    It needs `:req` among the dependencies of the application:

        {:req, "~> 0.5"}

    The options given next to it in the configuration are passed to `Req.request/1`, so
    anything Req understands can be set: timeouts, a proxy, a custom Finch pool.

        config :rollbax,
          http_client:
            {Rollbax.HTTPClient.Req,
             receive_timeout: 5_000, connect_options: [proxy: {:http, "proxy.internal", 3128, []}]}

    A report is posted once. Retries and redirects are off unless the options turn them on,
    since Rollbar answers a rate limited report with a status Req would otherwise retry.
    """

    @behaviour Rollbax.HTTPClient

    @impl true
    def post(url, headers, body, options)
        when is_binary(url) and is_list(headers) and is_list(options) do
      {configured_headers, options} = Keyword.pop(options, :headers, [])

      # Rollbax reads the body itself, so it is never decoded, whatever the options say.
      request =
        [retry: false, redirect: false]
        |> Keyword.merge(options)
        |> Keyword.merge(
          method: :post,
          url: url,
          headers: Enum.to_list(configured_headers) ++ headers,
          body: body,
          decode_body: false
        )

      case Req.request(request) do
        {:ok, %Req.Response{} = response} ->
          {:ok, response.status, headers_to_list(response.headers), response.body}

        {:error, exception} ->
          {:error, exception}
      end
    end

    # Req returns a list of values per header, or a single one when it is compiled with
    # `legacy_headers_as_lists`.
    @doc false
    def headers_to_list(headers) do
      for {name, values} <- headers, value <- List.wrap(values), do: {name, value}
    end
  end
end
