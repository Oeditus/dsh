defmodule DeepSeekHarness.MixProject do
  use Mix.Project

  def project do
    [
      app: :deep_seek_harness,
      version: "0.2.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_core_path: "priv/plts",
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        ignore_warnings: ".dialyzer_ignore.exs"
      ],
      releases: [
        dsh: [
          include_executables_for: [:unix],
          applications: [deep_seek_harness: :permanent],
          steps: [:assemble]
        ]
      ],
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto, :inets],
      mod: {DeepSeekHarness.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req, "~> 0.7"},
      {:jason, "~> 1.4"},
      {:marcli, "~> 0.3"},
      {:makeup_elixir, ">= 0.0.0", optional: true},
      {:makeup_erlang, ">= 0.0.0", optional: true},
      {:makeup_cure, ">= 0.0.0", optional: true},
      {:owl, "~> 0.13"},
      {:egit, "~> 0.2"},
      {:ragex, "~> 0.26"},
      {:dllb, "~> 0.9"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:oeditus_credo, "~> 0.11", only: [:dev, :test], runtime: false},
      {:propwise, "~> 0.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": [
        "format --check-formatted",
        "credo --strict",
        "dialyzer"
      ]
    ]
  end
end
