# Bug Fix: MCP tools/call persists typed-skill runs to the on-disk ledger

## Context

**gridctl** is an MCP gateway daemon written in Go (`pkg/mcp/`,
`internal/api/`) plus a TypeScript web UI (`web/`). It aggregates tools
from multiple MCP servers behind a single endpoint and lets external
MCP clients (Claude Desktop, Cursor, etc.) reach gridctl-registered
typed skills via the standard MCP protocol.

Typed skills are TypeScript handlers (`skill.ts` + `agent.json`)
dispatched by `pkg/registry`. A typed skill executes via
`registry.Server.CallTool(ctx, name, args)` and returns an
`mcp.ToolCallResult`.

The daemon persists every typed-skill run as a JSONL event ledger at
`~/.gridctl/runs/<run_id>.jsonl`. The ledger is consumed by:

- `gridctl runs list / runs trace / runs resume / runs approve` (CLI)
- `/api/agent/runs[/{id}][/{id}/events|/approve]` (HTTP + SSE)
- The web UI Runs tab
- `internal/api/optimize.go` heuristics (`unused_tool`, run-level cost)
- Approval gates (`pkg/agent/compose/approval.go` — `NewGate` requires
  a non-nil `*persist.Recorder`)

The ledger writer is wired only into one of the two entry points:

1. **Run Launcher** (`POST /api/agent/runs`) — wraps dispatch in
   `runner.Start`, which opens a `persist.Store` writer, records
   `EventRunStarted` synchronously, dispatches async, and records
   `EventRunCompleted` on completion. Persists correctly.
2. **MCP Streamable HTTP** (`POST /mcp` with `tools/call`) — routes
   through `gateway.HandleToolsCall → registry.Server.CallTool`
   directly. **No `runner.Start` wrap; no ledger write.**

This PR closes the gap.

## Investigation Context

- Full investigation:
  `prompts/gridctl/mcp-tools-call-ledger-gap/bug-evaluation.md`
- Root cause confirmed at `pkg/mcp/streamable.go:378` — `handleToolsCall`
  calls `s.gateway.HandleToolsCall(ctx, params)` with no run-persistence
  wrap. The Run Launcher's equivalent at `internal/api/agent_runs.go:335`
  uses `runner.Start(r.Context(), store, s.registryServer, ...)`
- The `Executor` interface in `pkg/agent/runner/runner.go:33` is
  exactly `CallTool(ctx, name, args) (*mcp.ToolCallResult, error)` —
  `*registry.Server` already satisfies it
- Reproduction is deterministic (no race). Confirmed via
  `proto/agent/audit-repo.sh` whose lines 451-462 contain a workaround
  comment block documenting the gap
- Scope is naturally bounded to TS-handler skills: only typed skills
  are advertised via MCP `tools/list` (`pkg/registry/server.go:144`
  filters on `HandlerLanguage == "ts"`), and the Run Launcher also
  rejects Go-plugin and prompt-only with 422 (`agent_runs.go:321-333`)
- Metrics observer is NOT affected — it fires from the gateway layer
  (`pkg/mcp/gateway.go:1398-1408`) which is shared between both
  surfaces. The bug is specifically about the per-run JSONL ledger
- Approval gates ARE affected but stem from the same root cause —
  `compose.NewGate` rejects nil recorder
  (`pkg/agent/compose/approval.go:217-222`). Once the MCP path opens a
  recorder, `approval()` works automatically — no separate fix needed
- Risk mitigations baked into the requirements below:
  - Persist only when the routed target is the typed-skill registry
    (do not persist tool calls proxied to upstream MCP servers)
  - Add a new synchronous `runner.Run` variant; do not mutate the
    existing async `runner.Start` (the Run Launcher contract depends
    on it)
  - Surface `run_id` via `result._meta.run_id` (MCP spec-compliant
    extension point), not via custom response fields
- Out of scope: `ParentRunID` for nested skill chains. The field
  exists (`pkg/agent/persist/events.go:144`) and is read by
  `optimize.go:226` and `persist/store.go:252`, but is never written
  anywhere today. Track as a separate follow-up

## Bug Description

When an external MCP client (Claude Desktop, Cursor, Continue, etc.)
invokes a registered typed skill via the MCP Streamable HTTP transport,
the skill executes correctly and returns the expected result, but no
run record is written to `~/.gridctl/runs/<run_id>.jsonl`. As a
consequence:

- `gridctl runs list` and `gridctl runs trace` show nothing for that
  invocation
- `/api/agent/runs` returns no entry
- The web UI Runs tab is empty
- `optimize.go`'s `unused_tool` heuristic mis-flags actively-used
  skills as stale
- If the skill calls `approval()`, the gate fails to construct
  because `compose.NewGate` requires a non-nil recorder

The expected behavior is that every typed-skill execution writes a
ledger record consistent with the Run Launcher path, regardless of
the entry point.

## Root Cause

`pkg/mcp/streamable.go:378-388` — `handleToolsCall` dispatches via the
gateway directly, bypassing `runner.Start`:

```go
func (s *StreamableHTTPServer) handleToolsCall(ctx context.Context, _ *StreamableSession, req *jsonrpc.Request) jsonrpc.Response {
    var params ToolCallParams
    if err := json.Unmarshal(req.Params, &params); err != nil {
        return jsonrpc.NewErrorResponse(req.ID, jsonrpc.InvalidParams, "Invalid tools/call params")
    }
    result, err := s.gateway.HandleToolsCall(ctx, params)
    if err != nil {
        return jsonrpc.NewErrorResponse(req.ID, jsonrpc.InternalError, err.Error())
    }
    return jsonrpc.NewSuccessResponse(req.ID, result)
}
```

The Run Launcher's working equivalent at `internal/api/agent_runs.go:335`:

```go
runID, startedAt, err := runner.Start(r.Context(), store, s.registryServer, runner.StartOptions{
    Skill:    req.SkillName,
    Flavor:   sk.HandlerLanguage,
    Input:    input,
    RawInput: rawInput,
})
```

The MCP transport never invokes `runner.Start`, never opens a
`persist.Store` writer, and never records `EventRunStarted` /
`EventRunCompleted`.

The correct fix opens the ledger for typed-skill targets at a single
chokepoint inside the gateway's tool-call dispatch — covering all
present and future MCP transports — and surfaces the new `run_id` to
the MCP response via the spec's `_meta` extension.

## Fix Requirements

### Required Changes

1. **Add `runner.Run` synchronous variant** in
   `pkg/agent/runner/runner.go`:
   - Signature:
     `Run(ctx context.Context, store *persist.Store, exec Executor, opts StartOptions) (runID string, result *mcp.ToolCallResult, err error)`
   - Opens the ledger via `store.OpenWriter(runID)`
   - Records `EventRunStarted` synchronously
   - Synchronously invokes `exec.CallTool(ctx, opts.Skill, opts.Input)`
   - Records `EventRunCompleted` with the dispatcher's output (or
     `EventError` + `EventRunCompleted{status: "error"}` on failure)
   - Closes the recorder before returning
   - Returns the run_id, the unmodified result, and any error
   - **Must not mutate or replace existing `runner.Start`**

2. **Add a `RunPersister` hook to `Gateway`** in
   `pkg/mcp/gateway.go`:
   - Define an interface (kept inside `pkg/mcp` to avoid an import
     cycle with `runner`):
     ```go
     type RunPersister interface {
         PersistAndCall(ctx context.Context, name string, arguments map[string]any) (runID string, result *ToolCallResult, err error)
     }
     ```
   - Add `(*Gateway).SetRunPersister(p RunPersister)` and a private
     field. Nil-safe: when unset, behavior is unchanged
   - In `HandleToolsCall` (`gateway.go:1267`), when the routed target
     is a typed skill (i.e., the resolved client is the registry server
     **and** the tool name is a registered typed skill — see step 5
     for the predicate), call `runPersister.PersistAndCall` instead of
     `client.CallTool`. If the persister is nil, fall back to direct
     dispatch (preserves current behavior in tests / partial wirings)

3. **Wire the persister in `internal/api/api.go`** after construction
   of `streamableServer`, `registryServer`, and the agent run store
   (today around `api.go:108` and the `SetAgentRunStore` call). Add a
   thin adapter in `internal/api/` (or under `internal/api/agent_runs.go`,
   adjacent to `handleAgentRunsLaunch`) that wraps `runner.Run` and
   satisfies the gateway's `RunPersister` interface. The adapter's
   `PersistAndCall` must:
   - Look up the skill via `registryServer.Store().GetSkill(name)`
   - Skip persistence and call through to `registryServer.CallTool`
     directly if the skill is not found or `HandlerLanguage != "ts"`
   - Call `runner.Run(ctx, store, registryServer, StartOptions{
       Skill: name, Flavor: "ts", Input: arguments,
       RawInput: <marshal of arguments> })`

4. **Surface `run_id` via `result._meta.run_id`** in
   `pkg/mcp/streamable.go:handleToolsCall` (or in the gateway code path
   if cleaner). When `gateway.HandleToolsCall` returns a `run_id`,
   embed it in `result._meta`:
   ```go
   result.Meta = map[string]any{"run_id": runID}
   ```
   Check the existing `ToolCallResult` struct
   (`pkg/mcp/types.go` near line 80-115) for a `Meta` field; add one
   with a `_meta` JSON tag if absent. MCP spec defines `_meta` as the
   standard extension point on result objects, so this is
   protocol-compliant and ignored by clients that don't know about it.

5. **Typed-skill predicate** at the gateway boundary. Decide whether
   `client.Name()` is the registry server's name (constant or set at
   construction — verify by reading `internal/api/api.go` around the
   `streamableServer`/`registryServer` setup and
   `pkg/registry/server.go`'s `Name()` method). The simpler robust
   predicate: `registryServer.Store().GetSkill(toolName)` returns a
   skill with `HandlerLanguage == "ts"`. Use that predicate.
   **Do not persist** tool calls that route to other clients (upstream
   proxied MCP servers).

6. **Regression test** `TestStreamableHTTPServer_ToolsCall_PersistsRunLedger`
   in `pkg/mcp/streamable_test.go`. Follow the pattern below in the
   "Regression Test" section.

7. **Negative-case test**
   `TestStreamableHTTPServer_ToolsCall_DoesNotPersist_NonTypedSkill`
   that wires a non-typed mock client and asserts the ledger remains
   empty.

8. **Documentation cleanup** — once the fix lands:
   - Delete the workaround comment block in
     `proto/agent/audit-repo.sh:451-462` and restore step 9 to the
     simple form (read `RUN_ID` and call `gridctl runs trace`)
   - Optional: add a brief note in `proto/agent/HOWTO-audit-repo.md`
     step 9 confirming the MCP path now persists

### Constraints

- **Do not modify `runner.Start`** — the async semantics matter for
  the Run Launcher's SSE contract
- **Do not persist** tool calls routed to upstream/proxied MCP servers
  (only typed-skill targets get a ledger)
- **Do not change the MCP protocol response shape** beyond adding
  `_meta` (per spec). Custom top-level fields are forbidden
- **Do not retro-fit `ParentRunID`** for nested skill chains in this
  PR. The field is never written today; that's a separate latent issue
  that should be tracked as follow-up
- **Do not couple `pkg/mcp` directly to `pkg/agent/runner`** — keep
  the `RunPersister` interface inside `pkg/mcp` so the gateway depends
  only on its own interface, and inject the runner-backed implementation
  from `internal/api`

### Out of Scope

- Populating `ParentRunID` for nested skill calls (separate follow-up)
- Removing the legacy unmounted `pkg/mcp/handler.go` (separate cleanup)
- Adding resume / approve over the MCP transport itself — `run_id` in
  `_meta` is sufficient for out-of-band resume/approve via the existing
  CLI (`gridctl runs resume`) and HTTP (`POST /api/agent/runs/{id}/approve`)
  surfaces
- Refactoring the Run Launcher to use `runner.Run` synchronously — its
  async contract is intentional for SSE

## Implementation Guidance

### Key Files to Read

| File | Why |
|---|---|
| `pkg/agent/runner/runner.go` | The existing `Start` is the template for `Run`. Note the async dispatch, the error paths, `outputFromResult`, `recordFailure`. |
| `pkg/agent/runner/runner_test.go` | Test pattern for ledger assertions — `TestStart_HappyPathWritesStartedAndCompleted` is the closest template. Use the same `waitForStatus` helper if applicable. |
| `pkg/mcp/streamable.go` (lines 340-400) | The defect site. `handleToolsCall` and `handleRequest`. Note that `Mcp-Session-Id` flows through session, not request body. |
| `pkg/mcp/gateway.go` (lines 1267-1413) | `HandleToolsCall`. Note the existing `ToolCallObserver` pattern (`ObserveToolCallWithClient` at line 1398) — the new `RunPersister` should follow the same nil-safe setter pattern. |
| `pkg/mcp/types.go` (lines 80-115) | `ToolCallResult` struct. Check whether `Meta` exists; add `Meta map[string]any \`json:"_meta,omitempty"\`` if not. |
| `pkg/registry/server.go` (lines 120-202) | `Tools()` filter, `CallTool` dispatch, `Store().GetSkill(name)` for the typed-skill predicate, `Name()` method if it exists. |
| `internal/api/agent_runs.go` (lines 275-346) | The working `handleAgentRunsLaunch` pattern. The new persister adapter mirrors its `registryServer.Store().GetSkill` + `runner.Start` shape. |
| `internal/api/api.go` (lines 85-115, 252-260, 311) | Where `streamableServer`, `registryServer`, and `agentRunStore` are constructed and wired. The new `SetRunPersister` call goes near the existing `SetAgentRunStore`. |
| `pkg/agent/compose/approval.go` (lines 200-260) | Approval gate construction — confirms the cascade fix; no code change needed here, but read to verify. |
| `pkg/agent/persist/events.go` | Event payload shapes. `RunStartedPayload`, `RunCompletedPayload`, `ErrorPayload`. |
| `proto/agent/audit-repo.sh` (lines 440-490) | The script that exercises this. Lines 451-462 are the workaround block to delete after the fix. |

### Files to Modify

- `pkg/agent/runner/runner.go` — add `Run` synchronous variant
- `pkg/agent/runner/runner_test.go` — add `TestRun_*` tests
  mirroring the `TestStart_*` family
- `pkg/mcp/types.go` — add `Meta` field to `ToolCallResult` if missing
- `pkg/mcp/gateway.go` — `RunPersister` interface, `SetRunPersister`,
  predicate logic in `HandleToolsCall`
- `pkg/mcp/streamable.go` — embed `run_id` into `result._meta` when
  returned by the gateway path
- `pkg/mcp/streamable_test.go` — add the two regression tests
- `internal/api/api.go` (or sibling) — construct and inject the
  runner-backed `RunPersister`
- `proto/agent/audit-repo.sh` — remove the workaround comment block
  at lines 451-462
- (optional) `proto/agent/HOWTO-audit-repo.md` — confirm step 9 now
  works via MCP

### Reusable Components

- `persist.Store.OpenWriter(runID)` — opens the JSONL writer; same
  function used by `runner.Start`
- `persist.NewRunID()` — runner-friendly run id format
- `runner.outputFromResult`, `runner.extractText`, `runner.recordFailure`
  — extract these into reusable helpers if `runner.Run` will share
  them, or duplicate them inline if that's cleaner
- `registryServer.Store().GetSkill(name)` — the same skill lookup the
  Run Launcher uses for handler-language gating
- Gateway's existing `ToolCallObserver` pattern (`gateway.go:1398`) —
  use the same nil-safe setter idiom for `RunPersister`

### Conventions to Follow

- **Sign commits with `-S`** (per `~/.claude/CLAUDE.md`)
- **No Co-authored-by trailers**; no mention of Claude in commit
  messages, PR titles, or branch names
- **Commit type**: `fix:` for the persistence wiring; the prompt-stack
  PR title should be under 50 chars (e.g., `fix: persist mcp tools/call
  runs to ledger`)
- **Branch prefix**: `fix/` (per fork-workflow convention; gridctl uses
  fork workflow per `feedback_fork_workflow.md` memory)
- **Tests**: Go convention `TestType_Behavior_Condition`. Existing test
  names use camel-cased phrases like
  `TestAgentRunsLaunch_ReturnsRunIDForTSSkill` — match that shape
- **Error messages**: lowercase, no trailing punctuation, prefixed with
  package context (e.g., `runner: opening run ledger: %w`)
- **Slog**: use `slog.Warn` for ledger close errors, not `t.Errorf` —
  the existing `runAsync` pattern in `runner.go:107` is the template
- **Build/test**: per memory `feedback_build_workflow.md`, use
  `make build` + `./gridctl`, not the brew-installed binary. Run
  `make test` and `make lint` before opening the PR. `go test -race
  ./pkg/mcp/... ./pkg/agent/runner/... ./internal/api/...` must pass

## Regression Test

### Test Outline

`pkg/mcp/streamable_test.go`:

```go
func TestStreamableHTTPServer_ToolsCall_PersistsRunLedger(t *testing.T) {
    storeDir := t.TempDir()
    store := persist.NewStore(storeDir)

    regStore := registry.NewStore(t.TempDir())
    regServer := registry.New(regStore)
    require.NoError(t, regServer.Initialize(context.Background()))

    // Seed a TS skill that returns a deterministic result without an
    // LLM call. Reuse the helper from agent_runs_test.go or a local
    // equivalent: registers SKILL.md + skill.ts that returns
    // {"ok": true}.
    seedTypedSkill(t, regServer, "demo", "ts")

    g := NewGateway()
    g.Router().AddClient(regServer)
    g.Router().RefreshTools()
    g.SetRunPersister(newRunPersister(store, regServer))

    srv := NewStreamableHTTPServer(g, nil)
    sid := initializeStreamable(t, srv, "")

    resp := callTool(t, srv, sid, "demo", map[string]any{"input": "x"})

    // 1. JSON-RPC success
    require.Nil(t, resp.Error, "tools/call returned error: %v", resp.Error)

    // 2. _meta.run_id present
    var result ToolCallResult
    require.NoError(t, json.Unmarshal(resp.Result, &result))
    require.False(t, result.IsError, "result.IsError should be false")
    require.NotNil(t, result.Meta, "result._meta missing")
    runID, ok := result.Meta["run_id"].(string)
    require.True(t, ok && runID != "", "result._meta.run_id missing or not a string")

    // 3. Ledger has the run with terminal status "ok"
    summary := waitForSummary(t, store, runID, 2*time.Second)
    require.Equal(t, "ok", summary.Status)
    require.Equal(t, "demo", summary.Skill)
    require.Equal(t, "ts", summary.Flavor)

    // 4. Events contain run_started + run_completed
    events, err := store.Read(runID)
    require.NoError(t, err)
    require.GreaterOrEqual(t, len(events), 2)
    require.Equal(t, persist.EventRunStarted, events[0].Type)
    require.Equal(t, persist.EventRunCompleted, events[len(events)-1].Type)
}

func TestStreamableHTTPServer_ToolsCall_DoesNotPersist_NonTypedSkill(t *testing.T) {
    storeDir := t.TempDir()
    store := persist.NewStore(storeDir)

    // Mock a non-registry AgentClient (a proxied upstream MCP server).
    ctrl := gomock.NewController(t)
    client := setupMockAgentClient(ctrl, "upstream", []Tool{
        {Name: "echo", Description: "echo"},
    })
    client.EXPECT().CallTool(gomock.Any(), "echo", gomock.Any()).Return(
        &ToolCallResult{Content: []Content{NewTextContent("ok")}}, nil,
    )

    g := NewGateway()
    g.Router().AddClient(client)
    g.Router().RefreshTools()
    g.SetRunPersister(newRunPersister(store, /* registry server omitted */ nil))

    srv := NewStreamableHTTPServer(g, nil)
    sid := initializeStreamable(t, srv, "")

    resp := callTool(t, srv, sid, "upstream__echo", map[string]any{})
    require.Nil(t, resp.Error)

    // Assert no JSONL files exist
    entries, err := os.ReadDir(storeDir)
    if err == nil {
        require.Empty(t, entries, "ledger should be empty for non-typed tool calls")
    }
}
```

### Existing Test Patterns

- **`pkg/agent/runner/runner_test.go`**: shows how to wire `persist.Store`,
  define a mock `Executor`, and poll `store.Summary(runID)` for terminal
  status. Use the same `waitForStatus` helper (or copy it into a
  test helper file in `pkg/mcp/` if not exported).
- **`pkg/mcp/streamable_test.go`**: `TestStreamableHTTPServer_ToolsCall`
  (line 221) demonstrates the `gomock`-based `AgentClient` mock,
  `initializeStreamable` session setup, and `httptest`-based POST
  helpers. Reuse `setupMockAgentClient` for the negative test.
- **`internal/api/agent_runs_test.go`**: `newAgentRunLaunchTestServer`
  (line 249) and `seedTypedSkill` show how to register a real typed
  skill in tests. If `seedTypedSkill` is exported or copyable, use
  it directly; otherwise duplicate the helper into
  `pkg/mcp/streamable_test.go`.

## Potential Pitfalls

1. **Double-recording when the Run Launcher path also exercises the
   gateway**. If `runner.Start` (Run Launcher) and the new gateway-level
   persister both run on the same call, you'd get two ledger entries.
   Verify the Run Launcher does NOT go through `gateway.HandleToolsCall`
   today (it calls `s.registryServer` directly via the `Executor`
   interface). If it does, add a "run_id already in context" guard
   that disables the gateway persister when context already carries a
   run id.
2. **Session-scoped state in MCP**. `Mcp-Session-Id` is required;
   tests must call `initializeStreamable` before `tools/call`. Don't
   skip that step.
3. **`ToolCallResult.Meta` placement**. If `Meta` is added to
   `ToolCallResult` in `pkg/mcp/types.go`, all existing JSON
   marshalling sites must accept the new optional field. Search for
   `ToolCallResult{` literals across `pkg/` to confirm none break.
   Use `json:"_meta,omitempty"` so absence is a no-op for the wire
   format.
4. **Argument marshalling for `RawInput`**. `runner.Start`'s
   `RawInput json.RawMessage` is the verbatim JSON. The adapter
   receives `arguments map[string]any` from the gateway — marshal it
   back to JSON before passing to `runner.Run`. The Run Launcher
   preserves the raw request bytes; the adapter cannot do that since
   the gateway has already unmarshalled. A `json.Marshal(arguments)`
   round-trip is acceptable (input ordering loss is recorded in the
   ledger but is not a correctness issue for resume).
5. **Approval flow inside MCP `tools/call`**. Once a recorder exists,
   `approval()` will block the MCP HTTP request until a decision is
   delivered. This is the correct behavior — confirm in the regression
   test or as a follow-up integration test, but do not change it.
6. **MCP transport tests use `gomock`** (per
   `pkg/mcp/streamable_test.go`). Don't introduce a different mock
   framework. Reuse `setupMockAgentClient` and friends.
7. **`runner.Run`'s context handling**. Unlike `runner.Start`, the
   synchronous variant should NOT detach from the request context —
   if the MCP client disconnects, the run should be cancelled and the
   ledger should record an error. Pass `ctx` through unchanged; do not
   call `context.WithoutCancel` inside `Run`.
8. **Test isolation**. `persist.NewStore(t.TempDir())` is the
   per-test pattern. Do not write to `~/.gridctl/runs/` in tests.

## Acceptance Criteria

1. `pkg/agent/runner/runner.go` exports `Run` with the documented
   synchronous signature. `runner.Start` is untouched.
2. `pkg/mcp/gateway.go` defines a `RunPersister` interface and
   `(*Gateway).SetRunPersister` method. `HandleToolsCall` calls the
   persister when the tool name resolves to a typed skill and falls
   back to direct dispatch otherwise (including when no persister is
   set).
3. `internal/api/api.go` wires a runner-backed `RunPersister`
   implementation into the streamable server's gateway after
   constructing `streamableServer`, `registryServer`, and
   `agentRunStore`.
4. `pkg/mcp/types.go::ToolCallResult` has a `Meta` field tagged
   `json:"_meta,omitempty"`. `streamable.handleToolsCall` (or the
   gateway path) embeds `run_id` into `result.Meta["run_id"]` when
   the persister returns one.
5. `TestStreamableHTTPServer_ToolsCall_PersistsRunLedger` passes:
   asserts `result._meta.run_id`, asserts ledger summary
   `Status == "ok"`, asserts events include `EventRunStarted` and
   `EventRunCompleted`.
6. `TestStreamableHTTPServer_ToolsCall_DoesNotPersist_NonTypedSkill`
   passes: assertions that a proxied upstream MCP tool call does NOT
   create a ledger file.
7. All existing tests still pass: `go test -race ./...`.
8. `proto/agent/audit-repo.sh` runs end-to-end with the bug fix in
   place: step 9 finds the freshly-created `repo-audit` run in the
   ledger and prints the OTel span sequence. The workaround comment
   block at lines 451-462 is removed.
9. Manual smoke test: with the daemon running, `curl … /mcp …
   tools/call …` of any TS skill produces a new file in
   `~/.gridctl/runs/`, visible via `gridctl runs list` and the web UI.
10. `make lint` and `make build` clean.

## References

- Full investigation:
  `prompts/gridctl/mcp-tools-call-ledger-gap/bug-evaluation.md`
- MCP specification — `_meta` extension on response objects:
  https://modelcontextprotocol.io/specification
- `proto/agent/audit-repo.sh` — the end-to-end repro and the workaround
  block to remove (lines 451-462)
- `proto/agent/HOWTO-audit-repo.md` step 9 (lines 474-507) — the
  promise that becomes reachable after the fix
- README:478-514 — public MCP integration positioning
- AGENTS.md:230, `cmd/gridctl/runs.go:33-37`, `cmd/gridctl/run.go:8-12`
  — documented persistence contract
- Commits: `b6512d6` (Run Launcher endpoint, 2026-05-13), `b3d2add`
  (MCP agent streaming removed, 2026-03-27), `3fea477` (MCP streamable
  introduced)
