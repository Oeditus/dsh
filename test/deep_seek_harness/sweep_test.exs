defmodule DeepSeekHarness.SweepTest do
  use ExUnit.Case, async: true

  alias DeepSeekHarness.Sweep

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "dsh_sweep_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(Path.join(tmp_dir, "project/workflow"))
    File.mkdir_p!(Path.join(tmp_dir, "project/reference"))
    File.mkdir_p!(Path.join(tmp_dir, "docs"))
    File.mkdir_p!(Path.join(tmp_dir, "vault"))

    File.write!(
      Path.join(tmp_dir, "project/workflow/idea.md"),
      "--- \ntype: code\n---\n# Auth feature\nImplement JWT auth token refresh."
    )

    File.write!(
      Path.join(tmp_dir, "project/lessons.md"),
      "# Lessons\n- Token expiration must match API session lifetime."
    )

    File.write!(
      Path.join(tmp_dir, "docs/auth.md"),
      "Settled requirement: tokens expire after 3600 seconds."
    )

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "runs prior-art sweep across existing corpora", %{tmp_dir: tmp_dir} do
    res = Sweep.run("auth token", cwd: tmp_dir, vault_root: Path.join(tmp_dir, "vault"))

    assert res.tokens == ["auth", "token"]
    assert length(res.corpora) == 4

    wf_corpus = Enum.find(res.corpora, &(&1.name == "Workflow Pipeline"))
    assert wf_corpus.searched?
    assert Enum.any?(wf_corpus.matches, &String.contains?(&1.line_content, "JWT auth"))

    ref_corpus = Enum.find(res.corpora, &(&1.name == "Topical Reference"))
    assert ref_corpus.searched?
    assert Enum.any?(ref_corpus.matches, &String.contains?(&1.line_content, "tokens expire"))

    lessons_corpus = Enum.find(res.corpora, &(&1.name == "Lessons Learned"))
    assert lessons_corpus.searched?

    assert Enum.any?(
             lessons_corpus.matches,
             &String.contains?(&1.line_content, "Token expiration")
           )

    vault_corpus = Enum.find(res.corpora, &(&1.name == "Knowledge Vault"))
    assert vault_corpus.searched?
    assert vault_corpus.matches == []
  end

  test "flags unsearched corpora when vault_root is invalid", %{tmp_dir: tmp_dir} do
    res = Sweep.run("auth", cwd: tmp_dir, vault_root: Path.join(tmp_dir, "non_existent_vault"))

    vault_corpus = Enum.find(res.corpora, &(&1.name == "Knowledge Vault"))
    refute vault_corpus.searched?
    assert String.contains?(vault_corpus.error, "Path(s) do not exist")

    formatted = Sweep.format_result(res)
    assert String.contains?(formatted, "!! NOT SEARCHED")
  end
end
