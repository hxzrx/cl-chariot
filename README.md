# CL-Chariot

English | [简体中文](README.zh-CN.md)

**An Agent Harness written in Common Lisp** — drives DeepSeek / Qwen / GLM / OpenAI
and other LLMs through a unified OpenAI-compatible protocol, providing a programmable
agent loop, a tool system, approval policies and session persistence. It can be
**embedded as a library into large projects**, and also ships with an
**interactive command-line frontend (CLI)**.

- Version: 0.8.0 · License: MIT
- Implementation requirement: any ANSI Common Lisp (the full test suite passes on SBCL 2.6 and CCL 1.13; no implementation-specific features)
- Design goal: integrate into large projects as a dependency library to harness complex, industry-grade agents

---

## Feature Overview

| Capability | Description |
|---|---|
| Multi-vendor providers | Built-in DeepSeek / Qwen (Alibaba Bailian) / GLM (Zhipu) / OpenAI presets; any OpenAI-compatible endpoint works. `:fallback-providers` failover chain: when the primary service fails, requests are automatically retried against fallbacks, with `:provider-switch` events for audit |
| Streaming output | SSE streaming parser; text and thinking (reasoning) deltas are delivered incrementally via event callbacks |
| Agent loop | "model → tool call → feed results back" multi-turn loop; four guardrails (turns / context / cost / stall); whole-round readonly tools execute in parallel (event and message order stay deterministic) |
| Tool system | Declarative `define-tool`; automatic JSON Schema generation; seven built-ins (bash/read/write/edit/glob/grep/web-fetch); the execution-world seam (`make-builtin-tools :world`) separates file/process/network access from the tool surface, allowing path-restricted worlds |
| MCP integration | MCP client over both stdio and Streamable HTTP (protocol 2025-11-25, backward compatible); lossless tool bridging; automatic re-handshake on session expiry; timeout / cancel / disconnect handling |
| Approval policy | yolo / default / readonly modes + tool allow/deny lists + a programmable ask callback |
| Run control | Cooperative cancellation (`:cancel-token`, settable from any thread) and wall-clock timeout (`:timeout`); `:cancelled`/`:timeout` stop reasons with messages preserved and resumable; nested runs (subagents) inherit the cancellation signal and deadline automatically |
| Concurrency contract | Immutable value-object configs are shareable across threads; one agent can run concurrently on many threads; session writes are thread-safe (line-integral JSONL, unique sequence numbers) plus a "one writer per session file" contract; event callbacks only fire synchronously on the run thread — all enforced by a dedicated concurrency suite |
| Goal verification | Programmable `:verify-callback` gate: forces a re-verification before natural completion, downgrades to `:unverified` on failure (fail-closed, off by default) |
| Run identity | Every `run` gets a unique run-id stamped on all its events and session records (nested runs carry a parent id) — hosts can align logs, billing and audits per run; `session-filter :run-id` scopes records to one run, `session-runs` summarizes per run |
| Session persistence | JSONL event stream; messages and all run events (with sequence numbers) mirrored to disk; run-boundary rotation/archival (`session-archive-runs`, atomic rewrite) and a cross-session run index (`session-index`) | projection/replay at any point, prefix-fork resume, and log search; the "everything the model saw is recorded" invariant; meta carries a config-digest fingerprint; crash-tolerant loading; resume from past conversations |
| Cost governance | Per-run `:max-total-tokens` budget guardrail; `session-usage-report` aggregates token usage across sessions, days and models (usage after a failover is attributed to the switched-to model); provider-level failover limits losses |
| Policy & eval | Prompts/budgets/sampling packed as versioned pure-data policy artifacts with content digests (`make-policy` / `apply-policy` / `policy-digest`); eval harness logs task-suite results keyed by policy fingerprint and diffs batches (`run-eval` / `eval-summary` / `eval-diff`) — prompt tuning becomes regression-testable engineering |
| Context management | CJK-aware token estimation; summarize-then-trim when over budget (programmable `:compaction-fn`, auto-degrades on failure); never produces orphan tool messages; compactions are recorded via `:compact`/`:summarize` events |
| Error resilience | Tool failures are fed back to the model and the loop continues; exponential backoff for HTTP 429/5xx and empty responses; automatic bail-out on repeated identical tool calls (`:stalled`); structured conditions on retry exhaustion |
| Subagents | Wrap a restricted subagent as a tool in one line, for delegating independent subtasks |
| Portable | Pure ANSI Common Lisp + uiop layer; tested on both SBCL and CCL |

---

## Quick Start

### 0. Installation

Dependencies (all from the official Quicklisp dist): `dexador`, `cl-ppcre`, `bordeaux-threads`, `flexi-streams`, `uiop`, `fiveam` (tests only).

With this directory registered in your ASDF source-registry, in any Lisp process:

```lisp
(ql:quickload :cl-chariot)   ; or (asdf:load-system :cl-chariot)
```

### 1. Use as a Library

```lisp
(ql:quickload :cl-chariot)

;; One-stop run: built-in tools + yolo mode (auto-approve everything)
(let ((provider (chariot-llm:make-provider :deepseek)))   ; API key read from $DEEPSEEK_API_KEY
  (let ((result (chariot:run-prompt provider "Count the .lisp files in the current directory"
                                :tools chariot-tools:+builtin-tools+
                                :permission-mode :yolo)))
    (format t "~A~%" (chariot:result-text result))))
```

More library usage in [docs/api.md](docs/api.md).

### 1b. Connecting MCP Servers

`cl-chariot/mcp` provides an MCP client over **stdio and Streamable HTTP**
(declared protocol version 2025-11-25, downward compatible with 2025-06-18 and
earlier), bridging an MCP server's tools into ordinary tool objects used exactly
like the built-ins:

```lisp
(ql:quickload :cl-chariot/mcp)

;; stdio: local subprocess
(let ((client (chariot-mcp:make-mcp-client "python3" "/path/to/mcp-server.py")))
  ;; or Streamable HTTP: remote endpoint
  ;; (let ((client (chariot-mcp:make-mcp-http-client "https://cantos.cn/mcp" :api-key "<token>")))
  (unwind-protect
       (progn
         (chariot-mcp:initialize client)                      ; handshake + version negotiation
         (let ((tools (chariot-mcp:mcp-tools-from-server client)))  ; tool bridging
           (chariot:run-prompt (chariot-llm:make-provider :deepseek) "…"
                           :tools (append chariot-tools:+builtin-tools+ tools))))
    (chariot-mcp:close-mcp-client client)))
```

Offline end-to-end demo (no API key needed): `sbcl --script examples/mcp-demo.lisp`.
See [docs/mcp.md](docs/mcp.md) and [mcp/README.md](mcp/README.md) (a real
HTTPS test-server deployment).

### 2. Command Line

```bash
bin/cl-chariot --help

# One-shot execution (for scripts and CI)
export DEEPSEEK_API_KEY=sk-...
bin/cl-chariot -P deepseek -m deepseek-v4-flash "Introduce yourself in one sentence"

# Interactive REPL
bin/cl-chariot -P glm --permission default
```

Built-in REPL slash commands: `/help` `/tools` `/mcp` `/model NAME` `/provider NAME` `/usage` `/clear` `/system TEXT` `/quit`.

#### Connecting MCP servers (`--mcp`)

```bash
# stdio: local subprocess (arguments separated by +)
bin/cl-chariot --mcp "fs=npx+-y+@modelcontextprotocol/server-filesystem+/tmp" "…"
# Streamable HTTP: remote endpoint (Bearer token after the second +)
bin/cl-chariot --mcp "cantos=@https://cantos.cn/mcp+<token>" "…"
```

At startup the client handshakes automatically and bridges MCP tools as local
tools (participating in approval like the built-ins); in the REPL use `/mcp` to
view server status and `/tools` to list all tools. See [docs/mcp.md](docs/mcp.md).

### 3. Run the Demo

```bash
export DEEPSEEK_API_KEY=sk-...
demo/run.sh          # runs three progressive examples
```

See [demo/README.md](demo/README.md).

### 4. Run the Tests

```bash
tests/run.sh                          # full offline suite (1199 assertions)
CHARIOT_LIVE=1 tests/run.sh               # plus live tests (needs API keys)
```

Everything passes on both SBCL and CCL; live tests cover streaming chat, tool
calls and the multi-turn loop.

---

## The Core API in Three Minutes

```lisp
;; 1) Provider config (preset + overrides; immutable value object)
(defparameter *provider*
  (chariot-llm:make-provider :deepseek      ; :deepseek / :qwen / :glm / :openai / any keyword
                         :model "deepseek-v4-flash"))

;; 2) Define a custom tool (declarative macro)
(chariot-tools:define-tool "word-count" "Count the words in a text" (:readonly t)
  (("text" "string" "The text to count" :required))
  (lambda (args)
    (format nil "~D" (length (chariot-util:split-string (chariot-json:jref args "text"))))))

;; 3) Assemble an agent and run
(let ((agent (chariot:make-agent
              :provider *provider*
              :tools (append chariot-tools:+builtin-tools+
                             (list (chariot-tools:find-tool chariot-tools:+builtin-tools+ "bash")))
              :permission-mode :default              ; mutating tools go through the ask callback
              :ask-callback (lambda (name) (yes-or-no-p "Allow tool ~A?" name))
              :on-event (lambda (event)              ; the unified event stream
                          (when (eq (getf event :kind) :text-delta)
                            (write-string (getf event :text))))
              :max-turns 20)))
  (let ((result (chariot:run agent "Read README.md and summarize")))
    (values (chariot:result-text result)
            (chariot:result-stop-reason result)
            (chariot:result-usage result))))
```

The event mechanism is the observability core of the framework: the CLI's
human-readable output and the embedder's structured logs consume the same event
stream (`:run-start` `:text-delta` `:tool-call` `:tool-result`
`:permission-denied` `:turn-start/end` `:cancel` `:provider-switch` `:run-end`,
and so on).

---

## Directory Layout

```
cl-chariot/
├── cl-chariot.asd          # All system definitions (base/llm/tools/agent/mcp/umbrella/cli/test/demo)
├── src/                    # Source (every file documented in Chinese comments)
│   ├── packages.lisp       #   Package definitions (module boundary = package boundary)
│   ├── util.lisp           #   Pure utilities: strings / alists / token estimation / diff
│   ├── json.lisp           #   In-house strict JSON parser (RFC 8259) + pure encoder
│   ├── message.lisp        #   Message model (zero conversion to wire format)
│   ├── provider.lisp       #   Provider layer: presets / SSE / retry / usage
│   ├── tool.lisp           #   Tool-system core (define-tool / schema / execution)
│   ├── tools-builtin.lisp  #   The seven built-in tools
│   ├── world.lisp          #   Execution-world seam: local / path-bound / bwrap-sandbox worlds
│   ├── context.lisp        #   Token estimation and history trimming
│   ├── permission.lisp     #   Approval decisions (pure functions)
│   ├── session.lisp        #   JSONL session persistence
│   ├── cancel.lisp         #   Cooperative cancel token and run-halt context
│   ├── agent.lisp          #   The agent loop
│   ├── mcp-jsonrpc.lisp    #   MCP: JSON-RPC 2.0 frame layer (pure functions)
│   ├── mcp-client.lisp     #   MCP: stdio client (subprocess / threads / timeouts)
│   ├── mcp-http.lisp       #   MCP: Streamable HTTP client (sessions / auto re-handshake)
│   ├── mcp-tools.lisp      #   MCP: tool bridging
│   ├── harness.lisp        #   Umbrella package: unified exports + subagent tool
│   └── cli.lisp            #   Command-line frontend
├── tests/                  # FiveAM test suite (offline + opt-in live layers)
├── mcp/                    # FastMCP test server for live runs (Streamable HTTP; deployment example: cantos.cn)
├── examples/               # Single-file example scripts (MCP end-to-end demo, etc.)
├── demo/                   # A complete example project
├── docs/                   # Architecture / API / provider docs
└── bin/cl-chariot          # CLI launcher
```

## Architecture Layers

```
┌──────────────────────────────────────────────────────┐
│  cl-chariot/cli        CLI frontend (REPL / one-shot) │
├──────────────────────────────────────────────────────┤
│  cl-chariot            Umbrella package + subagents   │
├──────────────────────────────────────────────────────┤
│  cl-chariot/agent      Loop · context · policy · logs │
├───────────────────────┬──────────────────────────────┤
│  cl-chariot/llm       │  cl-chariot/tools            │
│  providers·SSE·retry  │  define-tool · 7 built-ins   │
├───────────────────────┴──────────────────────────────┤
│  cl-chariot/base        JSON · message model · utils  │
└──────────────────────────────────────────────────────┘
```

Design principles and layer-by-layer notes in [docs/architecture.md](docs/architecture.md).

## Current Boundaries (Roadmap)

Capabilities not yet implemented, but with seams already reserved in the architecture:

- **Process-level sandbox** — two layers have landed: `make-path-bound-world`
  (path-prefix boundary, a logical boundary) + `make-bwrap-world` (bubblewrap
  process isolation: read-only base system, workspace bind mount, no network by
  default, IPC/PID/UTS isolation, with a `bwrap-usable-p` pre-probe); container
  orchestration and similar forms are left as extensions (execution-world seam
  in `src/world.lisp`);
- **Policy pack extensions** — the v1 core has landed (policy artifacts +
  eval harness, see above); multi-profile management and automated promotion
  pipelines remain future work, following the permission boundary "automated
  promotion may only touch prompts/budgets; code changes require human approval";
- **Web UI** — the event stream is the protocol; frontends can be built
  independently.

## License

MIT — see [LICENSE](LICENSE).
