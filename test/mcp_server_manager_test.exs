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

  test "handles removing connected MCP server gracefully" do
    assert {:error, msg} = MCPServerManager.remove_server("non_existent_server")
    assert msg =~ "not connected"
  end

  test "formats validation errors with dynamic language (JS/TS support)" do
    err_atom = %{
      type: :validation_error,
      language: :javascript,
      errors: [%{line: 12, message: "Unexpected token"}]
    }

    # Verify via private format_mcp_content or through validation error payload:
    formatted_atom_str = :erlang.apply(MCPServerManager, :format_mcp_content, [err_atom])

    assert formatted_atom_str =~
             "Validation Error: Code changes produced invalid javascript syntax:"

    assert formatted_atom_str =~ "● Line 12: Unexpected token"

    err_string_keys = %{
      "type" => "validation_error",
      "language" => "typescript",
      "errors" => [%{"line" => 42, "message" => "Type mismatch"}]
    }

    formatted_str = :erlang.apply(MCPServerManager, :format_mcp_content, [err_string_keys])

    assert formatted_str =~ "Validation Error: Code changes produced invalid typescript syntax:"
    assert formatted_str =~ "● Line 42: Type mismatch"
  end
end
