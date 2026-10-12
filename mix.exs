defmodule PusherServer.MixProject do
  use Mix.Project

  @source_url "https://github.com/femz12/pusher_server"
  @version "0.1.2"

  def project do
    [
      app: :pusher_server,
      version: @version,
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      releases: [
        pusher_server: [
          include_executables_for: [:unix]
        ]
      ],

      # --- Hex package metadata (fill in before `mix hex.publish`) ---
      description:
        "A self-hosted, Pusher-protocol-compatible WebSocket server " <>
          "(drop-in for Laravel Reverb) built on Cowboy.",
      package: package(),
      docs: docs(),
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :inets, :ssl],
      mod: {PusherServer.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:plug, "~> 1.16"},
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},
      {:redix, "~> 1.5"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => @source_url <> "/blob/main/CHANGELOG.md"
      },
      files: ~w(lib guides mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "guides/getting-started.md",
        "guides/configuration.md",
        "guides/embedding.md",
        "guides/multi-server.md",
        "guides/deployment.md",
        "guides/protocol-support.md",
        "guides/troubleshooting.md",
        "CONTRIBUTING.md",
        "SECURITY.md",
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        Guides: ~r{guides/},
        Project: ["CONTRIBUTING.md", "SECURITY.md", "CHANGELOG.md"]
      ],
      groups_for_modules: [
        "Public API": [PusherServer],
        Configuration: [PusherServer.Config],
        Backends: [PusherServer.Backend, PusherServer.Backend.Local, PusherServer.Backend.Redis],
        Internals: ~r/^PusherServer\.(?!Backend$|Backend\.Local$|Backend\.Redis$|Config$)/
      ]
    ]
  end
end
