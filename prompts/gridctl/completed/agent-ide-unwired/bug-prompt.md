# Bug Fix: Agent IDE Unwired in `gridctl serve`

## Context

gridctl is a Go-based MCP (Model Context Protocol) orchestration tool with an embedded React/TypeScript web UI under `web/`. The daemon (`gridctl serve` / `gridctl apply`) embeds the production `web/dist` build via `cmd/gridctl/embed.go` and serves it at the same port (default 8180) as the API surface in `internal/api/`. Subsystems plug into the API server via setters (`SetAgentRuntime`, `SetRegistryServer`, `SetVaultStore`, `SetPinStore`, `SetAgentRunStore`) that are called from `pkg/controller/gateway_builder.go` at apply/serve time. When a setter is nil at request time, the corresponding handler returns HTTP 503.

The Phase F "Agent IDE" is a project-rooted React canvas that visualizes typed-skill graphs (TS or Go) and hot-reloads on file changes via a server-sent-events stream. Its backend lives in `pkg/agent/dev/devserver/` and is exposed under `/api/agent/dev/*`. A standalone `gridctl agent dev` command also exists, primarily for JSON/CI use against a single project root.

## Investigation Context

- **Root cause confirmed**: PR #603 wired the unified agent runtime aggregate via `server.SetAgentRuntime(rt)` at `pkg/controller/gateway_builder.go:549` but never called `rt.SetDevServer(...)` first. The accessor `(s *Server).devServer()` at `internal/api/api.go:279-286` already prefers `agentRuntime.DevServer()` over the legacy `agentDevServer` field — so the entire read path is plumbed, only the constructor call is missing. The comment block at `internal/api/agent_dev.go:14-18` foreshadows a "future serve flag" that this fix delivers.
- **Risk mitigation baked into the fix**: additive only — new flag, new construction. Default behavior unchanged when the flag and the `~/.gridctl/registry/skills` fallback are both absent.
- **Reproduction confirmed**: deterministic on all platforms via the steps in the investigation. Daemon returns 503 from `internal/api/agent_dev.go:34`; standalone returns plain `404 page not found` because `pkg/agent/dev/devserver/devserver.go:71-77` registers no root pattern.
- **Defer**: do not embed the UI into the standalone `gridctl agent dev` command, and do not make `web/src/lib/agent-api.ts:8`'s `API_BASE` configurable. Both become unnecessary once UI + API co-locate on port 8180 via this fix.
- Link to full investigation: `~/code/prompt-stack/prompts/gridctl/agent-ide-unwired/bug-evaluation.md`

## Bug Description

After a stock install (`make build`) and scaffolding a skill under `~/.gridctl/registry/skills/<name>` via `gridctl agent init`:

- `gridctl serve --port 8180` boots the daemon. Browsing to `http://localhost:8180/agent` loads the IDE shell, but the sidebar renders **"EMPTY PROJECT — No SKILL.md found. Run gridctl agent init to scaffold a starter."** because `GET /api/agent/dev/skills` returns HTTP 503 `{"error":"agent dev server not configured"}`.
- `gridctl agent dev --root ~/.gridctl/registry/skills/<name> --port 8181` boots a standalone listener. `GET /api/agent/dev/skills` returns the parsed skills correctly, but `GET /` returns `404 page not found` — there is no HTML surface on that listener.

Expected behavior: at least one default-install path renders the populated Agent IDE canvas for skills installed under `~/.gridctl/registry/skills/`. The documented path (`proto/agent/09-dev-ide.md`) currently instructs `open http://localhost:8181/`, which 404s by construction.

Affected users: anyone following the Phase F documentation or attempting to use the Visual IDE from release notes.

## Root Cause

- `internal/api/agent_dev.go:23` defines `(s *Server).SetAgentDevServer(dev *devserver.Server)`. A full repo grep confirms this method has **zero production callers** — only test fixtures.
- `pkg/agent/runtime/runtime.go:102` defines `(r *Runtime).SetDevServer(d *devserver.Server)`. Also **zero production callers**.
- `pkg/controller/gateway_builder.go:531` resolves the runtime aggregate `rt`, lines 533-541 wire `rt.SetChatModel(provider)`, and line 549 wires `server.SetAgentRuntime(rt)`. Nowhere in this function is `rt.SetDevServer(...)` called, even though the accessor `internal/api/api.go:279-286` is already wired to read from `rt.DevServer()` first.
- The standalone `agentDevCmd` in `cmd/gridctl/agent.go:83-163` builds the HTTP listener using `srv.Handler()` directly with no static-file mount.

The correct logic is: when `Config.AgentDevRoot` is set on the controller (or when `~/.gridctl/registry/skills` exists as a default), construct a `watcher.New(root)`, run it on the controller's lifecycle context, construct a `devserver.NewServer(root, w)`, and call `rt.SetDevServer(srv)` before `server.SetAgentRuntime(rt)`.

## Fix Requirements

### Required Changes

1. Add a new `--agent-dev-root <path>` flag to `serveCmd` in `cmd/gridctl/root.go`. Default empty string. Hidden=false.
2. Add the same flag to `applyCmd` in `cmd/gridctl/apply.go` so applied stacks can opt in. Default empty string.
3. Add `AgentDevRoot string` to `controller.Config` in `pkg/controller/controller.go`.
4. In `cmd/gridctl/apply.go`, plumb the new flag through `runServeStackless()` and `runApply()` into the `controller.Config{}` literal.
5. In `pkg/controller/gateway_builder.go`, near the existing `rt.SetChatModel(provider)` block (around line 540), resolve the effective dev-root:
   - If `b.cfg.AgentDevRoot != ""`, use it.
   - Else if `os.Stat("$HOME/.gridctl/registry/skills")` succeeds, use that.
   - Else skip — leave `rt.DevServer()` nil; preserves current behavior.
6. When a non-empty root is resolved, construct `w, err := watcher.New(root)`. On error, log a warning and skip (do not fail the daemon — the IDE is non-essential). On success, start `go w.Run(ctx)` against the controller's lifecycle context and `defer` cleanup as needed. Construct `srv, err := devserver.NewServer(root, w)`. On error, log and skip. On success, call `rt.SetDevServer(srv)`. This call must occur **before** `server.SetAgentRuntime(rt)` so the read accessor picks it up.
7. Add a one-time stderr/log line: `agent IDE wired (root=<root>)` so users can see whether the IDE backend booted.
8. Rewrite `proto/agent/09-dev-ide.md` section 9.4 ("Open the canvas in a browser") to use the daemon path:
   ```
   # T1
   ~/code/gridctl/gridctl serve --port 8180 --agent-dev-root /tmp/gridctl-agent-test/hello-ts
   # T2
   open http://localhost:8180/agent
   ```
   Adjust step numbering or prerequisites in surrounding sections as needed for narrative consistency.
9. Add unit tests in a new `internal/api/agent_dev_test.go` covering both branches of `handleAgentDev`: 503 when no runtime/legacy server is wired, and successful delegation when either is wired.

### Constraints

- **Do not modify `web/src/lib/agent-api.ts`** or any other web file. UI + API co-locate on port 8180; no retargeting needed.
- **Do not embed the WebFS into `pkg/agent/dev/devserver/devserver.go`.** The standalone `gridctl agent dev` command remains JSON/API-only by intent.
- **Do not change the signature of `SetAgentDevServer`** or remove it. It is the legacy direct-wire path retained for test fixtures (see comment at `agent_dev.go:20-22`).
- **Do not break existing tests.** The fix is additive; no current behavior should change when `--agent-dev-root` is unset and `~/.gridctl/registry/skills` does not exist.
- **The watcher must shut down cleanly** when the controller's lifecycle context is cancelled. Lifetime should match the daemon, not leak goroutines.
- **Default fallback I/O** to `~/.gridctl/registry/skills` must be a non-fatal `os.Stat` check — never return an error or refuse to boot if the directory is missing.

### Out of Scope

- Embedding the React app into `gridctl agent dev` (path 2 from intake — defer).
- Making `web/src/lib/agent-api.ts`'s `API_BASE` configurable (path 3 from intake — unnecessary).
- Refactoring `internal/api/agent_dev.go` or removing the legacy `agentDevServer` field.
- Changing how `SetAgentRuntime` interacts with per-component setters.
- Hot-swapping the dev root at runtime (the flag is read once at apply time).
- Cross-origin / CORS work — co-location avoids this entirely.

## Implementation Guidance

### Key Files to Read

| File | Why |
|---|---|
| `internal/api/agent_dev.go` | The 503 origin and the legacy setter — understand the comment about precedence at lines 20-22 |
| `internal/api/api.go:79-102` | Server struct — see `agentDevServer` and `agentRuntime` fields and their comments |
| `internal/api/api.go:279-286` | The `devServer()` accessor that already prefers `agentRuntime.DevServer()` |
| `pkg/agent/runtime/runtime.go:85-113` | `SetChatModel` / `SetDevServer` / `DevServer` symmetry — model the new call after `SetChatModel` |
| `pkg/agent/dev/devserver/devserver.go:43-58` | `NewServer(root, w)` signature — `w` may be nil (disables SSE only) |
| `pkg/agent/dev/watcher/watcher.go` | `watcher.New(root)` and `Run(ctx)` lifecycle — see how `cmd/gridctl/agent.go:117` uses it |
| `pkg/controller/gateway_builder.go:496-636` | `buildAPIServer` — the natural insertion point is near the `rt.SetChatModel` block around line 540 |
| `pkg/controller/controller.go` (Config struct) | Where to add `AgentDevRoot string` |
| `cmd/gridctl/root.go:50-67` | `serveCmd` flag definitions — add the new flag here |
| `cmd/gridctl/apply.go:55-83` | `applyCmd` flags and `runServeStackless` — flag plumbing into `controller.Config` |
| `cmd/gridctl/agent.go:83-163` | `agentDevCmd` — the existing standalone wiring; useful as a reference for watcher lifecycle but **do not modify** |
| `proto/agent/09-dev-ide.md` | Update section 9.4 (and references in 9.5+ if they depend on standalone mode) |
| `pkg/agent/dev/devserver/devserver_test.go` | Existing test patterns — mirror style for the new `agent_dev_test.go` |

### Files to Modify

| File | Specific change |
|---|---|
| `cmd/gridctl/root.go` | After line 65, add `serveCmd.Flags().StringVar(&applyAgentDevRoot, "agent-dev-root", "", "Project root for the Agent IDE dev server (defaults to ~/.gridctl/registry/skills if present)")`. Declare `applyAgentDevRoot` in `apply.go`'s var block. |
| `cmd/gridctl/apply.go` | Add `applyAgentDevRoot string` to the var block (lines 17-30). Add the same flag to `applyCmd` in the `init()` at lines 55-68. In both `runServeStackless()` and `runApply()`, pass `AgentDevRoot: applyAgentDevRoot` into the `controller.Config{}` literal. |
| `pkg/controller/controller.go` | Add `AgentDevRoot string` to `Config` struct with a doc comment matching the flag help text. |
| `pkg/controller/gateway_builder.go` | After `rt.SetChatModel(provider)` block (~line 542) and **before** `server.SetAgentRuntime(rt)` (~line 549), insert the resolve + construct + wire block described in Required Changes step 6. |
| `proto/agent/09-dev-ide.md` | Replace section 9.4 (lines 63-79) with the daemon-based instructions. Verify steps 9.5, 9.6, 9.7 still narrate correctly against the daemon port; minor wording fixes only. |
| `internal/api/agent_dev_test.go` | New file. See test outline below. |

### Reusable Components

- `watcher.New(root)` and `(*Watcher).Run(ctx)` from `pkg/agent/dev/watcher/` — already used by `cmd/gridctl/agent.go:104-118`. **Reuse this exact pattern**; do not write a new watcher.
- `devserver.NewServer(root, w)` from `pkg/agent/dev/devserver/` — handles nil watcher gracefully.
- `os.UserHomeDir()` + `filepath.Join(home, ".gridctl", "registry", "skills")` for the default fallback resolution. See `pkg/skills/` for existing examples of how the project resolves `~/.gridctl/`.
- The existing `slog.Default()` logger pattern used elsewhere in `pkg/controller/gateway_builder.go` for the "wired" / "skipped" log lines.

### Conventions to Follow

- **Setter pattern**: subsystem getters/setters on `internal/api/api.go::Server` follow `func (s *Server) SetX(x *X)` / `func (s *Server) x() *X`. Mirror this if any new accessor is needed.
- **Apply-time wiring lives in `gateway_builder.buildAPIServer`**, not in the command file. The command file's only responsibility is flag → `controller.Config`.
- **Optional subsystem failures must be non-fatal**: log a warning, leave the field nil, let the handler return 503 with a clear message. Match how `SetMetricsAccumulator` and similar handle their inputs.
- **Comments are concise.** Match the existing style in `internal/api/agent_dev.go` — one short paragraph per exported symbol explaining the wiring decision, not what the code does.
- **Imperative commit messages, max 50 chars subject.** Example: `fix: wire agent dev server in serve flag`.

## Regression Test

### Test Outline

**`internal/api/agent_dev_test.go`** (new):

1. `TestHandleAgentDev_Unwired_Returns503`: construct `Server{}` with nil `agentRuntime` and nil `agentDevServer`. Call `s.handleAgentDev` against `httptest.NewRecorder` and `httptest.NewRequest("GET", "/api/agent/dev/skills", nil)`. Assert status 503, body matches `{"error":"agent dev server not configured"}`.
2. `TestHandleAgentDev_LegacyWired_Delegates`: construct `Server{}`, call `SetAgentDevServer(d)` with a minimal `devserver.Server` built against a tmpdir containing one `SKILL.md` + matching `skill.ts`. Assert `GET /api/agent/dev/skills` returns 200 with `{"skills":[...]}` containing that skill.
3. `TestHandleAgentDev_RuntimeWired_PrefersRuntime`: as above, but call `SetAgentRuntime(rt)` where `rt.DevServer()` is set, **and** also set a different `agentDevServer`. Assert the runtime's dev server is used (verify by routing to a known-distinct skill set).

**Optional integration smoke** (under `proto/agent/`):

```sh
TMPDIR=$(mktemp -d)
cp -r testdata/sample-skill "$TMPDIR/probe"
~/code/gridctl/gridctl serve --port 8180 --agent-dev-root "$TMPDIR" &
PID=$!
sleep 2
curl -fsS http://localhost:8180/api/agent/dev/skills | jq -e '.skills | length > 0'
kill $PID
```

### Existing Test Patterns

- `pkg/agent/dev/devserver/devserver_test.go` shows how to build a `devserver.Server` with a tmpdir and a nil watcher for unit-level testing — copy this pattern.
- `internal/api/` tests use `httptest.NewRecorder` / `httptest.NewRequest` (look for `_test.go` files in that directory). Use the same response-assertion helpers if any exist (e.g., a `decodeJSON` test util).

## Potential Pitfalls

- **Watcher leak on daemon shutdown**: if you `go w.Run(ctx)` but never bind to the controller's shutdown signal, the goroutine outlives the daemon in tests. Confirm `gateway_builder` has access to the controller's lifecycle context — if it does not, plumb one in via the `Config` rather than calling `context.Background()`.
- **Wiring order matters**: `rt.SetDevServer(srv)` **must** happen before `server.SetAgentRuntime(rt)`. The accessor reads from the aggregate held by the server, so a later `SetDevServer` call on `rt` will be observed by the server because the server holds a pointer — but writing setup in temporal order avoids the subtle aliasing assumption.
- **Default fallback false positives**: if `~/.gridctl/registry/skills` exists but is empty, the IDE will load an empty sidebar. That is correct behavior (matches `gridctl agent dev` against an empty root). Do not "validate the directory has skills" as a precondition.
- **Tests that don't expect agent runtime**: if any existing test in `internal/api/` constructs a `Server{}` without calling `SetAgentRuntime`, this fix should not change its behavior. Run the existing `internal/api/...` test suite after the change.
- **Flag-name churn risk**: the flag is named `--agent-dev-root` in the intake. If your team has a different naming convention for project-rooted flags elsewhere, mirror that. Check `cmd/gridctl/root.go` for sibling flag names before committing.
- **The `agentDevCmd` in `cmd/gridctl/agent.go` will remain broken at its root path.** This is intentional. Do not silently "improve" the standalone command — that scope is explicitly deferred.

## Acceptance Criteria

1. `gridctl serve --port 8180 --agent-dev-root <tmpdir-with-SKILL.md>` returns HTTP 200 from `GET /api/agent/dev/skills` with the scaffolded skill in the response.
2. `gridctl serve --port 8180` (no flag) with `~/.gridctl/registry/skills/<skill>` present returns HTTP 200 from `GET /api/agent/dev/skills` with that skill in the response — i.e., the zero-config default works.
3. `gridctl serve --port 8180` (no flag, no `~/.gridctl/registry/skills` directory) returns HTTP 503 from `GET /api/agent/dev/skills` with the existing error message — i.e., behavior is unchanged in the "nothing to serve" case.
4. Browsing to `http://localhost:8180/agent` in any of the configurations above renders the React canvas (not the "EMPTY PROJECT" placeholder) whenever skills are present.
5. New `internal/api/agent_dev_test.go` adds at least the three test cases listed in the regression test outline, and all pass with `go test ./internal/api/...`.
6. `proto/agent/09-dev-ide.md` section 9.4 instructs the daemon path, and a manual run of the updated steps end-to-end succeeds.
7. `make build` succeeds and `golangci-lint run` produces no new findings against the touched files.
8. No changes to `web/src/lib/agent-api.ts`, `pkg/agent/dev/devserver/devserver.go`, or `cmd/gridctl/agent.go` (the deferred-scope files).
9. Daemon shuts down cleanly via SIGINT — no leaked watcher goroutines (verify with `runtime.NumGoroutine()` before/after in a test, or by manual observation that the binary exits within 1s).

## References

- Investigation: `~/code/prompt-stack/prompts/gridctl/agent-ide-unwired/bug-evaluation.md`
- PR #599 `132fc36` — added the visual IDE
- PR #603 `f604180` — wired the runtime aggregate but stopped one constructor call short
- `internal/api/agent_dev.go:14-18` — comment foreshadowing the "future serve flag" this fix delivers
- `proto/agent/09-dev-ide.md` — Phase F smoke test, currently inaccurate at section 9.4
