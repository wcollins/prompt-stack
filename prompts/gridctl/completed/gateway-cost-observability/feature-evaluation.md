# Feature Evaluation: Gateway Cost Observability

**Date**: 2026-04-18
**Project**: gridctl
**Recommendation**: Build (Option 2 only; Option 1 Skip)
**Value**: High
**Effort**: Medium

## Summary

Gridctl should absorb the *gateway-relevant* half of codeburn's value — per-tool / per-client cost attribution and a `gridctl optimize` command driven by gateway-observed data — while explicitly **not** absorbing the session-transcript-parsing half. The former is 2026 table-stakes for MCP gateways (Bifrost, Kong, LiteLLM, Lunar all ship it) and gridctl is 70% of the way there already. The latter is a crowded, high-maintenance niche dominated by ccusage and Wes McKinney's Go-native `agentsview`, with a user persona (individual developers) that doesn't match gridctl's platform-engineer audience.

## The Idea

Two framings were evaluated:

**Option 1 — Full codeburn clone inside gridctl.** Parse Claude Code / Codex / Cursor / OpenCode / Pi / Copilot session files from disk (`~/.claude/projects/`, `~/.codex/sessions/`, Cursor SQLite, etc.), classify 13 activity types, render an Ink-style TUI dashboard, ship an `optimize` command that scans `~/.claude/` for waste, produce a macOS menubar companion.

**Option 2 — Scoped gateway-metrics enrichment.** Build a pricing layer on top of gridctl's existing `pkg/metrics` accumulator, add per-client attribution to tool-call observations, ship a `Cost` tab in the Web UI, and introduce a `gridctl optimize` command that produces findings from gateway-observed data only.

**Problem being solved (Option 2):** Platform teams running a shared gridctl stack can see *tokens* flowing through the gateway but cannot see *cost*, cannot attribute usage to the specific linked client that drove it (Claude Code session A vs. Cursor session B), and cannot see waste signals (MCP servers registered but never called, high schema overhead per invocation, missed format-conversion savings).

**Who benefits:** Platform engineers managing MCP infrastructure for a team — the same persona that already uses `gridctl plan`, `gridctl validate`, `gridctl pins verify`, and `gridctl traces`.

## Project Context

### Current State

Gridctl is an MCP orchestration tool — "Containerlab for MCP infrastructure." A daemon-backed Go binary aggregates downstream MCP servers (Docker / stdio / HTTP / SSE / SSH / OpenAPI) into a single `localhost:8180` gateway. The project is post-MVP: core orchestration, hot reload, distributed tracing, vault, schema pinning, and skills registry are stable or near-stable. Observability has been expanding steadily through 2026 (replica observability phase 3, embedded tiktoken, Anthropic `count_tokens` integration, MetricsTab in Web UI).

### Integration Surface

- `pkg/metrics/accumulator.go` — thread-safe token counting with per-server + per-replica atomic counters, 1-minute ring buffers, format-savings tracking. Designed for extension.
- `pkg/metrics/observer.go` — implements `mcp.ToolCallObserver`; counts input (JSON-marshaled args) + output (result content) tokens on every tool call.
- `pkg/token/counter.go`, `api_counter.go` — `HeuristicCounter`, `TiktokenCounter` (embedded cl100k_base), optional `APICounter` hitting Anthropic `count_tokens`.
- `pkg/tracing/provider.go` — OTel provider with in-memory ring buffer, W3C TraceContext propagation; spans don't yet carry token/cost attrs.
- `internal/api/api.go` — `GET /api/metrics/tokens?range=...` time-series, `/api/status` token_usage snapshot, `/api/traces`.
- `web/src/components/metrics/MetricsTab.tsx` — time-range selector, KPI cards, per-server sortable table, Recharts area chart, auto-refresh live mode.
- `web/src/components/sidebar/TokenUsageSection.tsx` — per-server sparklines + format-savings bar.
- `cmd/gridctl/traces.go`, `cmd/gridctl/pins.go`, `cmd/gridctl/validate.go` — reference patterns for scan/view/filter commands with `--format json` and exit code `0|1|2`.
- `pkg/provisioner/*.go` — knows where linked clients live per-platform (already multi-platform aware).

### Reusable Components

- Ring-buffer accumulator (extend to record cost alongside tokens).
- ToolCallObserver (extend to capture `client_id` from MCP session context).
- Trace span attributes (add `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `gen_ai.cost.usd` per OTel GenAI semantic conventions).
- `cmd/gridctl/traces.go` CLI pattern (table + JSON + filters).
- `cmd/gridctl/validate.go` / `pins.go` exit-code convention (`0` optimal, `1` findings, `2` infra error).
- Web UI `MetricsTab.tsx` composition model.

## Market Analysis

### Competitive Landscape

**Gateway-level cost attribution is 2026 table-stakes** — as of March/April 2026 the following ship per-tool/per-team/per-key cost tracking:

- Docker MCP Gateway — built-in OTel metrics, per-tool tracing.
- ToolHive (Stacklok) — aligned with OTel MCP semantic conventions merged January 2026.
- Kong AI Gateway 3.12 — per-tool cost granularity, underutilization detection.
- Bifrost (Maxim) — per-execution audit logs, per-tool cost, Code Mode claiming ~92% token reduction.
- Lunar.dev MCPX — token/cost usage per agent/application.
- LiteLLM proxy — deep cost tracking per key/team/user across 140+ providers; MCP support added March 2026 (PR #12526).
- MintMCP / MCP Manager / TrueFoundry — live dashboards combining LLM token + tool-call metrics.
- Apache APISIX / WSO2 — token-based rate limiting plugins.

**Session-transcript analyzers are a different category** — dominated by:

- `ccusage` (ryoppippi) — ~13k stars, v18.0.10 March 2026; ships an MCP server itself.
- `wesm/agentsview` — Go-native, 16 agents, SQLite-indexed, positioned as "100x faster ccusage replacement"; authored by Wes McKinney (pandas/Arrow).
- `codeburn` (AgentSeal) — ~2.7k stars, v0.7.5 April 2026, actively expanding breadth (Menubar app, 6 providers).
- Claude-Code-Usage-Monitor (Maciek-roboblog) — ~7.6k stars, real-time TUI.
- cccost, ccost, cursor-stats, cursor-pulse — niche/single-ecosystem.

### Market Positioning

- **Option 1:** Irrelevant-to-disadvantaged. Entering the session-analyzer niche means competing head-on with ccusage (13k stars, mature) and a Go-native competitor by a notable author (agentsview). Gridctl gains no differentiation and loses focus.
- **Option 2:** Catch-up + leap-ahead. Catch up on per-tool cost attribution (parity with Bifrost/Kong/LiteLLM). Leap ahead with `gridctl optimize` driven by gateway-observed data (unused servers, schema overhead, cache-miss patterns) tied to dollar impact — no competitor ties waste findings to concrete YAML/stack remediation.

### Ecosystem Support

- LiteLLM `model_prices_and_context_window.json` is the de facto pricing source. Embed at build time with `//go:embed`; refresh via weekly `go generate`.
- OTel GenAI semantic conventions (experimental, March 2026) define `gen_ai.operation.name`, conversation IDs, token-usage attributes, cost-tracking — align trace spans to these.
- `modernc.org/sqlite` is pure-Go and cross-compile-friendly, but **not needed for Option 2** (no session-file parsing).
- Bubble Tea is the idiomatic Go TUI; **not needed for Option 2**.
- `qhenkart/anthropic-tokenizer-go` exists for Claude-specific ground truth if heuristic + tiktoken ever proves insufficient.

### Demand Signals

- Gateway users ask for per-team / per-key cost attribution and rate limits (consistent across MintMCP, Composio, Kong writeups).
- Session-transcript TUI demand exists but is served by dedicated tools; gateway-adopter complaint volume for it is low.
- EU AI Act Article 14 traceability requirements (August 2026 effective) add regulatory pressure for gateway-level audit trails.

## User Experience

### Interaction Model

**Option 2 blends into the existing surfaces:**

- **Web UI:** `Cost` tab inside the existing Metrics panel. Cost KPI card (today / 7d / 30d), per-server cost table with sortable columns (tokens, cost, calls, $/call), cost-over-time area chart (mirrors token chart styling), optional top-N-clients panel.
- **CLI:** `gridctl optimize` — table output by default, `--format json` for CI. `--per-client`, `--min-impact`, `--stack` filters mirror `gridctl traces` conventions. Exit `0` optimal, `1` findings, `2` infra error — mirrors `validate` / `pins verify`.
- **REST:** `GET /api/metrics/cost?range=...` (mirrors `/metrics/tokens`), `GET /api/optimize` (mirrors `/pins`).

Users discover cost naturally because it lives where they already look for token data. `gridctl optimize` shows up in `gridctl --help` next to `validate` / `plan`.

### Workflow Impact

- Platform engineers reviewing a stack's cost get a single-page answer in the Web UI.
- CI pipelines can call `gridctl optimize --format json --min-impact 10%` to fail a PR that introduces an unused server or drops cache-hit ratios below threshold.
- Chargeback reporting: `/api/metrics/cost?per_client=true&range=30d` → CSV export.
- Zero friction change to existing commands.

### UX Recommendations & Tweaks

- **Do not ship a TUI.** Gridctl already has two modalities (Web UI + CLI text/JSON); a third (Ink/Bubble Tea) is cognitive overhead and clashes with the daemon model.
- **Anchor findings in YAML-level remediation.** Every `gridctl optimize` finding should end with a concrete stack.yaml change (e.g., "drop `tools: ['unused_tool_a']` from `github` server — saves ~$0.50/wk").
- **Expose cost with the currency stdlib pattern, not a config surface yet.** USD only in v1.
- **Tweak: Schema Overhead Detection.** Explicitly highlight servers where the cost of tool-definitions (schema) outweighs the value of the actual calls.
- **Tweak: Skill Attribution.** Attribute costs not just to servers, but to the specific `Skill Workflow` that triggered them.
- **Tweak: Synchronized Data.** Add cost fields directly to the existing metrics `bucket` struct to ensure time-series alignment.

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|---|---|---|
| Problem significance | Significant | Gateway cost attribution is 2026 table-stakes; gridctl is behind |
| User impact | Broad + Deep | Platform-engineer persona; used every time a stack is reviewed |
| Strategic alignment | Core mission | Extends the "zero configuration drift" observability story |
| Market positioning | Catch up + differentiate | Parity on cost attribution, lead on YAML-tied optimize findings |

### Cost Breakdown

| Dimension | Rating | Notes |
|---|---|---|
| Integration complexity | Moderate | Extends proven pkg/metrics; no new subsystems |
| Effort estimate | Medium | ~70% of plumbing already exists; pricing + attribution + UI tab + optimize command |
| Risk level | Low | No new file-parsing surface; no cross-platform session format churn; OTel GenAI alignment is safe |
| Maintenance burden | Moderate | Weekly pricing-map refresh via `go generate`; model-ID normalization; occasional LiteLLM upstream churn |

## Recommendation

**Build Option 2. Skip Option 1.**

The evaluation is one-sided on both axes: value and cost.

**Why Option 2 wins:**

1. **Market timing.** Gateway cost attribution is where the MCP gateway category is standardizing in 2026 and gridctl is one feature away from parity (pricing layer + per-client attribution on an already-existing token pipeline).
2. **Persona fit.** Gridctl's user is a platform engineer who already uses `gridctl validate` / `gridctl pins verify` / `gridctl traces`. A Cost tab and `gridctl optimize` command slot into that workflow without adding cognitive load.
3. **Implementation leverage.** `pkg/metrics/accumulator.go` has atomic per-server/per-replica counters + ring buffers; `MetricsTab.tsx` has KPI cards + time-series charts; `cmd/gridctl/traces.go` shows the exact CLI shape. Adding cost is composition, not invention.
4. **Low maintenance.** No session-file parsers means no format-churn chase (codeburn shipped 7 releases in two weeks in April 2026 because of this churn + a third-party security audit for safe read-only file access).
5. **Standards hedge.** Aligning trace-span attributes with the OTel GenAI semantic conventions (experimental March 2026) means gridctl is on the standard track if/when MCP observability converges there.

**Why Option 1 loses:**

1. **Wrong persona.** Codeburn / ccusage / agentsview target individual developers auditing their own usage across tools. Gridctl targets teams running a shared MCP gateway. The overlap is thin.
2. **Entrenched incumbents.** ccusage at 13k stars + Wes McKinney's `agentsview` in Go make "build a better codeburn in gridctl" a losing proposition.
3. **Wrong modality.** Gridctl is Web UI + CLI. A TUI is a third paradigm that doesn't fit the daemon-backed model.
4. **High maintenance.** Six provider parsers, SQLite drivers, format-change chase, security surface on file reads — a permanent tax.
5. **Scope dilution.** The README says "One endpoint. Dozens of AI tools. Zero configuration drift." Session-transcript TUI is off-mission.

**Explicit non-goals for Option 2** (prevent scope creep during build):

- No parsing of `~/.claude/projects/`, `~/.codex/sessions/`, Cursor SQLite, or any client-side session file.
- No TUI — Web UI + CLI table/JSON only.
- No menubar app.
- No multi-currency support in v1.
- No workflow of "import codeburn data into gridctl" — keep the tools separate.

**Keep codeburn in orbit:** The `codeburn/` directory currently vendored into the gridctl repo is useful as a reference for pricing shapes and optimize heuristics, but it should not live in the gridctl repo long-term. Recommend removing it after references are extracted — it's an unrelated npm package and will drift.

## References

- [ccusage](https://github.com/ryoppippi/ccusage) — dominant session-transcript analyzer
- [codeburn](https://github.com/AgentSeal/codeburn) — the reference feature being evaluated
- [wesm/agentsview](https://github.com/wesm/agentsview) — Go-native competitor to codeburn
- [Claude-Code-Usage-Monitor](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor) — TUI monitor
- [Docker MCP Gateway](https://docs.docker.com/ai/mcp-catalog-and-toolkit/mcp-gateway/)
- [ToolHive observability](https://github.com/stacklok/toolhive/blob/main/docs/observability.md)
- [Kong AI Gateway 3.12](https://konghq.com/blog/product-releases/enterprise-mcp-gateway)
- [Bifrost token cost analysis](https://www.getmaxim.ai/articles/best-mcp-gateway-in-2026-how-bifrost-cuts-token-usage-by-50/)
- [LiteLLM spend tracking](https://docs.litellm.ai/docs/proxy/cost_tracking)
- [LiteLLM model_prices_and_context_window.json](https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json)
- [OpenTelemetry GenAI semantic conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/)
- [Lunar.dev MCPX](https://www.lunar.dev/product/mcp)
- [Iris State of MCP Agent Observability 2026](https://iris-eval.com/blog/state-of-mcp-agent-observability-2026)
- [JetBrains 2026 AI coding tools survey](https://blog.jetbrains.com/research/2026/04/which-ai-coding-tools-do-developers-actually-use-at-work/)
- [qhenkart/anthropic-tokenizer-go](https://pkg.go.dev/github.com/qhenkart/anthropic-tokenizer-go)
- [modernc.org/sqlite](https://pkg.go.dev/modernc.org/sqlite) (reference only; not used in Option 2)
