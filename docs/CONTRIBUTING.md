# Contributing to DeepSeek Harness (DSH)

Thank you for contributing to DeepSeek Harness! This guide outlines how to create custom plugins, skills, MCP tools, and tests.

---

## 1. Creating Custom Plugin Tools

Plugins in DSH implement `DeepSeekHarness.Plugin.Behaviour`:

```elixir
defmodule MyCustomPlugin do
  @behaviour DeepSeekHarness.Plugin.Behaviour

  @impl true
  def name, do: "MyCustomPlugin"

  @impl true
  def description, do: "Custom utility tools for project analysis."

  @impl true
  def tools do
    [
      %{
        name: "my_tool",
        description: "Executes custom analysis",
        parameters: %{
          type: "object",
          properties: %{
            query: %{type: "string", description: "Search query"}
          },
          required: ["query"]
        },
        execute: &execute_my_tool/1
      }
    ]
  end

  def execute_my_tool(%{"query" => query}) do
    {:ok, "Result for #{query}"}
  end
end
```

Load plugins at startup or via `/plugins reload` live without dropping state:
```bash
dsh --plugin path/to/my_custom_plugin.exs
```

---

## 2. Creating Custom Skills

Skills are instruction folders placed in `.dsh/skills/<skill_name>/SKILL.md`:

```markdown
---
name: security-audit
description: Runs static analysis security check
---

# Security Audit Skill
1. Check for exposed secrets or hardcoded API keys.
2. Verify input sanitization in web endpoints.
```

---

## 3. Running Code Quality & Test Verification

Run all test suites and static code analysis:
```bash
mix test
mix format --check-formatted
mix credo --strict
```
