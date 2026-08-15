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

  test "navigates history up and down" do
    history = ["cmd_two", "cmd_one"]
    state = %{buffer: [], cursor: 0, history: history, hist_idx: -1, saved_buffer: []}

    up_state = LineEditor.history_navigate(state, :up)
    assert up_state.hist_idx == 0
    assert up_state.buffer == ~c"cmd_two"

    down_state = LineEditor.history_navigate(up_state, :down)
    assert down_state.hist_idx == -1
    assert down_state.buffer == []
  end

  test "finds items in history and toggles search mode" do
    history = ["git status", "mix test", "dsh review"]
    assert LineEditor.find_in_history("git", history) == "git status"
    assert LineEditor.find_in_history("xyz", history) == ""

    state = %{search_mode: false}
    assert LineEditor.toggle_reverse_search(state).search_mode == true
  end
end
