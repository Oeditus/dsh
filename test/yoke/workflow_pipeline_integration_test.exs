defmodule Yoke.WorkflowPipelineIntegrationTest do
  use ExUnit.Case, async: true

  alias Yoke.WorkflowIndex

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "yoke_wf_integration_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(Path.join(tmp_dir, "project"))

    {:ok, _path, slug} =
      WorkflowIndex.create_thought(
        "Session Compaction",
        "Implement automatic context compaction on high token count.",
        cwd: tmp_dir
      )

    {:ok, _dest} =
      WorkflowIndex.promote_item(slug, "backlog",
        priority: "Must Have",
        type: "code",
        cwd: tmp_dir
      )

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir, slug: slug}
  end

  test "finds backlog item and activates it for workflow execution", %{
    tmp_dir: tmp_dir,
    slug: slug
  } do
    {:ok, item} = WorkflowIndex.find_and_activate("session_compaction", tmp_dir)
    assert item.stage == "active"
    assert item.slug == slug
    assert String.contains?(item.path, "project/workflow/active")

    items = WorkflowIndex.scan_items(tmp_dir)
    active_item = Enum.find(items, &(&1.slug == slug))
    assert active_item.stage == "active"
  end

  test "closes out active item to completed/ and records close-out lesson", %{
    tmp_dir: tmp_dir,
    slug: slug
  } do
    {:ok, _active_item} = WorkflowIndex.find_and_activate(slug, tmp_dir)

    {:ok, comp_path} = WorkflowIndex.close_out_active(slug, cwd: tmp_dir)
    assert String.contains?(comp_path, "project/workflow/completed")

    items = WorkflowIndex.scan_items(tmp_dir)
    comp_item = Enum.find(items, &(&1.slug == slug))
    assert comp_item.stage == "completed"

    {:ok, lessons_content, _} = Yoke.Lessons.load_lessons(tmp_dir)
    assert String.contains?(lessons_content, "Completed workflow task `#{slug}`")
  end
end
