;;;; cl-chariot.asd — CL-Chariot system definitions
;;;;
;;;; CL-Chariot is an Agent Harness written in Common Lisp: it drives
;;;; DeepSeek / Qwen / GLM / OpenAI and other LLMs through a unified
;;;; OpenAI-compatible protocol, and provides a programmable agent loop,
;;;; a declarative tool system with pluggable execution worlds, approval
;;;; policies, session persistence, versioned policy artifacts with an
;;;; eval harness. It can be embedded as a library into large projects,
;;;; and also ships with an interactive command-line frontend (CLI).
;;;;
;;;; Layered structure (bottom-up):
;;;;   cl-chariot/base   — pure utilities, strict JSON codec, message model,
;;;;                       deprecation machinery (zero side-effect deps)
;;;;   cl-chariot/llm    — multi-vendor providers: presets, OpenAI-compatible
;;;;                       chat, SSE streaming, retry with backoff, usage
;;;;                       accounting (HTTP transport injectable)
;;;;   cl-chariot/tools  — tool system: define-tool, JSON Schema generation,
;;;;                       execution worlds (local / path-bound / bwrap
;;;;                       sandbox), seven built-in tools
;;;;   cl-chariot/agent  — agent core: loop with four guardrails (turns /
;;;;                       context / cost / stall), context trimming with
;;;;                       summarize-compaction, permissions, cooperative
;;;;                       cancel & timeout, JSONL sessions (replay / audit /
;;;;                       fork / usage reports), policy artifacts, eval harness
;;;;   cl-chariot/mcp    — MCP client: stdio and Streamable HTTP transports
;;;;                       (declared protocol 2025-11-25, downward compatible),
;;;;                       lossless tool bridging
;;;;   cl-chariot        — umbrella: unified API re-exports + subagent tool
;;;;   cl-chariot/cli    — command-line frontend (REPL and one-shot; --mcp)
;;;;   cl-chariot/test   — FiveAM test suite (offline + opt-in live layers)
;;;;   cl-chariot/demo   — practical example project (release-notes generator,
;;;;                       code-review agent, prompt-eval pipeline)
;;;;
;;;; Portability: ANSI Common Lisp plus uiop and other portable layers only;
;;;; no implementation-specific packages (e.g. sb-ext / ccl). The full test
;;;; suite passes on both SBCL and CCL.

(defsystem "cl-chariot/base"
  :description "CL-Chariot base layer: pure utilities, JSON codec, message model and deprecation machinery"
  :author "cl-chariot contributors"
  :license "MIT"
  :version "0.9.2"
  :depends-on ()
  :pathname "src/"
  :serial t
  :components ((:file "packages")
               (:file "util")
               (:file "deprecation")
               (:file "json")
               (:file "message")))

(defsystem "cl-chariot/llm"
  :description "CL-Chariot provider layer: OpenAI-compatible chat, SSE streaming, retry with backoff and usage accounting"
  :depends-on ("uiop" "dexador" "flexi-streams" "cl-chariot/base")
  :pathname "src/"
  :serial t
  :components ((:file "packages")
               (:file "provider")))

(defsystem "cl-chariot/tools"
  :description "CL-Chariot tool system: define-tool, execution worlds and the built-in tool set"
  :depends-on ("uiop" "cl-ppcre" "bordeaux-threads" "dexador" "flexi-streams"
               "cl-chariot/base")
  :pathname "src/"
  :serial t
  :components ((:file "packages")
               (:file "tool")
               (:file "world")
               (:file "tools-builtin")))

(defsystem "cl-chariot/agent"
  :description "CL-Chariot agent core: loop with guardrails, context compaction, permissions, sessions, policy artifacts and eval harness"
  :depends-on ("uiop" "bordeaux-threads" "cl-chariot/base" "cl-chariot/llm"
               "cl-chariot/tools")
  :pathname "src/"
  :serial t
  :components ((:file "packages")
               (:file "context")
               (:file "permission")
               (:file "cancel")
               (:file "session")
               (:file "agent")
               (:file "policy")
               (:file "eval")))

(defsystem "cl-chariot/mcp"
  :description "CL-Chariot MCP client: stdio and Streamable HTTP transports, lossless tool bridging (protocol 2025-11-25, downward compatible)"
  :depends-on ("uiop" "bordeaux-threads" "flexi-streams" "dexador"
               "cl-chariot/base" "cl-chariot/tools")
  :pathname "src/"
  :serial t
  :components ((:file "packages")
               (:file "mcp-jsonrpc")
               (:file "mcp-client")
               (:file "mcp-http")
               (:file "mcp-tools")))

(defsystem "cl-chariot"
  :description "CL-Chariot umbrella system: unified API re-exports and the subagent tool"
  :depends-on ("cl-chariot/agent")
  :pathname "src/"
  :serial t
  :components ((:file "packages")
               (:file "harness")))

(defsystem "cl-chariot/cli"
  :description "CL-Chariot command-line frontend (REPL and one-shot execution; --mcp attaches MCP servers)"
  :depends-on ("uiop" "cl-chariot" "cl-chariot/mcp")
  :pathname "src/"
  :serial t
  :components ((:file "packages")
               (:file "cli")))

(defsystem "cl-chariot/test"
  :description "CL-Chariot test suite (FiveAM; offline suites plus opt-in live layers)"
  :depends-on ("uiop" "fiveam" "cl-chariot/cli" "cl-chariot/mcp")
  :pathname "tests/"
  :serial t
  :components ((:file "packages")
               (:file "util-test")
               (:file "json-test")
               (:file "message-test")
               (:file "provider-test")
               (:file "tool-test")
               (:file "agent-test")
               (:file "concurrency-test")
               (:file "cost-test")
               (:file "runid-test")
               (:file "scale-test")
               (:file "policy-eval-test")
               (:file "deprecation-test")
               (:file "mcp-test")
               (:file "mcp-http-test")
               (:file "session-test")
               (:file "cli-test")
               (:file "live-test")
               (:file "mcp-live-test")
               (:file "run-tests")))

(defsystem "cl-chariot/demo"
  :description "CL-Chariot practical examples: release-notes generator, code-review agent and prompt-eval regression pipeline"
  :depends-on ("uiop" "cl-ppcre"
               "cl-chariot/base" "cl-chariot/llm" "cl-chariot/tools"
               "cl-chariot/agent" "cl-chariot")
  :pathname "demo/"
  :serial t
  :components ((:file "common")
               (:file "release-notes")
               (:file "code-review")
               (:file "eval-pipeline")
               (:file "demo")))
