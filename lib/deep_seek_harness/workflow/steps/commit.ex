defmodule DeepSeekHarness.Workflow.Steps.Commit do
  @moduledoc """
  Step ⑦: mirrors DSH's own "please commit" convention -- format the
  code, then create a git commit with a comprehensive, LLM-drafted
  message describing the accumulated diff since the workflow's base
  branch. Linting already gated the preceding `lint` step, so this step
  only re-runs `mix format` (idempotent, and the safety net in case any
  step after `lint` touched files) before committing.

  Stages changes itself (excluding `.dsh/`) instead of going through
  `Git.commit/2`'s blanket `git add .`, so this workflow's own internal
  bookkeeping under `.dsh/workflows/runs/` -- state, transcripts, split
  plans -- can never end up committed into the user's history, even in a
  repository that doesn't already gitignore `.dsh/` (as this project's
  own `.gitignore` does).
  """
  @behaviour DeepSeekHarness.Workflow.Step

  alias DeepSeekHarness.Git
  alias DeepSeekHarness.Workflow.Engine
  alias DeepSeekHarness.Workflow.Store

  @attribution "\n\nCo-Authored-By: Warp <agent@warp.dev>"

  @impl true
  def run(context, _params) do
    run_mix_format(context.cwd)
    stage_excluding_dsh(context.cwd)

    case Git.diff("--cached", context.cwd) do
      {:ok, diff_text} ->
        message = build_commit_message(context, diff_text)

        case commit(context.cwd, message) do
          {:ok, out} ->
            Store.append_transcript(
              context.run_id,
              :commit,
              %{"message" => message, "output" => out},
              context.cwd
            )

            {:ok, Map.put(context, :commit_message, message)}

          {:error, reason} ->
            {:error, "Commit failed: #{reason}"}
        end

      {:error, reason} ->
        {:error, "Failed to compute diff for commit message generation: #{reason}"}
    end
  end

  defp stage_excluding_dsh(cwd) do
    System.cmd("git", ["add", "-A", "--", ".", ":!.dsh"], cd: cwd, stderr_to_stdout: true)
  end

  defp commit(cwd, message) do
    case System.cmd("git", ["commit", "-m", message], cd: cwd, stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, code} -> {:error, "git commit exited with status #{code}: #{String.trim(out)}"}
    end
  rescue
    e -> {:error, "Git commit exception: #{Exception.message(e)}"}
  end

  @doc "Builds the LLM prompt used to draft a comprehensive commit message from a diff."
  def commit_prompt(diff_text) do
    """
    Write a comprehensive, conventional git commit message (a short imperative \
    summary line under 72 characters, a blank line, then a body explaining \
    what changed and why) for the following diff. Respond with ONLY the \
    commit message text -- no code fences, no preamble.

    ```diff
    #{diff_text}
    ```
    """
  end

  defp build_commit_message(context, diff_text) do
    base_message =
      case Engine.ask_llm(context, commit_prompt(diff_text)) do
        {:ok, text} when is_binary(text) and text != "" ->
          String.trim(text)

        _ ->
          "Automated commit for workflow '#{context.workflow.name}' (run #{context.run_id})"
      end

    base_message <> @attribution
  end

  defp run_mix_format(cwd) do
    if File.exists?(Path.join(cwd, "mix.exs")) do
      System.cmd("mix", ["format"], cd: cwd, stderr_to_stdout: true)
    end

    :ok
  rescue
    _ -> :ok
  end
end
