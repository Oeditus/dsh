defmodule DeepSeekHarness.HandsExecutorTest do
  use ExUnit.Case, async: true

  alias DeepSeekHarness.Hands.Executor

  test "executes local tool call" do
    config = %Executor{mode: :local}
    assert {:ok, _} = Executor.execute(config, "bash", %{"command" => "echo 'hello'"})
  end

  test "handles remote mode with bad node" do
    config = %Executor{mode: :remote, remote_node: :bad_node@local}
    assert {:error, msg} = Executor.execute(config, "bash", %{"command" => "echo 'hello'"})
    assert String.contains?(msg, "Remote node unreachable")
  end

  test "handles docker mode execution" do
    config = %Executor{mode: :docker, docker_container: "non_existent_container"}
    assert {:error, msg} = Executor.execute(config, "bash", %{"command" => "echo 'hello'"})
    assert String.contains?(msg, "Docker exec exited")
  end

  test "fallbacks unhandled docker tools to local" do
    config = %Executor{mode: :docker, docker_container: "non_existent_container"}
    assert {:ok, _} = Executor.execute(config, "read_file", %{"path" => "mix.exs"})
  end
end
