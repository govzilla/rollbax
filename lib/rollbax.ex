defmodule Rollbax do
  @moduledoc """
  This module provides functions to report any kind of exception or message to
  [Rollbar](https://rollbar.com).

  ## Configuration

  The `:rollbax` application needs to be configured properly in order to
  work. This configuration can be done, for example, in `config/config.exs`:

      config :rollbax,
        access_token: "9309123491",
        environment: "production"

  The following is a comprehensive list of configuration options supported by Rollbax:

    * `:access_token` - (binary or `nil`) the token needed to access the [Rollbar
      Items API (POST)](https://rollbar.com/docs/api/items_post/). As of now, Rollbar provides
      several access tokens for different "parts" of their API: for this configuration option, the
      `"post_server_item"` access token is needed. This option is required only when the
      `:enabled` option is set to `true`, and can be `nil` otherwise.

    * `:environment` - (binary) the environment that will be attached to each reported exception.

    * `:code_version` - (binary) the version of the application's code, attached to every
      report as the item's `code_version`. Rollbar reads a semantic version, an integer or a
      Git SHA, and uses it to tell which release an error first appeared in.

    * `:enabled` - (`true | false | :log`) decides whether things reported with `report/5` or
      `report_message/4` are actually reported to Rollbar. If `true`, they are reported; if
      `false`, `report/5` and `report_message/4` don't do anything; if `:log`, things reported
      with `report/5` and `report_message/4` are instead logged to the shell.

    * `:custom` - (map) a map of any arbitrary metadata you want to attach to everything reported
      by Rollbax. If custom data is specified in an individual call to `report/5` or
      `report_message/5` it will be merged with the global data, with the individual data taking
      precedence in case of conflicts. Defaults to `%{}`.

    * `:api_endpoint` - (binary) the Rollbar endpoint to report exceptions and messages to.
      Defaults to `https://api.rollbar.com/api/1/item/`.

    * `:enable_crash_reports` - see `Rollbax.Logger`.

    * `:reporters` - see `Rollbax.Logger`.

    * `:report_timeout` - (milliseconds) how long the HTTP client is given to post a report
      before the attempt is abandoned. Defaults to `60_000`.

    * `:before_send` - (`{module, function}` or a function of one argument) called with every
      report right before it is sent, to redact it or to keep it from being sent. See
      "Redacting reports" below.

    * `:dedupe_window` - (milliseconds) when set, a report with the same level and the same
      exception or message as one sent less than that long ago is not sent. The next one
      that is sent says how many were left out, in the `"duplicates_dropped"` custom value.
      Reports that differ only in their custom or occurrence data count as the same. About
      a thousand distinct reports are remembered at a time; past that, one more is simply
      sent again. Off by default.

    * `:flush_timeout` - (milliseconds) how long the reports still waiting or being posted
      are given to leave when the application stops. `0` stops at once. Defaults to `5_000`.

    * `:max_concurrency` - (positive integer) how many reports are posted at once. Defaults
      to `20`.

    * `:max_queue` - (positive integer) how many reports wait their turn while that many are
      being posted. A report that finds the queue full is dropped. Defaults to `1_000`.

    * `:http_client` - (module or `{module, options}`) the `Rollbax.HTTPClient` that posts the
      reports. Defaults to `Rollbax.HTTPClient.Req`, which needs the `:req` dependency. The
      options are handed to the client on every request; for the default client they are
      [Req options](https://hexdocs.pm/req/Req.html#new/1), so that is where timeouts or a proxy
      are set.

  ## Runtime configuration

  Configuration can be modified at runtime by providing a configuration callback, like this:

      config :rollbax,
        config_callback: {MyModule, :my_function}

  In the example above, `MyModule.my_function/1` will be called with the existing configuration as
  an argument. It's supposed to return a keyword list representing a possibly modified
  configuration. This can for example be used to read system environment variables at runtime when
  the application starts:

      defmodule MyModule do
        def my_function(config) do
          Keyword.put(config, :access_token, System.get_env("ROLLBAR_ACCESS_TOKEN"))
        end
      end

  ## Redacting reports

  A report can carry more than was meant to leave the application: the arguments of the
  function that failed, when the stacktrace holds them, and, for a crashed process, the log
  of the crash with the last message the process received.

  The `:before_send` callback receives the `"data"` of the
  [item](https://docs.rollbar.com/reference/create-item) about to be posted, a map with
  string keys, and returns the map to send in its place, or `nil` to send nothing:

      config :rollbax, before_send: {MyApp.Rollbar, :redact}

      defmodule MyApp.Rollbar do
        def redact(%{"custom" => %{"log" => _}} = data) do
          update_in(data["custom"], &Map.delete(&1, "log"))
        end

        def redact(data), do: data
      end

  It runs in the process that sends the reports, one report at a time, so it should be
  quick. When it raises, or returns anything but a map or `nil`, the report is not sent and
  the failure is logged.

  ## Crash reports

  Rollbax provides a `:logger` handler that reports logged crashes and exits to Rollbar. For
  more information, look at the documentation for `Rollbax.Logger`.
  """

  use Application

  @allowed_message_levels [:critical, :error, :warning, :info, :debug]

  @doc false
  def start(_type, _args) do
    config = init_config()

    if config[:proxy] do
      raise ArgumentError,
            ":proxy is no longer supported. Give the proxy to the HTTP client instead, for example " <>
              "http_client: {Rollbax.HTTPClient.Req, connect_options: [proxy: {:http, host, port, []}]}"
    end

    unless config[:enabled] in [true, false, :log] do
      raise ArgumentError, ":enabled may be only one of: true, false, or :log"
    end

    if config[:enabled] == true and is_nil(config[:access_token]) do
      raise ArgumentError, ":access_token is required when :enabled is true"
    end

    # Fails here, at startup, when the client cannot be used.
    {_module, _options} = Rollbax.Client.http_client(config[:http_client])
    _timeout = Rollbax.Client.report_timeout(config[:report_timeout])
    _limit = Rollbax.Client.limit(:max_concurrency, config[:max_concurrency], nil)
    _limit = Rollbax.Client.limit(:max_queue, config[:max_queue], nil)
    _before_send = Rollbax.Client.before_send(config[:before_send])
    _code_version = Rollbax.Client.code_version(config[:code_version])
    _flush_timeout = Rollbax.Client.flush_timeout(config[:flush_timeout])
    _dedupe_window = Rollbax.Client.dedupe_window(config[:dedupe_window])

    children = [
      {Rollbax.Client, config}
    ]

    # The handler goes in only once there is a client to hand its reports to.
    with {:ok, supervisor} <- Supervisor.start_link(children, strategy: :one_for_one) do
      if config[:enable_crash_reports] do
        :ok = Rollbax.Logger.attach(config[:reporters] || [Rollbax.Reporter.Standard])
      end

      {:ok, supervisor}
    end
  end

  @doc false
  def stop(_state) do
    _ = Rollbax.Logger.detach()
    :ok
  end

  defp init_config() do
    env = Application.get_all_env(:rollbax)

    config =
      env
      |> Keyword.take([
        :enabled,
        :custom,
        :api_endpoint,
        :enable_crash_reports,
        :reporters,
        :proxy,
        :http_client,
        :report_timeout,
        :max_concurrency,
        :max_queue,
        :before_send,
        :code_version,
        :flush_timeout,
        :dedupe_window
      ])
      |> put_if_present(:environment, env[:environment])
      |> put_if_present(:access_token, env[:access_token])

    case Application.get_env(:rollbax, :config_callback) do
      {config_callback_mod, config_callback_fun} ->
        apply(config_callback_mod, config_callback_fun, [config])

      nil ->
        config
    end
  end

  defp put_if_present(keyword, key, value) do
    if value, do: Keyword.put(keyword, key, value), else: keyword
  end

  @doc """
  Reports the given error/exit/throw.

  `kind` specifies the kind of exception being reported while `value` specifies
  the value of that exception. `kind` can be:

    * `:error` - reports an exception defined with `defexception`. `value` must
      be an exception, or this function will raise an `ArgumentError` exception.

    * `:exit` - reports an exit. `value` can be any term.

    * `:throw` - reports a thrown term. `value` can be any term.

  The `custom` and `occurrence_data` arguments can be used to customize metadata
  sent to Rollbar. `custom` is a map of any arbitrary metadata you want to
  attach to the exception being reported. `occurrence_data` is a map of
  key-value pairs where keys and values should be understood by the [Rollbar
  POST API for items](https://rollbar.com/docs/api/items_post/); for example, as
  of now Rollbar understands the `"person"` field and uses it to display users
  which an exception affected: `occurrence_data` can be used to attach
  `"person"` data to an exception being reported. Refer to the Rollbar API
  (linked above) for what keys are supported and what the corresponding values
  should be.

  This function is **fire-and-forget**: it will always return `:ok` right away and
  perform the reporting of the given exception in the background so as to not block
  the caller.

  ## Examples

  Exceptions can be reported directly:

      {:current_stacktrace, stacktrace} = Process.info(self(), :current_stacktrace)
      Rollbax.report(:error, ArgumentError.exception("oops"), stacktrace)
      #=> :ok

  Often, you'll want to report something you either rescued or caught. For
  rescued exceptions:

      try do
        raise ArgumentError, "oops"
      rescue
        exception ->
          Rollbax.report(:error, exception, __STACKTRACE__)
          # You can also reraise the exception here with reraise/2
      end

  For caught exceptions:

      try do
        throw(:oops)
        # or exit(:oops)
      catch
        kind, value ->
          Rollbax.report(kind, value, __STACKTRACE__)
      end

  Using custom data:

      Rollbax.report(:exit, :oops, stacktrace, %{"weather" => "rainy"})

  """
  @spec report(:error | :exit | :throw, any, [any], map, map) :: :ok
  def report(kind, value, stacktrace, custom \\ %{}, occurrence_data \\ %{})
      when kind in [:error, :exit, :throw] and is_list(stacktrace) and is_map(custom) and
             is_map(occurrence_data) do
    {class, message} = Rollbax.Item.exception_class_and_message(kind, value)

    report_exception(%Rollbax.Exception{
      class: class,
      message: message,
      stacktrace: stacktrace,
      custom: custom,
      occurrence_data: occurrence_data
    })
  end

  @doc """
  Reports the given `message`.

  `message` will be reported as a simple Rollbar message, for example, without a stacktrace.
  `level` is the level of the message, which can be one of:

    * `:critical`
    * `:error`
    * `:warning`
    * `:info`
    * `:debug`

  `custom` and `occurrence_data` work exactly like they do in `report/5`.

  ## Examples

      Rollbax.report_message(:critical, "Everything is on fire!")
      #=> :ok

  """
  @spec report_message(:critical | :error | :warning | :info | :debug, IO.chardata(), map, map) ::
          :ok
  def report_message(level, message, custom \\ %{}, occurrence_data \\ %{})
      when level in @allowed_message_levels and is_map(custom) and is_map(occurrence_data) do
    body = message |> IO.chardata_to_string() |> Rollbax.Item.message_body()
    Rollbax.Client.emit(level, System.system_time(:second), body, custom, occurrence_data)
  end

  @doc false
  @spec report_exception(Rollbax.Exception.t()) :: :ok
  def report_exception(%Rollbax.Exception{} = exception) do
    %{
      class: class,
      message: message,
      stacktrace: stacktrace,
      custom: custom,
      occurrence_data: occurrence_data
    } = exception

    body = Rollbax.Item.exception_body(class, message, stacktrace)
    Rollbax.Client.emit(:error, System.system_time(:second), body, custom, occurrence_data)
  end
end
