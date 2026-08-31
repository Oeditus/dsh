# DeepSeek Harness (DSH) — Development Workflows

DeepSeek Harness provides versatile agentic workflows for software engineering tasks.

---

## 1. Interactive REPL Mode
Launch the interactive agent REPL:
```bash
dsh
```
- **Slash Commands**: Use `/help`, `/stats`, `/tokens`, `/session`, `/git`, `/diff`, `/review`, `/commit`.
- **Reference Files**: Attach context with `@file.ex`, `@file://path`, or `@https://domain.com/doc`.
- **Multi-line Inputs**: End a line with `\` or open `"""` to type multi-line prompts.

---

## 2. One-Shot Command Execution
Pass a prompt directly on the command line:
```bash
dsh "Refactor lib/auth.ex to use JWT tokens"
```
Flags:
- `--model deepseek-reasoner`: Switch to DeepSeek-R1 reasoning model.
- `--plugin path/to/plugin.exs`: Load custom Elixir tools on startup.

---

## 3. Autonomous Code Reviews & Branch Comparison
Compare active branch against main and generate a structured Code Review:
```bash
/review main HEAD
```

---

## 4. Spatiotemporal Checkpoints & Undo
Create manual checkpoints before major refactorings:
```bash
/checkpoint Pre-refactor-auth
```
If an automated step introduces issues, roll back instantly:
```bash
/undo
```

---

## 5. Subagent Worker Delegation
Delegate complex or parallel sub-tasks to supervised background subagents:
```bash
/subagent "Research quantum encryption algorithms and summarize in markdown"
```

---

## 6. Customizable Multi-Step Workflows (`/workflow`)
Run a named, customizable, multi-step process on top of the ordinary agent
loop -- branch, describe the task, propose a non-clashing parallel split,
require tests + docs, lint, and commit -- with the entire run persisted
under `.dsh/workflows/`:
```bash
/workflow run elixir Add JWT-based session refresh to the auth module
```
See [`docs/WORKFLOW_ENGINE.md`](WORKFLOW_ENGINE.md) for the full reference,
including how to write your own custom workflow definitions.
