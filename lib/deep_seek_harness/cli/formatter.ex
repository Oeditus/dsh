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

  def banner do
    """
    #{cyan()}#{bold()}
    ██████╗ ███████╗██╗  ██╗   ███████╗██╗     ██╗██╗  ██╗██╗██████╗ 
    ██╔══██╗██╔════╝██║  ██║   ██╔════╝██║     ██║██║  ██║██║██╔══██╗
    ██║  ██║███████╗███████║   █████╗  ██║     ██║███████║██║██████╔╝
    ██║  ██║╚════██║██╔══██║   ██╔══╝  ██║     ██║██╔══██║██║██╔══██╗
    ██████╔╝███████║██║  ██║   ███████╗███████╗██║██║  ██║██║██║  ██║
    ╚═════╝ ╚══════╝╚═╝  ╚═╝   ╚══════╝╚══════╝╚═╝╚═╝  ╚═╝╚═╝╚═╝  ╚═╝
    #{reset()}#{dim()}DeepSeek Agentic CLI Harness in Elixir (DSH) — Powered by Erlang/OTP#{reset()}
    #{yellow()}Actors • Hot-Code Reloading • Distributed Brain/Hands • Spatiotemporal Checkpoints#{reset()}
    """
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
      #{cyan()}/clear#{reset()}                  Clear terminal output
      #{cyan()}/exit#{reset()} or #{cyan()}/quit#{reset()}            Exit DeepSeek Harness
    """
  end

  def format_user_prompt(session_id, model) do
    "#{green()}#{bold()}user@#{session_id} [#{model}]> #{reset()}"
  end

  def format_agent_response(content) do
    "#{cyan()}#{bold()}🤖 DeepSeek >#{reset()}\n#{content}"
  end

  def format_error(msg) do
    "#{red()}#{bold()}[ERROR]#{reset()} #{msg}"
  end

  def format_success(msg) do
    "#{green()}#{bold()}[SUCCESS]#{reset()} #{msg}"
  end

  def format_info(msg) do
    "#{blue()}#{bold()}[INFO]#{reset()} #{msg}"
  end
end
