defmodule DeepSeekHarness.Workflow.DefinitionTest do
  use ExUnit.Case, async: true

  alias DeepSeekHarness.Rules
  alias DeepSeekHarness.Workflow.Definition

  setup do
    cwd = Path.join(System.tmp_dir!(), "dsh_workflow_def_#{System.unique_integer([:positive])}")
    File.mkdir_p!(cwd)
    on_exit(fn -> File.rm_rf(cwd) end)
    %{cwd: cwd}
  end

  describe "parse/2" do
    test "accepts a minimal valid definition" do
      raw = %{"name" => "custom", "steps" => [%{"type" => "commit"}]}
      assert {:ok, %Definition{} = def_} = Definition.parse(raw)

      assert def_.name == "custom"
      assert def_.rules_scope == "all"
      assert def_.base_branch_prefixes == ["main", "master"]
      assert def_.steps == [%{"type" => "commit"}]
    end

    test "rejects a definition missing a name" do
      assert {:error, msg} = Definition.parse(%{"steps" => [%{"type" => "commit"}]})
      assert msg =~ "name"
    end

    test "rejects a definition with no steps" do
      assert {:error, msg} = Definition.parse(%{"name" => "empty", "steps" => []})
      assert msg =~ "at least one step"
    end

    test "rejects a step missing a type" do
      raw = %{"name" => "bad", "steps" => [%{"branch_prefix" => "x"}]}
      assert {:error, msg} = Definition.parse(raw)
      assert msg =~ "Step #1"
    end
  end

  describe "load/2 discovery tiers" do
    test "materializes the bundled 'elixir' workflow into the workspace tier on first use", %{
      cwd: cwd
    } do
      refute File.exists?(Path.join(Definition.definitions_dir(cwd), "elixir.json"))

      assert {:ok, %Definition{name: "elixir", source: :bundled} = def_} =
               Definition.load("elixir", cwd)

      assert Enum.any?(def_.steps, &(&1["type"] == "branch"))
      assert File.exists?(Path.join(Definition.definitions_dir(cwd), "elixir.json"))

      # Loading again now hits the materialized workspace file, not the
      # in-memory bundled fallback.
      assert {:ok, %Definition{source: :workspace}} = Definition.load("elixir", cwd)
    end

    test "seeds the bundled workflow's default rule under its rules_scope exactly once", %{
      cwd: cwd
    } do
      {:ok, _} = Definition.load("elixir", cwd)
      {:ok, _} = Definition.load("elixir", cwd)

      rules = Rules.load_rules(cwd)
      elixir_workflow_rules = Enum.filter(rules, &(&1["scope"] == "elixir_workflow"))

      assert length(elixir_workflow_rules) == 1
    end

    test "a workspace definition takes priority over the bundled default", %{cwd: cwd} do
      dir = Definition.definitions_dir(cwd)
      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, "elixir.json"),
        ~s({"name": "elixir", "description": "custom override", "steps": [{"type": "commit"}]})
      )

      assert {:ok, %Definition{source: :workspace, description: "custom override"}} =
               Definition.load("elixir", cwd)
    end

    test "returns an error for a completely unknown workflow name", %{cwd: cwd} do
      assert {:error, msg} = Definition.load("does-not-exist", cwd)
      assert msg =~ "Unknown workflow"
    end
  end

  describe "list_names/1 and list/1" do
    test "includes bundled workflows even before they are ever loaded", %{cwd: cwd} do
      assert "elixir" in Definition.list_names(cwd)
    end

    test "includes custom workspace definitions alongside bundled ones", %{cwd: cwd} do
      dir = Definition.definitions_dir(cwd)
      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, "custom.json"),
        ~s({"name": "custom", "steps": [{"type": "commit"}]})
      )

      names = Definition.list_names(cwd)
      assert "custom" in names
      assert "elixir" in names
    end

    test "list/1 returns descriptions for every discoverable workflow", %{cwd: cwd} do
      metas = Definition.list(cwd)
      assert Enum.any?(metas, &(&1.name == "elixir" and &1.description != ""))
    end
  end

  describe "init/3" do
    test "scaffolds a new custom workflow from the elixir template", %{cwd: cwd} do
      assert {:ok, path} = Definition.init("my-team-flow", "elixir", cwd)
      assert File.exists?(path)

      assert {:ok, %Definition{name: "my-team-flow"}} = Definition.load("my-team-flow", cwd)
    end

    test "refuses to overwrite an existing custom workflow", %{cwd: cwd} do
      {:ok, _} = Definition.init("dup", "elixir", cwd)
      assert {:error, msg} = Definition.init("dup", "elixir", cwd)
      assert msg =~ "already exists"
    end

    test "rejects an unknown template name", %{cwd: cwd} do
      assert {:error, msg} = Definition.init("whatever", "not-a-template", cwd)
      assert msg =~ "Unknown template"
    end
  end
end
