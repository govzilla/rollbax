# Rollbax

[![CI](https://github.com/govzilla/rollbax/actions/workflows/ci.yml/badge.svg)](https://github.com/govzilla/rollbax/actions/workflows/ci.yml)

Elixir client for [Rollbar](https://rollbar.com).

This is Govzilla's fork of [ForzaElixir/rollbax](https://github.com/ForzaElixir/rollbax). It posts
reports through a pluggable HTTP client, [Req](https://hexdocs.pm/req) by default, and reports
crashes through a `:logger` handler. See the [changelog](CHANGELOG.md) for what differs from 0.11.0.

## Installation

Add Rollbax as a dependency to your `mix.exs` file:

```elixir
defp deps() do
  [
    {:rollbax, github: "govzilla/rollbax"},
    {:req, "~> 0.5"}
  ]
end
```

Then run `mix deps.get` in your shell to fetch the dependencies. `:req` is what the default HTTP client is built on; leave it out if you [configure another client](#http-client).

## Usage

Rollbax requires some configuration in order to work. For example, in `config/config.exs`:

```elixir
config :rollbax,
  access_token: "ffb8056a621f309eeb1ed87fa0c7",
  environment: "production"
```

Then, exceptions (errors, exits, and throws) can be reported to Rollbar using `Rollbax.report/3`:

```elixir
try do
  DoesNotExist.for_sure()
rescue
  exception ->
    Rollbax.report(:error, exception, __STACKTRACE__)
end
```

For detailed information on configuration and usage, take a look at the [online documentation](http://hexdocs.pm/rollbax).

### Crash reports

Rollbax provides a way to automatically report crashes from OTP processes (GenServers, Tasks, and so on). It can be enabled with:

```elixir
config :rollbax, enable_crash_reports: true
```

Rollbax then adds a `:logger` handler that reports every logged event carrying a crash reason: a GenServer, a task or a plain process that terminated abnormally, a state machine from Elixir 1.17 on, and the crashes libraries log the same way. For more information, check out the documentation for `Rollbax.Logger`.

### Plug and Phoenix

For examples on how to take advantage of Rollbax in Plug-based applications (including Phoenix applications), have a look at the ["Using Rollbax in Plug-based applications" page in the documentation](http://hexdocs.pm/rollbax/using-rollbax-in-plug-based-applications.html).

### Non-production reporting

For non-production environments error reporting can be either disabled completely (by setting `:enabled` to `false`) or replaced with logging of exceptions (by setting `:enabled` to `:log`).

```elixir
config :rollbax, enabled: :log
```

### HTTP client

Reports are posted by a module implementing the `Rollbax.HTTPClient` behaviour. The default is `Rollbax.HTTPClient.Req`, and the options given next to it are passed to Req, so that is where a timeout or a proxy goes:

```elixir
config :rollbax,
  http_client:
    {Rollbax.HTTPClient.Req,
     receive_timeout: 5_000, connect_options: [proxy: {:http, "my-proxy", 3128, []}]}
```

To use another HTTP library, implement the behaviour's one callback and name the module:

```elixir
config :rollbax, http_client: MyApp.RollbarHTTPClient
```

## Contributing

To run the tests, run `mix test`. The project's alias adds `--no-start`, since the `:rollbax` application does not start without an `:access_token`.

Run `mix format` before committing.

Finally, thanks for contributing! :)

## License

This software is licensed under [the ISC license](LICENSE).
