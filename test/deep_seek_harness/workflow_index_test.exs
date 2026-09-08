defmodule DeepSeekHarness.WorkflowIndexTest do
  use ExUnit.Case, async: true

  alias DeepSeekHarness.WorkflowIndex

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "dsh_wf_index_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(Path.join(tmp_dir, "project"))

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "scaffolds stage directories and creates raw thought", %{tmp_dir: tmp_dir} do
    WorkflowIndex.ensure_scaffold(tmp_dir)
    assert File.dir?(Path.join(tmp_dir, "project/workflow/thoughts"))
    assert File.dir?(Path.join(tmp_dir, "project/workflow/backlog"))

    {:ok, path, slug} =
      WorkflowIndex.create_thought(
        "Authentication Refactor",
        "Refactor auth logic to use JWT tokens.",
        cwd: tmp_dir
      )

    assert String.contains?(slug, "authentication_refactor")
    assert File.exists?(path)

    items = WorkflowIndex.scan_items(tmp_dir)
    assert length(items) == 1
    item = hd(items)
    assert item.stage == "thoughts"
    assert Map.get(item.frontmatter, "summary") != ""
  end

  test "generates _MAP.md and _DEPS.md indexes and promotes items", %{tmp_dir: tmp_dir} do
    {:ok, _path, slug} =
      WorkflowIndex.create_thought(
        "Cache Engine",
        "Add Redis/ETS caching layer.",
        cwd: tmp_dir
      )

    {:ok, map_path, deps_path} = WorkflowIndex.generate_indexes(tmp_dir)
    assert File.exists?(map_path)
    assert File.exists?(deps_path)

    map_content = File.read!(map_path)
    assert String.contains?(map_content, "cache_engine")

    {:ok, dest_path} =
      WorkflowIndex.promote_item(slug, "backlog", priority: "Must Have", type: "code", cwd: tmp_dir)

    assert String.contains?(dest_path, "project/workflow/backlog")

    items = WorkflowIndex.scan_items(tmp_dir)
    item = Enum.find(items, &(&1.slug == slug))
    assert item.stage == "backlog"
    assert Map.get(item.frontmatter, "priority") == "Must Have"
  end

  test "checks items integrity for missing scalars", %{tmp_dir: tmp_dir} do
    WorkflowIndex.ensure_scaffold(tmp_dir)

    bad_file = Path.join(tmp_dir, "project/workflow/thoughts/20260908_invalid.md")
    File.write!(bad_file, "---\ntype: code\n---\n# Invalid thought\nNo summary scalar")

    assert {:error, errs} = WorkflowIndex.check_items(tmp_dir)
    assert Enum.any?(errs, &String.contains?(&1, "Missing required frontmatter scalar `summary:`"))
  end
end
