defmodule DeepSeekHarness.CLIMainTest do
  use ExUnit.Case, async: true

  alias DeepSeekHarness.CLI.Main

  test "parses --help flag without error" do
    assert :ok = Main.main(["--help"])
  end

  test "generates valid UUIDs for session tracking" do
    uuid = Main.generate_uuid()
    assert is_binary(uuid)
    assert String.match?(uuid, ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/)
  end
end
