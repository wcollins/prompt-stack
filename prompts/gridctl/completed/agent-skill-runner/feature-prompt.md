# Feature Implementation: Agent Skill Runner UI

## Context

gridctl is an MCP (Model Context Protocol) gateway and agent runtime — beta (v0.1.0-beta.x), Go backend, React + TypeScript + Vite frontend, React Router routing, Tailwind styling, Lucide icons. The `/agent` route serves a developer IDE for agent *skills*: typed graphs of `tool()` / `llm()` / `parallel()` / `handoff()` / `approval()` nodes, in either TypeScript (goja sandbox) or Go (compiled plugin) handler languages.

The IDE today is **read-only with respect to source** ("code is canon — neither view mutates source"). It already mutates *runtime* state from POST endpoints — `POST /api/agent/runs/{id}/resume` (via ResumeButton) and `POST /api/agent/runs/{id}/approve` (via ApprovalBanner). It already inspects runs via `?run=<run_id>` query param, which activates `useRunTrace` SSE subscription and overlays live status pills on the canvas. **No `POST /api/agent/runs` endpoint exists** — runs today are started only via `gridctl run` CLI (in-process, no `tool()`/`llm()`/`approval()` bindings) or raw `POST /mcp` JSON-RPC with `method=tools/call` (the daemon's wired-bindings path).

## Evaluation Context

Brief summary of the evaluation findings that shaped this prompt:

- **Market norm**: Every comparable platform (LangGraph Studio, Inngest, Prefect, Argo, Airflow, Restate, Apollo Explorer) unifies inspect + invoke on the same surface. The MCP Inspector is the canonical reference for MCP-tool UIs. Temporal's OSS Web UI is the cautionary tale of *not* shipping this.
- **Read-only-source principle is preserved**: Across every "definition + runtime" tool researched, "Run" never conflates with "edit definition." Triggering execution mutates runtime state, not source files.
- **Schema quality is the dominant risk to UX**: TS skill input schemas in gridctl default to `{"type":"object"}`. RJSF (react-jsonschema-form) needs richer schemas to be valuable. **Raw JSON editor must be the primary input mode**; RJSF form is a progressive enhancement that only shines when the skill exposes a meaningful schema.
- **Scoped to TS skills initially**: Go skills require a running daemon with `.so` plugin loaded — same constraint as `gridctl run`. Pre-flight the runner accordingly; Go skills land in a follow-up.
- **Doc loop closure**: The `proto/agent/HOWTO-audit-repo.md` step 8a originally drove the user to a UI launcher that didn't exist. Updating this doc is part of this feature, not a separate task.
- **Full evaluation**: `<prompts-dir>/gridctl/agent-skill-runner/feature-evaluation.md`

## Feature Description

Add a per-skill "Run" affordance to the `/agent` IDE that opens a modal launcher and starts a new run via a new `POST /api/agent/runs` endpoint, then redirects to `/agent?skill=<name>&run=<new_run_id>` so the existing read-only inspector + trace overlay handle visualization.

**What it does**: Lets a user pick a registered skill in the browser, supply input as JSON (raw editor) or via a generated form (when the skill's `inputSchema` is rich), and trigger a real run through the daemon — same code path the gateway uses today for MCP `tools/call`.

**What problem it solves**: Today, the only way to start a skill run end-to-end (with `tool()` / `llm()` / `approval()` bindings wired) is `POST /mcp` JSON-RPC. The CLI's `gridctl run` runs TS skills in a bindings-less sandbox. Neither is discoverable from the browser, and both add a context switch (terminal, curl envelope) that breaks the save-and-iterate loop for skill authors and adds friction for operators.

**Who benefits**:
- Skill authors during development: save skill → glance at canvas → click Run → watch trace, all in one tab.
- Operators running registered skills: discoverable invocation, input validation, run history, no curl.

## Requirements

### Functional Requirements

1. The web app exposes a Run button on each row of `SkillSidebar` (the existing skill list at `/agent`). Button is visible on hover or always-visible per chosen UX polish; must be keyboard-focusable.
2. Clicking Run opens a modal dialog scoped to the selected skill.
3. The modal contains:
   - Skill name and description (header).
   - A "Run like…" dropdown listing the 10 most recent runs of this skill; selecting one pre-fills the input editor with that run's `RunStartedPayload.Input`.
   - A tabbed input area: **JSON** tab (raw JSON editor, primary) and **Form** tab (RJSF-generated form when `inputSchema` is non-trivial — otherwise the tab is hidden or disabled).
   - A "Run" submit button and a "Cancel" button.
4. On submit, the frontend POSTs to `POST /api/agent/runs` with `{skill_name, input}` (where `input` is the decoded JSON object).
5. Backend `POST /api/agent/runs`:
   - Validates the skill exists in the registry and has handler language `ts` (initial scope; reject `go` and `""` with clear error message).
   - Validates the input JSON parses as an object.
   - Invokes the same orchestrator/skill-caller path that the gateway's MCP `tools/call` uses. **Do not duplicate the standalone CLI's bindings-less sandbox path.**
   - Returns `{run_id, started_at}` immediately (async; the run executes in the daemon and emits events via the existing JSONL ledger).
   - Returns 4xx with structured error on skill-not-found, wrong handler language, or invalid input JSON.
6. On successful response, the modal closes and the URL updates to `/agent?skill=<name>&run=<new_id>` (replace, not push, to avoid back-button accumulation).
7. The existing `useRunTrace` SSE subscription automatically activates on the new `run` query param — no new inspector code.
8. Per-skill last input is persisted to `localStorage` under a key like `gridctl.agent.lastInput.<skill_name>` and pre-fills the editor when the modal opens with no "Run like…" selection.
9. `proto/agent/HOWTO-audit-repo.md` step 8a is updated to describe the new launcher path.

### Non-Functional Requirements

- **Auth**: `POST /api/agent/runs` uses the same auth path as `POST /api/agent/runs/{id}/resume` / `.../approve`. Do not introduce a new auth surface.
- **Performance**: Modal open is instant (no network call required to open). Submit response should return within 200ms p95 (the run executes async; the response only confirms run-start).
- **Accessibility**: Modal is focus-trapped, ESC closes, focus returns to the originating Run button. Inputs have labels. Errors are announced via `aria-live`.
- **Bundle**: RJSF and a JSON syntax editor (e.g., `@uiw/react-textarea-code-editor`, or just a styled `<textarea>` if bundle pressure is real) — keep the bundle delta under 100KB gzipped where feasible.
- **No regression** to existing `?run=<id>` inspector behavior.

### Out of Scope

- **Go skills**: Reject `go`-handler skills in the new endpoint with a clear "Go skills require plugin load — use `gridctl run` after `gridctl agent build`" error. Adding Go support is a follow-up.
- **Prompt-only skills**: Reject with "prompt-only skills surface as MCP prompts, not invocable tools" (matches existing CLI rejection semantics).
- **A new run-history page**: Reuse `/agent?run=<id>` for the post-launch view. Do not build a `/runs` route.
- **A new BottomPanel tab**: Modal is the surface. BottomPanel is untouched.
- **Approval handling in the launcher**: The existing `ApprovalBanner` already handles paused runs; the launcher does not need its own approval UI.
- **Multi-step wizard**: Single-modal, single-screen. No wizard.
- **File uploads as input**: Inputs are JSON. File-binary inputs are a future concern.
- **Run cancellation from the launcher**: Cancellation is a separate concern (no cancel endpoint exists today; not creating one as part of this).
- **Schema-quality improvement work for TS skills**: The launcher must work with today's `{type:object}` defaults via raw JSON. Improving TS skill schema extraction is a separate feature.

## Architecture Guidance

### Recommended Approach

**Backend (Go)**:

Add `POST /api/agent/runs` to `internal/api/agent_runs.go`. The handler:
1. Parses request body `{skill_name: string, input: map[string]any}`.
2. Validates skill exists via the registry store; validates `HandlerLanguage == "ts"` (initial scope).
3. Calls into the same orchestrator entry point the MCP `handleToolsCall` uses. The cleanest architectural approach: factor out a `pkg/agent/runner.Start(ctx, runtime, skillName, input) (runID string, err error)` that both `pkg/mcp/streamable.go:handleToolsCall` and the new API handler can call. This avoids the new handler reaching into MCP envelope semantics.
4. Returns `{run_id, started_at}` synchronously after run-start (the run continues async; events stream via existing SSE).
5. Wire route in `internal/api/api.go` next to the other agent-run routes.

**Frontend (React + TypeScript)**:

Three new files:
1. `web/src/components/agent/ide/RunLauncherModal.tsx` — the modal component. Imports RJSF if `inputSchema` is non-trivial; falls back to a `<textarea>` JSON editor.
2. `web/src/components/agent/ide/SkillRunButton.tsx` — a small button component used inside `SkillSidebar` rows.
3. `web/src/lib/agent-runs.ts` (existing file) — add `launchRun({skill_name, input}): Promise<{run_id, started_at}>`.

Modify:
- `web/src/components/agent/ide/SkillSidebar.tsx` — render `<SkillRunButton />` on each row.
- `web/src/components/agent/ide/AgentIDE.tsx` — when the modal returns `run_id`, update URL params with `setParams({skill, run})`.

### Key Files to Understand

Read these before writing code:

| Priority | Path | Why |
|---|---|---|
| 1 | `internal/api/agent_runs.go` | The shape of existing run-lifecycle handlers; mirror their style, error-handling, and `writeJSONError` helper |
| 2 | `pkg/mcp/streamable.go` (handleToolsCall, around line 378) | Where runs are started today via MCP. Factor out the shared entry point from here. |
| 3 | `cmd/gridctl/run.go` | The standalone CLI run path. **Do not** copy this — it lacks `tool()`/`llm()` bindings. Understand the differences. |
| 4 | `web/src/components/agent/ide/AgentIDE.tsx` | URL param handling, `useRunTrace` activation. The post-launch redirect lands here. |
| 5 | `web/src/components/agent/ide/SkillSidebar.tsx` | Existing row layout; how the new Run button fits |
| 6 | `web/src/components/agent/ApprovalBanner.tsx` | Reference pattern for runtime-mutating UI calls from the read-only IDE; reuse the POST + optimistic update style |
| 7 | `web/src/components/agent/ide/useRunTrace.ts` | The hook the new run_id flows into; no changes needed, but confirm event handling for runs that start "right now" |
| 8 | `web/src/lib/agent-runs.ts` | Where the new `launchRun` client function lives; mirror the existing `approveAgentRun` style |
| 9 | `pkg/agent/persist/store.go` | `NewRunID()`, `RunStartedPayload`. No changes needed but confirm contract. |
| 10 | `pkg/registry/server.go` | Skill registry surface — `Tools()`, `CallTool()`. Inputs/outputs in scope for the new handler. |
| 11 | `internal/api/api.go` (lines 311-333) | Route registration block. New POST registers here. |
| 12 | `docs/skills.md` | Three-flavor model and explicit non-features. Confirms TS-first scope. |
| 13 | `proto/agent/HOWTO-audit-repo.md` (step 8a) | The doc that started this; update as part of the PR |

### Integration Points

- **`internal/api/api.go`** — register `POST /api/agent/runs` route next to existing run routes (lines 324–328).
- **`pkg/agent/runner` (new package, or inline in an existing one)** — extract a `Start(ctx, runtime, skillName, input)` function that wraps the orchestrator dispatch. Both `pkg/mcp/streamable.go:handleToolsCall` and the new API handler call this. Avoid passing JSON-RPC envelopes around outside `pkg/mcp`.
- **`web/src/components/agent/ide/SkillSidebar.tsx`** — render Run button per row; clicking opens the modal scoped to that skill.
- **`web/src/components/agent/ide/AgentIDE.tsx`** — own the modal open/close state; on close-with-run-id, call `setParams({skill, run})`.

### Reusable Components

- `useRunTrace` — reused 100% unchanged. The launcher's job is to produce a `run_id` and update the URL; the rest is free.
- `ApprovalBanner` style for the modal's submit handler — busy state, optimistic UX, error banner.
- `web/src/components/wizard/steps/StackForm.tsx` constants (`inputClass`, `labelClass`, `FieldError`) for consistent styling of the JSON editor and any plain inputs.
- `agent-runs.ts` `approveAgentRun` as the shape for `launchRun`.

## UX Specification

**Discovery**: Run button (`▶` icon) on each `SkillSidebar` row. Visible on row hover; always-visible variant if hover-only feels too hidden. Welcome screen (when no skill is selected) also shows a "Pick a skill, then Run" affordance.

**Activation**: Click Run → modal opens, focus moves to the JSON editor.

**Interaction**:
- Modal header: skill name + description (truncate-on-overflow).
- "Run like…" dropdown above the editor: lists 10 most recent runs of this skill by `started_at` desc. Each option labeled `{run_id_short} — {status} — {relative_time}`. Selecting one replaces editor contents.
- Tab strip: **JSON** (default, always present) | **Form** (only present when the skill's `inputSchema` has properties).
- JSON tab: monospace editor pre-filled with `{}` or last-used input. Inline parse errors below the editor (debounced).
- Form tab: RJSF with the skill's `inputSchema`. Validation errors inline. Form values mirror back to JSON tab on tab switch.
- Footer: "Cancel" (left) and "Run" (right). Run button disabled while parse error active or submit in-flight.

**Feedback during run**:
- Submit click → button shows spinner "Starting…" → response received → modal closes → URL updates → trace overlay activates on the canvas.
- If `useRunTrace` is already active for a different run, the URL change unsubscribes from the old one and subscribes to the new run cleanly (verify this in the existing hook).

**Error states**:
- Invalid JSON: inline error below editor; Run button disabled.
- 4xx from backend (skill not found, wrong handler language, invalid input): banner inside the modal; modal stays open; user can edit and retry.
- 5xx from backend: same as 4xx but with retry hint.
- Network error: same as 5xx.
- Run starts but immediately errors (e.g., missing vault key): user sees the error event in the trace overlay (existing path); not the launcher's responsibility.

## Implementation Notes

### Conventions to Follow

- Backend: error returns via `writeJSONError(w, msg, status)` — mirror existing handler style. Imperative-mood error messages ("skill %q not found", "input must be a JSON object").
- Backend tests: table-driven under the same `_test.go` file pattern as the rest of `internal/api/`. Use the same fake-store/registry fixtures the existing tests use.
- Frontend: function components only, no class components. Lucide icons. `cn()` helper from `web/src/lib/cn.ts` for class composition. Tailwind utility classes consistent with surrounding components.
- Frontend tests: existing tests use Vitest + React Testing Library — confirm patterns in `web/src/components/agent/ide/*.test.tsx` and mirror them.
- Commit conventions (project): `feat: <subject>` imperative mood, ≤50 chars, sign with `-S`, no Co-authored-by trailers, no Claude mention.
- This repo uses **fork workflow** — branch off upstream/main, PR to upstream.

### Potential Pitfalls

1. **Don't reuse the standalone CLI sandbox path** in the new endpoint. `cmd/gridctl/run.go` runs TS in-process with `nil` `tool()` / `llm()` / `approval()` bindings. The new endpoint must use the daemon's wired runtime so skills like `repo-audit` (which use `llm()`) actually work.
2. **Race between run-start and SSE subscription**: ensure the run's first events are durable in the ledger before the response returns, OR ensure `useRunTrace` retries on `404 — run not yet recorded` for the first few hundred ms. The simplest safe path is "write the `run_started` event before returning."
3. **RJSF bundle size**: RJSF can be heavy. Use a focused theme (e.g., `@rjsf/utils` + your own field templates) and tree-shake. If bundle delta exceeds 100KB gzipped, consider lazy-loading RJSF only when the Form tab is opened.
4. **JSON editor escape hatch**: a plain `<textarea>` with JSON.parse on debounce is sufficient for v1. A real syntax-highlighting editor (Monaco, CodeMirror) can come later.
5. **`useRunTrace` interaction with brand-new runs**: confirm the SSE handler tolerates a run that has zero events at subscribe time. The existing inspector is typically used on completed runs; this is the first launcher of "live from second 0" runs.
6. **localStorage quota**: bound to ~5MB. Storing per-skill last input is fine; storing run histories there is not. Use the existing `/api/agent/runs` listing for "Run like…".
7. **Authn/authz consistency**: copy the exact auth middleware chain used by `POST /api/agent/runs/{id}/resume`. Do not invent a new one.
8. **Concurrent runs of the same skill**: nothing prevents this in the registry, and it's fine — each run gets its own `run_id` and ledger. Don't add a single-instance lock.
9. **Validation surface**: input validation happens on the backend; the frontend can pre-validate the JSON parses, but the backend is the source of truth for schema validation. Don't duplicate validators.

### Suggested Build Order

1. **Backend slice**: factor out `Start(ctx, runtime, skillName, input)` from `pkg/mcp/streamable.go:handleToolsCall`. Add unit tests for the extracted function.
2. **Backend slice**: add `POST /api/agent/runs` handler in `internal/api/agent_runs.go`, register the route in `internal/api/api.go`. Add handler tests for happy path + skill-not-found + wrong-handler-language + invalid-input.
3. **Frontend client**: add `launchRun` to `web/src/lib/agent-runs.ts`. Add unit test mirroring `approveAgentRun` test style.
4. **Frontend modal (raw JSON only)**: build `RunLauncherModal.tsx` with the JSON tab only. Wire to `launchRun`. Wire URL-param update in `AgentIDE.tsx`. Test the launcher manually against a TS skill (`repo-audit`).
5. **Frontend integration**: render `SkillRunButton` in `SkillSidebar.tsx` rows. Polish hover states.
6. **"Run like…" picker**: add the dropdown of recent runs of this skill. Use the existing `fetchAgentRuns(limit)` filtered client-side by skill name.
7. **RJSF form tab**: add `Form` tab; show it only when the active skill's `inputSchema` has properties beyond `{type:object}`.
8. **localStorage memory**: persist last input per skill; restore on open.
9. **Doc update**: rewrite `proto/agent/HOWTO-audit-repo.md` step 8a to describe the new launcher.
10. **Polish + accessibility**: focus trap, ESC handling, `aria-live` error announcements, keyboard activation of Run button.

## Acceptance Criteria

1. From `/agent`, hovering a skill row in `SkillSidebar` reveals a Run button. Keyboard focus works the same.
2. Clicking Run opens a modal; the modal is focus-trapped; ESC closes it; focus returns to the originating button.
3. The modal shows the selected skill's name and description.
4. The modal's JSON tab is pre-filled with `{}` on first open, or the last input used for this skill (from localStorage), or the input from a "Run like…" selection.
5. Submitting with invalid JSON keeps the modal open and shows an inline error; the Run button is disabled.
6. Submitting with valid JSON calls `POST /api/agent/runs` with `{skill_name, input}`.
7. On 200, the modal closes; the URL updates to `/agent?skill=<name>&run=<new_id>` (replace); the trace overlay activates on the canvas and shows live status pills as events stream.
8. On 4xx (skill not found, wrong handler language, invalid input), the modal stays open and shows a banner with the error message.
9. Attempting to run a Go-handler skill is rejected by the backend with a clear "Go skills require plugin load" message; the rejection is surfaced in the modal.
10. Attempting to run a prompt-only skill is rejected by the backend with a clear "prompt-only skills surface as MCP prompts, not invocable tools" message.
11. The "Run like…" dropdown lists the 10 most recent runs of the active skill; selecting one replaces the JSON editor contents.
12. When the skill's `inputSchema` has properties beyond `{type:object}`, a Form tab is present; switching to it renders an RJSF form; switching back to JSON shows the form values serialized.
13. The new endpoint uses the same auth chain as the other `POST /api/agent/runs/{id}/*` endpoints.
14. Bundle delta for the web app is documented in the PR description; should be under 100KB gzipped (or justified if not).
15. Unit tests cover the backend handler's happy path, skill-not-found, wrong-handler-language, invalid-input, and the auth path.
16. Frontend tests cover modal open/close, JSON validation, submit happy path, and the URL update after submit.
17. `proto/agent/HOWTO-audit-repo.md` step 8a is updated to describe the new launcher and is checked in with the rest of the change.
18. Lint passes (`golangci-lint run`), tests pass (`go test -race`, `npm test`), web build passes (`npm run build`).

## References

- Full feature evaluation: `<prompts-dir>/gridctl/agent-skill-runner/feature-evaluation.md`
- MCP Inspector (canonical UI reference): https://github.com/modelcontextprotocol/inspector
- react-jsonschema-form: https://github.com/rjsf-team/react-jsonschema-form
- LangGraph Studio launcher pattern: https://blog.langchain.com/langgraph-studio-the-first-agent-ide/
- Inngest Invoke modal: https://www.inngest.com/docs/dev-server
- Existing internal references:
  - `internal/api/agent_runs.go` — handler style
  - `web/src/components/agent/ApprovalBanner.tsx` — runtime-mutating UI pattern
  - `web/src/components/agent/ide/useRunTrace.ts` — trace overlay activation
  - `pkg/mcp/streamable.go:handleToolsCall` — the existing run-start path to share with
  - `docs/skills.md` — three-flavor model and explicit non-features
