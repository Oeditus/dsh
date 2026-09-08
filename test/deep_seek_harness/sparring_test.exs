defmodule DeepSeekHarness.SparringTest do
  use ExUnit.Case, async: true

  alias DeepSeekHarness.Sparring

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "dsh_sparring_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(Path.join(tmp_dir, "project/workflow"))

    File.write!(
      Path.join(tmp_dir, "project/lessons.md"),
      "Cache invalidation causes stale state."
    )

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "prepares socratic and adversarial sparring with prior-art sweep", %{tmp_dir: tmp_dir} do
    {:ok, sweep_fmt, prompt} =
      Sparring.prepare_sparring("Cache state", cwd: tmp_dir, mode: :socratic)

    assert String.contains?(sweep_fmt, "Prior-Art Sweep for: [Cache, state]")
    assert String.contains?(prompt, "Socratic Sparring Mode: [Cache state]")
    assert String.contains?(prompt, "ONE question per response turn")

    {:ok, _sweep_fmt2, adv_prompt} =
      Sparring.prepare_sparring("Cache state", cwd: tmp_dir, mode: :adversarial)

    assert String.contains?(adv_prompt, "Adversarial Sparring Mode: [Cache state]")
    assert String.contains?(adv_prompt, "Actively challenge the proposed design")
  end
end
