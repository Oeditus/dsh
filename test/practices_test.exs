defmodule DeepSeekHarness.PracticesTest do
  use ExUnit.Case, async: false
  alias DeepSeekHarness.Practices

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "dsh_practices_test_#{System.unique_integer([:positive])}"
      )

    global_dir = Path.join(tmp_dir, "global_practices")
    File.mkdir_p!(tmp_dir)
    File.mkdir_p!(global_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir, global_dir: global_dir}
  end

  test "detects elixir language from mix.exs", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "mix.exs"), "# mix config")
    assert Practices.detect_languages(tmp_dir) == ["elixir"]
  end

  test "detects python language from pyproject.toml", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "pyproject.toml"), "[project]")
    assert Practices.detect_languages(tmp_dir) == ["python"]
  end

  test "detects rust language from Cargo.toml", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "Cargo.toml"), "[package]")
    assert Practices.detect_languages(tmp_dir) == ["rust"]
  end

  test "saves and loads practices in .lmml format", %{tmp_dir: tmp_dir, global_dir: global_dir} do
    items = [
      "Use pattern matching in function signatures.",
      "Prefer pipe operator for clear transformations."
    ]

    {:ok, _content} =
      Practices.save_practices(
        "testelixir",
        items,
        [target: :local, global_dir: global_dir],
        tmp_dir
      )

    loaded = Practices.load_practices("testelixir", tmp_dir, global_dir: global_dir)
    assert loaded.language == "testelixir"
    assert loaded.items == items
    assert String.contains?(loaded.narrative, "# Good Practices for Testelixir")
    assert String.contains?(loaded.narrative, "@@@manifest.json")
  end

  test "merges global and local practices", %{tmp_dir: tmp_dir, global_dir: global_dir} do
    global_items = ["Global practice item 1", "Shared practice item"]
    local_items = ["Shared practice item", "Local practice item 2"]

    Practices.save_practices(
      "testlang",
      global_items,
      [target: :global, global_dir: global_dir],
      tmp_dir
    )

    Practices.save_practices(
      "testlang",
      local_items,
      [target: :local, global_dir: global_dir],
      tmp_dir
    )

    merged = Practices.load_practices("testlang", tmp_dir, global_dir: global_dir)

    assert merged.items == [
             "Global practice item 1",
             "Shared practice item",
             "Local practice item 2"
           ]
  end

  test "adds and deletes practice items", %{tmp_dir: tmp_dir, global_dir: global_dir} do
    Practices.save_practices(
      "testelixir2",
      ["Initial practice"],
      [target: :local, global_dir: global_dir],
      tmp_dir
    )

    {:ok, _} =
      Practices.add_practice("testelixir2", "New added practice", tmp_dir, global_dir: global_dir)

    loaded = Practices.load_practices("testelixir2", tmp_dir, global_dir: global_dir)
    assert "New added practice" in loaded.items

    {:ok, _} =
      Practices.delete_practices("testelixir2", [1], tmp_dir, global_dir: global_dir)

    updated = Practices.load_practices("testelixir2", tmp_dir, global_dir: global_dir)
    refute "Initial practice" in updated.items
    assert "New added practice" in updated.items
  end

  test "squeezes practices from exemplary project directory", %{
    tmp_dir: tmp_dir,
    global_dir: global_dir
  } do
    proj_dir = Path.join(tmp_dir, "exemplary_elixir")
    File.mkdir_p!(Path.join(proj_dir, "lib"))
    File.write!(Path.join(proj_dir, "mix.exs"), "defmodule Example.MixProject do; end")

    File.write!(
      Path.join([proj_dir, "lib", "example.ex"]),
      """
      defmodule Example do
        @moduledoc "Exemplary module"
        def run(val) when is_integer(val), do: {:ok, val * 2}
      end
      """
    )

    {:ok, _} =
      Practices.squeeze_practices("testelixir3", [proj_dir], cwd: tmp_dir, global_dir: global_dir)

    loaded = Practices.load_practices("testelixir3", tmp_dir, global_dir: global_dir)
    assert loaded.language == "testelixir3"
    assert match?([_ | _], loaded.items)
  end

  test "builds prompt preamble with language practices", %{
    tmp_dir: tmp_dir,
    global_dir: global_dir
  } do
    File.write!(Path.join(tmp_dir, "mix.exs"), "# mix")

    Practices.save_practices(
      "elixir",
      ["Practice line for test"],
      [target: :local, global_dir: global_dir],
      tmp_dir
    )

    preamble = Practices.build_preamble(tmp_dir)
    assert String.contains?(preamble, "=== Language Good Practices ===")
    assert String.contains?(preamble, "Good Practices for Elixir")
    assert String.contains?(preamble, "- Practice line for test")
  end
end
