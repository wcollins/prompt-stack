# Feature Evaluation: Agent Skill Runner UI

**Date**: 2026-05-13
**Project**: gridctl
**Recommendation**: Build with caveats
**Value**: High
**Effort**: Medium

## Summary

Add a per-skill "Run" affordance to the `/agent` IDE that opens a modal launcher (raw JSON primary, RJSF schema-driven form as enhancement), POSTs to a new `POST /api/agent/runs` endpoint, and redirects to `/agent?run=<new_run_id>` so the existing read-only inspector + trace overlay does the visualization. Today, skills can only be invoked via `gridctl run` (in-process, no `tool()`/`llm()` bindings) or raw `/mcp` JSON-RPC. The market norm in 2026 is unified inspect + invoke; the "code is canon" principle is preserved because launching mutates runtime state, not source.

## The Idea

In the `/agent` web IDE, let users launch a new run of any registered skill — pick a skill, supply input (JSON or generated form), hit Run, and land in the existing trace overlay. This closes the inspect-and-invoke loop on a surface that today is read-only-runtime as well as read-only-source, and replaces the doc-only "Playground tab" workflow that was never actually shipped.

The feature serves both:

- **Skill authors** iterating during development — fast save→run→inspect loop without leaving the browser
- **Operators** running registered skills against real targets — discoverable runner with input validation and run history

## Project Context

### Current State

gridctl is a beta (v0.1.0-beta.x) MCP gateway + agent runtime — "Containerlab for MCP infrastructure." The agent runtime has shipped through Phase H (cost tracking, AGENTS.md sync) over the last six months, with typed skill SDK (TS + Go), goja sandbox, JSONL run persistence, time-travel resume, approval gates, single-writer orchestrator, and a visual IDE backend.

The `/agent` route is the developer surface for skills. Three-pane layout: SkillSidebar (left) → NodeList/Canvas (center) → NodeDetail (right), with BottomPanel showing Logs/Metrics/Spec/Traces/Pins. Trace overlay activates when the URL carries `?run=<run_id>`.

### Integration Surface

Backend:
- `internal/api/agent_runs.go` — existing run lifecycle handlers (list, get, events SSE, resume, approve). The new launcher endpoint lands here.
- `internal/api/api.go:324-328` — route registration. Add `POST /api/agent/runs`.
- `pkg/mcp/streamable.go:handleToolsCall` — the existing `/mcp tools/call` path is what the new endpoint will internally invoke (or call the orchestrator directly).
- `pkg/agent/persist/store.go` — JSONL ledger + `NewRunID()` + `RunStartedPayload`. No changes needed.
- `pkg/registry/server.go` — skill registry, `Tools()` + `CallTool()`. May need a "list skills for launcher" surface that includes `InputSchema`.

Frontend:
- `web/src/components/agent/ide/SkillSidebar.tsx` — add per-row Run button.
- `web/src/components/agent/ide/AgentIDE.tsx` — handle post-launch navigation to `?run=<id>`.
- `web/src/lib/agent-runs.ts` — add `launchRun({skill, input})` client.
- `web/src/components/agent/ide/RunLauncherModal.tsx` — new component.
- `web/src/components/agent/ApprovalBanner.tsx` — precedent for runtime-mutating UI on the read-only IDE.

### Reusable Components

- **`useRunTrace`** (`web/src/components/agent/ide/useRunTrace.ts`) — already subscribes to `/api/agent/runs/{run_id}/events` SSE and decorates canvas nodes. Reused as-is; new run_id flows in via URL change.
- **ApprovalBanner** — sibling pattern for "click a button, POST to a runtime mutator endpoint, optimistically update UI, then reconcile." Same shape as the launcher.
- **ResumeButton** — POSTs to `/api/agent/runs/{run_id}/resume`. Establishes precedent that the IDE can call POST endpoints; not a violation of "code is canon."
- **StackForm primitives** (`web/src/components/wizard/steps/StackForm.tsx`) — input/label/error-display class strings. Reusable for the raw JSON editor framing even if RJSF handles the form path.
- **agent-api.ts SkillSummary** — already lists registered skills for SkillSidebar. May need extension with `input_schema`.

## Market Analysis

### Competitive Landscape

| Platform | Launcher pattern |
|---|---|
| LangGraph Studio | Left input pane + Submit button. Auto-generates form from `config_schema`. Unified launcher + inspector. |
| Temporal Web UI | **No generic Start Workflow button** (long-standing community complaint). Only "Start Like This One" on existing executions. |
| Inngest Dev Server | Per-function **Invoke** modal with JSON payload editor; separate Runs inspector tab. |
| Restate Dashboard | Per-service **playground** sub-page with schema-generated form + copy-as-cURL. |
| Argo Workflows / Airflow / Prefect | First-class **Trigger/Submit/Run** button next to inspector views; unified surface. |
| Anthropic Workbench | Single-page launcher + inspector. `{{variable}}` placeholders auto-generate a small form. |
| MCP Inspector (official) | Tools tab → list → schema preview → generated form → Call button → JSON response. **The canonical reference for MCP UIs.** |

### Market Positioning

**Catch up.** Every comparable agent / workflow / LLM-app platform has this affordance in 2024–2026. Temporal's OSS UI is the cautionary tale of *not* shipping it — community pressure has accumulated for years. For gridctl pitched as an MCP gateway, the MCP Inspector pattern is the table-stakes reference.

### Ecosystem Support

- **react-jsonschema-form (RJSF)** — de-facto standard for JSON-Schema-driven React forms. Used by most Inspector-class tools. Mature, multiple themes, supports `dependencies` and `oneOf`/`anyOf`.
- **MCP Inspector** — the Anthropic reference for tool-invocation UI. Open source, can be studied directly.
- No JS bundling/runtime concerns — RJSF is widely deployed.

### Demand Signals

1. The `proto/agent/HOWTO-audit-repo.md` doc was written assuming a UI launcher existed (step 8a). The author's expectation is itself a signal.
2. The Playground tab was added then removed (commit 2a92fed, 2026-03-27) — an earlier attempt that didn't land cleanly.
3. The CLI comment in `cmd/gridctl/run.go` explicitly notes that `gridctl run` can't host `tool()`/`llm()`/`approval()` bindings; the daemon path is required. That makes a daemon-side launcher more capable than CLI for the common case.
4. Phase H just shipped; the agent runtime is actively growing, with consumer-affordance work being the natural next phase.

## User Experience

### Interaction Model

**Discovery**: Hovering or right-clicking a skill row in `SkillSidebar` reveals a Run button (▶). The button is also exposed on the welcome screen when no skill is active.

**Activation**: Click Run → modal opens with:

- **Default mode**: raw JSON editor pre-filled with `{}` (or the last-used input from this skill, stored in localStorage).
- **"Run like…" picker** above the editor: dropdown of the 10 most recent runs of this skill. Pick one → editor pre-fills with that run's `RunStartedPayload.Input`.
- **Form mode toggle**: if the skill's `inputSchema` is non-trivial (more than `{type:object}`), a "Form" tab renders an RJSF-generated form. Toggle freely between Form/JSON tabs.
- **Submit button**: "Run" — POSTs to `/api/agent/runs`, receives `{run_id}`, closes modal.

**Post-launch**: URL updates to `/agent?skill=<name>&run=<new_id>`. The existing `useRunTrace` hook auto-subscribes; canvas/NodeList nodes decorate with live status pills as events stream.

**Feedback during run**: trace overlay shows node_enter → node_exit progression with status (queued/running/ok/error/suspended), durations, model/tokens/cost.

**Approval mid-run**: existing `ApprovalBanner` catches paused runs; user clicks Approve/Reject — no new UI needed.

**Error states**:
- Schema validation failure (RJSF form mode): inline field errors before submit.
- Backend validation failure: 4xx from `POST /api/agent/runs` → modal stays open, error banner inside modal.
- Run-start failure (e.g., binding not configured): run starts but immediately errors; user sees the error event in the trace overlay (same path as today).

### Workflow Impact

**Adds** to the skill-author loop: save skill → glance at canvas → click Run → watch trace. No terminal context switch. Closes a real gap.

**Reduces** friction for operators: no need to construct curl commands or remember JSON-RPC envelope structure. Discoverable from `/agent`.

**Doesn't change** any existing surface: SkillSidebar gains one icon button; BottomPanel is untouched; trace overlay is untouched.

### UX Recommendations

1. **Per-skill modal, not a global picker** — discoverability is in-context; user already has a skill selected.
2. **Raw JSON editor primary, RJSF enhancement** — TS skill input schemas today default to `{type:object}`. RJSF needs rich schemas to shine; raw JSON works for everything.
3. **"Run like…" picker** — Temporal's pattern. Re-running with the same inputs is the #1 use case during iteration.
4. **localStorage memory** — remember last input per skill per browser. Free to add; high value for iteration.
5. **Auto-redirect to `?run=<id>`** — reuses 100% of existing inspector. Critical for keeping scope small.
6. **No new top-level route** — keep launcher inside `/agent`. A separate `/playground` would fragment the IDE surface and re-create the conflict you found.
7. **Update `proto/agent/HOWTO-audit-repo.md` step 8a** — point at the new launcher. Closes the bug-scout loop and prevents future regressions.

### Accessibility

- Modal: focus-trapped, ESC closes, focus returns to the originating Run button.
- Run button: keyboard-focusable, named "Run skill {name}".
- Schema form (RJSF) ships ARIA-conformant; raw JSON editor textarea needs a `<label>`.
- Status pills in trace overlay already have aria-live updates? — confirm during build.

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|---|---|---|
| Problem significance | Significant | Doc-driven expectation gap; CLI/curl is real friction; the existing run inspector is half a tool without a way to start runs |
| User impact | Broad + Deep | Both skill authors and operators benefit; the addition is in the main developer surface (`/agent`) |
| Strategic alignment | Core mission | `/agent` is positioned as the developer surface; an inspect-only IDE undersells the runtime that backs it |
| Market positioning | Catch up | Every comparable platform has this; Temporal's OSS gap is the cautionary tale |

### Cost Breakdown

| Dimension | Rating | Notes |
|---|---|---|
| Integration complexity | Moderate | New backend endpoint that bridges to MCP `tools/call` (or orchestrator directly); RJSF integration; modal infrastructure |
| Effort estimate | Medium | ~500 LOC backend + tests, ~600 LOC frontend + tests; days, not weeks |
| Risk level | Low–Medium | Weak input schemas degrade form UX (raw JSON fallback mitigates); auth/authz surface needs parity with existing `/api/agent/*` endpoints; Go skills require running daemon with plugin loaded |
| Maintenance burden | Moderate | RJSF version, schema-discovery code, parity with future skill primitives; the launcher is a thin wrapper around stable infrastructure |

## Recommendation

**Build with caveats.**

The architectural fit is strong: `/agent`'s read-only-source principle is preserved (source unchanged), the run inspector already exists and is reused, the MCP `tools/call` path already starts runs end-to-end, and the runtime is in active development with this as the natural next phase. The market norm makes the question "when, not if."

### Caveats

1. **Scope to TS skills first.** Go skills need a running daemon with the plugin loaded. Surface "Run" on TS skills only in the first PR; Go skills get the same UI in a follow-up once the build/load flow is documented for operators.
2. **Raw JSON editor primary; RJSF form is progressive enhancement.** Don't block ship on schema quality. Land the launcher with raw JSON, layer RJSF in either the same PR or a fast follow-up.
3. **Reuse `/agent?run=<id>` for the post-launch view.** Do not build a new run-detail page. The existing inspector is the goal of the redirect.
4. **Per-skill modal, not BottomPanel tab.** Keeps BottomPanel uncrowded (already has 5 tabs) and matches Inngest's per-function Invoke pattern.
5. **Update the proto HOWTO doc.** Step 8a in `proto/agent/HOWTO-audit-repo.md` should point at the new launcher when the feature lands. Don't ship the launcher without closing the bug-scout loop.
6. **Auth parity.** The new `POST /api/agent/runs` endpoint must use the same auth pattern as `POST /api/agent/runs/{id}/resume` and `POST /api/agent/runs/{id}/approve`. No new auth surface.

### What would change this from "Build with caveats" to "Build"

- Defining a richer `inputSchema` discipline for TS skills (jsdoc-driven, or a sibling `skill.schema.json`) would unlock RJSF as the primary input mode and elevate the launcher from "JSON editor with chrome" to "form-driven runner."

### What would change this to "Defer"

- If Phase I is committed to a different consumer affordance (run history page, traces drilldown, etc.) that would conflict with the modal pattern, defer until those surfaces stabilize.

## References

- [LangGraph Studio: The first agent IDE](https://blog.langchain.com/langgraph-studio-the-first-agent-ide/)
- [Temporal Community: UI for creating workflows](https://community.temporal.io/t/ui-for-creating-workflows/527)
- [Inngest Dev Server Documentation](https://www.inngest.com/docs/dev-server)
- [Restate UI announcement](https://www.restate.dev/blog/announcing-restate-ui)
- [Prefect: Configure UI forms for workflow inputs](https://docs.prefect.io/v3/advanced/form-building)
- [Anthropic Workbench help](https://support.claude.com/en/articles/8606378-how-do-i-use-the-workbench)
- [MCP Inspector docs](https://modelcontextprotocol.io/docs/tools/inspector)
- [MCP Inspector GitHub](https://github.com/modelcontextprotocol/inspector)
- [react-jsonschema-form](https://github.com/rjsf-team/react-jsonschema-form)
- [Argo Workflows User Guide](https://deepwiki.com/argoproj/argo-workflows/3-user-guide)
- [Apollo GraphOS Studio Explorer](https://www.apollographql.com/docs/graphos/platform/explorer)
- [Specmatic: MCP servers lying about their schemas](https://specmatic.io/demonstration/exposed-mcp-servers-are-lying-about-their-schemas/)
