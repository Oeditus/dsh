defmodule DeepSeekHarness.PluginLoaderTest do
  use ExUnit.Case, async: false

  alias DeepSeekHarness.Plugin.Loader, as: PluginLoader

  test "lists built-in default tools" do
    tools = PluginLoader.list_tools()
    tool_names = Enum.map(tools, & &1.name)

    assert "read_file" in tool_names
    assert "write_file" in tool_names
    assert "replace_file" in tool_names
    assert "list_dir" in tool_names
    assert "bash" in tool_names
    assert "elixir_eval" in tool_names
    assert "ask_question" in tool_names
  end

  test "executes built-in elixir_eval tool" do
    {:ok, result} = PluginLoader.execute_tool("elixir_eval", %{"code" => "21 * 2"})
    assert result =~ "42"
  end

  test "dynamic plugin file compilation and hot reloading" do
    tmp_plugin_path =
      Path.join(System.tmp_dir!(), "custom_math_plugin_#{System.unique_integer([:positive])}.exs")

    code = """
    defmodule CustomMathPlugin do
      @behaviour DeepSeekHarness.Plugin.Behaviour

      def name, do: "CustomMathPlugin"
      def description, do: "Custom math tools plugin"

      def tools do
        [
          %{
            name: "square",
            description: "Calculates the square of a number",
            parameters: %{
              type: "object",
              properties: %{n: %{type: "number"}},
              required: ["n"]
            },
            execute: fn %{"n" => n} -> {:ok, "\#{n * n}"} end
          }
        ]
      end
    end
    """

    File.write!(tmp_plugin_path, code)

    assert {:ok, names} = PluginLoader.load_file(tmp_plugin_path)
    assert "CustomMathPlugin" in names

    # Verify custom tool is immediately registered and executable
    {:ok, res} = PluginLoader.execute_tool("square", %{"n" => 9})
    assert res == "81"

    File.rm(tmp_plugin_path)
  end

  test "unregisters plugin modules and tool names live" do
    assert :ok = PluginLoader.unregister_plugins(["non_existent_tool_xyz"])
    tools = PluginLoader.list_tools()
    refute Enum.any?(tools, fn t -> t.name == "non_existent_tool_xyz" end)
  end
end
