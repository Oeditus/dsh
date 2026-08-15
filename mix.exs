defmodule DeepSeekHarness.MixProject do
  use Mix.Project

  def project do
    [
      app: :deep_seek_harness,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
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
      {:req, "~> 0.5.0"},
      {:jason, "~> 1.4"},
      {:marcli, "~> 0.3"},
      {:owl, "~> 0.13"}
    ]
  end
end
