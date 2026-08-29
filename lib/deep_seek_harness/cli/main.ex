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

    if workspace = System.get_env("DSH_WORKSPACE") do
      File.cd!(workspace)
    end

    {opts, extra_args, _invalid} =
      OptionParser.parse(args,
        switches: [
          prompt: :string,
          model: :string,
          conversation: :string,
          resume: :string,
          node: :string,
          connect: :string,
          plugin: :string,
          update: :boolean,
          help: :boolean
        ],
        aliases: [
          p: :prompt,
          m: :model,
          c: :conversation,
          r: :resume,
          u: :update,
          h: :help
        ]
      )

    cond do
      opts[:help] ->
        print_usage()
        halt(0)

      opts[:update] || "update" in extra_args || "self-update" in extra_args ->
        handle_self_update()
        halt(0)

      opts[:node] ->
        NodeManager.start_node(opts[:node])
        if opts[:connect], do: NodeManager.connect(opts[:connect])

        if has_prompt?(opts, extra_args) do
          run_one_shot(opts, extra_args)
        else
          Repl.start(opts)
        end

      has_prompt?(opts, extra_args) ->
        run_one_shot(opts, extra_args)

      true ->
        Repl.start(opts)
    end
  end

  defp has_prompt?(opts, extra_args) do
    prompt_opt = opts[:prompt]
    non_empty_extra = Enum.filter(extra_args, &(String.trim(&1) != ""))

    (is_binary(prompt_opt) and String.trim(prompt_opt) != "") or non_empty_extra != []
  end

  def handle_self_update do
    IO.puts(DeepSeekHarness.CLI.Formatter.format_info("Checking for DeepSeek Harness updates…"))

    repo_dir =
      System.get_env("DSH_REPO_DIR") ||
        Application.get_env(:deep_seek_harness, :repo_dir) || File.cwd!()

    if File.dir?(Path.join(repo_dir, ".git")) do
      IO.puts(
        DeepSeekHarness.CLI.Formatter.format_info(
          "Pulling latest git changes and refreshing production release…"
        )
      )

      script = """
      (sleep 0.5 && cd "#{repo_dir}" && git pull --rebase && MIX_ENV=prod mix release --overwrite >/dev/null 2>&1) &
      """

      System.cmd("bash", ["-c", script], cd: repo_dir)

      IO.puts(
        DeepSeekHarness.CLI.Formatter.format_success(
          "Update initiated! DSH release will be refreshed in the background."
        )
      )
    else
      IO.puts(DeepSeekHarness.CLI.Formatter.format_info("Standalone release active."))
    end
  end

  defp run_one_shot(opts, extra_args) do
    prompt = opts[:prompt] || Enum.join(extra_args, " ")
    model = opts[:model] || "deepseek-chat"
    session_id = opts[:conversation] || opts[:resume] || generate_uuid()

    {:ok, session_pid} = SessionSupervisor.start_session(session_id: session_id, model: model)

    if opts[:plugin] do
      DeepSeekHarness.Plugin.Loader.load_file(opts[:plugin])
    end

    result = Repl.handle_input(prompt, session_pid, session_id)

    try do
      DeepSeekHarness.MCP.ServerManager.stop_ragex()
    catch
      _, _ -> :ok
    end

    Repl.print_resume_banner(session_id)

    case result do
      :continue -> halt(0)
      :exit -> halt(0)
    end
  end

  # Wraps `System.halt/1` so tests can exercise the CLI's exit paths in-process
  # without killing the whole BEAM (and thus the rest of the test suite).
  # Real CLI invocations always halt; tests set
  # `Application.put_env(:deep_seek_harness, :system_halt_enabled, false)`.
  defp halt(code) do
    if Application.get_env(:deep_seek_harness, :system_halt_enabled, true) do
      System.halt(code)
    else
      :ok
    end
  end

  def generate_uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end

  defp print_usage do
    IO.puts("""
    DeepSeek Harness (DSH) — CLI Agentic Framework in Elixir

    USAGE:
      dsh                             Launch interactive REPL mode
      dsh -c <conversation_id>        Resume existing conversation
      dsh "Your prompt here"          One-shot mode
      dsh --prompt "Your prompt"      One-shot mode with flags
      dsh --model deepseek-reasoner   Specify model (deepseek-chat or deepseek-reasoner)
      dsh --node brain_1 --connect hands@127.0.0.1   Distributed Brain/Hands mode
      dsh --plugin path/to/plugin.exs Load custom plugin on startup

    OPTIONS:
      -c, --conversation STRING  Resume specific conversation ID
      -p, --prompt STRING        Input prompt to send to agent
      -m, --model STRING         Model selection (deepseek-chat, deepseek-reasoner)
          --node STRING          Start local Erlang distributed node name
          --connect STRING       Connect to remote Hands node
          --plugin FILE          Load external Elixir plugin file (.ex or .exs)
      -h, --help                 Display this help message
    """)
  end
end
