defmodule DeepSeekHarness.MCPServerManagerTest do
  use ExUnit.Case, async: true

  alias DeepSeekHarness.MCP.ServerManager, as: MCPServerManager

  test "discovers ragex directory path" do
    assert {:ok, dir} = MCPServerManager.discover_ragex_dir(".")
    assert String.contains?(dir, "ragex")
    assert File.exists?(Path.join(dir, "mix.exs"))
  end

  test "lists registered mcp servers" do
    servers = MCPServerManager.list_servers()
    assert is_list(servers)
  end

  test "loads configured servers from config" do
    assert {:ok, results} = MCPServerManager.load_from_config()
    assert is_list(results) or is_map(results)
  end
end
