# Using Rollbax in Plug-based applications

[Plug](https://github.com/elixir-plug/plug) provides the `Plug.ErrorHandler` plug, which "catches" the exceptions that happen inside a given plug so they can be acted on. `Rollbax.Plug.report/3` reports them to Rollbar together with the request they happened in:

```elixir
defmodule MyApp.Router do
  use Plug.Router # or `use MyAppWeb, :router` in a Phoenix application
  use Plug.ErrorHandler

  @impl Plug.ErrorHandler
  def handle_errors(conn, error) do
    Rollbax.Plug.report(conn, error)
    send_resp(conn, conn.status, "Something went wrong")
  end
end
```

The report carries the method, the URL without its query string, the address of the client and a few headers of the request.

## Metadata

`Rollbax.Plug.report/3` takes the custom data and the occurrence data `Rollbax.report/5` takes. For example, to show in Rollbar which user an error affected:

```elixir
def handle_errors(conn, error) do
  Rollbax.Plug.report(conn, error,
    custom: %{"request_id" => Logger.metadata()[:request_id]},
    occurrence_data: %{"person" => %{"id" => conn.assigns[:current_user_id]}}
  )

  send_resp(conn, conn.status, "Something went wrong")
end
```

Check the [documentation for the Rollbar API](https://docs.rollbar.com/reference/create-item) for everything an item can carry.

## Sensitive data

A request is full of things that must not leave the application, so `Rollbax.Plug` sends only what is known to be harmless:

  * the query string and the parameters are not sent. `query_string: true` and `params: true` turn them on;
  * of the headers, only `accept`, `accept-encoding`, `accept-language`, `content-length`, `content-type`, `host`, `origin`, `user-agent`, `x-forwarded-for`, `x-forwarded-proto` and `x-request-id` are sent. `:headers` takes the list to send in their place.

When the parameters are sent, scrub them first. The `:before_send` configuration (see `Rollbax`) receives every report right before it is sent and is the place to do it:

```elixir
config :rollbax, before_send: {MyApp.Rollbar, :scrub}

defmodule MyApp.Rollbar do
  def scrub(%{"request" => %{"params" => params}} = data) do
    put_in(data, ["request", "params"], scrub_params(params))
  end

  def scrub(data), do: data

  defp scrub_params(%{} = params) do
    Map.new(params, fn {key, value} ->
      if is_binary(key) and String.contains?(key, ["password", "token"]) do
        {key, "[FILTERED]"}
      else
        {key, scrub_params(value)}
      end
    end)
  end

  defp scrub_params([_ | _] = list), do: Enum.map(list, &scrub_params/1)
  defp scrub_params(other), do: other
end
```
