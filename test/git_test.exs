defmodule DeepSeekHarness.GitTest do
  use ExUnit.Case, async: true

  alias DeepSeekHarness.Git

  test "returns git status and diff" do
    assert {:ok, _status} = Git.status()
    assert {:ok, _diff} = Git.diff()
    assert {:ok, _diff_head} = Git.diff("HEAD")
  end

  test "diff_branches compares HEAD against HEAD" do
    assert {:ok, data} = Git.diff_branches("HEAD", "HEAD")
    assert data.base == "HEAD"
    assert data.head == "HEAD"
    assert is_binary(data.stat)
  end
end
