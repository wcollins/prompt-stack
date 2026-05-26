# Bug Investigation: Agent Surface Residue Cleanup

**Date**: 2026-05-22
**Project**: gridctl
**Recommendation**: Fix immediately (single bundled PR)
**Severity**: Low
**Fix Complexity**: Small

## Summary

Three pieces of agent-era code outlived the agent/A2A surface removal (PRs #680, #681, #682). None are functional defects — they are dead code and stale naming that mislead readers about what `gridctl` does. Fix is mechanical: rename one HTTP route, drop one CORS header, rename one variable + its comments and error messages, delete two dead frontend functions, fix one stale docs line, and consolidate command registration in `cmd/gridctl/root.go`. Risk is low; the existing test suites (Go + frontend Vitest) cover the changed surface.

## The Bug

After the agent/A2A surface was removed in commits a691e09 (`chore: remove agent runtime backend`), d0eb70c (`chore: remove agent runtime frontend, docs, and CHANGELOG`), and #682 (`docs: sync docs and examples with agent surface removal`), three classes of residue remained:

1. The HTTP route `GET /api/agents/{name}/logs` and its handler `handleAgentLogs` still exist, even though "agents" no longer exist as a concept. The handler internally filters by `entry.Attrs["server"] == name` — i.e., it operates on MCP server names. The URL contradicts the implementation. The frontend still calls this endpoint via `fetchAgentLogs()` in four places. Adjacent dead code: `restartAgent()` and `stopAgent()` are defined in `web/src/lib/api.ts` but never called and point at server routes (`/api/agents/{name}/restart`, `/api/agents/{name}/stop`) that do not exist.
2. The `X-Agent-Name` header is advertised in the CORS `Access-Control-Allow-Headers` list and set by one test, but no production handler reads it. The header is documented in `docs/api-reference.md:1120` even though #682 removed every other documented agent reference. Separately, `pkg/mcp/router.go` uses `agentName` as a local variable, named return value, function parameter name, struct-field comment annotation, and error-message word ("unknown agent: %s", "expected agent__tool"), but the actual value is the MCP server name (the prefix in `{server}__{tool}`).
3. `cmd/gridctl/root.go`'s `init()` block lists 16 commands in a single `rootCmd.AddCommand(...)` block, but six other commands (`reload`, `telemetry`, `traces`, `upgrade`, `export`, `version`) self-register via their own `init()` functions. Both patterns work; the inconsistency means `root.go` is no longer the canonical index of the CLI surface.

Expected behavior: After the agent removal, the gateway's HTTP surface, CORS allowlist, router code, and CLI registration should all read as if agents never existed. Actual behavior: each carries vestigial agent terminology that misleads anyone reading the code.

How discovered: Code review by the user after PR #682 cleaned up the docs surface.

## Root Cause

### Defect Locations

**Finding 1 — `/api/agents/{name}/logs`**
- Route registration: `internal/api/api.go:221`
- Handler: `internal/api/api.go:612-642` (`handleAgentLogs`)
- Backend tests (5 functions): `internal/api/api_test.go` (`TestHandleAgentLogs_NoBuffer`, `_FiltersByServer`, `_EmptyWhenNoMatch`, `_LinesParam`, `_MethodNotAllowed`)
- Frontend caller: `web/src/lib/api.ts:138` (`fetchAgentLogs`)
- Frontend usage: `web/src/pages/DetachedLogsPage.tsx:21, 152`; `web/src/components/log/LogsTab.tsx:21, 67`; `web/src/components/ui/LogViewer.tsx:4, 24`; `web/src/__tests__/LogViewer.test.tsx` (16 references across 9 test cases)

**Finding 1b — dead frontend functions**
- `web/src/lib/api.ts:168-181` (`restartAgent`)
- `web/src/lib/api.ts:187-200` (`stopAgent`)
- Both reference non-existent server routes — the canonical restart route is `POST /api/mcp-servers/{name}/restart` at `internal/api/api.go:223`.

**Finding 2a — `X-Agent-Name` header**
- CORS allowlist: `internal/api/api.go:531` (`allowHeaders := "Content-Type, X-Agent-Name, Authorization"`)
- Test setter (conditional): `pkg/mcp/streamable_test.go:31-33`
- Stale docs: `docs/api-reference.md:1120` (CORS section)
- Production readers: **none** (verified by `rg -n 'X-Agent-Name|Header\.Get.*[Aa]gent'`)

**Finding 2b — `agentName` identifier**
- `pkg/mcp/router.go:10` (doc comment "routes tool calls to the appropriate agent")
- `pkg/mcp/router.go:18-19` (struct field comments: `// agentName -> replica set`, `// prefixedToolName -> agentName`)
- `pkg/mcp/router.go:30` (`AddClient` doc: "adds an agent client to the router")
- `pkg/mcp/router.go:193, 199, 202, 207` (`agentName` local + `unknown agent: %s` and `agent %s: %w` error messages)
- `pkg/mcp/router.go:217-219` (`PrefixTool(agentName, toolName string) string` + comment `"agent__tool"`)
- `pkg/mcp/router.go:222-229` (`ParsePrefixedTool` named-return `(agentName, toolName, err)` + error message `"expected agent__tool"`)
- `pkg/mcp/router_test.go:233, 235, 257, 259, 264, 267` (`tc.agent`, `agent` local var, `wantAgent` field)
- `pkg/mcp/gateway.go:1258-1259` (local var name in autoscaler cold-start path)

**Finding 3 — `root.go` AddCommand drift**
- Canonical list (16 commands): `cmd/gridctl/root.go:22-43`
- Self-registering files (6, not 4 as the report estimated): `cmd/gridctl/reload.go:37-39`, `cmd/gridctl/telemetry.go:91-105`, `cmd/gridctl/traces.go:59-67`, `cmd/gridctl/upgrade.go:57-63`, `cmd/gridctl/export.go:36-40`, `cmd/gridctl/version.go:17-19`

### Why It Happens

The agent removal was scoped to deleting the agent runtime packages, the agent CLI subcommands, the `/api/agent/*` and `/api/playground/*` REST surfaces, and the agent IDE workspaces. It did not sweep:

- HTTP routes whose path includes the word `agents` but whose implementation operates on MCP server names. The `/api/agents/{name}/logs` endpoint predates the multi-server router pivot (commit 0ba07ea added `PrefixTool`/`ParsePrefixedTool` on 2026-01-06, before agents were removed) and was inherited rather than renamed.
- The CORS allowlist, which is co-located with the docs section the cleanup PRs deleted; the header was advertised but inert.
- Local variable names and error messages in `pkg/mcp/router.go`, which were written when "agent" and "MCP server" were synonyms in the gridctl mental model.
- Frontend `restartAgent`/`stopAgent` functions, which target server routes the backend never exposed (only `/api/mcp-servers/{name}/restart` exists).
- The `cmd/gridctl/root.go` registration drift is unrelated to agent removal — it accumulated over time as new commands were added by different contributors using a self-registering pattern. The cleanup is opportunistic.

### Similar Instances

`AgentClient` (interface type in `pkg/mcp`) and `AddClient`/`RemoveClient` methods on `Router` retain agent terminology. These are intentionally out of scope: renaming a public interface type ripples through the router, gateway, replica set, and test surface, which is a public-API change bigger than the cleanup warrants. Flag for a future dedicated rename pass.

## Impact

### Severity Classification

**Low across all findings.** Bug class is "incorrect-by-naming and dead code residue", not functional defect. No crash, no data loss, no security issue, no regression.

### User Reach

**Runtime**: zero. Every code path behaves correctly.

**Maintainer**: high. Any contributor reading `internal/api/api.go`, `pkg/mcp/router.go`, `web/src/lib/api.ts`, or `cmd/gridctl/root.go` will be misled by the stale naming. The `restartAgent`/`stopAgent` functions are latent footguns — if a future contributor wires them up to a UI button, they will 404 in production.

### Workflow Impact

Cosmetic / consistency only. No user-facing workflow is blocked.

### Workarounds

None needed. The current code works; the cost is reader confusion, not runtime breakage.

### Urgency Signals

None. Pre-1.0 project, no external clients depend on these names. The natural time to ship this is before the next tag, riding alongside the existing agent-removal commits in the `[Unreleased]` section.

## Reproduction

### Minimum Reproduction Steps

All findings are static and reproduce on every code read:

1. `curl localhost:8080/api/agents/foo/logs` — URL says "agents", returns logs for MCP server `foo`.
2. `curl -i -X OPTIONS -H "Origin: http://localhost" -H "Access-Control-Request-Headers: X-Agent-Name" localhost:8080/api/status` — preflight returns `X-Agent-Name` in `Access-Control-Allow-Headers`.
3. `rg -n agentName pkg/mcp/router.go` — every match is a misnomer.
4. `rg -n "rootCmd\.AddCommand" cmd/gridctl/` — 7 files have the call (root.go + 6 leaves).
5. (Dead-code) Calling `restartAgent("foo")` from a hypothetical UI button → `POST /api/agents/foo/restart` → 404.

### Affected Environments

All environments. These are source-tree defects.

### Failure Mode

Reader confusion; latent 404 on dead frontend functions if they are ever called.

## Fix Assessment

### Fix Surface

- **Backend Go**: `internal/api/api.go` (route + handler + CORS), `internal/api/api_test.go` (5 test renames), `pkg/mcp/router.go` (variable + comments + error messages + named return params), `pkg/mcp/router_test.go` (test variables), `pkg/mcp/gateway.go:1258` (local var rename), `pkg/mcp/streamable_test.go:31-33` (drop header set).
- **CLI**: `cmd/gridctl/root.go` (extend init list), `cmd/gridctl/reload.go`, `cmd/gridctl/telemetry.go`, `cmd/gridctl/traces.go`, `cmd/gridctl/upgrade.go`, `cmd/gridctl/export.go`, `cmd/gridctl/version.go` (each: drop `rootCmd.AddCommand(...)` from `init()`).
- **Frontend**: `web/src/lib/api.ts` (rename `fetchAgentLogs` → `fetchServerLogs`, update URL, delete `restartAgent` + `stopAgent`), `web/src/pages/DetachedLogsPage.tsx`, `web/src/components/log/LogsTab.tsx`, `web/src/components/ui/LogViewer.tsx`, `web/src/__tests__/LogViewer.test.tsx` (update imports + call sites).
- **Docs**: `docs/api-reference.md:1120` (drop `X-Agent-Name` from CORS line).
- **Changelog**: append entries to the `[Unreleased]` section's `Changed`/`Removed`/`Breaking` subsections — see Implementation Guidance in the prompt.

### Risk Factors

- The HTTP route rename `/api/agents/{name}/logs` → `/api/mcp-servers/{name}/logs` is a breaking change for any external client. Risk is theoretical: the project is pre-1.0, no documented external consumer, and the new path matches an existing convention (`/api/mcp-servers/{name}/restart`, `/api/mcp-servers/{name}/tools`).
- Renaming `PrefixTool` / `ParsePrefixedTool` **named-return** parameters changes godoc output but does not break callers (Go return parameter names are documentation-only at the call site). The function signatures, exported names, and behavior are unchanged.
- `pkg/mcp/streamable_test.go:31-33` sets `X-Agent-Name` conditionally on a non-empty argument; dropping the header set is safe because the header was inert in production. The test continues to exercise HTTP transport correctly.

### Regression Test Outline

No new tests required. The existing test suites already cover the changed surface:

- Backend: `go test ./internal/api/... ./pkg/mcp/...` (the renamed `TestHandleAgentLogs_*` → `TestHandleMCPServerLogs_*` keep their assertions; `TestPrefixTool`/`TestParsePrefixedTool` keep their assertions with renamed table-test fields).
- Frontend: `npm test` (the renamed `LogViewer.test.tsx` mocks of `fetchServerLogs` keep their assertions; mock-call assertions like `expect(fetchAgentLogs).toHaveBeenCalledWith('my-agent', 500)` get renamed to `fetchServerLogs`).
- CLI: `go build ./...` confirms registration; an optional smoke test `gridctl --help` lists all 22 commands.

The fix is correct iff all of `go build ./...`, `go test -race ./...`, `npm run build`, `npm test`, and `golangci-lint run` pass.

## Recommendation

**Fix immediately, single bundled PR.** This is the natural follow-up to PRs #680, #681, #682, and it should ride before the next release tag is cut. The findings share a single theme (agent-removal residue), the diffs are mechanical, and bundling avoids three near-identical PR review cycles. Severity is Low but value is high: every future reader of these files is paying interest on the inconsistency.

**Explicit scope guardrails**:
- Do **not** rename the `AgentClient` interface or its methods (`AddClient`/`RemoveClient`). That is a public-API change with wider blast radius and belongs in a separate, scoped PR.
- Do **not** redesign `/api/logs` to absorb the server-filtered query. Adding a `?server=` filter to `/api/logs` would be a sensible follow-up but is out of scope here — the minimum fix is a rename of the existing dedicated route.
- Do **not** introduce a redirect / backwards-compat shim for `/api/agents/{name}/logs`. The project is pre-1.0, no external consumer is documented, and a hard rename matches the existing convention.

## References

- Commits: a691e09 (backend agent removal), d0eb70c (frontend agent removal), 3f08c51 (docs sync, PR #682).
- Related route already using the canonical pattern: `POST /api/mcp-servers/{name}/restart` at `internal/api/api.go:223`.
- CHANGELOG `[Unreleased]` section already documents the agent removal — this PR extends the `Changed`/`Removed`/`Breaking` subsections.
