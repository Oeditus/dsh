defmodule DeepSeekHarness.LineEditorTest do
  use ExUnit.Case, async: true

  alias DeepSeekHarness.CLI.LineEditor

  describe "prompt building" do
    test "builds prompt string with configurable interpolation" do
      prompt = LineEditor.build_prompt("main", "deepseek-chat", :local)
      assert String.contains?(prompt, "deepseek-chat")
    end

    test "supports extended prompt style" do
      Application.put_env(:deep_seek_harness, :prompt_style, "extended")
      prompt = LineEditor.build_prompt("02ec14fa-0fae-62b0-9b52", "deepseek-chat", :local)
      assert String.contains?(prompt, "deepseek-chat")
      assert String.contains?(prompt, "id:02ec14fa")
    end
  end

  describe "persistent history" do
    test "loads and appends persistent history safely" do
      assert is_list(LineEditor.load_history())
      LineEditor.add_history("test_command_123")
      history = LineEditor.load_history()
      assert "test_command_123" in history
    end

    test "loads history most-recent-first, matching in-memory prepend order" do
      LineEditor.add_history("first_recorded_#{System.unique_integer([:positive])}")
      LineEditor.add_history("second_recorded_#{System.unique_integer([:positive])}")
      [most_recent | _rest] = LineEditor.load_history()
      assert String.starts_with?(most_recent, "second_recorded_")
    end
  end

  describe "cursor navigation" do
    test "moves cursor left and right without corrupting the buffer" do
      state = %{LineEditor.new_state("prompt> ") | buffer: String.graphemes("hello"), cursor: 3}

      assert LineEditor.move_left(state).cursor == 2
      assert LineEditor.move_right(state).cursor == 4

      assert LineEditor.move_left(%{state | cursor: 0}).cursor == 0
      assert LineEditor.move_right(%{state | cursor: 5}).cursor == 5
    end

    test "jumps to start and end of line" do
      state = %{LineEditor.new_state("prompt> ") | buffer: String.graphemes("hello"), cursor: 2}

      assert LineEditor.move_to_start(state).cursor == 0
      assert LineEditor.move_to_end(state).cursor == 5
    end

    test "backspace deletes the grapheme left of the cursor" do
      state = %{LineEditor.new_state("prompt> ") | buffer: String.graphemes("hello"), cursor: 3}
      result = LineEditor.delete_backward(state)

      assert result.buffer == String.graphemes("helo")
      assert result.cursor == 2

      unchanged = LineEditor.delete_backward(%{state | cursor: 0})
      assert unchanged.buffer == String.graphemes("hello")
      assert unchanged.cursor == 0
    end

    test "delete removes the grapheme at the cursor" do
      state = %{LineEditor.new_state("prompt> ") | buffer: String.graphemes("hello"), cursor: 1}
      result = LineEditor.delete_forward(state)

      assert result.buffer == String.graphemes("hllo")
      assert result.cursor == 1

      at_end = %{state | cursor: 5}
      assert LineEditor.delete_forward(at_end).buffer == String.graphemes("hello")
    end

    test "ctrl+u clears left of the cursor" do
      state = %{
        LineEditor.new_state("prompt> ")
        | buffer: String.graphemes("hello world"),
          cursor: 6
      }

      result = LineEditor.kill_to_start(state)

      assert result.buffer == String.graphemes("world")
      assert result.cursor == 0
    end

    test "ctrl+k clears right of the cursor" do
      state = %{
        LineEditor.new_state("prompt> ")
        | buffer: String.graphemes("hello world"),
          cursor: 5
      }

      result = LineEditor.kill_to_end(state)

      assert result.buffer == String.graphemes("hello")
      assert result.cursor == 5
    end

    test "ctrl+w deletes the word behind the cursor" do
      state = %{
        LineEditor.new_state("prompt> ")
        | buffer: String.graphemes("git commit "),
          cursor: 11
      }

      result = LineEditor.delete_word_backward(state)

      assert Enum.join(result.buffer) == "git "
      assert result.cursor == 4
    end

    test "inserts unicode graphemes and keeps combining marks clustered" do
      state =
        LineEditor.new_state("prompt> ")
        |> LineEditor.insert_char("é")
        |> LineEditor.insert_char("ñ")

      assert state.buffer == String.graphemes("éñ")
      assert state.cursor == 2

      # A base char followed by a combining accent should merge into one
      # grapheme cluster even though they arrive as separate keystrokes.
      combining_accent = <<0x0301::utf8>>
      composed = "e" <> combining_accent

      merged =
        LineEditor.new_state("prompt> ")
        |> LineEditor.insert_char("e")
        |> LineEditor.insert_char(combining_accent)

      assert merged.buffer == String.graphemes(composed)
      assert length(merged.buffer) == 1
    end
  end

  describe "history navigation" do
    test "navigates history up and down, preserving uncommitted input" do
      history = ["cmd_two", "cmd_one"]
      state = %{LineEditor.new_state("prompt> ", history) | buffer: String.graphemes("draft")}

      up_state = LineEditor.history_navigate(state, :up)
      assert up_state.hist_idx == 0
      assert up_state.buffer == String.graphemes("cmd_two")
      assert up_state.saved_buffer == String.graphemes("draft")

      up_again = LineEditor.history_navigate(up_state, :up)
      assert up_again.hist_idx == 1
      assert up_again.buffer == String.graphemes("cmd_one")

      # Cannot go further back than the oldest entry.
      assert LineEditor.history_navigate(up_again, :up) == up_again

      down_state = LineEditor.history_navigate(up_again, :down)
      assert down_state.hist_idx == 0
      assert down_state.buffer == String.graphemes("cmd_two")

      restored = LineEditor.history_navigate(down_state, :down)
      assert restored.hist_idx == -1
      assert restored.buffer == String.graphemes("draft")
    end
  end

  describe "reverse-incremental search" do
    test "finds items in history by substring" do
      history = ["git status", "mix test", "dsh review"]
      assert LineEditor.find_in_history("git", history) == "git status"
      assert LineEditor.find_in_history("xyz", history) == ""
      assert LineEditor.find_in_history("", history) == ""
    end

    test "cycles through multiple matches via offset" do
      history = ["mix test", "git commit", "git status"]
      assert LineEditor.find_in_history("git", history, 0) == "git commit"
      assert LineEditor.find_in_history("git", history, 1) == "git status"
      assert LineEditor.find_in_history("git", history, 2) == ""
    end

    test "toggles search mode on and is idempotent while already active" do
      state = LineEditor.new_state("prompt> ")
      activated = LineEditor.toggle_reverse_search(state)

      assert activated.search_mode == true
      assert activated.search_query == []
      assert LineEditor.toggle_reverse_search(activated) == activated
    end
  end

  describe "tab completion" do
    test "completes a unique slash command match" do
      assert {:ok, "/ragex"} = LineEditor.tab_complete("/ra")
      assert {:ok, "/review"} = LineEditor.tab_complete("/re")
      assert {:ok, "/checkpoint"} = LineEditor.tab_complete("/ch")
      assert {:ok, "/plugins"} = LineEditor.tab_complete("/pl")
    end

    test "extends to the common prefix when ambiguous but extendable" do
      assert {:ok, "/skill"} = LineEditor.tab_complete("/sk")
      assert {:ok, "/mode"} = LineEditor.tab_complete("/mod")
    end

    test "reports ambiguity when the common prefix cannot be extended" do
      assert {:ambiguous, matches} = LineEditor.tab_complete("/m")
      assert "/mcp" in matches
      assert "/mode" in matches
      assert "/model" in matches
    end

    test "returns :none for input with no matches or non-slash input" do
      assert :none = LineEditor.tab_complete("not_a_slash_cmd")
      assert :none = LineEditor.tab_complete("/zzz")
    end
  end

  describe "syntax highlighting and ghost suggestions" do
    test "highlights slash commands and shell commands" do
      cfg = %{"enable_syntax_highlighting" => true}
      assert LineEditor.highlight_input("/model chat", cfg) =~ "model"
      assert LineEditor.highlight_input("!git status", cfg) =~ "git status"
    end

    test "computes ghost auto-suggestions from history" do
      cfg = %{"enable_autosuggestions" => true}
      history = ["git commit -m 'fix'"]
      assert LineEditor.get_ghost_suggestion("git com", history, cfg) == "mit -m 'fix'"
    end

    test "calculates physical terminal display width of prompts with wide emojis" do
      prompt_str = "\e[36m📁 ragec\e[0m \e[32m🤖 deepseek-chat\e[0m ❯ "

      raw_len = String.length(String.replace(prompt_str, ~r/\e\[[0-9;]*[mGKH]/, ""))
      width = LineEditor.display_width(prompt_str)

      assert width == raw_len + 2
    end
  end
end
