# Bug Investigation: MCP tools/call doesn't persist typed-skill runs

**Date**: 2026-05-14
**Project**: gridctl
**Recommendation**: Fix with caveats
**Severity**: High
**Fix Complexity**: Small

## Summary

Typed (TS-handler) skills invoked through the MCP Streamable HTTP transport
(`POST /mcp` with `tools/call`) execute correctly but never write the JSONL
run ledger at `~/.gridctl/runs/<run_id>.jsonl`. The Run Launcher path
(`POST /api/agent/runs`) persists correctly because it wraps dispatch in
`runner.Start`; the MCP path goes through `gateway.HandleToolsCall →
registry.Server.CallTool` directly. The defect is a missing wrap, not a
broken implementation. Fix surface is small; risk is contained to picking
an insertion point and surfacing the run_id via the MCP-spec `_meta` field.

## The Bug

A typed skill invoked over the MCP transport returns the correct
`ToolCallResult` but leaves no on-disk audit record. As a result, every
downstream observability surface that reads the ledger is blind to that
invocation:

- `gridctl runs list` / `gridctl runs trace` — empty
- `/api/agent/runs` and its SSE companion — no entry
- Web UI Runs tab — no row
- `optimize.go` heuristics (`unused_tool`, run-level cost) — incorrect aggregates
- Per-skill / per-run cost attribution — lost (per-server/per-client
  intact via the gateway-level metrics observer at
  `pkg/mcp/gateway.go:1398`)
- Approval gates — `compose.NewGate` requires a non-nil recorder, so
  `approval()` cannot be constructed from an MCP-triggered run; the
  binding fails at the sandbox boundary

The Run Launcher (`POST /api/agent/runs`) was added in commit `b6512d6`
on 2026-05-13. The MCP Streamable transport predates it
(`3fea477`) and was simplified by `b3d2add` ("refactor: remove agent
streaming from mcp") on 2026-03-27. The persistent surface was retrofitted
on top of an existing stateless transport that had recently been
simplified, and the two surfaces were never reconciled. The scaffold
script `proto/agent/audit-repo.sh:451-462` already documents the gap with
a workaround comment block.

Expected behavior is (a) — every typed-skill execution writes a ledger
record regardless of entry point. The competing option (b) — codify the
split as "MCP is stateless protocol; Run Launcher is the persistent
surface" — fails the documented contract (AGENTS.md:230,
`cmd/gridctl/runs.go:33-37`, `cmd/gridctl/run.go:8-12`) and the public
positioning of gridctl as the MCP aggregator for Claude Desktop, Cursor,
Continue, Windsurf, et al. (README:478-514).

## Root Cause

### Defect Location

`pkg/mcp/streamable.go:378` — `handleToolsCall` dispatches directly via
`s.gateway.HandleToolsCall(ctx, params)`. No `runner.Start` wrapper, no
`persist.Store` wiring, no JSONL write.

Contrast with `internal/api/agent_runs.go:335` (`handleAgentRunsLaunch`)
which calls `runner.Start(r.Context(), store, s.registryServer, ...)` —
the call that opens the ledger and records `EventRunStarted`.

### Code Path

**MCP path (broken)**:
```
POST /mcp (tools/call)
  → StreamableHTTPServer.handlePost
  → StreamableHTTPServer.handleRequest          (streamable.go:347)
  → StreamableHTTPServer.handleToolsCall        (streamable.go:378)
  → Gateway.HandleToolsCall                     (gateway.go:1267)
  → router.RouteToolCall → AgentClient.CallTool
  → registry.Server.CallTool                    (registry/server.go:170)
  → tsDispatcher.Dispatch
  ✗ NO ledger write
```

**Run Launcher path (working)**:
```
POST /api/agent/runs
  → handleAgentRunsLaunch                       (agent_runs.go:285)
  → runner.Start                                (runner.go:64)
    → store.OpenWriter(runID)
    → rec.Record(EventRunStarted, ...)         [synchronous]
    → go runAsync(...)                         [async]
      → exec.CallTool                          (registry.Server.CallTool)
      → rec.Record(EventRunCompleted, ...)
      → rec.Close() → JSONL file flushed
  ✓ Ledger at ~/.gridctl/runs/<run_id>.jsonl
```

The two paths converge at `registry.Server.CallTool` but only one is
wrapped in the run-persistence machinery.

### Why It Happens

The `runner.Start` API was designed for asynchronous dispatch — the HTTP
response returns `{run_id, started_at}` before the skill finishes, and
the async goroutine writes the terminal event. That asymmetry is
intentional for the Run Launcher (it gives the UI an immediate `run_id`
to subscribe to via SSE). The MCP protocol's `tools/call` semantics are
synchronous — the response *is* the result — so `runner.Start`'s
async-only contract doesn't fit cleanly. Rather than build a synchronous
variant when MCP shipped, the MCP transport was left to call through
`registry.Server` directly without persistence.

The `Executor` interface (`runner.go:33-35`) is already exactly
`CallTool(ctx, name, args) (*ToolCallResult, error)` — the same shape
the gateway dispatches against. A small synchronous `runner.Run` variant
that opens the ledger, records start/end synchronously, and returns both
the run_id and the result closes the gap without changing the existing
async API.

### Similar Instances

`pkg/mcp/handler.go` contains a legacy `Handler` with the same defect at
line ~166, but it is **not mounted** in production
(`internal/api/api.go:108,311` only registers `StreamableHTTPServer`).
Fix scope is the streamable transport only; the legacy handler can be
left alone or deleted as cleanup.

A latent, separate defect: `ParentRunID` (`persist/events.go:144`) is
read by `optimize.go:226` and `persist/store.go:252` but **never
written** anywhere in the codebase. Nested skill calls inside a chained
orchestrator produce no parent linkage even when both are persisted.
That's a real bug, but distinct from this one — flagged for follow-up.

## Impact

### Severity Classification

**High**, not Critical: the bug breaks a documented contract on the
primary integration surface and silently destroys observability, but it
does not corrupt data, leak secrets, or crash the daemon. Skill results
returned over MCP are correct. The auditability gap cascades to a
functional break for `approval()` in MCP-triggered runs (`compose.NewGate`
rejects nil recorder), making this more than "just missing data."

### User Reach

Every external MCP client that integrates with the gridctl daemon —
Claude Desktop, Claude Code, Cursor, Windsurf, VS Code, Gemini,
OpenCode, Continue, Cline, AnythingLLM, Roo, Zed, Goose (per
README:478-514) — produces zero ledger entries when calling typed
skills. This is the **documented primary integration path**; the Run
Launcher is an internal UI affordance.

### Workflow Impact

| Surface | MCP-triggered run |
|---|---|
| `gridctl runs list` / `runs trace` | Empty for MCP runs |
| `/api/agent/runs` HTTP / SSE | Empty for MCP runs |
| Web UI Runs tab | Empty for MCP runs |
| `optimize.go` (`unused_tool` heuristic, cost aggregates) | Mis-flags MCP-invoked skills as unused; aggregates incomplete |
| Approval gates (`approval()` binding) | Fails to construct — gate rejects nil recorder |
| Per-run / per-skill cost attribution | Lost (gateway-level per-server / per-client metrics intact) |
| `gridctl runs resume` | Unavailable — no ledger to rehydrate |
| OTel span export | MCP runs absent from exported traces |

### Workarounds

- Use `POST /api/agent/runs` (Run Launcher) instead of MCP `tools/call`
- The Run Launcher UI in the Agent IDE works
- Neither workaround is acceptable for production usage of external MCP
  clients — Claude Desktop, Cursor et al. cannot use the Run Launcher
  endpoint; that is the entire point of having an MCP server

### Urgency Signals

- The team already knows: `proto/agent/audit-repo.sh:451-462` documents
  the gap with a workaround comment ("as of this build, MCP `tools/call`
  does not persist…")
- HOWTO-audit-repo.md step 9 (`proto/agent/HOWTO-audit-repo.md:474-507`)
  promises trace inspection after MCP `tools/call`. The promise is
  unreachable today
- Contract documents — AGENTS.md:230, `cmd/gridctl/runs.go:33-37`,
  `cmd/gridctl/run.go:8-12` — all promise universal JSONL persistence
  with no MCP caveat
- Run Launcher shipped 2026-05-13 (`b6512d6`); the gap was introduced
  simultaneously by not extending persistence across MCP. Closing it
  before the next release avoids cementing the divergence

## Reproduction

### Minimum Reproduction Steps

```sh
# 1. Build daemon
make build

# 2. Start daemon
./gridctl serve --foreground --port 8180 &

# 3. Register any TS-handler skill (use audit-repo.sh prerequisite,
#    or any fixture skill with HandlerLanguage == "ts")

# 4. Initialize MCP session and capture session id
SID=$(curl -si -X POST http://localhost:8180/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"repro","version":"1"}}}' \
  | awk 'tolower($1) == "mcp-session-id:" {print $2}' | tr -d '\r')

# 5. Notifications/initialized (no body needed)
curl -s -X POST http://localhost:8180/mcp \
  -H "Content-Type: application/json" -H "Mcp-Session-Id: $SID" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'

# 6. Call the TS skill via MCP
curl -s -X POST http://localhost:8180/mcp \
  -H "Content-Type: application/json" -H "Mcp-Session-Id: $SID" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"<SKILL>","arguments":{}}}'

# 7. Confirm absence
ls -la ~/.gridctl/runs/    # no new <run_id>.jsonl

# 8. Compare with Run Launcher (works)
curl -s -X POST http://localhost:8180/api/agent/runs \
  -H 'Content-Type: application/json' \
  -d '{"skill_name":"<SKILL>","input":{}}'
sleep 1
ls -la ~/.gridctl/runs/    # new <run_id>.jsonl present
```

Alternatively, `./proto/agent/audit-repo.sh https://github.com/sindresorhus/got`
demonstrates the full chained scenario (orchestrator + two leaves, all
dropped).

### Affected Environments

All. The defect is in `pkg/mcp/streamable.go:378`, which is
platform-independent Go. There is no OS, runtime, or configuration that
avoids it.

### Non-Affected Environments

- `POST /api/agent/runs` (Run Launcher) — wraps in `runner.Start`,
  persists correctly
- `gridctl run <skill>` CLI subcommand — has its own persistence path
  (`cmd/gridctl/run.go`)
- Legacy `mcp.Handler` (`pkg/mcp/handler.go`) — same defect but unmounted;
  does not affect production

### Failure Mode

Deterministic, silent. The MCP response returns success with a valid
`ToolCallResult`. The skill executes. No JSONL is written. No log line
indicates the omission. The first observable signal is downstream
(`runs list` empty, UI Runs tab empty, approval gate construction
failure when a skill calls `approval()`).

## Fix Assessment

### Fix Surface

| File | Change |
|---|---|
| `pkg/agent/runner/runner.go` | Add `Run(ctx, store, exec, opts) (runID string, result *mcp.ToolCallResult, err error)` — synchronous variant of `Start`. Records `EventRunStarted` synchronously, dispatches synchronously, records `EventRunCompleted`/`EventError`, returns both run_id and the unmodified result |
| `pkg/mcp/gateway.go` | Add a `RunPersister` hook on `Gateway`, set via a new `SetRunPersister(persister)` method. When `HandleToolsCall` routes to a registered typed-skill client (`registry.Server`), call the persister instead of the raw `client.CallTool` |
| `internal/api/api.go` | After constructing `streamableServer` and `registryServer`, wire the persister: `gateway.SetRunPersister(...)` plumbed through a thin adapter that calls `runner.Run` |
| `pkg/mcp/streamable.go` | If `run_id` is returned by the persister, embed it in `result._meta.run_id` (MCP spec extension point). The streamable transport already returns `result` as the JSON-RPC `result`; no protocol change |
| `pkg/mcp/streamable_test.go` | Add `TestStreamableHTTPServer_ToolsCall_PersistsRunLedger` covering the regression |
| `proto/agent/audit-repo.sh` | Remove workaround comment block at lines 451-462; step 9 now reachable |
| `proto/agent/HOWTO-audit-repo.md` | Optional clarification that step 9 works via MCP path |

### Risk Factors

1. **Sync/async mismatch**. `runner.Start` returns before the skill
   completes; the Run Launcher relies on that. MCP `tools/call` cannot.
   Mitigation: add `runner.Run` synchronous variant alongside; do not
   touch `runner.Start`.
2. **Over-eager persistence**. The gateway also routes tool calls to
   proxied upstream MCP servers (not typed skills). Persisting *those*
   would be wrong. Mitigation: persist only when the target client is
   `registry.Server` (or more precisely, only when the tool name resolves
   to a typed skill).
3. **run_id surfacing**. MCP spec defines `_meta` on result objects as
   the extension point for implementation-specific metadata. Putting
   `run_id` there is spec-compliant and ignored gracefully by clients
   that don't know about it. Avoid custom fields outside `_meta`.
4. **Latent ParentRunID issue**. `runner.Start` doesn't populate
   `ParentRunID` for nested skill calls. Chained orchestrators that call
   `tool()` from inside a typed skill will persist each leaf as a
   parent-less root. That's a real bug, but **out of scope** here.
   Document as follow-up.
5. **Double-recording risk**. If `runner.Run` is wired at the gateway
   layer and the Run Launcher also dispatches through the same gateway,
   the same skill could get two ledger entries. Mitigation: the Run
   Launcher calls `runner.Start` and then `exec.CallTool`, not via the
   gateway — verify with a trace and add a "skip if context already
   carries a run_id" guard if needed.

### Regression Test Outline

`TestStreamableHTTPServer_ToolsCall_PersistsRunLedger` in
`pkg/mcp/streamable_test.go`:

```go
func TestStreamableHTTPServer_ToolsCall_PersistsRunLedger(t *testing.T) {
    // Wire persist.Store + registry.Server + gateway with run-persister
    store := persist.NewStore(t.TempDir())
    regStore := registry.NewStore(t.TempDir())
    regServer := registry.New(regStore)
    require.NoError(t, regServer.Initialize(ctx))
    seedTypedSkill(t, regServer, "demo", "ts")  // fixture from agent_runs_test

    g := NewGateway()
    g.Router().AddClient(regServer)
    g.Router().RefreshTools()
    g.SetRunPersister(newRunPersister(store, regServer))

    srv := NewStreamableHTTPServer(g, nil)

    sid := initializeStreamable(t, srv, "")
    resp := callTool(t, srv, sid, "demo", map[string]any{})

    // 1. Response includes _meta.run_id
    var result ToolCallResult
    require.NoError(t, json.Unmarshal(resp.Result, &result))
    runID, ok := result.Meta["run_id"].(string)
    require.True(t, ok, "result._meta.run_id missing")

    // 2. Ledger has run_started + run_completed
    waitForTerminalStatus(t, store, runID, 2*time.Second)
    events, err := store.Read(runID)
    require.NoError(t, err)
    require.GreaterOrEqual(t, len(events), 2)
    require.Equal(t, persist.EventRunStarted, events[0].Type)
    require.Equal(t, persist.EventRunCompleted, events[len(events)-1].Type)
}
```

Add a second test `TestStreamableHTTPServer_ToolsCall_DoesNotPersist_NonRegistrySkill`
to assert that calls to upstream MCP servers proxied through the gateway
do **not** create ledger entries (only registry-targeted calls do).

## Recommendation

**Fix with caveats** — Next-release priority.

Why "with caveats" and not "immediately": the bug itself is small but
requires one architectural decision (insertion point) and one
spec-extension choice (`_meta.run_id`) that should be locked in
explicitly so the next refactor doesn't undo it. The fix is otherwise
trivial — the `Executor` interface, `persist.Store`, and `registry.Server`
already compose; only the wrapper is missing.

Scope boundaries the implementation must respect:

1. Persist only when the routed MCP tool target is the typed-skill
   registry. Proxied upstream MCP tool calls remain stateless
2. Add a new `runner.Run` synchronous variant. Do not mutate the
   existing `runner.Start` — the Run Launcher contract depends on it
3. Surface `run_id` via `result._meta.run_id` (MCP spec extension), not
   via custom response fields
4. Do not attempt to fix `ParentRunID` population for nested skill
   chains in this PR. Track as follow-up (`runner.Start` already
   accepts no `ParentRunID` parameter)
5. Update `proto/agent/audit-repo.sh:451-462` and
   `proto/agent/HOWTO-audit-repo.md` step 9 once the fix lands

After this fix, approval gates work automatically for MCP-triggered
runs (`compose.NewGate`'s recorder dependency is satisfied); no
separate `approval` work is needed.

## References

- `internal/api/agent_runs.go:275-346` — `handleAgentRunsLaunch`, the
  working pattern
- `pkg/agent/runner/runner.go:64-102` — `runner.Start`, the wrapper
  the MCP path is missing
- `pkg/mcp/streamable.go:378-388` — `handleToolsCall`, the defect site
- `pkg/mcp/gateway.go:1267-1413` — `HandleToolsCall`, the recommended
  insertion-point host
- `pkg/registry/server.go:170-202` — `CallTool`, the shared dispatcher
- `pkg/agent/persist/store.go` — `OpenWriter`, `Read`, `Summary`,
  `Stream`, `List`
- `pkg/agent/compose/approval.go:217-222` — Why approval gates fail
  without a recorder
- `proto/agent/audit-repo.sh:451-462` — Internal awareness of the gap
- `proto/agent/HOWTO-audit-repo.md:474-507` — The unreachable promise
- `README.md:22,478-514` — Public MCP integration positioning
- `AGENTS.md:230`, `cmd/gridctl/runs.go:33-37`, `cmd/gridctl/run.go:8-12`
  — Documented persistence contract
- Commits: `3fea477` (MCP streamable introduced), `b3d2add` (agent
  streaming removed from MCP, 2026-03-27), `b6512d6` (Run Launcher
  endpoint added, 2026-05-13)
- MCP spec on result `_meta`:
  https://modelcontextprotocol.io/specification — `_meta` field is the
  documented extension point on response objects
