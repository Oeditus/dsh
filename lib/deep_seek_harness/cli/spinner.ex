defmodule DeepSeekHarness.CLI.Spinner do
  @moduledoc """
  Terminal spinner component for DeepSeek Harness.
  Renders a single animated progress indicator ("⠋") at the bottom of the screen.
  Coordinates with Logger and LogFormatter to ensure log lines print above the spinner
  without corrupting or duplicating the spinner indicator.
  """
  use GenServer

  alias DeepSeekHarness.CLI.Formatter

  @frames ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
  @default_title "Thinking & coordinating with Hands…"

  # Client API

  def start(opts \\ []) do
    GenServer.start(__MODULE__, opts, name: __MODULE__)
  end

  def stop do
    if active?() do
      case GenServer.whereis(__MODULE__) do
        pid when is_pid(pid) ->
          ref = Process.monitor(pid)
          res = GenServer.call(pid, :stop)

          receive do
            {:DOWN, ^ref, :process, ^pid, _} -> :ok
          after
            500 -> :ok
          end

          res

        _ ->
          :ok
      end
    else
      :ok
    end
  catch
    :exit, _ -> :ok
  end

  @doc """
  Pauses spinner redraws without stopping the process.

  Any other process that needs to render its own content to the terminal
  (e.g. `DeepSeekHarness.CLI.QuestionPrompt`) MUST call this before writing,
  otherwise the spinner's periodic `\r\e[2K<frame>` redraws race with that
  output and corrupt the terminal. Safe to call even if the spinner isn't
  running.
  """
  def pause do
    if active?() do
      try do
        GenServer.call(__MODULE__, :pause, 500)
      catch
        :exit, _ -> :ok
      end
    else
      :ok
    end
  end

  @doc "Resumes spinner redraws after a previous `pause/0`. Safe to call even if the spinner isn't running."
  def resume do
    if active?() do
      try do
        GenServer.call(__MODULE__, :resume, 500)
      catch
        :exit, _ -> :ok
      end
    else
      :ok
    end
  end

  @doc """
  Runs `fun` with the spinner paused, then resumes it (if it was active).
  No-op wrapper around `fun.()` when the spinner isn't running.
  """
  def with_paused(fun) when is_function(fun, 0) do
    pause()

    try do
      fun.()
    after
      resume()
    end
  end

  def active? do
    match?({:ok, _pid}, GenServer.whereis(__MODULE__) |> case_pid())
  end

  def current_line do
    if active?() do
      try do
        GenServer.call(__MODULE__, :get_current_line, 50)
      catch
        :exit, _ -> ""
      end
    else
      ""
    end
  end

  def run(fun, opts \\ []) when is_function(fun, 0) do
    {:ok, _pid} = start(opts)

    try do
      fun.()
    after
      stop()
    end
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    title = Keyword.get(opts, :title, @default_title)
    refresh_every = Keyword.get(opts, :refresh_every, 80)
    user_tip = Keyword.get(opts, :tip, :auto)

    {tip, auto_tip?} =
      case user_tip do
        :auto -> {Formatter.random_tip(), true}
        nil -> {Formatter.random_tip(), true}
        false -> {nil, false}
        "" -> {nil, false}
        custom when is_binary(custom) -> {custom, false}
        _ -> {Formatter.random_tip(), true}
      end

    enabled? = tty?()

    state = %{
      title: title,
      refresh_every: refresh_every,
      frame_idx: 0,
      tick_count: 0,
      tip: tip,
      auto_tip?: auto_tip?,
      enabled?: enabled?,
      timer: nil,
      paused: false
    }

    state =
      if enabled? do
        timer = Process.send_after(self(), :tick, refresh_every)
        render_frame(state)
        %{state | timer: timer}
      else
        state
      end

    {:ok, state}
  end

  @impl true
  def handle_call(:stop, _from, state) do
    if state.enabled? do
      clear_line()
    end

    if state.timer, do: Process.cancel_timer(state.timer)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_call(:get_current_line, _from, state) do
    line =
      if state.enabled? and not state.paused do
        frame = Enum.at(@frames, state.frame_idx)
        format_line(frame, state.title, state.tip)
      else
        ""
      end

    {:reply, line, state}
  end

  # Pausing stops the redraw timer and clears the spinner's own line so that
  # another process (e.g. QuestionPrompt) can safely take over the terminal
  # without its output being interleaved with our periodic `\r\e[2K<frame>`
  # writes. Idempotent: calling :pause while already paused is a no-op.
  @impl true
  def handle_call(:pause, _from, %{paused: true} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:pause, _from, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    if state.enabled?, do: clear_line()
    {:reply, :ok, %{state | timer: nil, paused: true}}
  end

  # Idempotent: calling :resume while not paused is a no-op.
  @impl true
  def handle_call(:resume, _from, %{paused: false} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:resume, _from, state) do
    state = %{state | paused: false}

    if state.enabled? do
      render_frame(state)
      timer = Process.send_after(self(), :tick, state.refresh_every)
      {:reply, :ok, %{state | timer: timer}}
    else
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info(:tick, %{paused: true} = state) do
    # Drop stray ticks scheduled before a :pause call was processed; do not
    # reschedule while paused.
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    new_idx = rem(state.frame_idx + 1, length(@frames))
    new_tick_count = state.tick_count + 1

    new_tip =
      if state.auto_tip? and rem(new_tick_count, 50) == 0 do
        Formatter.random_tip()
      else
        state.tip
      end

    new_state = %{state | frame_idx: new_idx, tick_count: new_tick_count, tip: new_tip}

    if state.enabled? do
      render_frame(new_state)
      timer = Process.send_after(self(), :tick, state.refresh_every)
      {:noreply, %{new_state | timer: timer}}
    else
      {:noreply, new_state}
    end
  end

  @doc "Formats a spinner line given frame, title, and optional tip."
  def format_line(frame, title, tip \\ nil) do
    base = "#{frame} #{title}"

    case tip do
      nil ->
        base

      "" ->
        base

      false ->
        base

      tip_str when is_binary(tip_str) ->
        "#{base}  #{Formatter.gray()}(Tip: #{tip_str})#{Formatter.reset()}"
    end
  end

  defp render_frame(state) do
    frame = Enum.at(@frames, state.frame_idx)
    line = format_line(frame, state.title, state.tip)
    IO.write("\r\e[2K#{line}")
  end

  defp clear_line do
    IO.write("\r\e[2K")
  end

  defp tty? do
    case :io.columns() do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp case_pid(nil), do: :error
  defp case_pid(pid) when is_pid(pid), do: {:ok, pid}
end
