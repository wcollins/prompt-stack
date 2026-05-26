# Feature Implementation: Run Observability in the Agent IDE

## Context

**gridctl** is a local-first agent IDE and runtime. It exposes registered "skills" (typed agent workflows) that can be launched from three surfaces:

1. The in-IDE Run Launcher (web at `web/`)
2. The CLI (`gridctl run …`, `gridctl runs …`)
3. External MCP clients (Claude Desktop, Cursor, Continue) via the daemon's `tools/call` transport

The runtime persists every run as an append-only JSONL ledger at `~/.gridctl/runs/<run_id>.jsonl`. The event vocabulary is closed and documented in `pkg/agent/persist/events.go`: `run_started`, `run_completed`, `node_enter`, `node_exit`, `tool_call`, `tool_result`, `llm_call`, `llm_chunk`, `structured_output`, `approval_request`, `approval_response`, `error`.

The Agent IDE is a three-pane React shell (`web/src/components/agent/ide/`): skill sidebar / canvas / inspector. It subscribes to `/api/agent/runs/{id}/events` via SSE through `useRunTrace.ts` and folds each event into a per-node decoration map.

**Tech stack**: Go (runtime, registry, sandbox); TypeScript (sandboxed skill handlers via goja); React + TanStack Router + Tailwind for the web IDE; JSONL ledger for persistence.

**Project conventions** (from `~/.claude/CLAUDE.md` and existing code):
- Fork workflow (gridctl uses `origin`/`upstream`)
- Conventional commits, signed (`-S`), no Co-authored-by trailers, no mention of Claude in version control
- `make build` + `./gridctl` for local testing, never the brew binary
- Existing godoc style is exemplary — match the prose density and "why before what" framing of `pkg/agent/persist/events.go`

## Evaluation Context

Full evaluation: `<prompts-dir>/gridctl/agent-ide-run-legibility/feature-evaluation.md`

Key findings that shaped this prompt:

- **Per-node trace + parent linkage + runs browser are table stakes in 2026** (LangSmith, Langfuse, LangGraph Studio all ship the pattern). gridctl is currently below baseline — this is catch-up, not differentiation.
- **The consumer side is already complete**: `useRunTrace.ts` (lines 87–153) consumes every event type already. Slice A's events flow straight into the existing canvas overlay with zero frontend trace-overlay work.
- **`fetchAgentRuns` is orphaned outside `RunLauncherModal.tsx:101`** — the API client is shaped right, just not consumed by a browser surface.
- **Risk mitigations baked in**: (1) `EventLLMChunk` deferred (ledger bloat); (2) OpenTelemetry export deferred (scope); (3) Output truncation for very large payloads; (4) Test gaps in `dispatcher_test.go` and `store_test.go` closed as part of the work, not deferred.
- **`ParentRunID` is a one-line write** at recorder boundary plus carrying the parent run id through the sandbox context — cheap if done with the rest.
- **Bundle, not split**: each half ships independently but the user-felt "MCP runs are legible now" moment requires all three slices.

## Feature Description

Close the observability loop between MCP-persisted typed-skill runs and the Agent IDE. After this feature, a run fired via `tools/call` from Claude Desktop / Cursor / Continue inspects identically to one launched from the in-IDE Run Launcher.

Three internal slices, sequenced:

- **Slice A — Backend telemetry**: emit the richer event vocabulary from the TS dispatch path (`node_enter`, `node_exit`, `tool_call`, `tool_result`, `llm_call`, `approval_request`, `approval_response`); populate `ParentRunID` for nested skill calls.
- **Slice B — Run Output pane**: repurpose `NodeDetail.tsx`'s empty state ("awaiting selection") to render `EventRunCompleted.Output` as a JSON viewer when no node is selected.
- **Slice C — Runs browser**: add a `Skills | Runs` tab toggle to `SkillSidebar.tsx`. On `Runs`, show recent runs sorted by `started_at` desc, with child runs (non-empty `parent_run_id`) indented under their parent. Clicking a run sets `?skill=X&run=<id>` to activate the existing overlay path.

## Requirements

### Functional Requirements

**Slice A — Backend telemetry**

1. `runner.Run` and `runner.Start` MUST stash the run ID in the request context under a typed context key (e.g., `runIDKey{}`) before calling `exec.CallTool(ctx, ...)`.
2. The `BindingsProvider` closure in `pkg/controller/gateway_builder.go:889–907` MUST extract the run ID from context, open a `persist.Recorder` for that run, and pass it into the bindings struct.
3. The `tool()` binding in `pkg/agent/sandbox/bindings.go` (lines 111–144) MUST record `EventToolCall` before invoking `ToolCaller.CallTool`, and `EventToolResult` after settling. The `CallID` MUST be a generated id (e.g., ULID) that pairs the two events.
4. The `llm()` binding (lines 178–209) MUST record `EventLLMCall` after the provider responds, capturing `Model`, `Provider`, token counts, and `CostUSD`.
5. The `handoff()` binding (lines 372–407) MUST detect that this is a nested skill call: ensure the child run is launched with the parent's run ID in context so the child's `EventRunStarted` carries `ParentRunID`.
6. The `approval()` binding (lines 414–449) MUST record `EventApprovalRequest` before suspending and `EventApprovalResponse` after resuming.
7. `registry.Server.CallTool` MUST detect nested calls: if the context already carries a run ID AND the call dispatches to a typed-skill handler (TS or Go), the dispatched runner's `EventRunStarted` MUST set `ParentRunID = <parent run id>`.
8. Node enter/exit emission: TS skills don't have an obvious "node" boundary like the Go/eino graph does. Emit `EventNodeEnter` / `EventNodeExit` around each top-level binding call using the binding name as `NodeID` and `NodeName` (e.g., `tool:audit-repo.fetch-readme`, `llm:#1`). Use a counter scoped to the run to disambiguate repeated calls.
9. Arguments and outputs MUST be size-capped: if the JSON-encoded `Arguments` (or `Output`) exceeds 64 KB, store the first 64 KB with a `"truncated": true` field appended to the payload struct.
10. All event recording from bindings MUST go through the recorder's existing mutex — never write directly to the JSONL file. Async Promise delivery in `bindings.go` uses `loop.RunOnLoop` to settle on the goja thread; record events on the goroutine BEFORE `asyncDeliver` to ensure ordering matches the wire timeline.

**Slice B — Run Output pane**

11. `NodeDetail.tsx`'s no-node-selected state (lines 44–61) MUST render the run's terminal output when `runID` is non-null and `runTrace.events` contains a `run_completed` event.
12. The output MUST be rendered as a syntax-highlighted JSON `<pre>` block matching the existing error-display pattern (`NodeDetail.tsx:126`).
13. If the run is in-flight (no `run_completed` yet) but `runID` is non-null, render a loading state ("waiting for completion…") with the live event count.
14. If the run completed with an error, render the `Error` field instead of `Output`, in the same error styling.
15. Long outputs (> ~10 KB JSON-stringified) MUST collapse with an "expand" affordance; never blow up the DOM.

**Slice C — Runs browser**

16. `SkillSidebar.tsx` MUST gain a tab toggle (`Skills | Runs`) at the top of its scrollable region.
17. The `Runs` tab MUST fetch via `fetchAgentRuns(100)` and render runs sorted by `started_at` desc.
18. Runs with `parent_run_id` set MUST visually indent under their parent (when the parent is in the visible list); fold/unfold control on the parent row.
19. Each row MUST show: run-id-prefix (8 chars), skill name, status badge, relative time, event count.
20. Clicking a row MUST set `?skill=<r.skill>&run=<r.run_id>` (replacing both params), activating the existing trace overlay path.
21. The list MUST refresh when a new run is launched via `handleLaunched` in `AgentIDE.tsx`.
22. Lift the `fetchAgentRuns + filter by skill` logic out of `RunLauncherModal.tsx:99–118` into a shared hook (`useRunsForSkill` or similar) used by both the modal and the sidebar tab.

### Non-Functional Requirements

- **Backwards compatibility**: existing runs in `~/.gridctl/runs/*.jsonl` MUST continue to render. Don't break the SSE shape or the API client types.
- **Performance**: per-event recorder overhead MUST stay sub-millisecond on the hot path. The recorder already uses a mutex + buffered writer — measure before optimizing.
- **Accessibility**: tab toggle MUST use `role="tablist"` / `aria-selected` (match `RunLauncherModal.tsx:439–453`). Run list rows must be keyboard-navigable. Live regions for in-flight run status (`aria-live="polite"`).
- **Determinism**: event `seq` ordering MUST match the wire timeline. The recorder's monotonic counter handles this; the requirement is "don't bypass the recorder."

### Out of Scope

- `EventLLMChunk` streaming chunk emission and any streaming-chunk UI rendering. Defer to v2.
- OpenTelemetry GenAI semantic-convention export. Defer.
- Go-skill (eino) per-node telemetry — the Go runtime isn't wired for this yet either; deliberately out of scope.
- A separate `/runs` page route. The Runs browser lives inside `AgentIDE` as a sidebar tab — AgentIDE has no Routes layer above it and this should not change.
- `gridctl agent dev` host changes — work entirely within the existing dev server / runtime surface.
- Server-side notifications back to MCP clients ("view this run at …"). The MCP `tools/call` reply shape stays as-is.
- `structured_output` event emission requires schema-bound TS outputs that don't exist yet — emit only if/when the schema-extraction work lands. Otherwise skip silently.

## Architecture Guidance

### Recommended Approach

Pass the run ID via `context.Context` (Option A in the dispatch-path analysis). Add a typed context key in the `runner` package; `runner.Run` and `runner.Start` set it before dispatch. `BindingsProvider` extracts it and opens a `Recorder`. This is non-breaking for the `Executor` interface, `CallTool`, `TSDispatcher`, and `BindingsProvider` signatures.

Reasoning: any other approach (extending `Executor`, threading a recorder through 4 boundaries explicitly) requires API changes across packages with no offsetting benefit. Context-carry matches the existing pattern (the runtime already propagates `ctx` through the same path).

For parent-run detection at `registry.Server.CallTool`: check `ctx.Value(runIDKey{})` — non-empty means this is a nested call. The recorder for the child run writes `ParentRunID = <ctx value>` into `EventRunStarted`. Done.

### Key Files to Understand

Read these first, in order:

1. `pkg/agent/persist/events.go` — the event vocabulary contract. Match this prose style for any new code comments.
2. `pkg/agent/persist/store.go` — recorder lifecycle. Understand how `OpenWriter` / `Record` / `Close` interact with the JSONL mutex.
3. `pkg/agent/runner/runner.go` — the entry points (`Run`, `Start`). This is where context plumbing originates.
4. `pkg/agent/sandbox/bindings.go` — the emit sites. Pay attention to the async Promise pattern (lines 32–46, `asyncDeliver`); recorder writes must happen on the goroutine before delivery, not on the loop thread after.
5. `pkg/controller/gateway_builder.go:889–907` — `BindingsProvider` closure. The bindings struct grows a `Recorder` field here.
6. `pkg/registry/server.go:160–202` — `CallTool` dispatch. Nested-call detection lives here OR at runner entry (pick one — runner entry is cleaner because it owns the recorder lifecycle).
7. `web/src/components/agent/ide/useRunTrace.ts` — confirm what events the consumer already handles (everything — no changes needed).
8. `web/src/components/agent/ide/NodeDetail.tsx:44–61` — Slice B insertion point.
9. `web/src/components/agent/ide/SkillSidebar.tsx:50–88` — Slice C insertion point.
10. `web/src/components/agent/ide/RunLauncherModal.tsx:99–118` — `useRunsForSkill` hook extraction source.

### Integration Points

| Boundary | Change |
|---|---|
| `runner.Run` / `runner.Start` | Wrap ctx with run ID before `exec.CallTool`. Read existing ctx value to set `ParentRunID` on `RunStartedPayload`. |
| `registry.Server.CallTool` | No change required if runner-entry handles parent detection. If you prefer here: extract parent run ID and pass it to `runner.Run` via `StartOptions.ParentRunID` (add the field). |
| `gateway_builder.go` (`BindingsProvider`) | Extract run ID from ctx; open recorder via `persist.Store.OpenWriter` — but `runner.Run` already owns this recorder. Better: pass the recorder through ctx OR have runner construct the bindings provider. Pick the lower-friction option after reading the code. |
| `bindings.go` | Each async binding records pre-call (`tool_call`/`llm_call`/`approval_request`) and post-call (`tool_result`/`approval_response`) events. `node_enter`/`node_exit` wrap each top-level binding invocation. |
| `NodeDetail.tsx` empty state | Render `RunOutputView` component when `runID && !node`. |
| `SkillSidebar.tsx` | Add `<TabToggle>` and conditional `<RunsList>` body. |
| New: `useRunsForSkill(skillName?)` hook | Shared by `RunLauncherModal` and `RunsList`. Returns `{runs, loading, error, refresh}`. |

### Reusable Components

- `persist.Recorder.Record` — sole event-write API. Already mutex-guarded.
- `<pre>` error pattern in `NodeDetail.tsx:126` — adapt for `RunOutputView`.
- `formatRelativeTime` (`web/src/lib/time.ts`) — for run timestamps.
- `TabButton` component (`RunLauncherModal.tsx:427–455`) — extract or copy for `SkillSidebar` tab toggle.

## UX Specification

**Discovery**:
- In-IDE user: nothing new to learn — graph overlay starts decorating as events arrive; output pane appears on `run_completed`.
- External MCP-client user: visits the Agent IDE, sees a `Runs` tab in the left sidebar, clicks recent run → graph + output render.

**Activation**:
- Sidebar `Runs` tab toggle is the entry point. No modal, no separate route.
- Click a run row → URL params update → existing `useRunTrace` flow takes over.

**Interaction**:
- Slice A is invisible to users *as code* but transformative *as experience* — the existing canvas overlay starts working for TS skills.
- Slice B: output pane shows the result the moment the run completes. JSON-highlighted, copyable, collapsible if large.
- Slice C: scrollable runs list, child runs indent under parents with disclosure caret. Status badges color-coded (matches existing status colours in `useRunTrace.ts`).

**Feedback**:
- In-flight run: live event count in output pane, `aria-live="polite"` for screen readers.
- Completed run: timestamp + duration + final status badge.
- Errored run: error message in the same red-tinted `<pre>` block as node errors.

**Error states**:
- `fetchAgentRuns` fails → sidebar shows "couldn't load runs" with retry button (don't silent-fail like the modal does — runs is now a primary surface).
- Recorder write failure mid-run → log at warn (existing pattern in `runner.go:117`), don't fail the run.
- Size-capped truncation → render `"…"` with a tooltip "truncated to 64 KB".

## Implementation Notes

### Conventions to Follow

- **Commit format**: `feat:`, `fix:`, etc. — imperative mood, max 50 chars, no period.
- **Branch naming**: `feature/agent-ide-run-legibility` (or per-slice if splitting PRs).
- **Sign all commits** with `-S`. No Co-authored-by. No mention of Claude in commits/PRs/branches.
- **Godoc style**: match `pkg/agent/persist/events.go` — every exported symbol gets a comment that leads with the *why*, not the *what*. Keep comments tight; prose is dense by design.
- **Test conventions**: use the table-driven pattern visible in `persist/store_test.go`. Test files colocate with code.
- **Type discipline**: new event payloads (if any) extend `pkg/agent/persist/events.go` — don't shadow the contract elsewhere.

### Potential Pitfalls

1. **Async event ordering in `bindings.go`**: The Promise-based bindings deliver settlement on the goja event loop. If you record the `tool_result` event on the loop thread (post-delivery), it lands AFTER the model has already moved on conceptually. Record on the goroutine BEFORE `asyncDeliver` so wire-order matches causal-order.
2. **Recorder lifetime**: `runner.Run` opens and closes the recorder. If bindings open their own recorder via `Store.OpenWriter`, you'll race on the file. Always borrow the existing recorder — pass it through context or via the bindings struct.
3. **Nested-call detection edge cases**: A TS skill calling `tool("non-skill-tool-name")` (e.g., a real MCP tool) is NOT a nested skill call — don't try to set `ParentRunID`. Only `tool("registered-skill-name")` and `handoff(...)` are nested skill calls. The registry already distinguishes these — read `registry.Server.CallTool` to confirm before guessing.
4. **`SchemaForm` is lazy-loaded** (`RunLauncherModal.tsx:29`) — don't break that chunk by reorganizing. The hook extraction should leave the modal's lazy-load alone.
5. **`fetchAgentRuns` returns AgentRunSummary** which already has `parent_run_id` in the type (`agent-runs.ts:31`) — backend already populates it on the summary, you just need to fill in the JSON write path.
6. **Test gap closure**: `store_test.go` doesn't roundtrip `tool_result`, `llm_call`, `llm_chunk`, `structured_output`. Add table-driven cases as part of Slice A. `dispatcher_test.go` doesn't exercise the binding-level event emission — add tests that drive a TS skill through the dispatcher and assert the emitted event sequence.
7. **`Recorder` not currently surfaced to bindings**: confirm the cleanest plumbing path during Slice A. Three options: (a) ctx value, (b) extend Bindings struct, (c) `Executor` interface gets a `WithRecorder` decorator. Pick after reading the code; do not over-engineer.

### Suggested Build Order

**PR 1 — Slice A (backend telemetry + parent linkage)**:

1. Add `runIDKey` typed context key in `pkg/agent/runner`. `Run` and `Start` populate ctx before `exec.CallTool`.
2. Add `ParentRunID` read at runner entry: if ctx already has a run ID, surface it in `RunStartedPayload`.
3. Plumb recorder access to `bindings.go`. Pick the simplest of {ctx-value, bindings-struct field, executor decorator} after reading.
4. Add `node_enter` / `node_exit` emission around each top-level binding call (counter-scoped IDs).
5. Add `tool_call` / `tool_result` emission inside `tool()` and `handoff()` bindings.
6. Add `llm_call` emission inside `llm()` binding.
7. Add `approval_request` / `approval_response` emission inside `approval()` binding.
8. Add size-cap helper (64 KB) for verbatim argument/output JSON.
9. Tests: extend `store_test.go` for the full event-type roundtrip. Add `dispatcher_test.go` cases that assert event emission sequence for a TS skill calling `tool()`, `llm()`, `handoff()`.
10. Manual validation: run `audit-repo.sh` end-to-end; `cat ~/.gridctl/runs/<id>.jsonl` shows the full event sequence; open the IDE at `?run=<id>` and confirm the canvas decorates.

**PR 2 — Slices B + C (frontend output pane + runs browser)**:

1. Slice B: `RunOutputView` component (`<pre>` JSON viewer + truncate/expand). Render in `NodeDetail.tsx`'s no-node-selected branch when `runID` is set.
2. Slice B: in-flight loading state with live event count.
3. Slice C: extract `useRunsForSkill` hook from `RunLauncherModal.tsx:99–118`; update modal to use the hook.
4. Slice C: add `TabToggle` (extract or copy from `RunLauncherModal.tsx`) to `SkillSidebar.tsx`.
5. Slice C: `RunsList` component — group by `parent_run_id`, indent children, status badges, click sets URL params.
6. Slice C: wire `handleLaunched` in `AgentIDE.tsx` to trigger a refresh of the runs list.
7. Manual validation: launch via `RunLauncherModal`, watch sidebar refresh; open via `?run=<id>`, confirm output renders; toggle sidebar tabs; confirm nested runs indent.

## Acceptance Criteria

1. Running `audit-repo.sh` (or any TS-skill MCP call) produces a JSONL ledger containing `node_enter`/`node_exit`/`tool_call`/`tool_result`/`llm_call`/`run_completed` events in causal order — not just `run_started`/`run_completed`.
2. A TS orchestrator skill that calls `handoff("leaf-skill", …)` produces a child run whose `EventRunStarted.payload.parent_run_id` matches the parent's run ID.
3. `gridctl runs inspect <child-run-id>` (existing CLI) shows the parent linkage; the IDE's Runs tab indents the child under the parent.
4. Opening the Agent IDE at `?skill=<x>&run=<id>` shows: (a) per-node trace decoration on the canvas, (b) the final JSON output in the right pane when no node is selected, (c) the run summary in the toolbar.
5. The sidebar `Skills | Runs` tab toggle switches between the existing skill list and a runs list; clicking a run navigates to that run's view.
6. `useRunsForSkill` hook is exported from a shared module and consumed by both `RunLauncherModal` and the new Runs list.
7. `store_test.go` exercises every event type in the closed vocabulary except `llm_chunk` (deferred).
8. `dispatcher_test.go` includes at least one test asserting that a TS skill calling `tool()`, `llm()`, and `handoff()` emits the expected `node_enter`/`tool_call`/`tool_result`/`llm_call`/`node_exit` sequence with correct `parent_run_id` on the child.
9. Lint (`golangci-lint`), tests (`go test -race ./...`), web build (`npm run build`), and web lint pass cleanly on the feature branch.
10. Arguments or outputs larger than 64 KB are truncated with a `truncated: true` marker — never written verbatim past the cap.
11. `EventLLMChunk` and OpenTelemetry export are explicitly NOT present in the diff (verify via `git diff --stat` and grep).
12. No regressions in `RunLauncherModal`'s "Run like…" flow after extracting `useRunsForSkill`.

## References

- gridctl PR #628 (`53c9be2`) — `fix: persist mcp tools/call runs to ledger` (the persistence half this builds on)
- `pkg/agent/persist/events.go` — event vocabulary contract (read first)
- `pkg/agent/sandbox/bindings.go` — async Promise pattern and emit sites
- `web/src/components/agent/ide/useRunTrace.ts` — consumer-side trace folding (no changes needed)
- [LangSmith Run Data Format](https://docs.langchain.com/langsmith/run-data-format) — reference for `parent_run_id` semantics
- [LangGraph Studio thread history UX](https://changelog.langchain.com/announcements/langgraph-studio-v2-run-and-debug-production-traces-locally) — reference for runs-browser pattern
- [OpenTelemetry GenAI Agent Spans](https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-agent-spans/) — future-portable shape (do not implement now)
- Evaluation: `<prompts-dir>/gridctl/agent-ide-run-legibility/feature-evaluation.md`
