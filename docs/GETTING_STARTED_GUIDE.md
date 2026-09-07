# DeepSeek Harness (DSH) — Comprehensive Onboarding & Customization Guide

Welcome to **DeepSeek Harness (DSH)** — the open-source, developer-first agentic coding CLI built on the **Erlang/BEAM Virtual Machine**.

This guide is designed to take you from a fresh installation to completely tailoring DSH to your exact engineering standards:
1. [Core Architecture & Quickstart](#1-core-architecture--quickstart)
2. [Teaching DSH New Language Idiomatics (`.dsh/practices`)](#2-teaching-dsh-new-language-idiomatics-dshpractices)
3. [Starting & Driving Workflows (`/workflow`)](#3-starting--driving-workflows-workflow)
4. [Tuning Workflows for Your Team's Needs](#4-tuning-workflows-for-your-teams-needs)
5. [Writing Custom Elixir Plugins (`Plugin.Behaviour`)](#5-writing-custom-elixir-plugins-pluginbehaviour)
6. [Managing Scoped Rules, Custom Skills & Ragex MCP](#6-managing-scoped-rules-custom-skills--ragex-mcp)
7. [The Iterative Feedback Loop: Fitting Expectations 100%](#7-the-iterative-feedback-loop-fitting-expectations-100)

---

## 1. Core Architecture & Quickstart

### The BEAM Actor Advantage
Unlike single-threaded Node.js or Python coding harnesses that crash and wipe context when a tool execution fails, DSH separates reasoning (**Brain**) from execution (**Hands**):
- **Process Isolation**: The session actor (`DeepSeekHarness.Brain.Session`) runs as an OTP GenServer. Tool executions and sub-tasks run in isolated BEAM processes. If a shell command or external script fails, the session stays 100% intact.
- **Spatiotemporal Checkpoints**: Spatiotemporal state snapshots capture context, conversation history, and model parameters before major changes. You can roll back anytime with `/undo`.

### Basic Invocation
```bash
# Launch interactive REPL mode
dsh

# Run a one-shot command
dsh "Implement JWT authentication in lib/auth.ex"

# Switch model or execution target
dsh --model deepseek-reasoner
dsh --plugin path/to/my_plugin.exs
```

### Essential REPL Commands
- `/help` — List all slash commands and keyboard shortcuts.
- `/model [chat|reasoner]` — Switch between `deepseek-chat` (V3) and `deepseek-reasoner` (R1).
- `/mode [local|remote|docker]` — Switch Hands execution environment (Local host, Remote Erlang node, Docker container).
- `/ragex` — Mount first-class **Ragex** code intelligence engine (SCIP symbol graphs & AST search).
- `/checkpoint [label]` / `/undo` — Create state snapshot or revert to previous checkpoint.
- `/subagent <prompt>` — Spawn an independent background BEAM worker process for sub-tasks.
- `/compact` — Compress conversation history to save tokens.

### Context Expansion (`@` references)
Attach rich context directly inside prompts:
- `@lib/auth.ex` or `@file://path/to/file` — Inline file content into the prompt.
- `@https://hexdocs.pm/elixir/Kernel.html` — Fetch static web pages or documentation.
- `@error` or `"error above"` — Automatically attach recent build/tool log tracebacks.

---

## 2. Teaching DSH New Language Idiomatics (`.dsh/practices`)

When DSH works on a project, it automatically injects language-specific **Good Practices** into the system prompt context. You can teach DSH new languages, domain-specific conventions, or architectural guidelines using `.lmml` practice manifests.

### Practice Storage Locations & Precedence
1. **Project-Local**: `.dsh/practices/<language>.lmml` (takes highest precedence, specific to this repository).
2. **Global**: `~/.dsh/practices/<language>.lmml` (applies to all projects in that language on your system).
3. **Built-in Defaults**: Fallback guidelines shipped with DSH.

When both global and project-local files exist, DSH merges them seamlessly.

### Practice Manifest Structure (`.lmml`)
Practice manifests use **LMML** (a human-readable Markdown superset with inline `@@@manifest.json` metadata):

```markdown
# Good Practices for Elixir & Phoenix

@@@manifest.json
{
  "language": "elixir",
  "version": "1.0.0",
  "sources": ["exemplary_project_a", "company_styleguide"],
  "updated_at": "2026-09-07T18:00:00Z"
}
@@@

### Good Practices

- Follow standard Mix project structure (`lib/`, `test/`, `config/`).
- Use pattern matching in function heads rather than complex conditional branching (`def handle({:ok, val})`).
- Prefer the pipe operator `|>` for sequential data transformations.
- Always write explicit `{:ok, result}` or `{:error, reason}` tuples for boundary functions.
- Enforce strict Credo code checks with `/linter oeditus_credo`.
- Write unit tests in `test/` using `ExUnit` covering edge cases and boundary conditions.
```

### Interactive Training Workflow: Squeezing Exemplary Codebases
If you start working on a project in a new language (e.g., Rust, Go, TypeScript), DSH will detect the language and prompt you to point to exemplary repositories:

1. Type `/practices teach <language>` or answer the initialization prompt.
2. Provide paths to 1-3 exemplary, well-written codebases.
3. DSH will inspect the project structure, extract idiomatic design patterns, and squeeze out a human-editable `.lmml` file saved directly to `.dsh/practices/<language>.lmml`.
4. Edit `.dsh/practices/<language>.lmml` anytime to add or refine team-specific coding rules.

---

## 3. Starting & Driving Workflows (`/workflow`)

DSH features a built-in **Workflow Engine** that executes multi-step engineering pipelines on top of the agent loop — from branching to parallel task splitting, testing, linting, and committing.

### The Bundled `elixir` Workflow Pipeline

| Phase | Step Type | Action |
| :--- | :--- | :--- |
| ① | `branch` | Creates and checks out `dsh/elixir/<run-id>` off your active branch. |
| ② | `task_description` | Summarizes your task into a structured Markdown spec (`task_description.md`). |
| ③ | `task_split` | Evaluates if the task can be split into 2-5 non-clashing sub-tasks. |
| ④ | `subtask execution` | Spawns isolated Git worktrees and parallel BEAM subagents for split tasks. |
| ⑤ | `tests_and_docs` | Requires unit tests and docs, then actually executes `mix test` to verify. |
| ⑥ | `lint` | Gates on `mix format --check-formatted` and `mix credo diff <base>`. |
| ⑦ | `commit` | Stages changes (excluding `.dsh/`) and creates a git commit with a summary. |

### Workflow Execution Commands
```bash
# List available workflow definitions
/workflow list

# Run the elixir workflow for a specific feature task
/workflow run elixir "Add token refresh endpoint to AuthController"

# Inspect active or past workflow runs
/workflow status

# Inspect a specific workflow run ID
/workflow status elixir-1730000000-ab12cd

# Resume an interrupted or paused workflow run
/workflow resume elixir-1730000000-ab12cd

# Abort a workflow run
/workflow abort elixir-1730000000-ab12cd
```

### Non-Clashing Parallel Worktree Execution
When a workflow splits a task into sub-tasks:
1. Each sub-task is assigned its own **isolated Git worktree** at `.dsh/workflows/runs/<run-id>/subtasks/<id>`.
2. Each worktree runs on its own branch (`<workflow-branch>/subtask/<id>`) under a dedicated `Session` GenServer.
3. Because sub-tasks execute in separate directory trees, file write races are physically impossible.
4. Once completed, worktree branches are merged back into the main workflow branch sequentially.

---

## 4. Tuning Workflows for Your Team's Needs

You can customize existing workflows or build brand-new ones tailored to your stack (e.g. Python/Django, Rust/Cargo, TypeScript/React).

### Initializing a Custom Workflow
To create a new workflow definition based on the built-in template:
```bash
/workflow init my-team-flow --from elixir
```
This materializes a definition file at `.dsh/workflows/definitions/my-team-flow.json`.

### Customizing Workflow Step Definitions (`.json`)
Open `.dsh/workflows/definitions/my-team-flow.json` to customize the step pipeline:

```json
{
  "name": "my-team-flow",
  "description": "Custom engineering pipeline for Acme Corp services",
  "rules_scope": "my_team_workflow",
  "steps": [
    {
      "id": "branch",
      "type": "branch",
      "prefix": "feature/acme"
    },
    {
      "id": "spec",
      "type": "task_description",
      "prompt": "Create an explicit architectural spec before writing code."
    },
    {
      "id": "parallel_split",
      "type": "task_split",
      "max_subtasks": 4
    },
    {
      "id": "verify_tests",
      "type": "tests_and_docs",
      "test_command": "mix test --exclude integration"
    },
    {
      "id": "quality_gate",
      "type": "lint",
      "command": "mix quality"
    },
    {
      "id": "auto_commit",
      "type": "commit",
      "message_prefix": "feat(core):"
    }
  ]
}
```

### Step Types Reference
- `branch`: Manages git branch creation and checkout. Supports `"prefix"`.
- `task_description`: Forces structured spec creation before implementation.
- `task_split`: Evaluates task parallelizability. Configured via `"max_subtasks"`.
- `prompt`: Runs arbitrary prompt instructions against the agent.
- `tests_and_docs`: Mandates tests + docs, executes `"test_command"`.
- `lint`: Mandatory quality gate. Executes `"command"` (e.g., `mix credo`, `cargo clippy`, `pytest`).
- `commit`: Formats, stages, and commits changes. Supports `"message_prefix"`.

---

## 5. Writing Custom Elixir Plugins (`Plugin.Behaviour`)

When your team needs custom actions (e.g. querying an internal API, validating GraphQL schemas, deploying to staging, inspecting database state), write a custom **DSH Plugin**.

### The `DeepSeekHarness.Plugin.Behaviour` Contract
Create a `.exs` or `.ex` file implementing the behaviour callbacks:

```elixir
defmodule MyProject.Plugins.DatabaseValidator do
  @behaviour DeepSeekHarness.Plugin.Behaviour

  @impl true
  def name, do: "DatabaseValidator"

  @impl true
  def description, do: "Validates Ecto migration schemas against staging DB"

  @impl true
  def tools do
    [
      %{
        name: "validate_schema",
        description: "Validates that specified Ecto schema matches staging database tables.",
        parameters: %{
          type: "object",
          properties: %{
            schema_module: %{type: "string", description: "Elixir schema module (e.g., MyApp.User)"}
          },
          required: ["schema_module"]
        },
        execute: &validate_schema/1
      }
    ]
  end

  def validate_schema(%{"schema_module" => module_str}) do
    # Custom plugin logic here
    case Code.ensure_loaded(Module.concat([module_str])) do
      {:module, mod} ->
        {:ok, "Schema #{inspect(mod)} is valid and aligned with staging database."}

      {:error, _} ->
        {:error, "Module #{module_str} could not be loaded."}
    end
  end
end
```

### Loading Plugins
- **CLI Startup**: `dsh --plugin path/to/my_plugin.exs`
- **Dynamic Hot-Reload**: Place the plugin file in `.dsh/plugins/` and run `/plugins reload` inside the REPL. Hot-reloading registers new tools without dropping your session state!

---

## 6. Managing Scoped Rules, Custom Skills & Ragex MCP

### 1. Scoped Prompt Rules (`.dsh/rules.json`)
Persistent preamble rules steer agent behavior for specific scopes (`all`, `cr`, `commit`, or custom workflow scopes):

```bash
# Add a global rule
/rules add all: Always prefer Ragex MCP tools for code searching over raw bash commands.

# Add a Code Review rule
/rules add cr: Format table cells multiline to fit within 80 symbols width.

# List active rules
/rules list

# Toggle or delete rules by ID
/rules toggle 3
/rules delete 2
```

### 2. Custom Skills (`.dsh/skills/`)
Skills are modular instruction sets placed in `.dsh/skills/<skill_name>/SKILL.md` (or `~/.dsh/skills/`):

```markdown
---
name: ecto-migration-checker
description: Guideline for writing safe, non-locking Ecto database migrations
---

# Ecto Migration Checker Skill

When writing Ecto migrations:
1. Always set `local_prefix` if targeting multiple tenants.
2. Use `create_if_not_exists` index operations with `concurrently: true`.
3. Never execute raw `execute("ALTER TABLE ...")` without safety timeouts.
```

Invoke skills manually via `/skills ecto-migration-checker` or let DSH auto-activate them based on task context.

### 3. Ragex Code & Image Intelligence (`/ragex`)
Mount **Ragex** to give DSH native AST and SCIP code intelligence:
- `mcp_ragex_grep` & `mcp_ragex_search_code`: SCIP indexed full-text & symbol code search.
- `mcp_ragex_symbol_definition` & `mcp_ragex_symbol_references`: Exact cross-file symbol tracking.
- `mcp_ragex_metaast_search`: AST structure pattern matching.
- `mcp_ragex_structure` & `mcp_ragex_view`: High-level code structure inspection.
- `mcp_ragex_image_*`: High-performance image metadata, resize, crop, filter, composite, and SSIM visual diff tools (`mcp_ragex_image_compare`).

---

## 7. The Iterative Feedback Loop: Fitting Expectations 100%

To get DSH working exactly as your engineering team expects, follow this 4-step tuning cycle:

```
    ┌───────────────────────────────────────────────────────────┐
    │ 1. Observe Behavior                                       │
    │    Run DSH on real tasks. Watch tool calls and output.    │
    └─────────────────────────────┬─────────────────────────────┘
                                  │
                                  ▼
    ┌───────────────────────────────────────────────────────────┐
    │ 2. Codify Guidelines                                      │
    │    • Add rules via `/rules add`                           │
    │    • Refine `.dsh/practices/<lang>.lmml`                  │
    └─────────────────────────────┬─────────────────────────────┘
                                  │
                                  ▼
    ┌───────────────────────────────────────────────────────────┐
    │ 3. Automate Pipelines                                     │
    │    • Tune workflow definitions (`.dsh/workflows/`)        │
    │    • Add custom Elixir plugins (`.dsh/plugins/`)          │
    └─────────────────────────────┬─────────────────────────────┘
                                  │
                                  ▼
    ┌───────────────────────────────────────────────────────────┐
    │ 4. Snapshot & Replicate                                   │
    │    Commit `.dsh/` to Git so your entire team shares       │
    │    the exact same agent rules, practices, and workflows!  │
    └───────────────────────────────────────────────────────────┘
```

By version-controlling `.dsh/` inside your git repository, every engineer on your team gets an AI agent that adheres to the exact same architectural standards, lint gates, and workflow pipelines!
