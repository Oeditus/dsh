defmodule Yoke.CLI.InteractionServer do
  @moduledoc """
  Main process / GenServer for synchronizing and routing all user interactions
  and questions (interruptions) across main agents, subagents, and background tasks.

  Guarantees that all user prompts and interactive question modals are processed
  sequentially through this process's mailbox, preventing overlapping terminal TTY
  renders, scrambled output, or racing keystrokes between concurrent subagents.
  """
  use GenServer

  alias Yoke.CLI.QuestionPrompt
  alias Yoke.TaskEngine.PackageTracker

  @doc "Starts the named InteractionServer GenServer."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Asks questions to the user, routing the call through the InteractionServer mailbox.

  Synchronizes execution so only one prompt is active on the terminal at a time.
  """
  def ask(questions, opts \\ []) do
    case Process.whereis(__MODULE__) do
      nil ->
        QuestionPrompt.do_ask(questions, opts)

      pid ->
        if self() == pid do
          QuestionPrompt.do_ask(questions, opts)
        else
          GenServer.call(pid, {:ask, questions, opts}, :infinity)
        end
    end
  end

  @doc """
  Asks a single question to the user, routing the call through the InteractionServer mailbox.
  """
  def ask_single_question(question, options, is_multi \\ false, show_numbers \\ true, opts \\ []) do
    case Process.whereis(__MODULE__) do
      nil ->
        QuestionPrompt.do_ask_single_question(question, options, is_multi, show_numbers, opts)

      pid ->
        if self() == pid do
          QuestionPrompt.do_ask_single_question(question, options, is_multi, show_numbers, opts)
        else
          GenServer.call(
            pid,
            {:ask_single_question, question, options, is_multi, show_numbers, opts},
            :infinity
          )
        end
    end
  end

  # ---------------------------------------------------------------------
  # GenServer Callbacks
  # ---------------------------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:ask, questions, opts}, {from_pid, _ref}, state) do
    effective_opts = inject_caller_metadata(opts, from_pid)
    result = QuestionPrompt.do_ask(questions, effective_opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call(
        {:ask_single_question, question, options, is_multi, show_numbers, opts},
        {from_pid, _ref},
        state
      ) do
    effective_opts = inject_caller_metadata(opts, from_pid)

    result =
      QuestionPrompt.do_ask_single_question(
        question,
        options,
        is_multi,
        show_numbers,
        effective_opts
      )

    {:reply, result, state}
  end

  # ---------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------

  defp inject_caller_metadata(opts, caller_pid) do
    if Keyword.has_key?(opts, :subagent) do
      opts
    else
      case find_subagent_label(caller_pid) do
        nil -> opts
        label -> Keyword.put(opts, :subagent, label)
      end
    end
  end

  defp find_subagent_label(caller_pid) do
    with entries when is_list(entries) <-
           Registry.lookup(Yoke.PackageRegistry, "running_package"),
         {_pid, %{label: label}} <-
           Enum.find(entries, fn {pid, pkg} -> pid == caller_pid and pkg[:kind] == :subagent end) do
      label
    else
      _ ->
        fallback_first_subagent()
    end
  rescue
    _ -> nil
  end

  defp fallback_first_subagent do
    case Enum.find(PackageTracker.list(), fn pkg -> pkg[:kind] == :subagent end) do
      %{label: label} -> label
      _ -> nil
    end
  end
end
