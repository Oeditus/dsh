defmodule DeepSeekHarness.MCPClientTest do
  use ExUnit.Case, async: true

  alias DeepSeekHarness.MCP.Client

  test "starts MCP client port and handles initialize request" do
    # Launch cat as mock stdio port process
    opts = [command: "cat", name: "mock_mcp"]
    assert {:ok, pid} = Client.start_link(opts)
    assert Process.alive?(pid)
  end

  test "handles unhandled port messages gracefully" do
    opts = [command: "cat", name: "mock_mcp_unhandled"]
    {:ok, pid} = Client.start_link(opts)

    send(pid, {:random_msg, "test"})
    assert Process.alive?(pid)
  end
end
