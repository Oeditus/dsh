defmodule DeepSeekHarness.CLI.Formatter do
  @moduledoc """
  ANSI terminal styling, banner rendering, and text formatting helpers.
  """

  # IO ANSI shortcuts
  def reset, do: IO.ANSI.reset()
  def bold, do: IO.ANSI.bright()
  def dim, do: IO.ANSI.faint()
  def cyan, do: IO.ANSI.cyan()
  def green, do: IO.ANSI.green()
  def yellow, do: IO.ANSI.yellow()
  def magenta, do: IO.ANSI.magenta()
  def red, do: IO.ANSI.red()
  def blue, do: IO.ANSI.blue()
  def gray, do: IO.ANSI.light_black()
  def blink, do: IO.ANSI.blink_slow()

  @tips [
    "Use !command to execute shell commands directly (e.g. !git status)",
    "Use /help to view available slash commands and shortcuts",
    "Use /model [chat|reasoner] to switch between deepseek-chat and deepseek-reasoner models",
    "Use /mode [local|remote|docker] to set Hands execution target",
    "Use /plugins [reload] to list tools or hot-reload plugins live without dropping state",
    "Use /mcp [list|add|load] to manage Model Context Protocol (MCP) servers and tools",
    "Use /ragex to mount first-class Ragex code analysis & refactoring MCP tools",
    "Use /skills [name] to list available skills or execute a skill instruction",
    "Use /compact to compress conversation context to save tokens",
    "Use /diff to show colorized git diff of workspace changes",
    "Use /linter <tool> [cr|diff|project] to run native Elixir linters (oeditus_credo, propwise, credo)",
    "Use /review <base> [head] to compare two git branches and generate a detailed Code Review",
    "Use /commit <message> to auto-commit staged workspace changes to git",
    "Use /cost to display token usage and session cost statistics",
    "Use /permissions [auto|ask] to set tool execution safety mode",
    "Use /subagent <prompt> to spawn a background subagent worker for sub-tasks",
    "Use /checkpoint [label] to create a temporal state snapshot",
    "Use /undo to roll back state to previous checkpoint",
    "Use /session to display active session metadata & statistics",
    "Use /nodes to view distributed Erlang node cluster status",
    "Use /cb or /clipboard to copy latest assistant response to system clipboard",
    "Use /clear to clear terminal output",
    "Use /exit or /quit to exit DeepSeek Harness",
    "Press Ctrl+P to toggle permission mode, Ctrl+G to toggle sandbox, Ctrl+B to toggle the status bar"
  ]

  @doc "Returns the full list of tips derived from /help commands."
  def tips, do: @tips

  @doc "Returns a random tip string from the /help tips list."
  def random_tip, do: Enum.random(@tips)

  def banner do
    color = banner_color()

    """
    #{color}#{bold()}
    ██████╗ ███████╗██╗  ██╗    ██████╗  █████╗  ██████╗ ███████╗
    ██╔══██╗██╔════╝██║  ██║    ██╔══██╗██╔══██╗██╔════╝ ██╔════╝
    ██║  ██║███████╗███████║    ██████╔╝███████║██║  ███╗█████╗  
    ██║  ██║╚════██║██╔══██║    ██╔══██╗██╔══██║██║   ██║██╔══╝  
    ██████╔╝███████║██║  ██║    ██║  ██║██║  ██║╚██████╔╝███████╗
    ╚═════╝ ╚══════╝╚═╝  ╚═╝    ╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝ ╚══════╝
    #{reset()}#{dim()}DeepSeek Agentic CLI Harness (DSH RAGE) — Powered by Erlang/OTP#{reset()}
    #{yellow()}Actors • Hot-Code Reloading • Distributed Brain/Hands • Spatiotemporal Checkpoints#{reset()}
    """
  end

  def banner_color do
    env = System.get_env("DSH_ENV")

    dev? =
      cond do
        env == "dev" -> true
        env == "prod" -> false
        Code.ensure_loaded?(Mix) -> Mix.env() == :dev
        true -> false
      end

    if dev? do
      IO.ANSI.cyan()
    else
      IO.ANSI.light_magenta()
    end
  end

  def help_menu do
    """
    #{bold()}AVAILABLE SLASH COMMANDS & SHORTCUTS:#{reset()}
      #{cyan()}!command#{reset()}                 Execute shell command directly (e.g. !ls -la or !git status)
      #{cyan()}/help#{reset()}                   Show this help menu
      #{cyan()}/model [chat|reasoner]#{reset()}   Switch model (deepseek-chat V3 or deepseek-reasoner R1)
      #{cyan()}/mode [local|remote|docker]#{reset()}  Set Hands execution target
      #{cyan()}/plugins [reload]#{reset()}       List tools or hot-reload plugins live without dropping state
      #{cyan()}/mcp [list|add|load]#{reset()}    Manage Model Context Protocol (MCP) servers and tools
      #{cyan()}/ragex#{reset()}                  Mount first-class Ragex code analysis & refactoring MCP tools (@../ragex)
      #{cyan()}/skills [name]#{reset()}          List available skills or execute a skill instruction
      #{cyan()}/compact#{reset()}                Compress conversation context to save tokens
      #{cyan()}/diff#{reset()}                   Show colorized git diff of workspace changes
      #{cyan()}/review <base> [head]#{reset()}   Compare two git branches and generate a detailed Code Review
      #{cyan()}/commit <message>#{reset()}       Auto-commit staged workspace changes to git
      #{cyan()}/cost#{reset()}                   Display token usage and session cost statistics
      #{cyan()}/permissions [auto|ask]#{reset()} Set tool execution safety mode
      #{cyan()}/subagent <prompt>#{reset()}      Spawn a background subagent worker for sub-tasks
      #{cyan()}/checkpoint [label]#{reset()}     Create a temporal state snapshot
      #{cyan()}/undo#{reset()}                   Roll back state to previous checkpoint
      #{cyan()}/session#{reset()}                Display active session metadata & statistics
      #{cyan()}/nodes#{reset()}                  View distributed Erlang node cluster status
      #{cyan()}/cb#{reset()} or #{cyan()}/clipboard#{reset()}       Copy latest assistant response to system clipboard (Markdown)
      #{cyan()}/clear#{reset()}                  Clear terminal output
      #{cyan()}/exit#{reset()} or #{cyan()}/quit#{reset()}            Exit DeepSeek Harness

    #{bold()}HOTKEYS:#{reset()}
      #{cyan()}Ctrl+P#{reset()}                  Toggle permission mode (ask_confirm ⇄ auto_approve)
      #{cyan()}Ctrl+G#{reset()}                  Toggle workspace sandbox bounds on/off
      #{cyan()}Ctrl+B#{reset()}                  Toggle idle status bar mode (gauge ⇄ compact session line)
    """
  end

  def format_user_prompt(session_id, model) do
    "#{green()}#{bold()}user@#{session_id} [#{model}]> #{reset()}"
  end

  def format_user_prompt_str(prompt_str) do
    "#{green()}#{bold()}#{prompt_str}#{reset()}"
  end

  @doc "Renders markdown text using Marcli library into styled ANSI terminal text."
  def format_markdown(text) when is_binary(text) do
    Marcli.render(text)
  rescue
    _ -> text
  end

  def format_markdown(text), do: inspect(text)

  @doc """
  Formats context window memory usage percentage and token cost gauge bar.

  `delta_tokens` (optional) is the token count consumed by the most recent
  turn and is rendered as a `(+N)` suffix next to the running total. As
  usage climbs toward the context limit, the gauge escalates from green to
  yellow to bold red, and finally to a bold+blinking `/compact` warning hint
  near the recommended compaction threshold (terminal blink support varies).
  """
  def format_context_gauge(
        total_tokens,
        max_tokens \\ 128_000,
        cost_usd \\ 0.0,
        delta_tokens \\ 0,
        serving_processes \\ nil
      ) do
    pct = min(100, round(total_tokens / max(max_tokens, 1) * 100))
    bar_width = 16
    filled = round(pct / 100 * bar_width)
    empty = bar_width - filled

    bar = String.duplicate("█", filled) <> String.duplicate("░", empty)

    {color, emphasis, hint} =
      cond do
        pct >= 90 -> {red(), bold() <> blink(), "  󰀦 /compact strongly recommended"}
        pct >= 75 -> {red(), bold(), "  󰀦 /compact recommended"}
        pct >= 50 -> {yellow(), "", ""}
        true -> {green(), "", ""}
      end

    cost_str = :erlang.float_to_binary(cost_usd, [{:decimals, 4}])

    delta_str =
      if is_integer(delta_tokens) and delta_tokens > 0 do
        " #{green()}(+#{delta_tokens})#{reset()}"
      else
        ""
      end

    proc_count =
      cond do
        is_integer(serving_processes) -> serving_processes
        is_binary(serving_processes) -> serving_processes
        true -> length(Process.list())
      end

    "#{color}#{emphasis}[#{bar}] #{pct}%#{reset()} " <>
      "#{dim()}(#{total_tokens}/#{max_tokens} tokens#{reset()}#{delta_str}#{dim()} | $#{cost_str} USD | ⚡ #{proc_count} procs serving)#{reset()}" <>
      "#{color}#{bold()}#{hint}#{reset()}"
  end

  def format_agent_response(content) do
    rendered = format_markdown(content)
    "#{cyan()}#{bold()}󰚩 DeepSeek >#{reset()}\n#{rendered}"
  end

  def format_error(msg) do
    "#{red()}#{bold()}●#{reset()} #{msg}"
  end

  def format_success(msg) do
    "#{green()}#{bold()}●#{reset()} #{msg}"
  end

  def format_info(msg) do
    "#{blue()}#{bold()}●#{reset()} #{msg}"
  end

  @doc "Copies a markdown text payload to the OS clipboard."
  def copy_to_clipboard(text) when is_binary(text) do
    cmd_info =
      cond do
        wl = System.find_executable("wl-copy") -> {wl, []}
        xc = System.find_executable("xclip") -> {xc, ["-selection", "clipboard"]}
        xs = System.find_executable("xsel") -> {xs, ["--clipboard", "--input"]}
        pb = System.find_executable("pbcopy") -> {pb, []}
        cl = System.find_executable("clip.exe") || System.find_executable("clip") -> {cl, []}
        true -> nil
      end

    case cmd_info do
      {exec_path, args} ->
        try do
          port = Port.open({:spawn_executable, exec_path}, [:binary, args: args])
          Port.command(port, text)
          Port.close(port)
          :ok
        rescue
          e -> {:error, "Failed to copy to clipboard: #{Exception.message(e)}"}
        end

      nil ->
        {:error, "No system clipboard utility found (install xclip, wl-copy, xsel, or pbcopy)."}
    end
  end
end
