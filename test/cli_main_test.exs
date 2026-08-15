defmodule DeepSeekHarness.CLIMainTest do
  use ExUnit.Case, async: true

  alias DeepSeekHarness.CLI.Main

  test "parses --help flag without error" do
    assert :ok = Main.main(["--help"])
  end
end
