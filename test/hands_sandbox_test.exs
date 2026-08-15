defmodule DeepSeekHarness.HandsSandboxTest do
  use ExUnit.Case, async: false

  alias DeepSeekHarness.Hands.Executor, as: HandsExecutor

  test "executes local file operations cleanly" do
    config = %HandsExecutor{mode: :local}

    tmp_file = Path.join(System.tmp_dir!(), "test_sandbox_#{System.unique_integer([:positive])}.txt")

    # Write file
    {:ok, write_res} = HandsExecutor.execute(config, "write_file", %{"path" => tmp_file, "content" => "Hello DeepSeek Harness!"})
    assert write_res =~ "Successfully wrote"

    # Read file
    {:ok, read_res} = HandsExecutor.execute(config, "read_file", %{"path" => tmp_file})
    assert read_res == "Hello DeepSeek Harness!"

    # Replace file content
    {:ok, rep_res} = HandsExecutor.execute(config, "replace_file", %{"path" => tmp_file, "target" => "Hello", "replacement" => "Greetings"})
    assert rep_res =~ "Successfully replaced"

    # Verify replacement
    {:ok, read_res2} = HandsExecutor.execute(config, "read_file", %{"path" => tmp_file})
    assert read_res2 == "Greetings DeepSeek Harness!"

    File.rm(tmp_file)
  end

  test "executes local bash command" do
    config = %HandsExecutor{mode: :local}
    {:ok, out} = HandsExecutor.execute(config, "bash", %{"command" => "echo 'DSH Hands Execution Test'"})
    assert String.trim(out) == "DSH Hands Execution Test"
  end
end
