defmodule DeepSeekHarness.LessonsTest do
  use ExUnit.Case, async: true

  alias DeepSeekHarness.Lessons

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "dsh_lessons_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(Path.join(tmp_dir, "project"))

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "appends, loads, and formats lessons learned", %{tmp_dir: tmp_dir} do
    {:ok, path} =
      Lessons.append_lesson("Always close ETS tables on process termination.", cwd: tmp_dir)

    assert String.ends_with?(path, "project/lessons.md")

    {:ok, content, _path} = Lessons.load_lessons(tmp_dir)
    assert String.contains?(content, "Always close ETS tables on process termination.")

    preamble = Lessons.build_preamble(tmp_dir)
    assert String.contains?(preamble, "Project Lessons Learned & Gotchas")
    assert String.contains?(preamble, "Always close ETS tables on process termination.")
  end
end
