# demo/ — CL-Chariot Practical Examples

English | [简体中文](README.zh-CN.md)

Three self-contained examples, each one a small tool you could adapt into a
real workflow — not throwaway snippets. Together they exercise nearly the
whole feature matrix of the library: custom domain tools, execution worlds,
approval policies, goal verification, subagents, session auditing, budget
guardrails, and the policy/eval regression loop.

| # | Example | What it does | Library features shown |
|---|---|---|---|
| 1 | `example-release-notes` | **Release-notes generator**: turn a git commit range into categorized Markdown release notes | Custom domain tools (`git_log` / `git_diffstat`), path-bound execution world, `:readonly` approval mode, programmable verify gate (fail-closed `:unverified`), wall-clock timeout, multi-vendor fallback chain |
| 2 | `example-code-review` | **Code-review agent**: review the working diff (or a given range / the last commit), write a structured report, then audit its own session offline | Survey + write tools inside a path-bound world (toolset kept consistent with the approval whitelist), approval callback as policy, subagent delegation (docs/tests coverage), JSONL session persistence + audit APIs (`session-runs` / `session-filter` / `session-search` / `session-usage-report`), token budget, summarize-then-trim compaction |
| 3 | `example-eval-pipeline` | **Prompt regression pipeline**: two versioned policy artifacts run against one task suite whose ground truth is computed from the repo at runtime; batches are summarized and diffed | Policy artifacts (`make-policy` / `save-policy` / `load-policy` / `policy-digest`), `apply-policy`, eval harness (`run-eval` / `eval-load` / `eval-summary` / `eval-diff`) |

All three default to analyzing **this repository itself**, so they work
out of the box with real data (git history, README, sources, LICENSE).

## Running

```bash
# 1) Configure a key (default provider: deepseek)
export DEEPSEEK_API_KEY=sk-...

# 2) Run everything, or pick one
demo/run.sh                 # all three examples
demo/run.sh release         # example 1 only (likewise: review / eval)

# Or from Lisp
sbcl --noinform --non-interactive \
     --eval '(progn (require :asdf) (load "~/quicklisp/setup.lisp") (asdf:load-system :cl-chariot/demo))' \
     --eval '(chariot-demo:example-release-notes)'
```

Prerequisites: this repository registered in your ASDF source-registry and
Quicklisp available (same as the main README).

### Environment variables

Shared (see `common.lisp`):

| Variable | Meaning | Default |
|---|---|---|
| `CHARIOT_PROVIDER` | Primary provider preset (`deepseek` / `qwen` / `glm` / `openai`) | `deepseek` |
| `CHARIOT_MODEL` | Model override for the primary provider | preset default |
| `CHARIOT_FALLBACK_PROVIDERS` | Space-separated fallback chain, e.g. `"glm qwen"` — on primary failure requests retry down the chain with `:provider-switch` audit events | none |
| `CHARIOT_INTERACTIVE` | `1` = approval callbacks ask a human y/N instead of auto-deciding | auto |

Per-example:

| Variable | Example | Meaning | Default |
|---|---|---|---|
| `CHARIOT_RELEASE_RANGE` | 1 | git commit range for the notes | previous tag → current tag/HEAD |
| `CHARIOT_REVIEW_RANGE` | 2 | git commit range to review | uncommitted changes, else last commit |

Example combining them:

```bash
CHARIOT_FALLBACK_PROVIDERS="glm qwen" \
CHARIOT_RELEASE_RANGE="v0.8.0..v0.9.0" \
demo/run.sh release
```

## Artifacts

Everything is written under `demo/out/` (git-ignored):

- `release-notes-<tag>.md` — written by the *host* code, only after the
  verify gate accepted the agent's output (the agent itself has no write
  permission — that separation is the point of the gate);
- `review-report.md` — written by the agent through an approved `write`
  tool call;
- `review-session.jsonl` — the full session record of example 2;
- `policy-v1.json` / `policy-v2.json` — the policy artifacts (save → load →
  digest round-trip);
- `eval-log.jsonl` — append-only eval log, cross-batch comparable.

## What embedders can lift directly

- `make-demo-event-printer` (`common.lisp`) — a compact renderer for the
  unified event stream (`:tool-call`, `:provider-switch`, `:verify`,
  `:compact`, `:run-end`, …); copy it and adjust to your logging stack.
- `make-git-log-tool` / `make-changes-tool` — the recommended shape for
  domain tools: close over the parameters at construction time (the
  capability boundary *is* the parameter boundary), declare readonly-ness,
  surface every failure as `tool-error` so the model can react.
- `make-release-notes-verifier` — the verify-gate pattern: "the model claims
  done" and "the goal is met" are forced apart programmatically.
- `make-review-ask-callback` — approval as code: a whitelist for
  unattended runs, a human y/N behind `CHARIOT_INTERACTIVE=1`.
- `print-review-audit` — post-hoc session auditing with zero extra model
  calls: every run (including nested subagent runs) is queryable by run-id,
  kind, error flag, or full text.

## Related

- No API key? `examples/mcp-demo.lisp` is a fully offline end-to-end demo.
- API details: [docs/api.md](../docs/api.md) · embedding guide:
  [docs/embedding.md](../docs/embedding.md).
