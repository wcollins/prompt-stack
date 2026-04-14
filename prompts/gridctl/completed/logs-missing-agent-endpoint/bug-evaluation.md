# Bug Investigation: Logs Panel Missing Agent Endpoint

**Date**: 2026-03-30
**Project**: gridctl
**Recommendation**: Fix immediately
**Severity**: High
**Fix Complexity**: Trivial

## Summary

The Logs tab in the gridctl menu pane displays `Error: Unexpected token '<', "<!doctype "... is not valid JSON` for every non-gateway MCP server resource. The root cause is a missing backend HTTP handler: the frontend calls `GET /api/agents/{name}/logs` but no such route is registered, so the SPA fallback serves `index.html` which the frontend then fails to parse as JSON. The fix is a single new handler function and route registration (~30 lines of Go) with zero side effects on existing code.

## The Bug

**Wrong behavior**: Clicking the Logs tab for any MCP server (atlassian, github, zapier, etc.) immediately shows a red error banner: `Error: Unexpected token '<', "<!doctype "... is not valid JSON`. The log viewer shows 0/0 entries.

**Expected behavior**: The Logs tab should display recent log entries for the selected MCP server, filtered from the global log buffer.

**How discovered**: User report with screenshots showing the error on both HTTP-transport (atlassian) and STDIO-transport (github) resources.

## Root Cause

### Defect Location

- **Frontend caller**: `web/src/lib/api.ts:110` — `fetchAgentLogs()` fetches `GET /api/agents/{name}/logs`
- **Backend router**: `internal/api/api.go:174-231` — `Handler()` method; no `/api/agents/` route registered
- **SPA fallback**: `internal/api/api.go:221` — `spaHandler` catches the unmatched request and serves `index.html`

### Code Path

```
User clicks Logs tab for "atlassian"
→ LogsTab.tsx:64  fetchAgentLogs("atlassian", 500)
→ api.ts:110      fetch("/api/agents/atlassian/logs?lines=500")
→ api.go:221      spaHandler catches route — no /api/agents/ registered
→ responds with index.html (<!doctype html>...)
→ api.ts:131      response.json() — fails to parse HTML
→ LogsTab.tsx:70  setError("Unexpected token '<' ...")
```

### Why It Happens

`Handler()` in `api.go` registers routes for `/api/logs` (gateway logs), `/api/mcp-servers/` (server restart), and others, but never registers `/api/agents/`. The comment in `api.ts:102` explicitly notes these are "Agent Control Functions (require backend endpoints)", confirming the backend was never implemented.

### Similar Instances

The frontend also defines `restartAgent()` at `api.ts:138` which calls `POST /api/agents/{name}/restart`. That endpoint is also unregistered. The backend has `handleMCPServerRestart` under `/api/mcp-servers/{name}/restart`, but the `/api/agents/` path for restart is similarly missing. This investigation focuses on logs only.

## Impact

### Severity Classification

High — broken core feature. Not a crash or data loss, but the Logs tab is prominent in the UI and fails for every user who clicks it on a non-gateway node.

### User Reach

Every gridctl user who opens the Logs tab for any MCP server resource (which is the primary use case — the gateway node logs are less commonly inspected). Confirmed across HTTP and STDIO transport types.

### Workflow Impact

Logs are a critical debugging tool. When an MCP server misbehaves, the Logs tab is the first place to look. This bug blocks that entire workflow.

### Workarounds

Clicking the **Gateway** node instead of a specific MCP server node will show gateway-level logs (the `/api/logs` endpoint is functional). However, this shows all logs without per-server filtering, making it harder to debug specific server issues.

### Urgency Signals

Feature appears newly shipped; the bug is immediately visible to every user on first interaction with the feature. No evidence of active issue tracking found — this investigation is the first formal record.

## Reproduction

### Minimum Reproduction Steps

1. Launch gridctl with at least one connected MCP server
2. Click any MCP server node in the canvas (not the gateway node)
3. Click the **Logs** tab in the menu pane
4. Observe: red error `Error: Unexpected token '<', "<!doctype "... is not valid JSON`

### Affected Environments

All — HTTP transport (atlassian), STDIO transport (github), all OS platforms. The bug is in the backend route registration, independent of environment.

### Non-Affected Environments

The **Gateway** node logs work correctly (uses `/api/logs` which IS registered).

### Failure Mode

System remains functional — no crash, no data corruption. The logs panel simply shows an error. The gateway and MCP servers continue operating normally.

## Fix Assessment

### Fix Surface

Single file: `internal/api/api.go`

1. Add route registration: `mux.HandleFunc("/api/agents/", s.handleAgentAction)`
2. Add `handleAgentAction` dispatcher that parses `{name}` and `{action}` from the path
3. Add `handleAgentLogs` that filters `s.logBuffer` entries by `entry.Attrs["server"] == name`

### Risk Factors

None — completely new endpoint. No existing handlers modified. No existing data structures changed.

### Regression Test Outline

In `internal/api/api_test.go`, add:
- `TestHandleAgentLogs_NoBuffer` — nil logBuffer returns empty array
- `TestHandleAgentLogs_WithEntries` — buffer with mixed-server entries returns only matching server's entries
- `TestHandleAgentLogs_LinesParam` — `?lines=N` parameter is respected
- `TestHandleAgentLogs_UnknownServer` — non-existent server name returns empty array (not 404)
- `TestHandleAgentLogs_MethodNotAllowed` — POST returns 405

## Recommendation

Fix immediately. The fix is ~30 lines of Go, zero risk, and resolves a prominent broken feature that every user encounters. Follow the exact pattern of `handleGatewayLogs` — filter `s.logBuffer.GetRecent()` by `entry.Attrs["server"] == name`.

## References

- Root cause confirmed in: `internal/api/api.go:175-231` (route registration), `internal/api/api.go:512-555` (reference implementation: handleGatewayLogs)
- Frontend caller: `web/src/lib/api.ts:104-132`
- Component trigger: `web/src/components/log/LogsTab.tsx:51-74`
- Log entry model: `pkg/logging/buffer.go:12-20` (BufferedEntry)
- Per-server log tagging: `pkg/mcp/gateway.go:465` (`g.logger.With("server", cfg.Name)`)
