defmodule DeepSeekHarness.MCPServerManagerTest do
  use ExUnit.Case, async: true

  alias DeepSeekHarness.MCP.ServerManager, as: MCPServerManager

  test "discovers ragex directory path" do
    assert {:ok, dir} = MCPServerManager.discover_ragex_dir(".")
    assert String.contains?(dir, "ragex")
    assert File.exists?(Path.join(dir, "mix.exs"))
  end
end
