defmodule Gingko.MixProject do
  use Mix.Project

  def project do
    [
      app: :gingko,
      version: "0.1.1",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      releases: releases(),
      dialyzer: [plt_add_apps: [:mix]]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Gingko.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def releases do
    [
      gingko: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            macos_silicon: [os: :darwin, cpu: :aarch64],
            linux: [os: :linux, cpu: :x86_64],
            linux_arm: [os: :linux, cpu: :aarch64],
            windows: [os: :windows, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:anubis_mcp, "~> 0.17"},
      {:bandit, "~> 1.5"},
      {:bumblebee, "~> 0.6"},
      {:burrito, "~> 1.5"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.22", only: :dev},
      {:dns_cluster, "~> 0.2.0"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, "~> 0.22"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:ex_check, "~> 0.16", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:gettext, "~> 1.0"},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:jason, "~> 1.2"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:mimic, "~> 2.0", only: :test},
      {:mnemosyne, github: "edlontech/mnemosyne", branch: "main"},
      {:nx, "~> 0.10", override: true},
      {:oban, "~> 2.18"},
      {:owl, "~> 0.12"},
      {:oban_web, "~> 2.11"},
      {:phoenix, "~> 1.8.3"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:quiver, "~> 0.2"},
      {:scholar, "~> 0.4"},
      {:recode, "~> 0.8", only: [:dev], runtime: false},
      {:req, "~> 0.5"},
      {:sycophant, "~> 0.1"},
      {:swoosh, "~> 1.16"},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:toml_elixir, "~> 3.0"}
    ] ++ accelerator_deps()
  end

  defp accelerator_deps do
    case :os.type() do
      {:unix, :linux} -> [{:exla, "~> 0.10"}]
      {:unix, :darwin} -> [{:emlx, "~> 0.2"}]
      _ -> []
    end
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "assets.build"],
      test: ["test"],
      "assets.setup": [
        "cmd --cd assets #{assets_install_command()}",
        "tailwind.install --if-missing",
        "esbuild.install --if-missing"
      ],
      "assets.build": ["assets.setup", "compile", "tailwind gingko", "esbuild gingko"],
      "assets.deploy": [
        "assets.setup",
        "compile",
        "tailwind gingko --minify",
        "esbuild gingko --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end

  defp assets_install_command do
    ~s(sh -c "if command -v yarn >/dev/null 2>&1; then yarn install --frozen-lockfile; elif command -v corepack >/dev/null 2>&1; then corepack yarn install --frozen-lockfile; else echo 'Yarn not found. Install Yarn or enable Corepack.'; exit 1; fi")
  end
end
