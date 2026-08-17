# DeepSeek Harness — Troubleshooting Guide

Common diagnostic procedures for DeepSeek Harness CLI and runtime issues.

---

## 1. DeepSeek API Key Issues
**Symptom**: `AI configuration validation failed: API key not set`
**Resolution**:
Export your DeepSeek API Key before launching DSH:
```bash
export DEEPSEEK_API_KEY="sk-..."
dsh
```

---

## 2. Line Boundary Mismatch Error on `edit_file` / Ragex
**Symptom**: `Validation Error: Code changes produced invalid Elixir syntax: unexpected reserved word: "end"`
**Resolution**:
This occurs when `line_start` or `line_end` in `edit_file` extends past block boundaries (clipping or duplicating `def`, `do`, or `end` keywords). Inspect the line numbers of the function in your target file and pass the exact span to `edit_file`.

---

## 3. Remote Node Connection Failures
**Symptom**: `Remote node unreachable: nodedown`
**Resolution**:
Ensure both nodes share the exact same Erlang cookie and host configuration:
```bash
# On Hands host:
elixir --sname hands@127.0.0.1 --cookie secret_dsh_cookie -S mix run --no-halt

# On CLI Brain host:
dsh --node brain@127.0.0.1 --connect hands@127.0.0.1
```

---

## 4. MCP Server Stdio Timeouts
**Symptom**: `Failed to fetch tools/list from MCP server`
**Resolution**:
Check that the MCP server binary is executable and installed in system `$PATH`. Test manual execution via `/mcp list` or inspect `.dsh/config.json`.
