defmodule DeepSeekHarness.CLI.QuestionPromptTest do
  use ExUnit.Case, async: true

  alias DeepSeekHarness.CLI.QuestionPrompt
  alias DeepSeekHarness.Plugin.DefaultTools

  describe "QuestionPrompt pure state operations" do
    test "initializes fresh state with cursor at 0" do
      state = QuestionPrompt.new_state("Which framework?", ["Phoenix", "Absinthe"], false, 2)

      assert state.cursor == 0
      assert state.question == "Which framework?"
      assert length(state.options) == 2
      assert state.custom_idx == 2
      assert MapSet.size(state.selected) == 0
    end

    test "moves cursor up and down with wrapping" do
      state = QuestionPrompt.new_state("Question", ["A", "B", "C"], false, 3)

      state = QuestionPrompt.move_down(state)
      assert state.cursor == 1

      state = QuestionPrompt.move_down(state)
      assert state.cursor == 2

      state = QuestionPrompt.move_down(state)
      assert state.cursor == 0

      state = QuestionPrompt.move_up(state)
      assert state.cursor == 2
    end

    test "toggles selection in multi-select mode" do
      state = QuestionPrompt.new_state("Question", ["A", "B"], true, 2)

      state = QuestionPrompt.toggle_selection(state)
      assert MapSet.member?(state.selected, 0)

      state = QuestionPrompt.toggle_selection(state)
      refute MapSet.member?(state.selected, 0)
    end

    test "selects index directly" do
      state = QuestionPrompt.new_state("Question", ["A", "B", "C"], false, 3)

      state = QuestionPrompt.select_index(state, 2)
      assert state.cursor == 2

      # Out of bounds ignored
      state = QuestionPrompt.select_index(state, 10)
      assert state.cursor == 2
    end
  end

  describe "QuestionPrompt answer formatting" do
    test "formats standard selected options answer" do
      q = "Select target database:"
      ans = %{selected: ["PostgreSQL", "SQLite"]}
      formatted = QuestionPrompt.format_answer(q, ans)

      assert formatted =~ "Question: Select target database:"
      assert formatted =~ "User selected: PostgreSQL; SQLite"
    end

    test "formats custom written response answer" do
      q = "What features to add?"
      ans = %{selected: ["Auth"], custom: "GraphQL API"}
      formatted = QuestionPrompt.format_answer(q, ans)

      assert formatted =~ "Question: What features to add?"
      assert formatted =~ "Selected options: Auth"
      assert formatted =~ "User custom response: GraphQL API"
    end

    test "formats cancelled answer" do
      q = "Confirm deployment?"
      ans = %{cancelled: true}
      formatted = QuestionPrompt.format_answer(q, ans)

      assert formatted =~ "User cancelled the question prompt."
    end
  end

  describe "DefaultTools ask_question tool integration" do
    test "ask_question tool is registered in DefaultTools" do
      tools = DefaultTools.tools()
      ask_tool = Enum.find(tools, &(&1.name == "ask_question"))

      assert ask_tool != nil
      assert ask_tool.description =~ "Ask the user one or more multiple-choice questions"
    end

    test "returns error on invalid arguments" do
      assert {:error, msg} = DefaultTools.ask_question(%{})
      assert msg =~ "Invalid arguments"
    end
  end
end
