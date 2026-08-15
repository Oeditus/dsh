defmodule DeepSeekHarness.SkillManagerTest do
  use ExUnit.Case, async: true

  alias DeepSeekHarness.Skill.Manager, as: SkillManager

  test "parses SKILL.md file with frontmatter" do
    tmp_dir = Path.join(System.tmp_dir!(), "skill_test_#{System.unique_integer([:positive])}")
    skill_file = Path.join(tmp_dir, "SKILL.md")
    File.mkdir_p!(tmp_dir)

    content = """
    ---
    name: test-skill
    description: A sample test skill
    ---

    # Guidelines
    Perform clean refactoring.
    """

    File.write!(skill_file, content)

    assert {:ok, skill} = SkillManager.parse_skill_file(skill_file, "test-skill")
    assert skill.name == "test-skill"
    assert skill.description == "A sample test skill"
    assert String.contains?(skill.content, "Perform clean refactoring.")

    File.rm_rf!(tmp_dir)
  end
end
