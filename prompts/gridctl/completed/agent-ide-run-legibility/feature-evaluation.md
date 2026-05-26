# Feature Evaluation: Run Observability in the Agent IDE

**Date**: 2026-05-14
**Project**: gridctl
**Recommendation**: **Build (with caveats)**
**Value**: High
**Effort**: Medium (~1 week)

## Summary

After PR #628 closed the persistence gap for MCP `tools/call` runs, the Agent IDE renders essentially nothing when opening a persisted run: events flow only at run boundaries, the final output has no surface, and there is no way to browse past runs in-product. This feature ships the missing observability loop — richer telemetry from the TS dispatch path, parent→child run linkage, a Run Output surface, and a Runs browser — as one bundled feature in three internal slices. Build, but with scope discipline: defer `EventLLMChunk` streaming and OpenTelemetry export.

## The Idea

Make a run launched from an external MCP client (Claude Desktop, Cursor, Continue) inspect the same as one launched from the in-IDE Run Launcher. Today, opening a persisted run id in the IDE produces a flat graph and no terminal output. Close the gap on both ends:

- **Producer side**: emit the rich event vocabulary already defined in `pkg/agent/persist/events.go` (`NodeEnter`, `NodeExit`, `ToolCall`, `ToolResult`, `LLMCall`, `ApprovalRequest`, `ApprovalResponse`) from the TS dispatch path, and populate `ParentRunID` for nested skill calls.
- **Consumer side**: render the run's terminal `Output` in the IDE three-pane layout, and add a sidebar-tab Runs browser so past runs are reachable without hand-crafting URLs.

Beneficiaries: the gridctl maintainer validating typed skills locally; external MCP-client users (Claude Desktop, Cursor) who already persist runs but have no in-product way to inspect them; the `audit-repo.sh` demo whose "confirm in the UI" path is currently empty.

## Project Context

### Current State

`pkg/agent/runner/runner.go` exposes both async `Start` and sync `Run` (the latter added by PR #628 for the MCP path). Both write `EventRunStarted` + `EventRunCompleted` only. Nothing in the codebase writes any other event type for a TS-handler skill.

`pkg/agent/persist/events.go` defines a closed event vocabulary as godoc-documented contract: 10 event types covering node entry/exit, tool/LLM calls, structured outputs, approvals, and errors. The recorder API (`persist.Recorder.Record`) is the single write path.

The Agent IDE (`web/src/components/agent/ide/AgentIDE.tsx`) is a three-pane shell (280 / flex / 360). `useRunTrace.ts` subscribes to `/api/agent/runs/{id}/events` via SSE and folds every event type into a `byNode` decoration map — the consumer side is already complete, waiting for events. `NodeDetail.tsx` shows only the selected node's data and currently renders "awaiting selection" as the empty state. `SkillSidebar.tsx` lists skills only. `RunLauncherModal.tsx` is the only consumer of `fetchAgentRuns` (line 101), via its existing "Run like…" picker — so the list endpoint is plumbed but orphaned outside that modal.

### Integration Surface

| File | Role | Today | After |
|---|---|---|---|
| `pkg/agent/runner/runner.go` | TS-run entry | Writes 2 events | Stashes runID in ctx; writes `ParentRunID` when nested |
| `pkg/controller/gateway_builder.go:889–907` | `BindingsProvider` closure | Builds tool/llm/handoff/approval closures | Extracts runID from ctx; opens recorder for bindings |
| `pkg/agent/sandbox/bindings.go` | tool/llm/handoff/approval implementations | Async Promise settlement | Same + `recorder.Record(...)` before settling |
| `pkg/agent/persist/events.go` | Event vocabulary | Closed contract | No change — already designed for this |
| `pkg/registry/server.go:160–202` | `CallTool` dispatch | Routes typed-skill vs MCP-tool | Same; nested-call detection lives here or at runner entry |
| `web/src/components/agent/ide/AgentIDE.tsx` | Three-pane shell | Reads ?skill & ?run params | Same |
| `web/src/components/agent/ide/NodeDetail.tsx` | Right pane | Empty when no node selected | Empty state renders run terminal Output |
| `web/src/components/agent/ide/SkillSidebar.tsx` | Left rail | Skills only | Skills / Runs tab toggle at top |
| `web/src/lib/agent-runs.ts` | API client | `fetchAgentRuns` already exists | No change — already shaped right |

### Reusable Components

- `persist.Recorder` is the only event-write API and is already passed through `runner.Run`. Reuse — don't fork.
- `useRunTrace` already handles every event type. No frontend rewiring for the canvas overlay; it just starts working.
- `RunLauncherModal.tsx`'s "Run like…" history fetch (`fetchAgentRuns(50)` + filter by skill) is the exact same shape the Runs sidebar tab needs. Lift this into a hook (`useRunsForSkill`) and reuse it in both places.
- Error rendering in `NodeDetail.tsx:126` uses a `<pre>` JSON block — reuse the same pattern for the terminal output viewer.
- The CLI already has `gridctl runs list / inspect / trace / resume / approve` (`cmd/gridctl/runs.go`), so the web Runs browser is a UI overlay on a proven surface, not a new pattern.

## Market Analysis

### Competitive Landscape

This is **table-stakes** UX in 2026 across the agent-observability landscape:

- **LangSmith**: "high-fidelity traces that render the complete execution tree of an agent, showing tool selections, retrieved documents, and exact parameters at every step." Native `parent_run_id` field for nested runs (exact same name gridctl chose).
- **Langfuse**: "hierarchical view of each agent run — the full node execution sequence, nested LLM calls with token counts and costs, tool invocations with their inputs and outputs, and latency at every step." Uses `parentObservationId` for nesting.
- **LangGraph Studio**: thread-list dropdown at the top of the right-hand pane; clicking a past thread loads its state in-place. LangSmith Studio v2 adds "pull down production traces and run them locally to debug."
- **Helicone**: request/response focused — multi-step agents are stitched after the fact (the pattern gridctl is deliberately avoiding).

### Market Positioning

Currently **catch-up**, not differentiation. gridctl's IDE silhouette (typed graph + sandboxed TS + local-first JSONL ledger) is genuinely distinctive — but only when the trace surface is populated. The current state ("MCP runs persist but render empty") is the gridctl-specific version of falling behind market expectations.

### Ecosystem Support

The OpenTelemetry GenAI semantic conventions (`gen_ai.*` agent spans, tool spans, LLM spans) stabilized through 2026 with Datadog and Grafana native support. gridctl's event vocabulary (`NodeEnter`, `NodeExit`, `ToolCall`, `ToolResult`, `LLMCall`) maps cleanly — a clean future export path, but explicitly **out of scope** for this feature.

No mature library solves "sandboxed TypeScript skill emits standard agent telemetry into a local JSONL ledger." This is build, not adopt.

### Demand Signals

Direct: PR #628's commit message ("persist mcp tools/call runs to ledger") flags this gap implicitly — it persists runs but stops short of populating them. The user's intake confirms validating typed skills locally is currently a `cat ~/.gridctl/runs/*.jsonl` workflow.

Indirect: every comparable tool ships this; users coming from LangSmith / LangGraph Studio will expect the pattern.

## User Experience

### Interaction Model

**Discovery & activation (in-IDE user)**: Already smooth — `RunLauncherModal` submits, URL flips to `?skill=X&run=<id>`, `useRunTrace` subscribes. After this feature, the canvas decorates with per-node trace data as events arrive, and the right pane shows the terminal output as soon as `run_completed` lands.

**Discovery (external MCP-client user)**: The `tools/call` reply still goes to Claude Desktop / Cursor. In-product, discovery happens via the new **Runs** sidebar tab. The pattern mirrors LangGraph Studio's thread dropdown but lives in the rail where users already navigate. Clicking a run sets `?run=<id>` (and `?skill=<skill>` from the summary), triggering the same overlay path.

**Nested runs**: With `ParentRunID` populated, the Runs sidebar tab can indent child runs under their parent for the "orchestrator + leaves" pattern. This is a high-value-low-cost UX win — the data flows for free once `ParentRunID` is plumbed.

### Workflow Impact

Strictly additive for in-IDE users — no existing flow changes. For external MCP-client users, the "run via Claude Desktop, inspect in gridctl IDE" path becomes the natural canonical loop instead of CLI-only.

### UX Recommendations

1. **Output pane: repurpose `NodeDetail`'s empty state**, do not add a fourth pane. At 1340px minimum width the three-pane layout already crowds laptop screens. Render the terminal `Output` as a `<pre>` JSON block (reuse the existing error-display pattern from `NodeDetail.tsx:126`). When a node is selected, the pane behaves as today.
2. **Runs browser: sidebar tab toggle (`Skills | Runs`)**, not a separate route. AgentIDE has no Routes layer above it; keep it that way. Tab pattern matches `RunLauncherModal.tsx:439–453`.
3. **Parent-run linkage in the runs list**: indent child runs under their parent. Filter affordance: "show all runs / show only this skill's runs / show only root runs (hide children)."
4. **Output truncation**: `useRunTrace` accumulates the full events array — for large outputs, truncate with "expand" affordance. Don't blow up the DOM.
5. **Accessibility**: Tab toggle needs `role="tablist"` / `aria-selected`. Runs list should announce status changes via `aria-live` for in-flight runs. JSON viewer should support keyboard select-all + copy.

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|---|---|---|
| Problem significance | **Critical** | PR #628 created the gap by closing the persistence half. The IDE actively lies about MCP runs today. |
| User impact | **Broad+Deep** | Maintainer + every external MCP-client user + demo path. |
| Strategic alignment | **Core mission** | Phases A–H built up to a graph IDE; without trace data it's a brochure. |
| Market positioning | **Catch up** | Below baseline against LangSmith / Langfuse / LangGraph Studio on this axis. |

### Cost Breakdown

| Dimension | Rating | Notes |
|---|---|---|
| Integration complexity | **Moderate** | Plumb runID via `context.Context` across 3–4 boundaries; emit events at 4–5 binding sites; add 2 frontend surfaces. No layout/architecture rewrites. |
| Effort estimate | **Medium** | Backend ~2–3 days well-tested. Frontend ~2 days. Total ~1 week. |
| Risk level | **Medium** | (1) Async Promise-settlement timing in `bindings.go` could mis-order events if not serialized through `Recorder`'s mutex. (2) Nested-call detection must distinguish nested skill calls from top-level — false-positives flatten hierarchy, false-negatives orphan runs. (3) `EventLLMChunk` for streaming responses would explode ledger size — deferred. |
| Maintenance burden | **Moderate** | Event vocabulary is closed and well-documented. New emit sites couple sandbox to persist — already coupled at the runner level, no new architectural debt. Test gaps in `dispatcher_test.go` and `store_test.go` widen unless covered as part of the work. |

## Recommendation

**Build, with caveats.** Bundle as one feature ("Run observability in the Agent IDE") with three internal slices shipped in order:

- **Slice A — Backend**: rich event emission from `bindings.go` + `ParentRunID` plumbing. ~2–3 days. Unlocks the canvas overlay immediately because `useRunTrace` is already wired.
- **Slice B — Frontend output pane**: repurpose `NodeDetail`'s empty state to render `EventRunCompleted.Output`. ~1 day. Trivial once events flow.
- **Slice C — Frontend runs browser**: sidebar tab toggle in `SkillSidebar`, reusing `fetchAgentRuns` + `ParentRunID` for the nested-runs treeview. ~1–2 days.

Slice A in its own PR (well-bounded, immediately valuable, gates B+C). Slices B+C can share a PR or split.

**Caveats (apply as scope discipline)**:
1. **`EventLLMChunk` streaming**: explicitly out of scope. Defer. Streaming chunk UI is a v2 conversation.
2. **OpenTelemetry export**: out of scope. The event vocabulary maps cleanly to `gen_ai.*` spans — keep that path open by not breaking the shape — but do not ship it now.
3. **Test coverage gap**: `dispatcher_test.go` covers loading + binding but not bindings-level emission; `store_test.go` only covers ~half the event vocabulary. Slice A must close both as part of the work, not as a follow-up.
4. **Ledger size**: `tool_call` arguments and `tool_result` outputs are stored verbatim. For very large payloads (a long file read, a large JSON response), the JSONL line can balloon. Either truncate at the binding boundary with a size cap or document the unbounded-tail behaviour. Recommend a soft cap (e.g., 64KB per argument/output) with a `truncated: true` flag.

Why not split as two features? Each half ships independently and is internally coherent, but neither alone delivers the user-felt loop closure. The "MCP runs are legible now" moment only happens when Slice C lands. A bundled feature with sequenced slices preserves the staged delivery model (each slice merges separately) without breaking the user story into two prompt files that would re-derive the same context.

## References

- [LangSmith Run Data Format](https://docs.langchain.com/langsmith/run-data-format) — `parent_run_id` / `trace_id` schema for nested runs
- [Langfuse Tracing Documentation](https://langfuse.com/docs/tracing) — hierarchical observation tree with `parentObservationId`
- [LangGraph Studio v2 Production Traces](https://changelog.langchain.com/announcements/langgraph-studio-v2-run-and-debug-production-traces-locally) — thread-list dropdown UX pattern
- [OpenTelemetry GenAI Agent Spans](https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-agent-spans/) — future-portable semantic convention shape
- [OpenTelemetry GenAI Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/) — `gen_ai.*` attributes for LLM / tool / agent operations
- [Best LLM Observability Tools 2026](https://www.firecrawl.dev/blog/best-llm-observability-tools) — market survey context
- gridctl PR #628 — `fix: persist mcp tools/call runs to ledger` (commit `53c9be2`)
- `pkg/agent/persist/events.go` — local event vocabulary contract
- `web/src/components/agent/ide/useRunTrace.ts` — consumer-side trace folding (already complete)
