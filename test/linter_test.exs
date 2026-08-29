defmodule DeepSeekHarness.LinterTest do
  use ExUnit.Case, async: true
  alias DeepSeekHarness.Linter

  describe "list_tools/0" do
    test "returns list of available tools including oeditus_credo and propwise" do
      tools = Linter.list_tools()
      names = Enum.map(tools, & &1.name)

      assert "oeditus_credo" in names
      assert "propwise" in names
      assert "credo" in names
      assert "dialyzer" in names
      assert "all" in names
    end
  end

  describe "run/2" do
    test "returns help text on empty input or help" do
      {:ok, help1} = Linter.run("")
      {:ok, help2} = Linter.run("help")

      assert String.contains?(help1, "Usage: /linter")
      assert String.contains?(help2, "Available External Tools")
    end

    test "returns error on unknown tool" do
      {:error, err} = Linter.run("unknown_tool")
      assert String.contains?(err, "Unknown linter tool")
    end

    @tag ragex: true
    test "accepts aliases for oeditus_credo" do
      {:ok, out1} = Linter.run("oeditus_credo cr main")
      {:ok, out2} = Linter.run("oeditus cr main")
      {:ok, out3} = Linter.run("oeditus-credo cr main")

      assert is_binary(out1)
      assert is_binary(out2)
      assert is_binary(out3)
    end

    @tag ragex: true
    test "handles propwise on cr mode cleanly" do
      {:ok, out} = Linter.run("propwise cr main")
      assert is_binary(out)
    end
  end
end
