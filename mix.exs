defmodule Vaporator.MixProject do
  use Mix.Project

  @app :vaporator
  @version "0.1.0"
  @all_targets [:rpi3, :x86_64]

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.9",
      archives: [nerves_bootstrap: "~> 1.6"],
      start_permanent: Mix.env() == :prod,
      build_embedded: true,
      aliases: [loadconfig: [&bootstrap/1]],
      deps: deps(),
      releases: [{@app, release()}],
      preferred_cli_target: [run: :host, test: :host],
      test_coverage: [tool: ExCoveralls],
      perferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        vcr: :test,
        "vcr.delete": :test,
        "vcr.check": :test,
        "vcr.show": :test
      ]
    ]
  end

  # Starting nerves_bootstrap adds the required aliases to Mix.Project.config()
  # Aliases are only added if MIX_TARGET is set.
  def bootstrap(args) do
    Application.start(:nerves_bootstrap)
    Mix.Task.run("loadconfig", args)
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {Vaporator, []},
      extra_applications: [
        :logger,
        :runtime_tools,
        :persistent_storage,
        :gen_stage
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Dependencies for all targets
      {:nerves, "~> 1.5.0", runtime: false},
      {:nerves_hub_cli, "~> 0.9.0", runtime: false},
      {:shoehorn, "~> 0.6"},
      {:ring_logger, "~> 0.8.0"},
      {:toolshed, "~> 0.2.10"},
      {:dhcp_server, "~> 0.7.0"},

      # Dependencies for all targets except :host
      {:nerves_runtime, "~> 0.11.4", targets: @all_targets},
      {:nerves_hub, "~> 0.7.4", targets: @all_targets},
      {:nerves_init_gadget, "~> 0.6.0", targets: @all_targets},
      {:nerves_leds, "~> 0.8.0", targets: @all_targets},

      # Dependencies for specific targets
      {:vaporator_system_rpi3, "~> 0.1.0", runtime: false, targets: :rpi3},
      {:nerves_system_x86_64, "~> 1.8", runtime: false, targets: :x86_64},
      {:httpoison, "~> 1.5.0"},
      {:poison, "~> 4.0.1"},
      {:json, "~> 1.3.0"},
      {:timex, "~> 3.6"},
      {:ets, "~> 0.7"},
      {:dir_walker, "~> 0.0.8"},
      {:gen_stage, "~> 0.14"},
      {:excoveralls, "~> 0.11", only: :test},
      {:exvcr, "~> 0.10", only: :test},
      {
        :persistent_storage,
        github: "cellulose/persistent_storage", tag: "v0.10.1"
      }
    ]
  end

  def release do
    [
      overwrite: true,
      cookie: "#{@app}_cookie",
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: Mix.env() == :prod
    ]
  end
end
