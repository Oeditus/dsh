# DeepSeek Harness (DSH)

An agentic CLI coding harness for **DeepSeek** models (`deepseek-chat` V3, `deepseek-coder` V2.5, and `deepseek-reasoner` R1), built in **Elixir & Erlang/OTP**.

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

### 2. DeepSeek Model Selection & Best Practices

DeepSeek Harness supports the full suite of official DeepSeek models, local open-weights models, and third-party API aggregators. Switch models anytime via `/model <alias>` or `--model <alias>`:

| Model | ID / Alias in DSH | Best Used For | Strengths & Characteristics |
| :--- | :--- | :--- | :--- |
| **DeepSeek-V3** | `deepseek-chat`<br>`/model chat` | **Agentic workflows & multi-tool tasks** *(Default)* | 671B MoE model. Offers high general reasoning and **highest tool-calling precision** across multi-turn agent loops. |
| **DeepSeek-Coder-V2.5** | `deepseek-coder`<br>`/model coder` | **Direct code generation, syntax completion & refactoring** | Trained specifically on **338+ programming languages**. Produces idiomatic Elixir/C++/Rust code with high precision on syntax and language conventions. |
| **DeepSeek-R1** | `deepseek-reasoner`<br>`/model reasoner` | **Complex debugging & architectural design** | Reinforcement Learning (RL) reasoning model. DSH captures and streams `[DeepSeek-R1 Reasoning]` Chain-of-Thought output live before tool execution. |

---

## Key Features & Capabilities

### 1. Persistent Session Resumption (`dsh -c <id>` & `/resume`)
- Every session is assigned a unique UUID (e.g. `df97eb34-cb33-4f21-bada-2e9c3cf75d46`).
- On exit, `dsh` prints your conversation ID:
  ```
  Resume with -c (or command below):
  dsh --conversation=df97eb34-cb33-4f21-bada-2e9c3cf75d46
  ```
- Resume any conversation across restarts with `dsh -c <id>` or interactively pick past sessions in the REPL via `/resume`.

### 2. Scoped Rule Engine (`/rules`)
- Manage prompt preambles and execution constraints.
- **Scopes**:
  - `all:` — Applied to all user prompt turns (e.g. `all: typographic quotes “” mean the exact quote`).
  - `<command>:` — Applied only when executing specific commands (e.g. `cr: format table cells multiline to fit in 80 symbols width` for `/cr`).
- Use `/rules` to list rules, `/rules add <scope: text>` to add rules, and `/rules delete` to launch the interactive checkbox modal.

### 3. Context Reference Expansion (`@`) & Smart Error Resolution
- Type `@filename`, `@/path`, `@file://...`, or `@https://...` anywhere in user prompts to attach contents.
- `@` triggers an interactive TUI file picker filtered by `.gitignore` rules (excluding `_build`, `deps`, `.elixir_ls`).
- Intelligently expands ambiguous error references ("error above", `@error`) and tracks `:open` vs `:resolved` issue status across tool calls.

### 4. Interactive Question TUI Modal (`ask_question`)
- Allows the AI model to request user feedback, clarify requirements, or present multi-choice design decisions with keyboard navigation and OK/Cancel buttons.

### 5. Model Context Protocol (MCP) & First-Class Ragex Integration
- Mount external Model Context Protocol (MCP) servers via `stdio` (JSON-RPC) or HTTP/SSE.
- Native integration with **Ragex** for SCIP code indexing, AST refactoring, and semantic code search (`/ragex`).

### 6. One-Command Global Installation & Updates
- Install globally to `~/.local/bin/dsh` via `mix dsh.install` or `install.sh`.
- Run `dsh` smoothly from **any** workspace directory.
- Perform background in-place self-updates anytime using `dsh --update` or `/update`.

---

## Installation & Setup

This guide provides step-by-step instructions to get **DeepSeek Harness (`dsh`)** up and running on your system, along with its database backend **`dllb`** (which powers **Ragex** code analysis and knowledge graph indexing).

---

### Prerequisites (What You Need First)

Before installing `dsh` or `dllb`, ensure your machine has the following tools installed:

1. **Elixir & Erlang/OTP**: 
   - `dsh` is built using the Elixir programming language on top of the Erlang runtime engine.
   - **Required versions**: Elixir `1.18+` and Erlang/OTP `27+`.
   - *How to install*: Use your system package manager (e.g. `brew install elixir` on macOS or `sudo apt install elixir` on Ubuntu) or a version manager like [`asdf`](https://asdf-vm.com/) / [`mise`](https://mise.jdx.dev/).
2. **Git**: Required to download the project source code.
3. **C/C++ Build Tools & Libraries** *(Linux only)*:
   - Required for compiling native code dependencies: `build-essential` and `libgit2-dev`.
   - *Ubuntu/Debian command*: `sudo apt-get install -y build-essential libgit2-dev`

---

### 1. Installing `dsh` (DeepSeek Harness)

Choose **one** of the two installation methods below:

#### Option A: Quick Automated Installer (Recommended)

Run this single command in your terminal to automatically clone, build, and install `dsh`:

```bash
curl -fsSL https://raw.githubusercontent.com/Oeditus/ragec/main/install.sh | bash
```

#### Option B: Manual Installation from Source

If you prefer installing manually from the source code:

```bash
# 1. Clone the repository
git clone https://github.com/Oeditus/ragec.git
cd ragec

# 2. Fetch project dependencies
mix deps.get

# 3. Compile and install dsh globally to ~/.local/bin/dsh
mix dsh.install
```

#### 📍 Adding `~/.local/bin` to Your System `$PATH`

After installation, ensure `~/.local/bin` is included in your shell path so you can run `dsh` from any terminal directory:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

> **Tip:** Add the line above to your shell configuration file (e.g. `~/.bashrc` or `~/.zshrc`) so it is available automatically in every new terminal window.

---

### 2. Installing `dllb` for `ragex` Code Indexing

#### What is `dllb` and why do I need it?
`dsh` features a powerful code intelligence engine called **Ragex** (`/ragex`). To store code symbol relationship graphs, perform fast full-text code searches, and cache project metadata across restarts, Ragex uses a lightweight, high-performance database server called **`dllb-server`** (written in Rust).

Installing `dllb-server` enables persistent, per-project database indexing.

#### Option A: Download Pre-Compiled Binary (Easiest)

1. Go to the [`dllb` GitHub Releases](https://github.com/Oeditus/dllb/releases) page.
2. Download the `dllb-server` binary for your platform (e.g., Linux or macOS).
3. Move the binary into your `~/.local/bin` directory (or any directory in your system `$PATH`) and make it executable:

```bash
# Move to local bin directory
mv dllb-server ~/.local/bin/

# Make executable
chmod +x ~/.local/bin/dllb-server
```

#### Option B: Compile `dllb-server` from Source (Rust / Cargo)

If you have the **Rust toolchain** installed (`cargo`):

```bash
# 1. Clone the dllb repository
git clone https://github.com/Oeditus/dllb.git
cd dllb

# 2. Build the optimized release binary
cargo build --release -p dllb-server

# 3. Option i: Copy the compiled binary to your PATH
cp target/release/dllb-server ~/.local/bin/

# OR Option ii: Leave it in sibling directory `../dllb/target/release/dllb-server`
```

#### How Ragex Finds `dllb-server` (Path Resolution Precedence)

When you run `/ragex` inside `dsh`, Ragex looks for the `dllb-server` executable automatically in this order:

1. **Custom Environment Variable**: `DLLB_SERVER_BIN=/path/to/dllb-server`
2. **System `$PATH`**: Directories in your `$PATH` (e.g. `~/.local/bin/dllb-server` or `/usr/local/bin/dllb-server`).
3. **Sibling Repository Path**: Relative path `../dllb/target/release/dllb-server` or `../dllb/target/debug/dllb-server`.

---

### 3. Verifying Your Installation

1. **Check `dsh` CLI**:
   ```bash
   dsh --version
   ```
2. **Start `dsh` in any project**:
   ```bash
   cd /path/to/your/project
   dsh
   ```
3. **Test Ragex Code Indexing**:
   Inside the `dsh` REPL session, type:
   ```text
   /ragex
   ```
   You should see confirmation that Ragex and the `dllb` knowledge graph backend have been successfully initialized!

---

## REPL Slash Commands & Shortcuts

| Command | Action |
| :--- | :--- |
| `!command` | Execute shell command directly (e.g. `!git status`, `!mix test`) |
| `/cr [base]` | Generate Code Review for current branch against `main` or custom base |
| `/diff [branch]` | Display colorized git diff of workspace or against target branch |
| `/resume [id]` | Resume specific session ID or open interactive conversation picker modal |
| `/rules [add\|delete]` | Manage scoped prompt preambles and launch deletion checkbox modal |
| `/model [chat\|coder\|reasoner]` | Switch active model (`deepseek-chat`, `deepseek-coder`, `deepseek-reasoner`) |
| `/mode [local\|remote\|docker]` | Set Hands execution target |
| `/compact` | Compress conversation context to save tokens |
| `/undo` | Roll back state to previous temporal checkpoint |
| `/checkpoint [label]` | Create a manual temporal state snapshot |
| `/plugins [reload]` | List tools or hot-reload plugins live without dropping state |
| `/mcp [list\|add\|load]` | Manage Model Context Protocol (MCP) servers and tools |
| `/ragex` | Mount first-class Ragex code analysis & refactoring MCP tools |
| `/skills [name]` | List available skills or execute a skill instruction |
| `/update` | Background self-update `dsh` release to latest code |
| `/commit <message>` | Auto-stage and commit workspace changes |
| `/cost` \| `/tokens` | Display token usage breakdown and cumulative session cost |
| `/permissions [auto\|ask]` | Set tool execution safety mode |
| `/subagent <prompt>` | Spawn a background subagent worker for sub-tasks |
| `/cb` \| `/clipboard` | Copy latest assistant response to system clipboard |
| `/clear` | Clear terminal output |
| `/help` | Display help menu |
| `/exit` \| `/quit` | Exit DeepSeek Harness and print conversation resume banner |

---

## Documentation

For full command reference, keyboard shortcuts, rule scoping tactics, and advanced BEAM distribution workflows, see [`docs/cheat_sheet.md`](file:///home/am/Proyectos/Oeditus/ragec/docs/cheat_sheet.md).
