defmodule DeepSeekHarness.Workflow.Steps.TaskDescription do
  @moduledoc """
  Step ②: summarizes the user's original request (`context.seed_prompt`,
  e.g. the text passed to `/workflow run <name> ...`) into a clear,
  structured task specification, persisted to `task_description.md`
  under the run's directory so it's inspectable and editable on disk.

  Uses `Engine.ask_llm/2` -- a one-shot, tool-free completion outside any
  `Brain.Session`'s visible history -- since this is a pure summarization
  task, not something that needs tool-calling capability.
  """
  @behaviour DeepSeekHarness.Workflow.Step

  alias DeepSeekHarness.Workflow.Engine
  alias DeepSeekHarness.Workflow.Store

  @impl true
  def run(context, _params) do
    seed = Map.get(context, :seed_prompt, "")

    case Engine.ask_llm(context, prompt(seed)) do
      {:ok, text} ->
        description = String.trim(text)
        Store.write_task_description!(context.run_id, description, context.cwd)

        Store.append_transcript(
          context.run_id,
          :task_description,
          %{"seed_prompt" => seed, "response" => description},
          context.cwd
        )

        {:ok, Map.put(context, :task_description, description)}

      {:error, reason} ->
        {:error, "Failed to generate task description: #{reason}"}
    end
  end

  @doc "Builds the LLM prompt used to turn a raw request into a structured task specification."
  def prompt(seed) do
    """
    Summarize the following task request into a clear, structured task \
    specification that a software engineer could execute without further \
    clarification. Include: Goal, Key Requirements/Constraints, and Acceptance \
    Criteria, each as a Markdown section. Respond with the specification in \
    Markdown only -- no preamble, no meta-commentary about the summarization \
    itself.

    Task request:
    #{seed}
    """
  end
end
