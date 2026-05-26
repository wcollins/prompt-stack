# Bug Investigation: Agent IDE Unwired in `gridctl serve`

**Date**: 2026-05-12
**Project**: gridctl
**Recommendation**: Fix immediately
**Severity**: High
**Fix Complexity**: Small

## Summary

The Phase F Agent IDE is unreachable on any default install: `gridctl serve` embeds the React UI but never constructs the dev-server backend, so `/api/agent/dev/skills` always 503s; `gridctl agent dev` constructs the backend but mounts no HTML, so its root path 404s. The documented entry point (`open http://localhost:8181/` per `proto/agent/09-dev-ide.md`) was never wired to begin with. Fix is a small, additive change in `gateway_builder.go` plus a flag on `serve` — risk is low and the unified runtime aggregate already plumbs the read path end-to-end.

## The Bug

Two commands exist for the Agent IDE and **neither produces a working canvas**:

- `gridctl serve --port 8180` → `http://localhost:8180/agent` loads the IDE shell, but the sidebar reads `"EMPTY PROJECT — No SKILL.md found. Run gridctl agent init to scaffold a starter."` because `GET /api/agent/dev/skills` returns `{"error":"agent dev server not configured"}` with HTTP 503.
- `gridctl agent dev --root ~/.gridctl/registry/skills/probe --port 8181` → `GET /api/agent/dev/skills` works, but `GET /` returns `404 page not found`. No HTML is served from this listener.

Expected behavior: at least one default-install path renders a populated canvas for skills installed under `~/.gridctl/registry/skills/`. Discovered while exercising the Phase F deliverables documented in `proto/agent/09-dev-ide.md`.

## Root Cause

Three independent design gaps combine. All three are verified against current `main`.

### Defect Location

1. `internal/api/agent_dev.go:23` — `SetAgentDevServer` exists but is **never called in production code** (only in tests). The accessor `s.devServer()` at `api.go:279-286` prefers `s.agentRuntime.DevServer()` over the legacy field, and `runtime.SetDevServer` at `pkg/agent/runtime/runtime.go:102` is also never called in production. The dev-server constructor exists, the setter exists, the read path exists — but no construction call chains them together.
2. `pkg/agent/dev/devserver/devserver.go:71-77` — `Handler()` registers exactly three routes: `GET /api/agent/dev/skills`, `GET /api/agent/dev/skills/{name}`, `GET /api/agent/dev/events`. No `mux.Handle("/", webFS)` or static-file fallback.
3. `web/src/lib/agent-api.ts:8` — `const API_BASE = ''` is hardcoded. All five fetch/EventSource calls in the IDE (`agent-api.ts:54,67,94,152,181`) resolve against the empty base, so the UI on 8180 cannot talk to a backend on 8181.

### Code Path

```
User hits  http://localhost:8180/agent
        │
        ▼
internal/api/api.go  serves embedded React app from WebFS (works)
        │
React app fetches /api/agent/dev/skills
        │
        ▼
api.go:333          mux.HandleFunc("/api/agent/dev/", s.handleAgentDev)
        │
        ▼
agent_dev.go:31     handleAgentDev — s.devServer() → nil
        │
        ▼
agent_dev.go:33-35  503 "agent dev server not configured"
```

The break point: `pkg/controller/gateway_builder.go:548-550` calls `server.SetAgentRuntime(rt)` but never calls `rt.SetDevServer(...)` first. The line right above it (`rt.SetChatModel(provider)` at 540) is the model for what's missing.

### Why It Happens

Wiring was incomplete in PR #603 ("fix: wire agent runtime, TS dispatcher, and require shim"). That PR wired the runtime aggregate but stopped one constructor call short of the dev server. The comment block on `SetAgentDevServer` at `agent_dev.go:14-18` foreshadows this:

> "...they can wire a dev server here at apply time (or via a future serve flag)."

The "future serve flag" never landed.

### Similar Instances

Only two commits touch any of the affected files:

```
132fc36  feat: add visual IDE for agent runtime (phase F slices 1–3) (#599)
f604180  fix: wire agent runtime, TS dispatcher, and require shim (#603)
```

No similar half-wired subsystems found elsewhere in the codebase. The other `Set*Server` setters in `internal/api/api.go` (`SetRegistryServer`, `SetVaultStore`, `SetPinStore`, `SetAgentRunStore`, `SetAgentApprovalRegistry`) are all called from `gateway_builder.go` at apply time.

## Impact

### Severity Classification

**High.** Bug class is "feature regression on default install path." Not data loss, not security. But a marquee Phase F deliverable is non-functional in any out-of-the-box configuration and has documented (broken) instructions.

### User Reach

Anyone who follows `proto/agent/09-dev-ide.md`, finds the IDE shell at `/agent` in the daemon UI, or reads release notes referencing the Visual IDE. Specifically affects skill authors who would use the canvas to validate graph structure before running.

### Workflow Impact

**Critical path blocker** for the documented Agent IDE workflow. Skill authors are forced back to `gridctl agent validate <name> --format json | jq` — adequate for CI but not the visual workflow the feature promises.

### Workarounds

- `curl -s http://localhost:8181/api/agent/dev/skills | jq` against the standalone server — works but is not the canvas.
- No workaround exists that produces a working canvas without code changes.

### Urgency Signals

- Feature shipped ~3 weeks ago (PR #599 / #603) and is doc-referenced.
- `proto/agent/09-dev-ide.md` and `proto/agent/HOWTO-audit-repo.md` reference behavior that doesn't exist.
- Likely user-visible in any release notes for Phase F.
- No data corruption risk; no security risk → "next release," not "hotfix."

## Reproduction

### Minimum Reproduction Steps

```sh
# 1. Build
cd ~/code/gridctl && make build

# 2. Scaffold a skill in the registry
mkdir -p ~/.gridctl/registry/skills/probe
cd ~/.gridctl/registry/skills/probe
~/code/gridctl/gridctl agent init --name probe --lang ts

# 3a. Validate works
~/code/gridctl/gridctl agent validate probe --format json | jq '.valid'   # → true

# 3b. Boot daemon
~/code/gridctl/gridctl serve --port 8180 &
sleep 2

# 3c. Daemon API: 503
curl -s http://localhost:8180/api/agent/dev/skills
# → {"error":"agent dev server not configured"}

# 3d. Daemon UI: empty shell
# Browse http://localhost:8180/agent — sidebar reads "EMPTY PROJECT"

# 4a. Standalone command
~/code/gridctl/gridctl agent dev --root ~/.gridctl/registry/skills/probe --port 8181 &
sleep 1

# 4b. API works
curl -s http://localhost:8181/api/agent/dev/skills | jq '.skills[].name'
# → "probe"

# 4c. Root path 404s
curl -s http://localhost:8181/
# → 404 page not found
```

### Affected Environments

Deterministic on all platforms — bug is in pure Go/TS source, not OS-specific. Reproduces with any `make build` of current `main`.

### Non-Affected Environments

None — bug is universal.

### Failure Mode

- Daemon: HTTP 503 with JSON envelope `{"error":"agent dev server not configured"}` from `internal/api/agent_dev.go:34`. UI degrades gracefully to "EMPTY PROJECT" placeholder rather than crashing.
- Standalone: Plain-text `404 page not found` from Go's default `http.ServeMux` because no `/` pattern is registered in `devserver.Handler()`.

Neither failure mode leaves the system corrupted — both are recoverable by restart with a different config.

## Fix Assessment

### Fix Surface

| File | Change |
|---|---|
| `cmd/gridctl/root.go` | Add `--agent-dev-root` flag to `serveCmd`, default `""` |
| `pkg/controller/controller.go` (Config struct) | Add `AgentDevRoot string` |
| `cmd/gridctl/apply.go` (`runServeStackless`) | Plumb `applyAgentDevRoot` (or new var) into `controller.Config` |
| `pkg/controller/gateway_builder.go` | Resolve effective root (flag → `~/.gridctl/registry/skills` if exists → unset). When set, construct `watcher.New(root)` + `devserver.NewServer(root, w)`, call `rt.SetDevServer(dev)`, start `w.Run(ctx)` on the controller's lifecycle |
| `proto/agent/09-dev-ide.md` | Rewrite section 9.4 to use `gridctl serve --agent-dev-root <path>` on port 8180 instead of `open http://localhost:8181/` |
| `internal/api/agent_dev_test.go` (new) | Table-test both branches of `handleAgentDev` (configured + 503) |

Estimated ~80–150 lines including tests.

### Risk Factors

- **Watcher lifecycle**: the standalone command's watcher runs in a goroutine for the lifetime of the process. Wiring into the daemon needs to bind the watcher's `Run(ctx)` to the controller's lifecycle context and clean up on shutdown.
- **Default-on behavior**: if the fix auto-defaults to `~/.gridctl/registry/skills`, the daemon now does I/O on the user's home dir on startup. Should be tolerant of missing dir (no error).
- **Concurrent skill writes**: while watcher is observing the registry, `gridctl skill add` may write into it. Existing `gridctl agent dev` already handles this via the watcher's debounce — should reuse, not reimplement.
- **No CORS issues**: UI + API co-located on 8180, so the `API_BASE = ''` constant continues to work unchanged.

### Regression Test Outline

1. **Unit (`internal/api/agent_dev_test.go`)** — confirm `handleAgentDev` returns 503 when `agentDevServer == nil && agentRuntime == nil`, and delegates to `devserver.Handler()` when either is set. Table-driven.
2. **Unit (`pkg/controller/gateway_builder_test.go` or similar)** — confirm when `Config.AgentDevRoot` is set to a tmpdir containing a `SKILL.md`, the runtime's `DevServer()` returns non-nil after build.
3. **Integration (smoke)** — script under `proto/agent/` boots `gridctl serve --agent-dev-root <tmpdir>` and asserts `curl /api/agent/dev/skills` returns non-empty `.skills`.

## Recommendation

**Fix immediately, next release.** Severity is High but not Critical, complexity is Small, risk is Low. The unified runtime accessor at `api.go:279-286` already prefers `agentRuntime.DevServer()`, so the wiring lives entirely within `gateway_builder.go` and the flag plumbing — no API surface changes, no behavior changes when the flag is unset.

**Defer:**

- Path 2 (embed UI into standalone `gridctl agent dev`) — leave the standalone command as the JSON/curl/jq surface for CI smoke tests and follow-up. The doc fix removes the "open http://localhost:8181/" promise that this path was needed to deliver.
- Path 3 (configurable `API_BASE`) — unnecessary once UI + API are co-located on port 8180.

**Conditions to revisit deferred paths:** if a use case emerges where the standalone command must serve the canvas (e.g., a CI smoke that includes browser-driven assertions), path 2 becomes warranted as a follow-up.

## References

- PR #599 — `132fc36 feat: add visual IDE for agent runtime (phase F slices 1–3)`
- PR #603 — `f604180 fix: wire agent runtime, TS dispatcher, and require shim` (the PR where this wiring was *supposed* to land)
- `proto/agent/09-dev-ide.md` — Phase F smoke test, currently inaccurate at section 9.4
- `proto/agent/HOWTO-audit-repo.md` — references daemon-served IDE behavior
- `internal/api/agent_dev.go:14-18` — comment foreshadowing the "future serve flag"
