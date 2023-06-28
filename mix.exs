defmodule ZenMonitor.Mixfile do
  use Mix.Project

  def project do
    [
      app: :zen_monitor,
      name: "ZenMonitor",
      version: "2.0.3",
      elixir: "~> 1.7",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      docs: docs(),
      elixirc_paths: elixirc_paths(Mix.env()),
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :instruments],
      mod: {ZenMonitor.Application, []}
    ]
  end

  defp aliases do
    [
      test: "test --no-start"
    ]
  end

  defp deps do
    [
      {:gen_stage, "~> 1.0"},
      {:instruments, "~> 2.1"},
      {:gen_registry, "~> 1.0"},
      {:ex_doc, "~> 0.27.3", only: :dev, runtime: false},
      {:dialyxir, "~> 1.0", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      name: "ZenMonitor",
      extras: ["README.md"],
      main: "readme",
      source_url: "https://github.com/discordapp/zen_monitor",
      groups_for_modules: [
        "Programmer Interface": [
          ZenMonitor
        ],
        "Local ZenMonitor System": [
          ZenMonitor.Local,
          ZenMonitor.Local.State,
          ZenMonitor.Local.Connector,
          ZenMonitor.Local.Connector.State,
          ZenMonitor.Local.Dispatcher,
          ZenMonitor.Local.Tables
        ],
        "Proxy ZenMonitor System": [
          ZenMonitor.Proxy,
          ZenMonitor.Proxy.State,
          ZenMonitor.Proxy.Batcher,
          ZenMonitor.Proxy.Batcher.State,
          ZenMonitor.Proxy.Tables
        ],
        "Supervisors / OTP / Utilities": [
          ZenMonitor.Application,
          ZenMonitor.Supervisor,
          ZenMonitor.Local.Supervisor,
          ZenMonitor.Proxy.Supervisor,
          ZenMonitor.Metrics,
          ZenMonitor.Truncator
        ]
      ]
    ]
  end

  defp elixirc_paths(:test) do
    elixirc_paths(:any) ++ ["test/support"]
  end

  defp elixirc_paths(_) do
    ["lib"]
  end

  defp package() do
    [
      name: :zen_monitor,
      description: "ZenMonitor provides efficient monitoring of remote processes.",
      maintainers: ["Discord Core Infrastructure"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/discordapp/zen_monitor"
      }
    ]
  end
end
