defmodule DeepSeekHarness.ContextExpanderTest do
  use ExUnit.Case, async: true

  alias DeepSeekHarness.CLI.ContextExpander

  test "expands local relative path file reference" do
    tmp_path = Path.join(System.tmp_dir!(), "test_ref_#{System.unique_integer([:positive])}.txt")
    File.write!(tmp_path, "Hello reference context!")

    prompt = "Please inspect @#{tmp_path} and summarize it."
    assert {:ok, expanded, attachments} = ContextExpander.expand(prompt)

    assert String.contains?(expanded, "[Ref: #{tmp_path}]") and
             String.contains?(expanded, "Hello reference context!")

    assert tmp_path in attachments

    File.rm(tmp_path)
  end

  test "expands relative path with parent dir (@../foo)" do
    tmp_dir = Path.join(System.tmp_dir!(), "sub_dir_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    tmp_file = Path.join(tmp_dir, "file.txt")
    File.write!(tmp_file, "Parent relative test")

    assert {:ok, expanded, _attachments} = ContextExpander.expand("Check @#{tmp_file}")
    assert String.contains?(expanded, "Parent relative test")

    File.rm_rf!(tmp_dir)
  end

  test "expands file URI reference (@file://...)" do
    tmp_path = Path.join(System.tmp_dir!(), "file_uri_#{System.unique_integer([:positive])}.txt")
    File.write!(tmp_path, "File URI content")

    assert {:ok, expanded, _attachments} = ContextExpander.expand("Check @file://#{tmp_path}")
    assert String.contains?(expanded, "File URI content")

    File.rm(tmp_path)
  end

  test "enforces workspace sandbox bounds when enabled" do
    workspace = Path.join(System.tmp_dir!(), "workspace_#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    inside_file = Path.join(workspace, "inside.txt")
    outside_file = Path.join(System.tmp_dir!(), "outside_#{System.unique_integer([:positive])}.txt")

    File.write!(inside_file, "Inside workspace")
    File.write!(outside_file, "Outside workspace")

    # Allowed inside workspace
    assert {:ok, exp1, _att1} = ContextExpander.expand("Read @#{inside_file}", workspace, sandbox_workspace: true)
    assert String.contains?(exp1, "Inside workspace")

    # Denied outside workspace sandbox
    assert {:ok, exp2, att2} = ContextExpander.expand("Read @#{outside_file}", workspace, sandbox_workspace: true)
    refute String.contains?(exp2, "Outside workspace")
    assert att2 == []

    File.rm_rf!(workspace)
    File.rm(outside_file)
  end

  test "retains original token if target file does not exist" do
    assert {:ok, expanded, attachments} =
             ContextExpander.expand("Check @/tmp/non_existent_file_xyz_123.txt")

    assert String.contains?(expanded, "@/tmp/non_existent_file_xyz_123.txt")
    assert attachments == []
  end
end
