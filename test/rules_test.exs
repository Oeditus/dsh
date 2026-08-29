defmodule DeepSeekHarness.RulesTest do
  use ExUnit.Case, async: false

  alias DeepSeekHarness.Rules

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "dsh_rules_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  test "initializes default rules if rules.json is missing", %{tmp_dir: tmp_dir} do
    rules = Rules.load_rules(tmp_dir)
    assert length(rules) == 3
    assert Enum.any?(rules, fn r -> r["scope"] == "all" and r["text"] =~ "typographic" end)
    assert Enum.any?(rules, fn r -> r["scope"] == "cr" and r["text"] =~ "table cells" end)
  end

  test "adds and deletes rules", %{tmp_dir: tmp_dir} do
    {:ok, rule} = Rules.add_rule("commit: enforce conventional commit format", tmp_dir)
    assert rule["scope"] == "commit"
    assert rule["text"] == "enforce conventional commit format"

    rules = Rules.load_rules(tmp_dir)
    assert Enum.any?(rules, fn r -> r["id"] == rule["id"] end)

    {:ok, _updated} = Rules.delete_rules([rule["id"]], tmp_dir)
    rules_after = Rules.load_rules(tmp_dir)
    refute Enum.any?(rules_after, fn r -> r["id"] == rule["id"] end)
  end

  test "builds preambles per scope", %{tmp_dir: tmp_dir} do
    Rules.load_rules(tmp_dir)

    all_preamble = Rules.build_preamble("all", tmp_dir)
    assert all_preamble =~ "typographic quotes"
    assert all_preamble =~ "backticks mean a code quote"
    refute all_preamble =~ "table cells"

    cr_preamble = Rules.build_preamble("cr", tmp_dir)
    assert cr_preamble =~ "typographic quotes"
    assert cr_preamble =~ "table cells"
  end

  test "toggles rule status", %{tmp_dir: tmp_dir} do
    Rules.load_rules(tmp_dir)
    {:ok, _} = Rules.toggle_rule(1, tmp_dir)

    all_preamble = Rules.build_preamble("all", tmp_dir)
    refute all_preamble =~ "typographic quotes"
  end

  test "separates header, rule bullets, and closing marker with blank lines", %{
    tmp_dir: tmp_dir
  } do
    Rules.load_rules(tmp_dir)
    preamble = Rules.build_preamble("all", tmp_dir)

    # A blank line must separate the header from the bullet list and the
    # bullet list from the closing "===" marker, otherwise Markdown's lazy
    # continuation rule folds the marker onto the last bullet's line when
    # this preamble is later rendered.
    assert preamble =~ "=== Prompt & Execution Rules ===\n\n-"
    assert preamble =~ ~r/\n\n=+\n\n/
    refute preamble =~ ~r/[^\n]===============================/
  end
end
