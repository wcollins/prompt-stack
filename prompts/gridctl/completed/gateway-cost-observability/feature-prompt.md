# Feature Implementation: Gateway Cost Observability

## Context

Gridctl is a Go-based MCP (Model Context Protocol) orchestration tool — "Containerlab for MCP infrastructure." It aggregates downstream MCP servers (Docker / stdio / HTTP / SSE / SSH / OpenAPI) into a single gateway exposed on `localhost:8180`, plus a React Web UI. Primary user persona is the **platform engineer** managing shared MCP infrastructure for a team.

**Tech stack:**
- Backend: Go 1.25+, stdlib-first, `log/slog`, OpenTelemetry tracing (`go.opentelemetry.io/otel` v1.43.0), embedded tiktoken (`tiktoken-go/tokenizer`)
- Frontend: React + Vite + Tailwind + Recharts + Lucide icons; Zustand state; `web/AGENTS.md` design system ("Obsidian Observatory")
- Build: `make build` (builds frontend + backend), `make test`, integration tests with `-tags=integration` and `-race`
- Conventions: see `AGENTS.md`, `CONSTITUTION.md`, `web/AGENTS.md`
- Platform: multi-platform (darwin, linux, windows) — don't break cross-compilation

**Relevant architecture:**

- `pkg/metrics/accumulator.go` already tracks per-server + per-replica token counts with atomic counters, 1-minute ring buffers (10000 slots ≈ 7 days), and format-savings tracking. It exposes `TokenCounts`, `TokenUsage`, `DataPoint`, `TimeSeriesResponse` types.
- `pkg/metrics/observer.go` implements the `mcp.ToolCallObserver` interface, counting input (JSON-marshaled args) + output (result content) tokens per tool call and recording them via `RecordReplica()`.
- `pkg/token/counter.go` and `pkg/token/api_counter.go` provide `HeuristicCounter`, `TiktokenCounter` (embedded cl100k_base), and optional `APICounter` (Anthropic `/v1/messages/count_tokens`).
- `pkg/tracing/provider.go` gives OTel tracing with an in-memory ring buffer and W3C TraceContext propagation; spans currently don't carry token/cost attributes.
- `internal/api/api.go` exposes `GET /api/metrics/tokens?range={30m,1h,6h,24h,7d}` and `/api/status` with `token_usage`.
- `web/src/components/metrics/MetricsTab.tsx` renders the metrics dashboard: time-range selector, KPI cards, per-server sortable table, Recharts area chart, live/paused mode. `web/src/components/sidebar/TokenUsageSection.tsx` renders the per-server sidebar sparkline.
- `cmd/gridctl/traces.go`, `cmd/gridctl/pins.go`, `cmd/gridctl/validate.go` are reference patterns for CLI commands (table output, `--format json`, filters, exit codes `0|1|2`).
- `pkg/provisioner/*.go` knows where each linked client's config lives per-platform.

## Evaluation Context

This prompt implements **Option 2** from the feature evaluation — the scoped gateway-metrics enrichment. **Option 1 (a codeburn-style session-transcript TUI) was rejected** for these reasons that the implementer must respect:

- The session-transcript niche is dominated by ccusage (~13k stars) and Wes McKinney's Go-native `agentsview`. Duplicating that functionality in gridctl competes on a losing axis with a wrong persona.
- Gridctl's competitive pressure in 2026 is **gateway-level per-tool/per-client cost attribution**, where Bifrost, Kong, LiteLLM, Lunar, and MintMCP all shipped features through Q1 2026.
- The UX target is platform engineers who already use `gridctl validate` / `gridctl pins verify` / `gridctl traces` — the Web UI + CLI modalities are the right surfaces; **do not add a TUI**.
- Align trace-span attributes with the OpenTelemetry GenAI semantic conventions (experimental as of March 2026) so gridctl rides the emerging standard rather than inventing a private shape.

**Explicit non-goals** (enforce throughout the build):

- No parsing of `~/.claude/projects/`, `~/.codex/sessions/`, Cursor's `state.vscdb`, or any client-side session file.
- No TUI — output is Web UI + CLI table/JSON only.
- No menubar app.
- No multi-currency support in v1 (USD only).
- Do not read from the locally-vendored `codeburn/` directory at runtime. Treat it as a reference during development; the feature must not depend on it being present.

Full evaluation: `prompts/gridctl/gateway-cost-observability/feature-evaluation.md`

## Feature Description

Add a **cost layer**, **per-client attribution**, a **Web UI `Cost` tab**, and a **`gridctl optimize` CLI command** to gridctl's existing gateway observability pipeline.

**What it does:**

1. Compute dollar cost for every tool call observed by the gateway using LiteLLM's `model_prices_and_context_window.json` pricing data embedded at build time.
2. Tag each tool-call observation with the originating client (e.g., `claude-code`, `cursor`, `claude-desktop`) derived from the MCP `initialize` params and the gridctl `link` state.
3. Surface cost alongside tokens in `/api/metrics/tokens` / `/api/status` and a new `/api/metrics/cost` endpoint.
4. Add a `Cost` tab (or a `$` KPI card + cost chart inside the existing Metrics tab — pick whichever fits the "Obsidian Observatory" layout better) in the Web UI.
5. Ship `gridctl optimize` — a scan-and-findings CLI command that inspects gateway-observed data (server usage, tool-schema overhead, format-savings shortfall, cache-miss signals) and prints actionable findings with dollar impact and YAML remediation hints.

**Problem solved:** Platform engineers running a shared gridctl stack can answer "what did this stack cost this week, and what can I change to spend less?" without leaving gridctl.

**Who benefits:** The same persona already using `gridctl validate`, `gridctl pins verify`, `gridctl traces` — platform engineers maintaining a team MCP gateway.

## Requirements

### Functional Requirements

The MCP session layer already captures `ClientInfo{Name, Version}` on the `Session` struct from the `initialize` request (see `pkg/mcp/session.go`); the per-client work in section 3 below is primarily threading that captured value through the observer path, not net-new session-layer capture.

1. **Pricing layer (`pkg/pricing/`)**
   1.1. Embed `model_prices_and_context_window.json` from LiteLLM at build time via `//go:embed`. Store under `pkg/pricing/data/model_prices.json`. Add a `make update-pricing` target (or a `go generate` directive) that pulls the latest file from `https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json`. Document the refresh cadence (weekly recommended).
   1.2. Expose `pkg/pricing.Lookup(model string) (Rates, bool)` returning `Rates{InputPerToken, OutputPerToken, CacheReadPerToken, CacheWritePerToken float64}`. Return `false` when the model ID is unknown (do not panic; do not fabricate rates).
   1.3. Implement model-ID normalization: gridctl stores model strings as emitted by clients (e.g., `claude-opus-4-7`, `gpt-5.1`). LiteLLM keys vary (`anthropic/claude-opus-4-7`, `claude-opus-4-7-20251001`). Build a normalization map with deterministic fallbacks; unknown models log once at `WARN` and are treated as zero-cost (no silent failure).
   1.4. Expose `pkg/pricing.Calculate(model string, usage Usage) (float64, bool)` returning USD cost. `pricing.Usage` is a new struct in this package carrying `InputTokens`, `OutputTokens`, `CacheReadTokens`, and `CacheWriteTokens`; introducing it (rather than extending `metrics.TokenCounts`) keeps the existing `metrics.TokenCounts` JSON shape unchanged on `/api/metrics/tokens` and `/api/status` while giving the cost path the fields it needs to price cache traffic correctly.
   1.5. **`pricing.Source` interface.** Define `pricing.Source` as `interface { Lookup(model string) (Rates, bool); Name() string }`. Ship `pricing.NewLiteLLMSource()` (returning a Source backed by the embedded JSON) as the default. The package's top-level `Lookup` and `Calculate` functions read from a package-level Source variable that can be swapped via `pricing.SetSource(s Source)` for tests or alternate pricing providers. Document the path for future alternate sources (Anthropic / OpenAI pricing pages, community-maintained JSON) without implementing them in v1.

2. **Cost accumulation (extend `pkg/metrics/`)**
   2.1. Add `Cost` alongside `TokenCounts` without breaking existing JSON shapes. Prefer a parallel `CostAccumulator` or a composed struct over mutating existing public types — Article IX (stack YAML back-compat) does not cover the API shape but `/api/metrics/tokens` consumers may exist. Add new fields as additive.
   2.2. Record cost at the same moment tokens are recorded in `observer.go`: compute per-call cost at ingest time using the model from the tool-call context (or the server-level default if the model isn't in the call). Never compute cost at read time from stored token totals — models drift per server/call. When the underlying MCP tool result reports cache-read or cache-write usage, those token counts are priced separately using the LiteLLM `cache_read_input_token_cost` and `cache_creation_input_token_cost` rates; cache-read tokens MUST NOT be conflated with input tokens for pricing purposes. The OTel GenAI attributes `gen_ai.usage.cache_read.input_tokens` and `gen_ai.usage.cache_creation.input_tokens` (added to the spec in February 2026) are the canonical names for these counts.
   2.3. Ring-buffer cost bucket alongside the existing token bucket. Per-server + per-replica + (new) per-client.
   2.4. **Code Mode sandbox instrumentation.** Tool calls dispatched through `mcp.callTool` inside the goja sandbox MUST produce per-call cost records identical in shape to direct gateway tool calls. Per-client attribution (section 3) flows through the sandbox unchanged: the outer `execute` call's `client_id` is the originating client for every nested `mcp.callTool`. Cost is recorded inside the sandbox's `callTool` binding (`pkg/mcp/codemode_sandbox.go`), not at the outer `execute` boundary; instrumenting only at the boundary would lose attribution fidelity for exactly the high-tool-count workloads where attribution matters most.

3. **Per-client attribution**
   3.1. Extend `pkg/mcp/session.go` / `handler.go` (whichever owns the MCP session lifecycle) to capture the `clientInfo.name` + `clientInfo.version` from the `initialize` request and attach it to the session context. Map common values (`"claude-ai"`, `"Claude Code"`, `"Cursor"`) through a small normalization table to stable short names (`claude-desktop`, `claude-code`, `cursor`, etc.). Unknown clients pass through verbatim but lowercased and hyphenated.
   3.2. Thread a `client_id` field through the `ToolCallObserver` interface on the tool-call path without breaking existing observers (add a new optional `ToolCallObservation` struct field, or a new `OnToolCallWithClient` method with a default adapter — prefer additive).
   3.3. Aggregate per-client token + cost counters in `pkg/metrics/accumulator.go` with the same atomic pattern used for per-server.
   3.4. Include `per_client` in `TokenUsage` (additive; omitempty to avoid breaking existing JSON consumers). The field name `per_client` is fixed for v1; future per-user / per-team dimensions will land as sibling fields (`per_user`, `per_team`) under the same `TokenUsage` shape, not by reshaping `per_client`. The internal accumulator field stays `perClient` for v1.

4. **OTel GenAI span attributes**
   4.1. On each tool-call span, set attributes aligned with OTel GenAI semantic conventions (March 2026 experimental): `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `gen_ai.usage.cache_read.input_tokens`, `gen_ai.usage.cache_creation.input_tokens`, `gen_ai.request.model`, `gen_ai.cost.usd` (custom until the spec defines one — document clearly), `mcp.server.name`, `mcp.tool.name`, `mcp.client.name`. The cache-token attributes are emitted only when the underlying tool result reports cache usage; otherwise omit them entirely (do not emit zero). Keep the existing gridctl-specific attributes untouched.
   4.2. Reference: https://opentelemetry.io/docs/specs/semconv/gen-ai/ — use the names verbatim where the spec defines them.

5. **REST API**
   5.1. `GET /api/metrics/cost?range={30m,1h,6h,24h,7d}&per_client=false` — returns a `CostTimeSeriesResponse` mirroring `TimeSeriesResponse` but with `USD` values per bucket. Optional `per_client=true` groups by client.
   5.2. Extend `/api/status` with a `cost` field on the existing `token_usage` snapshot (`cost.session_usd`, `cost.per_server`, `cost.per_client`, `cost.per_replica`). Additive.
   5.3. `DELETE /api/metrics/cost` — mirrors existing `DELETE /api/metrics/tokens` behavior (clears cost counters; leaves tokens alone if called alone).
   5.4. `GET /api/optimize?stack={name}&min_impact=0.10` — returns a `OptimizeReport` with `{findings: [...], health_score, generated_at}`. Each finding has `id`, `severity` (info/warn/critical), `title`, `summary`, `impact_usd_per_week`, `remediation` (YAML snippet or command), `detected_at`.

6. **CLI command `gridctl optimize`**
   6.1. Registered in `cmd/gridctl/optimize.go`. Mirrors the shape of `cmd/gridctl/traces.go` and `cmd/gridctl/pins.go`.
   6.2. Default output: styled table via `go-pretty/v6/table` (already in use by `traces.go`). Columns: severity, title, weekly $, remediation hint.
   6.3. `--format json` prints the same `OptimizeReport` shape from the API. Exit codes: `0` no findings or all `info`-level, `1` at least one `warn`/`critical`, `2` infrastructure error (gateway unreachable).
   6.4. Flags: `--stack` / `-s` (auto-detect when only one running; error with clear message when ambiguous), `--min-impact` (filter by weekly $), `--severity` (info/warn/critical), `--follow` is **not** supported (explicitly out of scope).
   6.5. Document in `AGENTS.md` CLI reference and `docs/api-reference.md`.

7. **Web UI**
   7.1. Extend `web/src/components/metrics/MetricsTab.tsx`: add a `$ Cost` KPI card beside the existing Input/Output KPIs, and an area chart for cost-over-time using the same Recharts styling. Time-range selector reuses the existing state.
   7.2. Add a `Top Clients` panel (sortable table: client name, calls, tokens, cost) below the per-server table. Hidden when `per_client` data is empty.
   7.3. Add a sidebar "Optimize" entry that fetches `GET /api/optimize` and renders findings as a compact list with severity badges and remediation snippets (collapsible). Reuse the sidebar panel style from `TokenUsageSection.tsx`.
   7.4. All new UI must follow the "Obsidian Observatory" design system documented in `web/AGENTS.md`. Use existing Tailwind tokens, Lucide icons (`DollarSign`, `Lightbulb`, `TrendingDown`).
   7.5. Live mode (auto-refresh) reuses the existing polling hook. Cost data polls at the same cadence as tokens.

8. **Optimize finding heuristics (gateway-data-driven only)**
   Implement at least these findings in `pkg/optimize/`:
   - `unused_server` — server registered in stack but zero tool calls in the last 7d. Impact = estimated schema overhead tokens × invocations saved × cost. Remediation: YAML to remove server or downgrade to `tools: []` exclusion.
   - `unused_tool` — server used but specific tool never called in 7d when `tools:` filter doesn't already exclude it. Remediation: add to exclusion list.
   - `schema_overhead` — **Tweak**: Highlight servers with high schema cost vs tool value. Formula: `(schema_tokens * refresh_frequency) / tool_usage_ratio`. Tool-definition byte counts can be read from the existing pin records in `pkg/pins.PinStore` (which already SHA256-hashes every tool definition for TOFU pinning) instead of recomputing them from live tool definitions; treat this as guidance rather than a hard requirement in case the pin shape evolves. Remediation: use `tools:` filter to prune unused tools.
   - `format_savings_shortfall` — servers with non-JSON-friendly output shapes not using `output_format: toon|csv`. Impact: estimated savings from the existing format-savings baseline.
   - `expensive_model_on_cheap_task` (optional, stretch) — flag when `Opus`-tier models dominate cost on servers whose tools are simple lookups. Informational only in v1.
   Every finding must include `impact_usd_per_week` computed from recorded data, not guesses. If data is insufficient (< 24h of observations), emit a single `info` finding saying so and exit.

9. **Documentation**
   9.1. Update `README.md` "Features" section with a "Cost Observability" bullet.
   9.2. Update `AGENTS.md` directory structure + CLI reference + REST API sections.
   9.3. Update `docs/api-reference.md` with all new endpoints.
   9.4. Add `docs/cost-observability.md` covering: pricing refresh cadence, model-ID normalization story, what `gridctl optimize` does and does not see, limitations (rates are best-effort; not a billing source of truth), and a pointer to complementary tools (ccusage, codeburn) for client-side session analysis.
   9.5. Add `CHANGELOG.md` entries under `[Unreleased]` for each user-visible change (Article XV).

### Non-Functional Requirements

- **Backward compatibility (Article IX + stack YAML).** No stack.yaml schema changes. Existing `/api/metrics/tokens` consumers must not break; additive only.
- **No silent failures (Article XI).** Unknown model IDs logged at `WARN` once per model; missing pricing = zero cost with a flag in the response indicating pricing-unavailable counts.
- **Error propagation, no panic (Article V).** Library code returns errors.
- **Context propagation (Article VI).** All new functions performing I/O accept `context.Context` first.
- **Structured logging (Article XIV).** `log/slog` with structured fields; no `fmt.Println` in `pkg/`.
- **Dependency minimalism (Articles I, II).** Do not add new external deps unless stdlib cannot achieve the same result. Pricing JSON parsing uses `encoding/json`. No SQLite driver. No TUI library. No CSV library beyond `encoding/csv` if needed.
- **Performance.** Cost calculation on the hot path must be lock-free (atomic) on the session aggregate; per-client and per-server maps follow the existing `serverMu sync.RWMutex` pattern. No allocations on the tool-call path beyond what token counting already does.
- **Multi-platform.** No platform-specific code. No CGO. No file system reads outside gridctl's own `~/.gridctl/` state dir (the point of Option 2 is that we do not touch client session files).

### Out of Scope

- Reading any client-side session files (`~/.claude/projects/`, `~/.codex/sessions/`, Cursor SQLite, etc.). If this temptation arises during build, stop and re-read the evaluation.
- TUI output of any kind.
- Menubar apps or native UIs.
- Currency conversion (USD only).
- Historical backfill — cost accumulates from the time the feature ships; previous token data is not retroactively priced.
- A separate "Costs" top-level nav in the Web UI. Keep it in the existing Metrics/Observability area.
- Per-user (not per-client) attribution. MCP doesn't expose user identity at the session layer.
- Exporting data to Datadog / Prometheus / external observability platforms. Keep endpoints local; integrations are a separate feature.

## Architecture Guidance

### Recommended Approach

**Composition over refactor.** The existing `pkg/metrics` accumulator is well-designed and heavily tested (43 test functions across metrics/token/tracing). Do not refactor its ring-buffer logic; **extend** it with parallel cost counters that follow the same pattern.

Think of this feature as three new layers on an existing tower:

1. `pkg/pricing/` — pure lookup, no dependencies on other gridctl packages.
2. `pkg/metrics/` extensions — cost counters beside token counters, using the same atomic + ring-buffer patterns.
3. `pkg/optimize/` — a new package that reads from `pkg/metrics` + the running gateway state to produce findings.

The MCP session layer gets a small additive change to capture `client_id`; the observer gets a small additive change to pass it along.

### Key Files to Understand

Read these first, in this order:

1. `pkg/metrics/accumulator.go` — understand atomic counters, ring buffers, per-server / per-replica patterns.
2. `pkg/metrics/observer.go` — understand where tokens get recorded on the hot path.
3. `pkg/mcp/session.go` + `pkg/mcp/handler.go` — understand MCP session lifecycle and where `initialize` is handled.
4. `pkg/token/counter.go`, `pkg/token/api_counter.go` — understand the Counter interface; your pricing lookup is structurally similar.
5. `pkg/tracing/provider.go` — understand span creation and attribute setting.
6. `internal/api/api.go` — understand route registration and response types.
7. `cmd/gridctl/traces.go` — gold-standard CLI pattern; `gridctl optimize` should look like a sibling.
8. `cmd/gridctl/pins.go` — scan + findings + exit-code pattern.
9. `web/src/components/metrics/MetricsTab.tsx` — UI composition + time-range handling + Recharts usage.
10. `web/src/components/sidebar/TokenUsageSection.tsx` — sidebar panel style.
11. `web/AGENTS.md` — "Obsidian Observatory" design system.
12. `AGENTS.md` + `CONSTITUTION.md` — project-wide rules.

### Integration Points

| File | Change |
|---|---|
| `pkg/metrics/accumulator.go` | Add `CostCounts` type, `sessionCost`, per-server + per-replica + per-client cost maps, cost ring buffers |
| `pkg/metrics/observer.go` | Compute cost on ingest, record via new `RecordCost` method |
| `pkg/mcp/session.go` / `handler.go` | Capture `clientInfo` from `initialize`, store on session |
| `pkg/mcp/types.go` | Add `ClientID` to `ToolCallObservation` (or new method on `ToolCallObserver`) |
| `pkg/tracing/provider.go` (or where spans get attrs) | Add OTel GenAI attributes to tool-call spans |
| `internal/api/api.go` | Register `GET /api/metrics/cost`, `DELETE /api/metrics/cost`, `GET /api/optimize`; extend `/api/status` |
| `cmd/gridctl/optimize.go` | New file — Cobra command mirroring `traces.go` |
| `cmd/gridctl/root.go` | Register the new command |
| `web/src/components/metrics/MetricsTab.tsx` | Add Cost KPI card + cost area chart + Top Clients panel |
| `web/src/components/sidebar/*` | Optional new `OptimizeSection.tsx` listing findings |
| `web/src/api/` (wherever `fetchTokenMetrics` lives) | Add `fetchCostMetrics`, `fetchOptimizeReport` |
| `README.md`, `AGENTS.md`, `docs/api-reference.md`, `docs/cost-observability.md`, `CHANGELOG.md` | Documentation |

### Reusable Components

- **Atomic counter pattern** from `pkg/metrics/accumulator.go` (lines 61–107). Use identically for cost.
- **Ring-buffer bucket pattern** (same file, lines 93–115). Duplicate for cost OR extend `bucket` struct to carry cost alongside tokens — prefer the latter if it does not bloat memory.
- **Observer pattern** from `pkg/metrics/observer.go` — add cost computation before `RecordReplica`.
- **CLI table rendering** via `go-pretty/v6/table` as seen in `cmd/gridctl/traces.go`.
- **Exit-code convention** from `cmd/gridctl/pins.go` and `cmd/gridctl/validate.go`.
- **Time-range parsing** from `internal/api/api.go` (wherever `/api/metrics/tokens?range=...` is parsed).
- **Web UI polling hook** (the one `MetricsTab.tsx` already uses).
- **Recharts styling tokens** from `MetricsTab.tsx` (colors, axis config, tooltip).

## UX Specification

- **Discovery (CLI):** `gridctl --help` lists `optimize` next to `validate` / `plan` / `traces`. `gridctl optimize --help` shows usage and examples identical in shape to `gridctl traces --help`.
- **Discovery (Web UI):** Metrics tab gains a `$` KPI card. Sidebar gets an "Optimize" panel that shows a finding count badge when > 0. No new top-level nav.
- **Activation (CLI):** `gridctl optimize` — zero required flags when one stack is running.
- **Interaction (CLI):** Table output by default, `--format json` for CI. Every finding ends with a remediation snippet (YAML block or command) the user can paste into their stack.
- **Interaction (Web UI):** Hover a cost bar → tooltip shows breakdown (input/output/cache-read/cache-write tokens + model + $/token). Click a top-client row → filter metrics to that client.
- **Feedback:** Cost values show "—" when pricing unavailable for a model, never a fabricated number. A muted footer line lists any models without pricing data so users can file an upstream issue or refresh pricing.
- **Error states:**
  - `gridctl optimize` with gateway unreachable → exit 2, clear error "gateway not running; try `gridctl status`".
  - Ambiguous stack → exit 2, message listing running stacks and suggesting `--stack`.
  - Pricing refresh failure (in `go generate`) → non-fatal warning, stale data continues to work.
  - Web UI cost chart loading → skeleton state identical to token chart.

## Implementation Notes

### Conventions to Follow

- **Go:** stdlib-first (Articles I, II). `log/slog` with structured fields (Article XIV). `context.Context` first arg on any I/O function (Article VI). Errors returned, not panicked (Article V). Godoc comments on all exported functions, types, methods (per `AGENTS.md`).
- **TypeScript/React:** Functional components, hooks, Zustand for state, Tailwind classes from the existing design system, Lucide icons. Match the naming and structure already in `web/src/components/metrics/`.
- **Tests (Article III):** New exported Go functions need unit tests. Table-driven tests preferred (per `AGENTS.md`). Integration tests for the observer + accumulator + API path under `tests/integration/` with `-race`.
- **No secrets (Article VII):** None of this needs API keys, but don't introduce config surface that might tempt users to paste one.
- **CLI output (Article X):** `--format json` is mandatory for `gridctl optimize`. Exit codes meaningful.
- **Changelog (Article XV):** Entry per user-visible change under `[Unreleased]`.
- **Commits:** follow `AGENTS.md` + `CLAUDE.md`. `<type>: <subject>`, imperative, ≤50 chars. Sign commits (`-S`). No Co-Authored-By. No mention of AI in commits/PRs/branches. Fork workflow (remember: gridctl uses fork-and-pull; use `/branch-fork` skill to start).

### Potential Pitfalls

- **Model-ID normalization is the hardest part.** LiteLLM's keys sometimes prefix the provider (`anthropic/claude-opus-4-7`), sometimes suffix the date (`-20251001`), sometimes neither. Build a deterministic normalizer with tests covering the top ~20 Claude/GPT/Gemini model IDs observed in the wild. Log unknown models once, keep running.
- **Cache-read vs. input tokens.** LiteLLM's pricing distinguishes `cache_read_input_token_cost` and `cache_creation_input_token_cost`. This is a correctness requirement, not an optional extension. Conflating cache-read tokens with input tokens mis-prices Claude tool calls by roughly an order of magnitude because cache-read rates are ~10% of input rates and cache-write rates are ~125% of input rates. Acceptance criterion 21 enforces this.
- **Hot-path allocation.** Pricing lookup must be allocation-free on steady-state (map read). Benchmark with `testing.B` on `BenchmarkRecord` to confirm no regression.
- **Cost at ingest, not read.** If you compute cost from stored token totals at read time, a model change mid-window will mis-price earlier calls. Record cost at observation time — once it's in the bucket, it's frozen.
- **`ToolCallObserver` interface change.** Existing implementors (if any tests use a fake) will break if you change the method signature. Prefer adding a new method or an optional field on the observation struct with a zero-value default.
- **Web UI polling churn.** `MetricsTab` already polls in live mode. Don't add a second independent poll for cost — piggyback on the existing fetch to reduce requests.
- **Optimize findings must not over-fire.** Less than 24h of observation = one `info`-level finding saying "need more data." Otherwise the report will scream on freshly-applied stacks.
- **Tempting but wrong: don't read `~/.claude/projects/` to enrich attribution.** The whole evaluation rejected Option 1. If you feel the urge, reread the non-goals.
- **Pricing file size.** LiteLLM's JSON is ~1.5 MB. Embedding it is fine; embedding history is not. Use the latest snapshot only.
- **Do not delete the `codeburn/` directory as part of this PR.** That's a separate cleanup. Ignore it.

### Suggested Build Order

1. **`pkg/pricing/`** — pure package, no deps. Embed JSON, write lookup + normalizer, unit-test the normalizer map hard. (Small)
2. **`pkg/metrics/` cost extension** — add cost counters alongside token counters. Unit tests mirror existing `accumulator_test.go`. (Small)
3. **`pkg/metrics/observer.go`** — wire pricing into the observer. Extend `observer_test.go`. (Small)
4. **Per-client attribution** — session-level capture of `clientInfo`, threading through the observer. Unit + integration tests. (Medium)
5. **OTel GenAI span attributes** — on the existing span creation path. (Small)
6. **REST API** — new endpoints + extensions to existing. Integration tests via `httptest`. (Medium)
7. **`gridctl optimize` CLI** + `pkg/optimize/` heuristics — start with `unused_server` + `unused_tool`, add the rest after the scaffolding lands. (Medium-Large)
8. **Web UI Cost KPI + chart + Top Clients panel** — extend `MetricsTab.tsx`. Visually verify in a running stack (per `CLAUDE.md`: test UI changes by running the feature in a browser). (Medium)
9. **Sidebar Optimize panel** — if time permits; can be a follow-up PR. (Small)
10. **Documentation sweep** — README, AGENTS.md, api-reference.md, cost-observability.md, CHANGELOG.md. (Small)

Ship in five PRs:

- **PR 1 (cost layer):** Steps 1-3. `pkg/pricing/` (with `pricing.Source` interface), cost counters in `pkg/metrics/`, observer wiring including cache-token handling. Defines the data shape.
- **PR 2 (attribution + API):** Steps 4-6. Per-client threading, OTel GenAI span attributes (including cache-token attributes), Code Mode sandbox instrumentation, REST endpoints. Extends `/api/metrics/tokens` and `/api/status` additively; adds `/api/metrics/cost`.
- **PR 3 (Web UI parity):** Step 8. `$ Cost` KPI card, cost-over-time chart, Top Clients panel. Sidebar Optimize panel deferred to PR 4.
- **PR 4 (optimize, narrow):** Step 7 narrowed to `unused_server` and `unused_tool` heuristics only, plus Step 9. `gridctl optimize` CLI, `GET /api/optimize`, and the Sidebar Optimize panel.
- **PR 5 (optimize, expanded):** Remaining heuristics (`schema_overhead` reusing `pkg/pins` hashes, `format_savings_shortfall`, `expensive_model_on_cheap_task`). Ships after at least 30 days of gateway data validates the threshold values used in each finding's impact calculation.

Each PR carries its own `CHANGELOG.md` entry under `[Unreleased]` (Article XV).

## Acceptance Criteria

1. `pkg/pricing.Lookup("claude-opus-4-7")` returns non-zero rates matching LiteLLM's pricing file.
2. `pkg/pricing.Lookup("fake-model-xyz")` returns `(_, false)` and logs a single `WARN` on first encounter.
3. `GET /api/metrics/tokens` response shape is unchanged from today for existing consumers (regression test).
4. `GET /api/status` includes a new `cost` field with `session_usd`, `per_server`, `per_client`; omitempty when empty.
5. `GET /api/metrics/cost?range=1h` returns a time-series response with USD cost per 1-minute bucket.
6. `GET /api/metrics/cost?range=24h&per_client=true` groups data by normalized client name.
7. Each tool-call OTel span carries `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `gen_ai.request.model`, `gen_ai.cost.usd`, `mcp.server.name`, `mcp.tool.name`, `mcp.client.name`.
8. `gridctl optimize` run against a fresh stack with < 24h data exits 0 with one info-level finding.
9. `gridctl optimize` run against a stack with an unused server exits 1 and prints that finding with a dollar impact and a YAML remediation snippet.
10. `gridctl optimize --format json` output validates against the documented `OptimizeReport` schema.
11. `gridctl optimize --stack wrong-name` exits 2 with a helpful error.
12. Web UI MetricsTab shows a `$ Cost` KPI card with today's total and a cost-over-time chart that scales with the time-range selector.
13. Web UI `Top Clients` panel appears when `per_client` data is available, sorts by cost desc, is hidden otherwise.
14. All new exported Go functions have godoc + unit tests; integration tests added for the accumulator / observer / API path with `-race`.
15. `make build` succeeds cross-platform (darwin/linux/windows); no new CGO dependencies.
16. No changes to `stack.yaml` schema. No deprecations of existing `/api/metrics/tokens` fields.
17. `README.md`, `AGENTS.md`, `docs/api-reference.md`, `docs/cost-observability.md`, `CHANGELOG.md` all updated.
18. Manual verification: run `gridctl apply examples/getting-started/mcp-basic.yaml`, exercise a few tool calls from a linked client, open `http://localhost:8180`, confirm the `Cost` card updates in live mode.
19. `gridctl optimize` never claims an impact it did not measure from gateway data; if data is insufficient, it says so.
20. No reads of `~/.claude/`, `~/.codex/`, Cursor's state.vscdb, or any client-side session file anywhere in the codebase introduced by this feature.
21. Cache-read tokens (`gen_ai.usage.cache_read.input_tokens`) and cache-write tokens (`gen_ai.usage.cache_creation.input_tokens`), when reported by the underlying MCP tool result, are priced separately from input tokens using the LiteLLM `cache_read_input_token_cost` and `cache_creation_input_token_cost` rates. A unit test against a fixture with cache traffic asserts the resulting USD cost matches the per-rate calculation, not the conflated-input calculation.
22. The `pricing.Source` interface accepts at least one alternate implementation (e.g., a deterministic in-memory test source) and `pricing.SetSource` swaps the active source without modifying call sites. A unit test exercises this swap.
23. Tool calls executed inside the Code Mode sandbox via `mcp.callTool` produce per-call cost records identical in shape to direct gateway tool calls. Per-client attribution flows through the sandbox unchanged: the outer `execute` call's `client_id` is recorded on every nested tool-call observation. An integration test under `tests/integration/` covers a Code Mode invocation with at least two nested tool calls and asserts the cost records.

## References

- Feature evaluation: `prompts/gridctl/gateway-cost-observability/feature-evaluation.md`
- LiteLLM model prices: https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json
- OpenTelemetry GenAI semantic conventions: https://opentelemetry.io/docs/specs/semconv/gen-ai/
- OTel GenAI agent spans: https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-agent-spans/
- MCP 2026 roadmap: https://blog.modelcontextprotocol.io/posts/2026-mcp-roadmap/
- ToolHive observability (reference for OTel alignment): https://github.com/stacklok/toolhive/blob/main/docs/observability.md
- LiteLLM cost tracking docs (reference for per-key/team/user shape): https://docs.litellm.ai/docs/proxy/cost_tracking
- Bifrost cost attribution (reference for optimize heuristics): https://www.getmaxim.ai/articles/best-mcp-gateway-in-2026-how-bifrost-cuts-token-usage-by-50/
- `qhenkart/anthropic-tokenizer-go` (only if heuristic + tiktoken insufficient): https://pkg.go.dev/github.com/qhenkart/anthropic-tokenizer-go
- Gridctl AGENTS.md, CONSTITUTION.md, web/AGENTS.md — authoritative local conventions
- Reference-only (do not import or depend on): `codeburn/` directory in the gridctl repo
- Second-opinion evaluation: `prompts/gridctl/gateway-cost-observability/feature-evaluation-second-opinion.md`
- OpenTelemetry GenAI cache-token attributes (`gen_ai.usage.cache_read.input_tokens` and `gen_ai.usage.cache_creation.input_tokens`): https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-spans/
