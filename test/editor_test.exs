defmodule Yoke.CLI.EditorTest do
  use ExUnit.Case, async: true

  alias Yoke.CLI.Editor

  describe "editor detection & execution" do
    test "get_editor/1 respects EDITOR and VISUAL env vars" do
      System.put_env("EDITOR", "my_custom_editor")
      assert Editor.get_editor() == "my_custom_editor"

      System.delete_env("EDITOR")
      System.put_env("VISUAL", "my_visual_editor")
      assert Editor.get_editor() == "my_visual_editor"

      System.delete_env("VISUAL")
      assert Editor.get_editor("nano") == "nano"
    end

    test "edit_text/2 falls back when no valid EDITOR executable exists" do
      System.put_env("EDITOR", "non_existent_editor_cmd_12345")
      assert {:fallback, "sample text"} = Editor.edit_text("sample text")
      System.delete_env("EDITOR")
    end

    test "edit_file/2 reports error when editor binary is not found" do
      System.put_env("EDITOR", "non_existent_editor_cmd_12345")
      assert {:error, :no_editor} = Editor.edit_file("test.txt")
      System.delete_env("EDITOR")
    end
  end
end
