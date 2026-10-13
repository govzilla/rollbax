defmodule Rollbax.Mixfile do
  use Mix.Project

  @version "0.12.0"

  @default_api_endpoint "https://api.rollbar.com/api/1/item/"

  def project() do
    [
      app: :rollbax,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      description: "Exception tracking and logging from Elixir to Rollbar",
      package: package(),
      deps: deps(),
      aliases: [test: "test --no-start"],
      name: "Rollbax",
      docs: [
        main: "Rollbax",
        source_ref: "v#{@version}",
        source_url: "https://github.com/govzilla/rollbax",
        extras: ["pages/Using Rollbax in Plug-based applications.md"]
      ]
    ]
  end

  def application() do
    [
      extra_applications: [:logger],
      env: env(),
      mod: {Rollbax, []}
    ]
  end

  defp deps() do
    [
      {:jason, "~> 1.0"},
      {:req, "~> 0.5", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:plug, "~> 1.16", only: :test},
      {:bandit, "~> 1.5", only: :test}
    ]
  end

  defp package() do
    [
      maintainers: ["Aleksei Magusev", "Andrea Leopardi", "Eric Meadows-Jönsson"],
      licenses: ["ISC"],
      links: %{"GitHub" => "https://github.com/govzilla/rollbax"}
    ]
  end

  defp env() do
    [
      enabled: true,
      custom: %{},
      api_endpoint: @default_api_endpoint,
      enable_crash_reports: false,
      reporters: [Rollbax.Reporter.Standard]
    ]
  end
end
