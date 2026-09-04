defmodule DeepSeekHarness.CLI.Interrupt do
  @moduledoc """
  Lets the user break out of an in-flight "AI is responding" turn by
  pressing Ctrl+Q, instead of only Ctrl+C -- which raises SIGINT and tears
  down the whole Erlang VM (losing the entire session, not just the one
  long/misbehaving turn).

  `run/2` executes `turn_fun` (a blocking call into
  `DeepSeekHarness.Brain.Session`, e.g. `Session.send_user_message/2` or
  `Session.generate_code_review/3`) in its own Task while concurrently
  watching raw keystrokes for Ctrl+Q. On Ctrl+Q, `Session.cancel_current_turn/1`
  is called against `session_pid`, which aborts the session's own in-flight
  agent-loop Task and makes the still-pending `turn_fun` call return
  `{:error, "Turn cancelled by user (Ctrl+Q)."}` almost immediately -- the
  session process itself is never killed, so conversation history up to
  (but not including) the interrupted turn is preserved intact.

  Known limitation: while a permission-confirmation or `ask_question`
  modal is on-screen (i.e. `DeepSeekHarness.CLI.Spinner` is paused -- see
  `DeepSeekHarness.CLI.Spinner.with_paused/1`), the keystroke watcher below
  backs off entirely rather than competing with that modal for keystrokes.
  Ctrl+Q is only recognized while the spinner itself is actively showing
  ("AI is responding"), not while the AI is waiting on a modal answer --
  use the modal's own Ctrl+C ("deny"/"cancelled") in that case.
  """
  alias DeepSeekHarness.Brain.Session
  alias DeepSeekHarness.CLI.Spinner

  @ctrl_q "\x11"
  @ctrl_o "\x0f"
  @paused_poll_interval_ms 120

  @doc """
  Runs `turn_fun` (a zero-arity function) to completion, or until the user
  presses Ctrl+Q while it's running -- in which case
  `Session.cancel_current_turn/1` is called against `session_pid` and this
  returns as soon as `turn_fun` itself then returns (almost immediately
  after cancellation).

  Falls back to running `turn_fun.()` directly, without any keystroke
  watching, when stdin isn't a real interactive terminal (tests, CI,
  piped input) -- there would be no keyboard to watch for Ctrl+Q anyway.
  """
  def run(session_pid, turn_fun) when is_function(turn_fun, 0) do
    if tty?() do
      run_interruptible(session_pid, turn_fun)
    else
      turn_fun.()
    end
  end

  defp run_interruptible(session_pid, turn_fun) do
    task = Task.async(turn_fun)

    # `spawn_monitor/1` (rather than `spawn/1` + a later `Process.monitor/1`)
    # guarantees we hold a monitor ref for the watcher from the instant it
    # exists, so the `after` block below can synchronously wait for it to
    # die before touching the terminal mode.
    {watcher, watcher_ref} = spawn_monitor(fn -> watch_for_interrupt(session_pid) end)

    try do
      Task.await(task, :infinity)
    after
      # `Process.exit(watcher, :kill)` is *asynchronous* -- it sends the kill
      # signal and returns immediately, but the watcher (which re-asserts raw
      # terminal mode on every loop iteration) may still be alive for a brief
      # window. If it called `set_raw_mode/0` after we restore cooked mode,
      # the terminal would be left in raw mode and the next LineEditor render
      # (and any typed input) would corrupt the screen -- the "empty screen
      # / reset brings it back" symptom. So we block until the watcher is
      # confirmed dead BEFORE restoring cooked mode, then flush so the
      # response output is actually on the terminal before control returns.
      stop_watcher(watcher, watcher_ref)
      restore_tty_mode()
      DeepSeekHarness.CLI.Formatter.flush()
    end
  end

  # Kills the watcher and waits (bounded) for its `:DOWN` before returning,
  # so no in-flight `set_raw_mode/0` can race the caller's `restore_tty_mode/0`.
  defp stop_watcher(watcher, ref) do
    Process.exit(watcher, :kill)

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    after
      500 -> :ok
    end
  end

  defp watch_for_interrupt(session_pid) do
    if Spinner.active?() and Spinner.paused?() do
      # A confirmation/question modal (or the max-tool-depth "continue?"
      # prompt) currently owns the TTY -- see the moduledoc's "Known
      # limitation" -- back off and check again shortly rather than racing
      # it for keystrokes.
      Process.sleep(@paused_poll_interval_ms)
      watch_for_interrupt(session_pid)
    else
      # Re-assert raw mode on every iteration: a modal that just finished
      # (`DeepSeekHarness.CLI.QuestionPrompt`) unconditionally restores
      # cooked mode when *it* exits, since it has no idea this outer
      # "AI is responding" phase still wants raw mode for the rest of the
      # turn. Cooked mode would otherwise silently break Ctrl+Q detection
      # (many terminals treat it as XON software flow control, consuming
      # it before it ever reaches this program) for whatever remains of
      # the turn. Idempotent/cheap when already raw.
      set_raw_mode()

      case read_char() do
        @ctrl_q ->
          Session.cancel_current_turn(session_pid)

        @ctrl_o ->
          DeepSeekHarness.CLI.LineEditor.toggle_expand_tool_calls(%{})
          watch_for_interrupt(session_pid)

        :eof ->
          :ok

        _other ->
          watch_for_interrupt(session_pid)
      end
    end
  end

  defp read_char do
    case :io.get_chars("", 1) do
      :eof -> :eof
      {:error, _reason} -> :eof
      char when is_binary(char) -> char
      char when is_list(char) -> IO.iodata_to_binary(char)
    end
  end

  defp set_raw_mode do
    case :shell.start_interactive({:noshell, :raw}) do
      :ok -> :ok
      {:error, :already_started} -> :ok
    end
  rescue
    _ -> :error
  end

  defp restore_tty_mode do
    case :shell.start_interactive({:noshell, :cooked}) do
      :ok -> :ok
      {:error, :already_started} -> :ok
    end
  rescue
    _ -> :ok
  end

  defp tty? do
    if (function_exported?(Mix, :env, 0) and Mix.env() == :test) or
         System.get_env("CI") != nil or
         Application.get_env(:deep_seek_harness, :non_interactive, false) do
      false
    else
      case :io.columns() do
        {:ok, _} -> true
        _ -> false
      end
    end
  end
end
