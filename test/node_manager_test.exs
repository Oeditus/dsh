defmodule DeepSeekHarness.NodeManagerTest do
  use ExUnit.Case, async: true

  alias DeepSeekHarness.Distribution.NodeManager

  test "lists node distribution status" do
    info = NodeManager.list_nodes()
    assert is_atom(info.self)
    assert is_boolean(info.alive?)
    assert is_list(info.connected)
  end

  test "handles node connection attempt" do
    res = NodeManager.connect("non_existent_node@127.0.0.1")
    assert match?({:ok, _}, res) or match?({:error, _}, res)
  end

  test "handles rpc call failure on invalid node" do
    result = NodeManager.rpc_call(:invalid_node@local, Kernel, :node, [])
    assert {:error, msg} = result
    assert String.contains?(msg, "RPC failed")
  end
end
