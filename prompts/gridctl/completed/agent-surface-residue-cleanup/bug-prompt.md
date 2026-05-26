# Bug Fix: Agent Surface Residue Cleanup

## Context

gridctl is an MCP gateway and skill library written in Go (`cmd/gridctl/`, `internal/`, `pkg/`) with a React/TypeScript frontend (`web/`). The project uses the Cobra CLI library, the Go `net/http` `ServeMux` with method-prefixed routes (Go 1.22+), and a pre-1.0 versioning strategy with no documented external API consumers.

In PRs #680, #681, and #682 the project removed its agent/A2A runtime surface (typed-skill execution, agent IDE, `/api/agent/*`, `/api/playground/*`, `pkg/agent/`, the Stage/Runs UI workspaces). The `[Unreleased]` section of `CHANGELOG.md` documents that removal under `Removed`, `Changed`, and `Migration` headings.

The agent removal was scoped to surfaces with `agent` in their name. It did not sweep three related cleanup items that are addressed in this PR:

1. A misleadingly-named HTTP route that operates on MCP server names but has "agents" in its URL.
2. A `X-Agent-Name` CORS allowlist entry that no production handler reads, plus a `agentName` local-variable naming convention in `pkg/mcp/router.go` that conflicts with the actual semantics (MCP server name, not agent name).
3. Accidental drift in how CLI commands register themselves on `rootCmd` — some are listed in `cmd/gridctl/root.go`'s `init()` block, others self-register from their own files.

## Investigation Context

Investigation completed; root cause is unambiguous. Key findings shaping this prompt:

- The HTTP route `/api/agents/{name}/logs` is **actively used** by the frontend (`fetchAgentLogs` in `web/src/lib/api.ts:138`, called from `DetachedLogsPage.tsx`, `LogsTab.tsx`, `LogViewer.tsx`, and 16 references across the `LogViewer.test.tsx` suite). It is also covered by 5 backend tests. This is a rename, not a deletion.
- The frontend `restartAgent` and `stopAgent` functions in `web/src/lib/api.ts` are **defined but never called**, and they reference server routes that do not exist (the canonical restart route is `/api/mcp-servers/{name}/restart`). They are pure dead code from the agent era and should be deleted.
- The CORS header `X-Agent-Name` has **zero production readers** (verified via `rg -n 'X-Agent-Name|Header\.Get.*[Aa]gent'`). One test sets it conditionally; that line should be removed. The header is also documented in `docs/api-reference.md:1120` (CORS section) — that doc line should be updated.
- `cmd/gridctl/root.go` has **6 self-registering commands**, not 4 as the original report estimated (`export` and `version` also self-register). No double-registration exists.
- The `AgentClient` interface type and its `AddClient`/`RemoveClient` methods retain agent terminology. These are **explicitly out of scope** for this PR — renaming a public interface ripples too far for a cleanup commit.

Full investigation: `prompts/gridctl/agent-surface-residue-cleanup/bug-evaluation.md`

## Bug Description

After the agent/A2A surface removal in PRs #680/#681/#682, three pieces of agent-era code remained in the tree:

**Misleading HTTP route.** `GET /api/agents/{name}/logs` (`internal/api/api.go:221`) and its handler `handleAgentLogs` (`internal/api/api.go:612-642`) still exist. The handler filters logs by `entry.Attrs["server"] == name`, so the URL says "agents" but the implementation operates on MCP server names. The frontend `fetchAgentLogs` still calls this endpoint from four places.

**Dead frontend agent control functions.** `web/src/lib/api.ts:168-200` defines `restartAgent` and `stopAgent`, which POST to `/api/agents/{name}/restart` and `/api/agents/{name}/stop`. These backend routes do not exist; the canonical route is `POST /api/mcp-servers/{name}/restart`. The two functions are not called anywhere in `web/`.

**Stale CORS allowlist + docs + test.** `internal/api/api.go:531` includes `X-Agent-Name` in `Access-Control-Allow-Headers`. `pkg/mcp/streamable_test.go:32` sets the header on a test request. `docs/api-reference.md:1120` documents the header in the CORS section. No production handler reads it.

**Stale `agentName` identifier in `pkg/mcp/router.go`.** The variable name, named-return parameters of `PrefixTool` and `ParsePrefixedTool`, struct-field comments on `Router.sets`/`Router.tools`, the doc comment on `Router`, and the error messages "unknown agent: %s" and "expected agent__tool" all refer to what is now an MCP server name. `pkg/mcp/gateway.go:1258` has the same misnomer in the autoscaler cold-start path. `pkg/mcp/router_test.go` carries the misnomer through its table-test field names.

**Inconsistent command registration in `cmd/gridctl/root.go`.** The `init()` block at lines 22-43 registers 16 commands via `rootCmd.AddCommand(...)`. Six additional commands (`reload`, `telemetry`, `traces`, `upgrade`, `export`, `version`) self-register in their own files' `init()` functions. Both patterns work, but `root.go` reads as the canonical CLI index and is now incomplete.

## Root Cause

The agent removal in PRs #680/#681/#682 deleted everything that exposed agent semantics on the runtime path. It did not touch:

- HTTP routes whose URL contains "agents" but whose body operates on MCP server names. `/api/agents/{name}/logs` predates the multi-server router pivot — commit 0ba07ea added `PrefixTool`/`ParsePrefixedTool` on 2026-01-06, before agents were a separate concept, and the route was inherited.
- The CORS allowlist, co-located with `internal/api/api.go`'s middleware where the cleanup pass did not look.
- Local variable names and error messages in `pkg/mcp/router.go`, which were written when "agent" and "MCP server" were synonyms in the gridctl mental model.
- Frontend functions whose only callers had already been deleted; the functions themselves were missed by the frontend removal pass.

The `root.go` AddCommand drift is unrelated to agent removal — it accumulated as new commands were added by different contributors using a self-registering pattern. The cleanup is opportunistic and rides along because it touches the same `cmd/gridctl/` directory the next contributor will read after this PR.

## Fix Requirements

### Required Changes

1. **Rename HTTP route** `/api/agents/{name}/logs` → `/api/mcp-servers/{name}/logs` to match the existing `/api/mcp-servers/{name}/restart` and `/api/mcp-servers/{name}/tools` convention. Rename the handler `handleAgentLogs` → `handleMCPServerLogs`. Update the leading doc comment on the handler.
2. **Rename the 5 backend tests** in `internal/api/api_test.go`: `TestHandleAgentLogs_NoBuffer` → `TestHandleMCPServerLogs_NoBuffer`, `_FiltersByServer`, `_EmptyWhenNoMatch`, `_LinesParam`, `_MethodNotAllowed`. Update the test URLs from `/api/agents/...` to `/api/mcp-servers/...`.
3. **Rename frontend function** `fetchAgentLogs` → `fetchServerLogs` in `web/src/lib/api.ts:138`. Update the JSDoc comment and the URL the function fetches.
4. **Update frontend callers**: `web/src/pages/DetachedLogsPage.tsx` (import + line 152 call), `web/src/components/log/LogsTab.tsx` (import + line 67 call), `web/src/components/ui/LogViewer.tsx` (import + line 24 call), `web/src/__tests__/LogViewer.test.tsx` (import + every `vi.mocked(fetchAgentLogs)` mock + `expect(fetchAgentLogs).toHaveBeenCalledWith(...)` assertion — 16 references). The mock-call-args strings like `'my-agent'` can stay as test data; they're arbitrary names.
5. **Delete dead frontend functions** `restartAgent` (`web/src/lib/api.ts:164-181`) and `stopAgent` (`web/src/lib/api.ts:183-200`). Also delete the `// === Agent Control Functions (require backend endpoints) ===` section header at line 132 if these were the only functions under it. Verify with `rg -n "restartAgent|stopAgent" web/` that no callers exist (currently none do).
6. **Drop `X-Agent-Name`** from the CORS allowlist at `internal/api/api.go:531`. Resulting line: `allowHeaders := "Content-Type, Authorization"`.
7. **Drop `X-Agent-Name`** from the stale docs CORS block at `docs/api-reference.md:1120`. Resulting line: `Access-Control-Allow-Headers: Content-Type, Authorization`.
8. **Drop the test header setter** at `pkg/mcp/streamable_test.go:31-33` (the `if agentName != "" { req.Header.Set("X-Agent-Name", agentName) }` block). The `agentName` parameter is also unused in the helper after this change — remove the parameter from the helper signature and from all callers in the same test file, or rename to `serverName` if other call sites need to thread a server identifier through (read the helper and its callers to decide).
9. **Rename `agentName` → `serverName`** in `pkg/mcp/router.go`:
   - Line 10 doc comment: "routes tool calls to the appropriate agent" → "routes tool calls to the appropriate MCP server"
   - Line 18 field comment: `// agentName -> replica set` → `// serverName -> replica set`
   - Line 19 field comment: `// prefixedToolName -> agentName` → `// prefixedToolName -> serverName`
   - Line 30 doc comment on `AddClient`: keep as-is OR change "agent client" → "client" (both reasonable; do whichever reads cleaner without changing the public method name).
   - Lines 193, 199, 207: local variable `agentName` → `serverName`.
   - Line 202: error message `"unknown agent: %s"` → `"unknown server: %s"`.
   - Line 207: error message `"agent %s: %w"` → `"server %s: %w"`.
   - Line 217 comment `"agent__tool"` → `"server__tool"`.
   - Line 218: `func PrefixTool(agentName, toolName string)` → `func PrefixTool(serverName, toolName string)`.
   - Line 222 doc comment: "agent and tool names" → "server and tool names".
   - Line 223: `func ParsePrefixedTool(prefixed string) (agentName, toolName string, err error)` → `func ParsePrefixedTool(prefixed string) (serverName, toolName string, err error)`.
   - Line 226 error message: `"invalid tool name format: %s (expected agent__tool)"` → `"invalid tool name format: %s (expected server__tool)"`.
10. **Rename `agentName` → `serverName`** in `pkg/mcp/router_test.go`. Update the table-test field names (`tc.agent` → `tc.server`, `wantAgent` → `wantServer`) and the returned variable in `TestParsePrefixedTool`. Update assertion error messages correspondingly.
11. **Rename local variable** in `pkg/mcp/gateway.go:1258` from `agentName` → `serverName` (and the call site on line 1259 that passes it to `g.GetAutoscaler(...)`).
12. **Consolidate CLI registration in `cmd/gridctl/root.go`**: extend the `init()` block at lines 22-43 to add `rootCmd.AddCommand(reloadCmd)`, `rootCmd.AddCommand(telemetryCmd)`, `rootCmd.AddCommand(tracesCmd)`, `rootCmd.AddCommand(upgradeCmd)`, `rootCmd.AddCommand(exportCmd)`, `rootCmd.AddCommand(versionCmd)`. Remove the corresponding `rootCmd.AddCommand(...)` line from each of:
    - `cmd/gridctl/reload.go` (line 38)
    - `cmd/gridctl/telemetry.go` (line 104 — keep the three `telemetryCmd.AddCommand(...)` calls that register subcommands; only remove the `rootCmd.AddCommand(telemetryCmd)` line)
    - `cmd/gridctl/traces.go` (line 66 — flag setup in the same init() stays)
    - `cmd/gridctl/upgrade.go` (line 62)
    - `cmd/gridctl/export.go` (line 39 — flag setup stays)
    - `cmd/gridctl/version.go` (line 18 — this init() may become empty; if so, delete the empty `func init() {}` entirely)
   
   The resulting `root.go` `AddCommand` list should be in a sensible order — preserve the existing 16-command order and append the 6 in any reasonable grouping (e.g., alphabetical, or by category: keep `reload`/`telemetry`/`traces`/`upgrade` near the existing operations group, `export` near `apply`/`destroy`, `version` last). Use judgment.
13. **Update `CHANGELOG.md`** `[Unreleased]` section:
    - Under `### Breaking`, add an entry noting `GET /api/agents/{name}/logs` was renamed to `GET /api/mcp-servers/{name}/logs` (pre-1.0, no shim).
    - Under `### Removed`, add an entry noting the `X-Agent-Name` CORS header was removed (no production reader).
    - Under `### Changed`, add an entry noting `pkg/mcp` internal naming was clarified (`agentName` → `serverName` in router and gateway internals; public interface names unchanged).

### Constraints

- **Do not rename** the `AgentClient` interface or its methods (`AddClient`, `RemoveClient`, etc). That is a public-API change with wider blast radius and belongs in a separate, scoped PR.
- **Do not redesign** `/api/logs` to absorb the server-filtered query. Adding a `?server=` filter would be a sensible follow-up but is out of scope. The minimum fix is to rename the existing dedicated route.
- **Do not add a redirect / backwards-compat shim** for `/api/agents/{name}/logs`. Pre-1.0, no documented external consumer; clean rename.
- **Preserve every existing test assertion's intent.** The 5 backend log-handler tests should keep testing the same behavior (no-buffer empty response, server-name filter correctness, empty-when-no-match, lines query param, method-not-allowed). The 16 frontend test references should keep testing the same UI behaviors.
- **Do not change route HTTP methods or response shapes.** The renamed route returns identical JSON.
- **Preserve `PrefixTool` and `ParsePrefixedTool` public behavior.** Renaming named-return parameters changes godoc but does not change Go ABI. Function names, parameter count, return arity, and return types must be unchanged.

### Out of Scope

- Renaming `AgentClient`, `AddClient`, `RemoveClient`.
- Adding a `?server=` query param to `/api/logs`.
- Touching the `/api/mcp-servers` and `/api/tools` surfaces beyond the one rename specified.
- Renaming the test parameter `agentName` in `pkg/mcp/streamable_test.go`'s helper — if the parameter is unused after dropping the header set, remove it; otherwise rename to `serverName`. Use judgment based on how the helper is called.
- Any CLI behavior changes (`gridctl <cmd>` invocations must work identically before and after this PR).

## Implementation Guidance

### Key Files to Read

Before writing changes, read these end-to-end to anchor on the existing patterns:

- `internal/api/api.go` — `Server` struct, `Handler()` routing block (lines 209-242), and the CORS middleware around line 525-540. See how `/api/mcp-servers/{name}/restart` and `/api/mcp-servers/{name}/tools` are structured for the canonical pattern.
- `internal/api/api_test.go` — naming convention for the 5 `TestHandleAgentLogs_*` tests so the rename keeps the same style.
- `pkg/mcp/router.go` — full file (it is small, ~230 lines). Note that `Router.sets` and `Router.tools` are the load-bearing fields and that `PrefixTool`/`ParsePrefixedTool` are the public helpers used by 5+ test files and `gateway.go`.
- `pkg/mcp/router_test.go` lines 220-275 (`TestPrefixTool` and `TestParsePrefixedTool`) — table-test structure.
- `web/src/lib/api.ts` — the whole file. Note that the file already uses a convention of "MCP servers" elsewhere; the rename brings `fetchAgentLogs` in line with that.
- `web/src/__tests__/LogViewer.test.tsx` — the 16-reference test file. Read the whole file to understand the mock pattern; the rename is mechanical but should not change behavior.
- `cmd/gridctl/root.go` — full file. Note that `init()` does three things: registers a persistent flag, calls `initHelp()`, and lists `AddCommand` calls. The 6 new entries should slot into the existing list, not into a new block.
- One representative self-registering file (e.g., `cmd/gridctl/telemetry.go`) to confirm the `init()` pattern. `telemetry.go`'s `init()` does flag setup + subcommand registration + root registration; the move only deletes the last line.
- `CHANGELOG.md` `[Unreleased]` section — match the existing bullet style and tone.

### Files to Modify

| File | Change |
|------|--------|
| `internal/api/api.go` | Rename route at line 221, rename handler at line 614, update handler doc comment at line 612-613, drop `X-Agent-Name` from CORS allowlist at line 531. |
| `internal/api/api_test.go` | Rename 5 `TestHandleAgentLogs_*` functions → `TestHandleMCPServerLogs_*`; update test URLs from `/api/agents/...` to `/api/mcp-servers/...`. |
| `pkg/mcp/router.go` | Rename `agentName` → `serverName` throughout (variables, named returns, parameter names, comments, error messages). See Required Changes #9 for the line-by-line list. |
| `pkg/mcp/router_test.go` | Rename table-test fields and locals. See Required Changes #10. |
| `pkg/mcp/gateway.go` | Rename local at line 1258 (and the call site on the next line). |
| `pkg/mcp/streamable_test.go` | Drop the `X-Agent-Name` header set at lines 31-33 and clean up the helper signature/callers. |
| `web/src/lib/api.ts` | Rename `fetchAgentLogs` → `fetchServerLogs`, update URL and JSDoc, delete `restartAgent` and `stopAgent` (lines 164-200) and the section comment at line 132 if it's now orphaned. |
| `web/src/pages/DetachedLogsPage.tsx` | Update import (line 21) and call (line 152). |
| `web/src/components/log/LogsTab.tsx` | Update import (line 21) and call (line 67). |
| `web/src/components/ui/LogViewer.tsx` | Update import (line 4) and call (line 24). |
| `web/src/__tests__/LogViewer.test.tsx` | Update import (line 22), mock decl (line 6), and 16 references to `fetchAgentLogs`. |
| `docs/api-reference.md` | Drop `X-Agent-Name` from line 1120. |
| `cmd/gridctl/root.go` | Extend `init()` block with 6 new `AddCommand` calls. |
| `cmd/gridctl/reload.go` | Delete `rootCmd.AddCommand(reloadCmd)` from init() (line ~38). |
| `cmd/gridctl/telemetry.go` | Delete `rootCmd.AddCommand(telemetryCmd)` from init() (line ~104); keep the three subcommand `AddCommand` lines. |
| `cmd/gridctl/traces.go` | Delete `rootCmd.AddCommand(tracesCmd)` from init() (line ~66); keep flag setup. |
| `cmd/gridctl/upgrade.go` | Delete `rootCmd.AddCommand(upgradeCmd)` from init() (line ~62); keep flag setup. |
| `cmd/gridctl/export.go` | Delete `rootCmd.AddCommand(exportCmd)` from init() (line ~39); keep flag setup. |
| `cmd/gridctl/version.go` | Delete `rootCmd.AddCommand(versionCmd)` from init() (line ~18); if init() becomes empty, delete the empty function. |
| `CHANGELOG.md` | Append entries to `[Unreleased]` under `Breaking`, `Removed`, and `Changed`. |

### Reusable Components

- Use the existing `mcp-servers` path convention in `internal/api/api.go:223-224` as the template for the renamed route. No new helpers needed.
- Use the existing CORS allowlist format (comma-separated string in `allowHeaders`) — just delete the header.
- Use the existing `AddCommand` block style in `cmd/gridctl/root.go` for the consolidated registrations.

### Conventions to Follow

- Go: idiomatic naming, error-message lowercasing matches existing style (`"unknown server: %s"`, `"server %s: %w"`).
- Test file naming: `TestHandle<RouteName>_<Scenario>` (matches the 5 existing names).
- Frontend: function names in camelCase; `fetchServerLogs` matches the existing `fetchGatewayLogs`/`fetchStatus`/etc. style in `web/src/lib/api.ts`.
- CHANGELOG: match the existing bullet style under each subsection — short, present-tense, lead with the surface that changed.
- Signed commits (`-S`), no Co-authored-by trailers, no mention of Claude in commit messages or PR descriptions (per user's global instructions).

## Regression Test

### Test Outline

No new tests required. Verify by running the existing suites:

**Backend**:
- `go build ./...` — must compile.
- `go test -race ./internal/api/... ./pkg/mcp/...` — the renamed `TestHandleMCPServerLogs_*` tests must pass with the renamed route. `TestPrefixTool` and `TestParsePrefixedTool` must pass with the renamed table-test fields.
- `go vet ./...` — no new vet warnings.
- `golangci-lint run` — no new lint warnings.

**Frontend**:
- `npm run build` — must succeed.
- `npm test` — `LogViewer.test.tsx` must pass with all 16 mock references renamed to `fetchServerLogs`.

**CLI**:
- `./gridctl --help` — must list all 22 commands. Compare before/after to confirm `reload`, `telemetry`, `traces`, `upgrade`, `export`, `version` are still present and that no command was lost.
- `./gridctl <each-command> --help` — spot-check 2-3 of the moved commands (e.g., `gridctl telemetry --help`, `gridctl traces --help`) to confirm flags and subcommands still work.

### Existing Test Patterns

- Go tests: table-driven where appropriate; `t.Helper()` in test helpers; httptest for HTTP handler tests. See `internal/api/api_test.go` for the existing handleAgentLogs tests' structure.
- Frontend tests: Vitest with `vi.mocked()` for module-level mocks; `@testing-library/react` for component tests. See `web/src/__tests__/LogViewer.test.tsx`.

## Potential Pitfalls

- **`pkg/mcp/streamable_test.go` helper signature**: the helper takes an `agentName` parameter that becomes unused after dropping the `X-Agent-Name` header set. Decide whether to remove the parameter entirely or rename to `serverName` based on whether it's threaded into other request logic. Read the helper and its callers before changing the signature.
- **Named return values in `PrefixTool`/`ParsePrefixedTool`**: Go return parameter names are documentation-only at the call site — renaming `agentName` → `serverName` in the signature does not break callers. But it does change godoc. If the project has any tooling that pins godoc output, this is the only change that would surface.
- **`Router.AddClient` doc comment**: line 30 says "adds an agent client to the router". The public method is `AddClient` and the parameter type is `AgentClient` — both stay. Update the doc comment word `agent` → `MCP server` (or just delete the redundant word). Do not rename the method or the type.
- **Frontend `__tests__/LogViewer.test.tsx` mock data**: assertions like `expect(fetchAgentLogs).toHaveBeenCalledWith('my-agent', 500)` get renamed at the function-name level. The string `'my-agent'` is arbitrary test data and can stay (or be renamed to `'my-server'` for consistency — judgment call, either is fine).
- **`cmd/gridctl/version.go` empty init()**: after deleting the `AddCommand` line, the init() may be empty. Delete the empty `func init() {}` rather than leaving a no-op.
- **`cmd/gridctl/telemetry.go`**: this file has more than just an `AddCommand` line in init() — it also registers three subcommands on `telemetryCmd` (status, wipe, tail). Only delete the `rootCmd.AddCommand(telemetryCmd)` line; the subcommand registrations and flag setup must stay.
- **CHANGELOG `[Unreleased]` section structure**: read the existing entries first to match tone and bullet density. The agent-removal entries are detailed; these new entries can be shorter (one-line per change).
- **Route rename is a breaking change**: even though no external consumer is documented, the PR description and CHANGELOG `Breaking` section must call this out clearly. Future-you reading the changelog should see the rename without having to grep.

## Acceptance Criteria

1. `rg -n "/api/agents" .` returns zero hits in `internal/`, `cmd/`, `pkg/`, `web/`, `docs/`, and `CHANGELOG.md` (except for historical CHANGELOG entries documenting the past surface).
2. `rg -n "X-Agent-Name" .` returns zero hits in code or non-historical docs.
3. `rg -n "agentName" pkg/mcp/` returns zero hits (or only hits that are part of `AgentClient` type references, which are explicitly out of scope).
4. `rg -n "unknown agent|expected agent__tool|appropriate agent" pkg/mcp/` returns zero hits.
5. `rg -n "rootCmd\.AddCommand" cmd/gridctl/` returns hits only in `cmd/gridctl/root.go`.
6. `rg -n "restartAgent|stopAgent" web/` returns zero hits.
7. `rg -n "fetchAgentLogs" web/` returns zero hits; `rg -n "fetchServerLogs" web/` returns 9+ hits (api.ts definition + 4 callers + 4 frontend test references after renaming).
8. `go build ./...` succeeds.
9. `go test -race ./...` succeeds with all renamed tests passing.
10. `golangci-lint run` produces no new warnings.
11. `npm run build` succeeds in `web/`.
12. `npm test` succeeds in `web/` with all renamed `LogViewer.test.tsx` assertions passing.
13. `./gridctl --help` lists all 22 commands (apply, destroy, status, serve, stop, link, unlink, var, vault, validate, plan, info, skill, pins, optimize, activate, reload, telemetry, traces, upgrade, export, version).
14. `curl -i localhost:<port>/api/mcp-servers/<server>/logs` returns the same JSON shape that `/api/agents/<server>/logs` returned before the PR.
15. `CHANGELOG.md`'s `[Unreleased]` section has at least one entry under `Breaking` (route rename), one under `Removed` (CORS header), and one under `Changed` (`pkg/mcp` internal naming).
16. The PR description summarizes the change as the natural follow-up to PRs #680/#681/#682, calls out the route rename as a breaking change, and links to the bug-evaluation.md investigation.

## References

- `prompts/gridctl/agent-surface-residue-cleanup/bug-evaluation.md` — full investigation.
- Prior cleanup PRs: #680 (backend agent removal), #681 (frontend agent removal), #682 (docs sync).
- Existing canonical pattern: `/api/mcp-servers/{name}/restart` at `internal/api/api.go:223` and `/api/mcp-servers/{name}/tools` at `internal/api/api.go:224`.
- Go 1.22 `ServeMux` method-prefixed routes: https://pkg.go.dev/net/http#ServeMux
