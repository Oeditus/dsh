defmodule Yoke.ScrapTest do
  use ExUnit.Case, async: true

  alias Yoke.Scrap

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "yoke_scrap_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "appends and reads scrap notes", %{tmp_dir: tmp_dir} do
    {:ok, path} = Scrap.append_note("Consider using Ets for session cache", cwd: tmp_dir)
    assert String.ends_with?(path, ".yoke/scrap.md")

    {:ok, content, _path} = Scrap.read_scrap(cwd: tmp_dir)
    assert String.contains?(content, "Consider using Ets for session cache")

    {:ok, _} = Scrap.append_note("Verify beam memory limits", cwd: tmp_dir)
    {:ok, updated_content, _} = Scrap.read_scrap(cwd: tmp_dir)
    assert String.contains?(updated_content, "Verify beam memory limits")
  end

  test "clears scrap notes", %{tmp_dir: tmp_dir} do
    {:ok, _} = Scrap.append_note("Temporary note", cwd: tmp_dir)
    assert :ok == Scrap.clear_scrap(cwd: tmp_dir)

    {:ok, content, _} = Scrap.read_scrap(cwd: tmp_dir)
    assert String.contains?(content, "No scrap notes recorded yet")
  end
end
