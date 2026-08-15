# DeepSeek Harness (DSH) in Elixir 🚀

An advanced, feature-rich agentic CLI coding harness for **DeepSeek** models (`deepseek-chat` V3 and `deepseek-reasoner` R1), built in **Elixir & Erlang/OTP**.

Derived from **José Valim’s architectural principles**, **DeepSeek Harness (DSH)** / **Cordis** (*Spatiotemporal Composability*), **Google Antigravity (`agy`)**, and **Claude Code CLI**.

---

## 🌟 Derived Features & Capabilities

### 1. 🔍 `@` Reference Expansion
- Pass `@filename`, `@/absolute/path`, `@../relative/path`, `@file://...`, or `@https://...` anywhere in user prompts.
- Automatically resolves and injects formatted file or URI contents into the context window before sending to DeepSeek.

### 2. 📜 Project Rules & Context (`.dshrules` / `.dsh/rules.md`)
- Automatically discovers `.dshrules`, `.dsh/rules.md`, or `AGYRULES` in workspace directory and appends them to the agent's system prompt context.

### 3. 🎯 Skill Instruction Engine (`/skills`)
- Discovers skill instruction directories (`SKILL.md`) in `.dsh/skills/`, `~/.dsh/skills/`, or custom paths.
- View and execute skills via `/skills` and `/skill <name>`.

### 4. 🔌 Model Context Protocol (MCP) & First-Class Ragex Integration
- **Ragex (`@../ragex`) First-Class Support**: Type `/ragex` inside `./dsh` to mount **~50 advanced code analysis, SCIP indexing, semantic search, quality audit, and AST refactoring tools** into DeepSeek Harness.
- `DeepSeekHarness.MCP.Client` connects to any external Model Context Protocol (MCP) servers over `stdio` (JSON-RPC) or HTTP/SSE.
- Dynamically converts external MCP tools into native DSH plugin tools.

### 5. ⚡ Direct Shell Execution Shortcut (`!cmd`)
- Type `!command` (e.g. `!git status`, `!ls -la`, `!mix test`) directly in the REPL for instant shell execution.

### 6. 🗜️ Context Compression (`/compact`)
- Summarizes long message histories using DeepSeek to free up context window space while preserving key architectural decisions and modified file history.

### 7. 🔀 Git Awareness & `/diff` / `/commit`
- `/diff`: Renders ANSI colorized git diffs of unstaged workspace modifications.
- `/commit <message>`: Auto-stages and commits changes with structured message generation.

### 8. 📊 Token & Cost Statistics (`/cost`)
- Displays estimated context tokens, completion tokens, total session token usage, and API cost estimates.

### 9. 🛡️ Permission Safety Modes (`/permissions`)
- Toggle permission modes (`:ask_confirm` vs `:auto_approve` / YOLO mode) for file modifications and bash commands.

### 10. 🧠 Background Subagents (`/subagent`)
- Spawn background subagent session actors (`SessionSupervisor.start_session`) to handle parallel research or complex sub-tasks.

---

## ⚡ Quick Start

```bash
# Build binary
mix deps.get
mix compile
mix escript.build

# Launch interactive REPL
./dsh

# One-shot command execution with @ file reference
./dsh "Summarize the implementation in @lib/deep_seek_harness/brain/session.ex"
```

---

## 🎮 REPL Commands & Shortcuts

```
  !command                 Execute shell command directly (e.g. !ls -la or !git status)
  /help                   Show help menu
  /model [chat|reasoner]   Switch model (deepseek-chat V3 or deepseek-reasoner R1)
  /mode [local|remote|docker]  Set Hands execution target
  /plugins [reload]       List tools or hot-reload plugins live without dropping state
  /skills [name]          List available skills or execute a skill instruction
  /compact                Compress conversation context to save tokens
  /diff                   Show colorized git diff of workspace changes
  /commit <message>       Auto-commit staged workspace changes to git
  /cost                   Display token usage and session cost statistics
  /permissions [auto|ask] Set tool execution safety mode
  /subagent <prompt>      Spawn a background subagent worker for sub-tasks
  /checkpoint [label]     Create a temporal state snapshot
  /undo                   Roll back state to previous checkpoint
  /session                Display active session metadata & statistics
  /nodes                  View distributed Erlang node cluster status
  /clear                  Clear terminal output
  /exit or /quit          Exit DeepSeek Harness
```
