defmodule DeepSeekHarness.FormatterTest do
  use ExUnit.Case, async: true

  alias DeepSeekHarness.CLI.Formatter

  test "renders ANSI color shortcuts" do
    assert Formatter.reset() == IO.ANSI.reset()
    assert Formatter.bold() == IO.ANSI.bright()
    assert Formatter.dim() == IO.ANSI.faint()
    assert Formatter.cyan() == IO.ANSI.cyan()
    assert Formatter.green() == IO.ANSI.green()
    assert Formatter.yellow() == IO.ANSI.yellow()
    assert Formatter.magenta() == IO.ANSI.magenta()
    assert Formatter.red() == IO.ANSI.red()
    assert Formatter.blue() == IO.ANSI.blue()
    assert Formatter.gray() == IO.ANSI.light_black()
  end

  test "provides tips list derived from help menu" do
    tips = Formatter.tips()
    assert is_list(tips)
    assert length(tips) > 10
    assert Enum.any?(tips, &String.contains?(&1, "/help"))
    assert Enum.any?(tips, &String.contains?(&1, "/compact"))

    random_tip = Formatter.random_tip()
    assert is_binary(random_tip)
    assert random_tip in tips
  end

  test "renders ASCII banner with DSH RAGE title" do
    banner = Formatter.banner()
    assert String.contains?(banner, "DSH RAGE")
    assert String.contains?(banner, "DeepSeek Agentic CLI Harness")
  end

  test "renders help menu with all slash commands" do
    menu = Formatter.help_menu()
    assert String.contains?(menu, "/help")
    assert String.contains?(menu, "/mcp")
    assert String.contains?(menu, "/review")
    assert String.contains?(menu, "/skills")
    assert String.contains?(menu, "/compact")
  end

  test "formats prompt string and status messages" do
    assert String.contains?(
             Formatter.format_user_prompt("main", "deepseek-chat"),
             "user@main [deepseek-chat]>"
           )

    assert String.contains?(Formatter.format_user_prompt_str("test_prompt"), "test_prompt")
    assert String.contains?(Formatter.format_agent_response("Hello"), "DeepSeek >")
    assert String.contains?(Formatter.format_error("Failed"), "●")
    assert String.contains?(Formatter.format_success("Done"), "●")
    assert String.contains?(Formatter.format_info("Notice"), "●")
  end

  test "formats markdown string with marcli rendering" do
    md = "# Title\n- Item 1\n- Item 2"
    rendered = Formatter.format_markdown(md)
    assert is_binary(rendered)
  end

  test "attempts copying text to system clipboard" do
    res = Formatter.copy_to_clipboard("test_clipboard_content")
    assert res == :ok or match?({:error, _}, res)
  end
end
