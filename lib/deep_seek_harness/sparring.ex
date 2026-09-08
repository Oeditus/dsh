defmodule DeepSeekHarness.Sparring do
  @moduledoc """
  Socratic & Adversarial Sparring Engine for DeepSeek Harness.

  Enforces a 2-phase sparring process to pressure-test new features or architectural ideas:
  1. Prior-art sweep (`DeepSeekHarness.Sweep`)
  2. Socratic dialogue (1 question per turn to surface assumptions and edge cases)
  3. Adversarial sparring (blunt counter-arguments, failure mode analysis, R1 CoT reasoning)
  """

  alias DeepSeekHarness.CLI.Formatter
  alias DeepSeekHarness.Sweep

  @doc """
  Initiates a prior-art sweep and returns the formatted sparring prompt instructions.
  """
  def prepare_sparring(topic_or_slug, opts \\ []) do
    cwd = Keyword.get(opts, :cwd, ".")
    mode = Keyword.get(opts, :mode, :socratic)

    sweep_res = Sweep.run(topic_or_slug, cwd: cwd)
    sweep_formatted = Sweep.format_result(sweep_res)

    prompt =
      case mode do
        :adversarial -> build_adversarial_prompt(topic_or_slug, sweep_formatted)
        _ -> build_socratic_prompt(topic_or_slug, sweep_formatted)
      end

    {:ok, sweep_formatted, prompt}
  end

  @doc """
  Builds the Socratic Sparring system instruction prompt.
  """
  def build_socratic_prompt(topic, sweep_output) do
    """
    ### Socratic Sparring Mode: [#{topic}]

    Prior-Art Sweep Findings:
    #{sweep_output}

    === Sparring Instructions ===
    1. Ask PRECISELY ONE question per response turn to clarify intent, surface hidden assumptions, and uncover edge cases.
    2. Do NOT write code yet. Focus entirely on refining requirements and architectural constraints.
    3. Cover these areas sequentially across turns:
       - Core problem & intent
       - Implicit assumptions & dependencies
       - Boundary conditions & failure modes
       - Integration with existing codebase & conventions
    4. Once requirements are clear, summarize the refined thought and ask if the user is ready for Adversarial Sparring (`/spar adversarial`).
    """
  end

  @doc """
  Builds the Adversarial Sparring system instruction prompt.
  """
  def build_adversarial_prompt(topic, sweep_output) do
    """
    ### Adversarial Sparring Mode: [#{topic}]

    Prior-Art Sweep Findings:
    #{sweep_output}

    === Adversarial Instructions ===
    1. Actively challenge the proposed design, architecture, or feature.
    2. Be direct, blunt, and specific — point out flaws, unreasonable assumptions, performance traps, and maintenance burdens.
    3. Question trade-offs, failure modes, and competitive alternatives ("Why not X instead?").
    4. Concede immediately when the user provides a strong counter-argument; do not be contrarian for its own sake.
    5. Frame challenges as binary-checkable acceptance criteria before approving promotion to `backlog/`.
    """
  end

  @doc """
  Formats sparring initiation for CLI display.
  """
  def format_spar_start(topic, mode, sweep_formatted) do
    mode_str = if mode == :adversarial, do: "Adversarial Sparring", else: "Socratic Sparring"

    """
    #{Formatter.bold()}=== Initiating #{mode_str} for: [#{topic}] ===#{Formatter.reset()}

    #{sweep_formatted}

    #{Formatter.cyan()}● Sparring prompt activated. Model will probe requirements turn-by-turn.#{Formatter.reset()}
    """
  end
end
