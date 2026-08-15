defmodule DeepSeekHarness.LineEditorTest do
  use ExUnit.Case, async: true

  alias DeepSeekHarness.CLI.LineEditor

  test "builds prompt string with configurable interpolation" do
    prompt = LineEditor.build_prompt("main", "deepseek-chat", :local)
    assert String.contains?(prompt, "main")
    assert String.contains?(prompt, "deepseek-chat")
  end

  test "loads and appends persistent history safely" do
    assert is_list(LineEditor.load_history())
    LineEditor.add_history("test_command_123")
    history = LineEditor.load_history()
    assert "test_command_123" in history
  end
end
