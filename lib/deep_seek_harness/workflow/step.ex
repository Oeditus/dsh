defmodule DeepSeekHarness.Workflow.Step do
  @moduledoc """
  Behaviour implemented by every workflow step type (`branch`,
  `task_description`, `task_split`, `tests_and_docs`, `lint`, `commit`,
  and the free-form `prompt` escape hatch). `DeepSeekHarness.Workflow.Engine`
  looks up a step's module by its `"type"` string and calls `run/2`.

  The `context` threaded through every step is a plain map, at minimum
  carrying `:run_id`, `:cwd`, and `:workflow` (a `Workflow.Definition`
  struct), plus whatever earlier steps accumulated into it (`:branch`,
  `:task_description`, `:subtasks`, ...). Each step returns an updated
  context for the next step to consume.
  """

  @typedoc "Accumulated state threaded through every step of a single workflow run."
  @type context :: map()

  @doc """
  Executes this step against `context` with its own JSON params (the
  step's map from the definition, minus `"type"`).

  Returns `{:ok, updated_context}` to continue to the next step,
  `{:halt, reason}` when a user-facing gate was declined (a clean stop,
  not a failure), or `{:error, reason}` when the step itself failed.
  """
  @callback run(context, params :: map()) ::
              {:ok, context} | {:halt, String.t()} | {:error, String.t()}
end
