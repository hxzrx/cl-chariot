# examples/ — Single-File Example Scripts

English | [简体中文](README.zh-CN.md)

Unlike `demo/` (a complete ASDF example project), this directory holds
**self-contained single-file scripts** you run directly with `--script` /
`--load`. Each one targets a typical entry scenario of the library.

| Script | Needs API key? | Scenario | What it shows |
|---|---|---|---|
| `mcp-demo.lisp` | No | **MCP client, end to end**: a scripted fake LLM drives the full agent loop; the agent calls tools bridged from a real MCP server (python3, stdio transport) | `make-mcp-client` → `initialize` handshake (version negotiation) → `mcp-tools-from-server` bridging → `execute-tool` → tool results fed back to the model → `annotations.readOnlyHint` mapped to readonly classification |
| `bwrap-sandbox.lisp` | No | **Sandbox boundary self-check**: before handing an agent a bash tool in production, verify the execution-world boundary holds | `bwrap-usable-p` pre-probe (with graceful degradation to a path-bound world), `make-bwrap-world` assembly, then a probe battery: workspace writable & host-visible, base system read-only, no network, non-zero exit codes surfaced, lexical path boundary for file tools |
| `live-quickstart.lisp` | Yes | **First five minutes, live**: a real micro-chore — count TODO/FIXME comments in the current directory | Provider assembly with optional fallback chain (`CHARIOT_FALLBACK_PROVIDERS`), readonly survey tools inside a path-bound world, streaming event rendering, run summary with usage and wall-clock time, `:timeout` guardrail |

## Running

```bash
# Offline examples (python3 required for mcp-demo; bubblewrap optional for the sandbox check)
sbcl --script examples/mcp-demo.lisp
sbcl --script examples/bwrap-sandbox.lisp

# Live example (needs a key)
CHARIOT_PROVIDER=deepseek DEEPSEEK_API_KEY=sk-... \
  sbcl --script examples/live-quickstart.lisp
```

Exit codes are uniform across the scripts: `0` success, `2` missing API key
(live script only), `3` Quicklisp missing, `1` boundary self-check failed
(sandbox mode).

## Environment variables (live-quickstart.lisp)

| Variable | Meaning | Default |
|---|---|---|
| `CHARIOT_PROVIDER` | Provider preset (`deepseek` / `qwen` / `glm` / `openai`) | `deepseek` |
| `CHARIOT_MODEL` | Model override for the primary provider | preset default |
| `CHARIOT_FALLBACK_PROVIDERS` | Space-separated fallback chain, e.g. `"glm qwen"` | none |

## Files

- `fake-mcp-server.py` — the fake MCP server used by `mcp-demo.lisp`
  (shared with the test suite; implements lifecycle + tools with paging,
  slow/failing tools, server-initiated requests, crash injection).

For the complete, progressively complex example project (release notes,
code review with session auditing, prompt-eval regression pipeline), see
[../demo/](../demo/README.md). MCP details: [../docs/mcp.md](../docs/mcp.md).
