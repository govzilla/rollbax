if Code.ensure_loaded?(Plug.Conn) do
  defmodule Rollbax.Plug do
    @moduledoc """
    Reports the errors of a Plug application, with the request they happened in.

    `report/3` is made to be called from the `handle_errors/2` callback of
    `Plug.ErrorHandler`:

        defmodule MyApp.Router do
          use Plug.Router # or `use MyAppWeb, :router` in a Phoenix application
          use Plug.ErrorHandler

          @impl Plug.ErrorHandler
          def handle_errors(conn, error) do
            Rollbax.Plug.report(conn, error)
            send_resp(conn, conn.status, "Something went wrong")
          end
        end

    ## What is sent about the request

    The report carries a `"request"` Rollbar understands: the method, the URL without its
    query string, the address of the client and a few headers.

    A request is full of things that must not leave the application, so only what is known
    to be harmless is sent. The query string and the parameters are not sent unless asked
    for. Of the headers, only these are: `accept`, `accept-encoding`, `accept-language`,
    `content-length`, `content-type`, `host`, `origin`, `user-agent`, `x-forwarded-for`,
    `x-forwarded-proto` and `x-request-id`. `:before_send` (see `Rollbax`) is the place for
    anything finer.

    ## Options

      * `:custom` - (map) custom data for the report, as in `Rollbax.report/5`.

      * `:occurrence_data` - (map) occurrence data for the report, as in `Rollbax.report/5`.
        A `"request"` given here replaces the one this module builds.

      * `:query_string` - (boolean) whether to send the query string. Defaults to `false`.

      * `:params` - (boolean) whether to send the parameters of the request, when they were
        fetched. Defaults to `false`.

      * `:headers` - (list of lower case names) the headers to send, in place of the ones
        above. A header given more than once is sent with its values joined by `", "`.

    """

    @default_headers ~w(accept accept-encoding accept-language content-length content-type host
                        origin user-agent x-forwarded-for x-forwarded-proto x-request-id)

    @doc """
    Reports the error Plug caught while serving `conn`.

    `error` is the map `Plug.ErrorHandler` hands to `handle_errors/2`, with the `:kind`, the
    `:reason` and the `:stack` of the error. Returns `:ok` right away, like
    `Rollbax.report/5`.
    """
    @spec report(
            Plug.Conn.t(),
            %{kind: :error | :exit | :throw, reason: term, stack: list},
            keyword
          ) ::
            :ok
    def report(
          %Plug.Conn{} = conn,
          %{kind: kind, reason: reason, stack: stacktrace},
          options \\ []
        )
        when kind in [:error, :exit, :throw] and is_list(stacktrace) and is_list(options) do
      custom = Keyword.get(options, :custom, %{})

      occurrence_data =
        options
        |> Keyword.get(:occurrence_data, %{})
        |> Map.put_new_lazy("request", fn -> request(conn, options) end)

      Rollbax.report(kind, reason, stacktrace, custom, occurrence_data)
    end

    @doc """
    Returns the `"request"` of a report for `conn`. Takes the options of `report/3` that are
    about the request.
    """
    @spec request(Plug.Conn.t(), keyword) :: map
    def request(%Plug.Conn{} = conn, options \\ []) when is_list(options) do
      %{
        "method" => conn.method,
        "url" => url(conn),
        "user_ip" => conn.remote_ip |> :inet.ntoa() |> List.to_string(),
        "headers" => headers(conn, Keyword.get(options, :headers, @default_headers))
      }
      |> put_query_string(conn, Keyword.get(options, :query_string, false))
      |> put_params(conn, Keyword.get(options, :params, false))
    end

    defp headers(%Plug.Conn{req_headers: req_headers}, names) when is_list(names) do
      req_headers
      |> Enum.filter(fn {name, _value} -> name in names end)
      |> Enum.group_by(fn {name, _value} -> name end, fn {_name, value} -> value end)
      |> Map.new(fn {name, values} -> {name, Enum.join(values, ", ")} end)
    end

    defp url(%Plug.Conn{} = conn) do
      Plug.Conn.request_url(%{conn | query_string: ""})
    end

    defp put_query_string(request, %Plug.Conn{query_string: query_string}, true),
      do: Map.put(request, "query_string", query_string)

    defp put_query_string(request, _conn, false), do: request

    defp put_params(request, %Plug.Conn{params: %Plug.Conn.Unfetched{}}, true), do: request

    defp put_params(request, %Plug.Conn{params: %{} = params}, true),
      do: Map.put(request, "params", params)

    defp put_params(request, _conn, false), do: request
  end
end
