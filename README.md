# DeepSeek Harness (DSH)

An agentic CLI coding harness for **DeepSeek** models (`deepseek-chat` V3 and `deepseek-reasoner` R1), built in **Elixir & Erlang/OTP**.

Derived from **José Valim's architectural framework** for process-isolated AI agents, **DeepSeek V3/R1 model architecture**, **Google Antigravity**, and **Warp Terminal TUI patterns**.

---

## Architectural Foundation: José Valim's Vision & DeepSeek Model Integration

DeepSeek Harness (DSH) bridges modern LLM reasoning capabilities with Erlang/OTP's battle-tested fault tolerance and process concurrency model.

### 1. José Valim's Actor-Driven Harness Architecture
In traditional AI harnesses (typically single-threaded Node.js or Python runtimes), a tool execution error or unhandled exception can crash the entire interactive session, wiping out conversation context and active state. DSH implements José Valim's vision for agentic harnesses on the BEAM virtual machine:

- **Decoupled Brain & Hands Architecture**: The agent's cognitive state ("Brain") runs as an isolated GenServer process (`DeepSeekHarness.Brain.Session`). Tool execution ("Hands") is cleanly separated (`DeepSeekHarness.Hands.Executor`), allowing commands to execute locally, on remote Erlang nodes, or inside isolated Docker containers.
- **Fault-Tolerant Supervision**: If a tool execution or sub-task process fails, the OTP supervision tree isolates the failure without impacting the user's interactive REPL session.
- **Spatiotemporal Checkpoints & Instant Rollback**: State snapshots record conversation history, model configurations, and context state before each tool execution turn, providing temporal undo capabilities (`/undo`) and state branching.
- **Live Hot-Code Tool Reloading**: Tools and plugins can be compiled, hot-swapped, or reloaded live (`/plugins reload`) without losing conversation memory or resetting GenServer process state.
- **Lightweight Parallel Subagents**: Sub-tasks can be delegated to child session processes (`SessionSupervisor.start_session`), running parallel agentic loops concurrently across BEAM worker threads.

### 2. DeepSeek Model Integration (V3 & R1)
DSH is tailored to maximize the reasoning and execution capabilities of DeepSeek V3 (`deepseek-chat`) and DeepSeek R1 (`deepseek-reasoner`):

- **First-Class Reasoning Token Handling**: Captures and renders `reasoning_content` emitted by DeepSeek R1, surfacing step-by-step chain-of-thought logic before tool invocation.
- **Adaptive Tool Execution Loop**: Detects duplicate tool call loops, provides automatic system feedback to redirect the model, and features automatic fallback to standard shell commands when non-standard tools fail repeatedly.
- **Context Compression & Cost Efficiency**: Built-in context summarization (`/compact`) maintains long-running coding sessions within token limits while tracking prompt and completion token statistics (`/cost`).

---

## Key Features & Capabilities

### 1. Interactive Question TUI Modal (`ask_question`)
- Exported tool (`ask_question`) allowing the AI model to request user feedback, clarify underspecified requirements, or present multi-choice design decisions.
- Displays a Warp / Antigravity styled terminal modal rendered in raw TTY mode with keyboard arrow navigation, option toggling, and custom write-in response support.

### 2. Context Reference Expansion (`@`)
- Pass `@filename`, `@/absolute/path`, `@../relative/path`, `@file://...`, or `@https://...` anywhere in user prompts.
- Automatically resolves and injects file or URI contents into the context window before sending prompts to DeepSeek.

### 3. Model Context Protocol (MCP) & First-Class Ragex Integration
- Mount external Model Context Protocol (MCP) servers via `stdio` (JSON-RPC) or HTTP/SSE.
- Native integration with **Ragex** (`@../ragex`) for SCIP code indexing, AST refactoring, and semantic code search.

### 4. Project Rules & Skill Engine
- Automatically discovers workspace rules (`.dshrules`, `.dsh/rules.md`) and appends them to the system prompt context.
- Discovers and executes skill instructions (`SKILL.md`) via `/skills` and `/skill <name>`.

### 5. Direct Shell Shortcut & Terminal Line Engine
- Fast shell execution shortcut using `!command` (e.g. `!git status`, `!mix test`).
- Modern terminal TUI line editor (`LineEditor`) featuring grapheme-aware cursor navigation, history search (Ctrl+R), slash-command autocompletion, and configurable prompt styling.

---

## Quick Start

### Building and Execution

```bash
# Fetch dependencies and compile project
mix deps.get
mix compile

# Launch interactive REPL mode
mix run -e "DeepSeekHarness.CLI.Main.main([])"

# One-shot command execution with @ file reference
mix run -e "DeepSeekHarness.CLI.Main.main([\"Summarize implementation in @lib/deep_seek_harness/brain/session.ex\"])"

# Build standalone binary executable
mix escript.build
./dsh
```

---

## REPL Commands & Shortcuts

```
  !command                 Execute shell command directly (e.g. !ls -la or !git status)
  /help                   Show help menu
  /model [chat|reasoner]   Switch model (deepseek-chat V3 or deepseek-reasoner R1)
  /mode [local|remote|docker]  Set Hands execution target
  /plugins [reload]       List tools or hot-reload plugins live without dropping state
  /mcp [list|add|load]    Manage Model Context Protocol (MCP) servers and tools
  /ragex                  Mount first-class Ragex code analysis & refactoring MCP tools
  /skills [name]          List available skills or execute a skill instruction
  /compact                Compress conversation context to save tokens
  /diff                   Show colorized git diff of workspace changes
  /review <base> [head]   Compare two git branches and generate a detailed Code Review
  /commit <message>       Auto-commit staged workspace changes to git
  /cost                   Display token usage and session cost statistics
  /permissions [auto|ask] Set tool execution safety mode
  /subagent <prompt>      Spawn a background subagent worker for sub-tasks
  /checkpoint [label]     Create a temporal state snapshot
  /undo                   Roll back state to previous checkpoint
  /session                Display active session metadata & statistics
  /nodes                  View distributed Erlang node cluster status
  /cb                     Copy latest assistant response to system clipboard
  /clear                  Clear terminal output
  /exit or /quit          Exit DeepSeek Harness
```
