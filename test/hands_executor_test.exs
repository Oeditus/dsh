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

  test "returns correct tool icon for known tools" do
    assert Executor.tool_icon("read_file") == "󰈔"
    assert Executor.tool_icon("write_file") == "󰏫"
    assert Executor.tool_icon("bash") == "󰆍"
    assert Executor.tool_icon("grep_search") == "󰍉"
    assert Executor.tool_icon("list_dir") == "󰉋"
    assert Executor.tool_icon("git_status") == "󰘬"
    assert Executor.tool_icon("unknown_tool") == "󰒓"
  end

  test "formats tool calls user-friendly" do
    assert Executor.format_tool_call("read_file", %{"path" => "test/git_test.exs"}) ==
             "read_file(path: \"test/git_test.exs\")"

    assert Executor.format_tool_call("bash", %{"command" => "mix test"}) ==
             "bash(command: \"mix test\")"

    assert Executor.format_tool_call("list_dir", %{}) == "list_dir()"
  end
end
