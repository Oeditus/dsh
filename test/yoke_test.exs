defmodule YokeTest do
  use ExUnit.Case

  test "starts a session via top-level API and sends message" do
    {:ok, session_pid} = Yoke.start_session(session_id: "api_test")
    assert is_pid(session_pid)

    {:ok, response} = Yoke.send_message(session_pid, "What tools do you have?")
    assert is_binary(response.content)
  end

  test "returns non-empty version string matching configured version" do
    vsn = Yoke.version()
    assert is_binary(vsn)
    assert vsn =~ ~r/^\d+\.\d+\.\d+/
    assert vsn == Mix.Project.config()[:version]
  end
end
