defmodule DeepSeekHarness.Workflow.Steps.Lint do
  @moduledoc """
  Step ⑥: runs `mix format --check-formatted` and `mix credo diff <base>`
  as hard, exit-code-gated checks the workflow cannot proceed past (to
  the `commit` step) while they're failing, plus the richer
  `DeepSeekHarness.Linter` report for whichever `tools` the step's params
  request (default `"all"`) as a best-effort, non-gating artifact for
  the user to review -- `DeepSeekHarness.Linter.run/2` always returns
  `{:ok, output}` even when the underlying tool reports issues, since
  it's designed for interactive `/linter` display, not automated gating.
  """
  @behaviour DeepSeekHarness.Workflow.Step

  alias DeepSeekHarness.Linter
  alias DeepSeekHarness.Workflow.Store

  @impl true
  def run(context, params) do
    base = Map.get(context, :original_branch, "main")
    tools = Map.get(params, "tools", "all")

    with {:ok, _} <- check_format(context.cwd),
         {:ok, credo_out} <- check_credo_diff(context.cwd, base) do
      report = build_report(context, tools, base)
      Store.write_artifact!(context.run_id, "lint_report.txt", report, context.cwd)

      Store.append_transcript(
        context.run_id,
        :lint,
        %{"base" => base, "tools" => tools, "credo" => credo_out},
        context.cwd
      )

      {:ok, Map.put(context, :lint_output, report)}
    end
  end

  defp check_format(cwd) do
    case System.cmd("mix", ["format", "--check-formatted"], cd: cwd, stderr_to_stdout: true) do
      {_out, 0} ->
        {:ok, :formatted}

      {out, _code} ->
        {:error,
         "`mix format --check-formatted` failed -- run `mix format` and try again:\n#{out}"}
    end
  rescue
    e -> {:error, "Failed to run `mix format`: #{Exception.message(e)}"}
  end

  defp check_credo_diff(cwd, base) do
    if File.exists?(Path.join(cwd, "mix.exs")) do
      case System.cmd("mix", ["credo", "diff", base], cd: cwd, stderr_to_stdout: true) do
        {out, 0} -> {:ok, out}
        {out, _code} -> {:error, "`mix credo diff #{base}` reported issues:\n#{out}"}
      end
    else
      {:ok, "(no mix.exs found; skipping credo)"}
    end
  rescue
    e -> {:error, "Failed to run `mix credo`: #{Exception.message(e)}"}
  end

  defp build_report(context, tools, base) do
    case Linter.run("#{tools} diff #{base}", context.cwd) do
      {:ok, out} -> out
      {:error, reason} -> "(extended linter report unavailable: #{reason})"
    end
  end
end
