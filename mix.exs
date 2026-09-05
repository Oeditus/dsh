defmodule DeepSeekHarness.MixProject do
  use Mix.Project

  def project do
    [
      app: :deep_seek_harness,
      version: "0.5.3",
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
      # NOTE: intentionally NOT named "dsh" -- `mix escript.build` writes its
      # output to a file at the project root with this name, which would
      # silently overwrite the tracked `dsh` launcher bash script (same
      # filename). The release workflow renames the built escript to `dsh`
      # only when packaging the release asset, after the checkout is done.
      escript: [
        main_module: DeepSeekHarness.CLI.Main,
        name: "dsh_escript",
        app: :deep_seek_harness
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
      {:md, "~> 0.13", override: true},
      {:lmml, "~> 0.1"},
      {:makeup_elixir, ">= 0.0.0", optional: true},
      {:makeup_erlang, ">= 0.0.0", optional: true},
      {:makeup_cure, ">= 0.0.0", optional: true},
      {:owl, "~> 0.13"},
      {:egit, "~> 0.2"},
      {:ragex, "~> 0.29"},
      {:dllb, "~> 0.9"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:oeditus_credo, "~> 0.11", only: [:dev, :test], runtime: false},
      {:propwise, "~> 0.4", only: [:dev, :test], runtime: false}
    ] ++ embeddings_deps()
  end

  # `ragex`'s Bumblebee-based embeddings/vector search and Image processing
  # tools rely on native/NIF-backed libraries (exla, image/vix) that cannot
  # load from inside a `mix escript.build` archive (see MIX_ENV=:escript
  # below). ragex itself marks them `optional: true`, so this project must
  # declare them directly to pull them into the standard `mix release` /
  # dev / test dependency tree and keep embeddings-based semantic search and
  # image tools working there. They're deliberately omitted under the
  # dedicated `escript` Mix env used to build the standalone `dsh` escript,
  # so that build stays free of anything that can't load from an archive.
  defp embeddings_deps do
    if Mix.env() == :escript do
      []
    else
      [
        {:bumblebee, "~> 0.5"},
        {:nx, "~> 0.12"},
        {:exla, "~> 0.9"},
        {:image, "~> 0.54"}
      ]
    end
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
