defmodule DeepSeekHarness.CLI.Main do
  @moduledoc """
  CLI entrypoint module for `dsh` escript executable.
  Supports interactive REPL and command-line execution arguments.
  """
  alias DeepSeekHarness.Brain.SessionSupervisor
  alias DeepSeekHarness.CLI.Repl
  alias DeepSeekHarness.Distribution.NodeManager

  def main(args) do
    # Ensure custom agy-style LogFormatter is installed
    DeepSeekHarness.CLI.LogFormatter.install()

    # Ensure application dependencies are started
    Application.ensure_all_started(:deep_seek_harness)

    args = Enum.reject(args, fn a -> a in ["eval", "--"] end)

    {opts, extra_args, _invalid} =
      OptionParser.parse(args,
        switches: [
          prompt: :string,
          model: :string,
          node: :string,
          connect: :string,
          plugin: :string,
          help: :boolean
        ],
        aliases: [
          p: :prompt,
          m: :model,
          h: :help
        ]
      )

    cond do
      opts[:help] ->
        print_usage()
        System.halt(0)

      opts[:node] ->
        NodeManager.start_node(opts[:node])
        if opts[:connect], do: NodeManager.connect(opts[:connect])

        if opts[:prompt] || extra_args != [] do
          run_one_shot(opts, extra_args)
        else
          Repl.start(opts)
        end

      opts[:prompt] || extra_args != [] ->
        run_one_shot(opts, extra_args)

      true ->
        Repl.start(opts)
    end
  end

  defp run_one_shot(opts, extra_args) do
    prompt = opts[:prompt] || Enum.join(extra_args, " ")
    model = opts[:model] || "deepseek-chat"

    {:ok, session_pid} = SessionSupervisor.start_session(session_id: "oneshot", model: model)

    if opts[:plugin] do
      DeepSeekHarness.Plugin.Loader.load_file(opts[:plugin])
    end

    result = Repl.handle_input(prompt, session_pid, "oneshot")

    # System.halt/1 skips normal port cleanup, which would otherwise leave
    # the per-project Ragex/dllb OS process running as an orphan and force
    # a full re-index on the next launch instead of an instant cache hit.
    try do
      DeepSeekHarness.MCP.ServerManager.stop_ragex()
    catch
      _, _ -> :ok
    end

    case result do
      :continue -> System.halt(0)
      :exit -> System.halt(0)
    end
  end

  defp print_usage do
    IO.puts("""
    DeepSeek Harness (DSH) — CLI Agentic Framework in Elixir

    USAGE:
      dsh                             Launch interactive REPL mode
      dsh "Your prompt here"          One-shot mode
      dsh --prompt "Your prompt"      One-shot mode with flags
      dsh --model deepseek-reasoner   Specify model (deepseek-chat or deepseek-reasoner)
      dsh --node brain_1 --connect hands@127.0.0.1   Distributed Brain/Hands mode
      dsh --plugin path/to/plugin.exs Load custom plugin on startup

    OPTIONS:
      -p, --prompt STRING    Input prompt to send to agent
      -m, --model STRING     Model selection (deepseek-chat, deepseek-reasoner)
          --node STRING      Start local Erlang distributed node name
          --connect STRING   Connect to remote Hands node
          --plugin FILE      Load external Elixir plugin file (.ex or .exs)
      -h, --help             Display this help message
    """)
  end
end
