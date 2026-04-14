# Bug Fix: Logs Panel Missing Agent Endpoint

## Context

gridctl is a Go + React desktop application that manages MCP (Model Context Protocol) servers. The backend is a Go HTTP server (`internal/api/api.go`) that exposes a JSON REST API consumed by the React frontend (`web/src/`). The app runs as a daemon and serves both the API and the SPA from the same HTTP server.

The Go backend uses `net/http` with a `ServeMux`. Unmatched routes fall through to a SPA handler that returns `index.html`. The frontend is a Vite/React app using TypeScript.

## Investigation Context

- Root cause confirmed: `internal/api/api.go:175-231` registers all API routes; `/api/agents/` is completely absent
- Risk: None — isolated new endpoint, zero changes to existing code paths
- Reproduction: Deterministic, affects all users on all platforms the moment they click the Logs tab
- Full investigation: `prompt-stack/prompts/gridctl/logs-missing-agent-endpoint/bug-evaluation.md`

## Bug Description

When a user selects any MCP server node (e.g., atlassian, github, zapier) and clicks the **Logs** tab in the menu pane, the panel displays:

```
Error: Unexpected token '<', "<!doctype "... is not valid JSON
```

0 log entries are shown. The Gateway node's Logs tab works fine.

**Expected**: The Logs tab should display recent log entries for the selected MCP server, filtered from the global log buffer.

**Affected users**: All gridctl users — every non-gateway node triggers this error.

## Root Cause

The frontend function `fetchAgentLogs()` in `web/src/lib/api.ts:110` calls:
```
GET /api/agents/{name}/logs?lines={lines}
```

The backend `Handler()` method in `internal/api/api.go:175-231` registers routes for `/api/logs`, `/api/mcp-servers/`, and others — but **never registers `/api/agents/`**.

The SPA fallback handler (`api.go:221`) catches the unmatched request and returns `index.html`. The frontend then calls `response.json()` on that HTML, which throws `"Unexpected token '<'"`.

Per-server logs ARE already in the global log buffer — each MCP server client logger is created with `g.logger.With("server", cfg.Name)` (`pkg/mcp/gateway.go:465`), so buffer entries for server "atlassian" will have `Attrs["server"] == "atlassian"`.

## Fix Requirements

### Required Changes

All changes are in `internal/api/api.go` only.

1. Register a new route in `Handler()`:
   ```go
   mux.HandleFunc("/api/agents/", s.handleAgentAction)
   ```
   Add this alongside the existing `/api/mcp-servers/` route registration (around line 186).

2. Add `handleAgentAction` dispatcher:
   - Parse `{name}` and `{action}` from the URL path (same pattern as `handleMCPServerAction` at line 472)
   - For action `"logs"`: call `s.handleAgentLogs(w, r, name)`
   - Default: `http.Error(w, "Unknown action: "+action, http.StatusBadRequest)`

3. Add `handleAgentLogs` handler:
   - Method guard: GET only (405 otherwise)
   - Nil buffer guard: if `s.logBuffer == nil`, write empty JSON array and return
   - Parse `lines` query param (same as `handleGatewayLogs`)
   - Call `s.logBuffer.GetRecent(lines)` then filter where `entry.Attrs["server"] == name`
   - Return filtered slice via `writeJSON` (empty slice if no matches — not 404)

### Constraints

- Do NOT modify any existing handler
- Do NOT return 404 for an unknown server name — return an empty array (the server may simply have no logs yet)
- Follow the exact same nil-guard and lines-param pattern as `handleGatewayLogs`
- Return `[]logging.BufferedEntry` (same type as gateway logs)

### Out of Scope

- The `restartAgent()` frontend function (`api.ts:138`) which calls `/api/agents/{name}/restart` — also unregistered, but separate issue
- Per-server log buffer isolation (currently all logs share one buffer)
- Log level filtering for agent logs (can be added later following `handleGatewayLogs` pattern)

## Implementation Guidance

### Key Files to Read First

1. `internal/api/api.go` — entire file; understand the full route table and existing handler patterns
2. `pkg/logging/buffer.go:12-20` — `BufferedEntry` struct (what the filter operates on)
3. `pkg/mcp/gateway.go:463-466` — confirms per-server logs tagged with `attrs["server"]`

### Files to Modify

**`internal/api/api.go`** — three changes:

1. In `Handler()` (around line 186), add:
   ```go
   mux.HandleFunc("/api/agents/", s.handleAgentAction)
   ```

2. After `handleMCPServerAction` (around line 491), add:
   ```go
   // handleAgentAction routes agent control requests.
   // URL pattern: /api/agents/{name}/{action}
   func (s *Server) handleAgentAction(w http.ResponseWriter, r *http.Request) {
       path := strings.TrimPrefix(r.URL.Path, "/api/agents/")
       parts := strings.Split(path, "/")
       if len(parts) < 2 {
           http.Error(w, "Invalid path: expected /api/agents/{name}/{action}", http.StatusBadRequest)
           return
       }
       name := parts[0]
       action := parts[1]
       switch action {
       case "logs":
           s.handleAgentLogs(w, r, name)
       default:
           http.Error(w, "Unknown action: "+action, http.StatusBadRequest)
       }
   }
   ```

3. After `handleAgentAction`, add:
   ```go
   // handleAgentLogs returns structured logs from the global buffer filtered by server name.
   // GET /api/agents/{name}/logs?lines=100
   func (s *Server) handleAgentLogs(w http.ResponseWriter, r *http.Request, name string) {
       if r.Method != http.MethodGet {
           http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
           return
       }
       if s.logBuffer == nil {
           writeJSON(w, []logging.BufferedEntry{})
           return
       }
       lines := 100
       if linesParam := r.URL.Query().Get("lines"); linesParam != "" {
           if n, err := strconv.Atoi(linesParam); err == nil && n > 0 {
               lines = n
           }
       }
       all := s.logBuffer.GetRecent(lines * 10) // fetch extra to account for filtering
       filtered := make([]logging.BufferedEntry, 0)
       for _, entry := range all {
           if server, ok := entry.Attrs["server"]; ok && server == name {
               filtered = append(filtered, entry)
           }
       }
       if len(filtered) > lines {
           filtered = filtered[len(filtered)-lines:]
       }
       writeJSON(w, filtered)
   }
   ```

### Reusable Components

- `writeJSON(w, v)` — already used throughout `api.go` for JSON responses
- `strconv.Atoi` — already imported
- `strings.TrimPrefix` / `strings.Split` — already used in `handleMCPServerAction` (exact same pattern)
- `logging.BufferedEntry` — already imported

### Conventions to Follow

- Handler doc comment format: `// handleX does Y.\n// METHOD /api/path`
- Method guard at top of handler (GET-only handlers use `if r.Method != http.MethodGet`)
- Nil guard for optional resources (logBuffer, metricsAccumulator)
- Return empty slice (not nil) for zero results: `writeJSON(w, []logging.BufferedEntry{})`
- No exported handler methods — all are `func (s *Server) handleX(...)` unexported

## Regression Test

### Test Outline

In `internal/api/api_test.go`, add a `// --- Agent logs endpoint tests ---` section following the `TestHandleGatewayLogs_*` block:

```
TestHandleAgentLogs_NoBuffer
  - nil logBuffer → 200, empty JSON array

TestHandleAgentLogs_FiltersByServer
  - logBuffer has entries for "atlassian" and "github"
  - GET /api/agents/atlassian/logs
  - response contains only atlassian entries

TestHandleAgentLogs_EmptyWhenNoMatch
  - logBuffer has entries for "github" only
  - GET /api/agents/atlassian/logs
  - response is empty array (not 404)

TestHandleAgentLogs_LinesParam
  - logBuffer has 20 entries for "atlassian"
  - GET /api/agents/atlassian/logs?lines=5
  - response has ≤ 5 entries

TestHandleAgentLogs_MethodNotAllowed
  - POST /api/agents/atlassian/logs → 405
```

### Existing Test Patterns

Tests use `newTestServer(t)` or `newTestServerWithLogBuffer(t, size)` helpers. Assertions check `rec.Code` and decode `rec.Body` into `[]logging.BufferedEntry`. See `TestHandleGatewayLogs_WithEntries` at `api_test.go:441` for exact pattern to follow.

## Potential Pitfalls

1. **Filter over-fetch**: `s.logBuffer.GetRecent(lines)` returns the N most recent entries from ALL servers. Filter on top means you may return fewer than `lines` entries for a specific server. Fetch a multiple (e.g., `lines * 10`) before filtering, then trim to `lines`. This is a heuristic — it's acceptable for the initial fix.

2. **Nil Attrs map**: `entry.Attrs` can be nil if the log entry has no extra attributes. The expression `entry.Attrs["server"]` on a nil map returns the zero value without panicking in Go — this is safe.

3. **URL path parsing**: `/api/agents/` is registered with a trailing slash so `net/http` routes all `/api/agents/*` paths to `handleAgentAction`. The `strings.TrimPrefix` + `strings.Split` approach is identical to `handleMCPServerAction` at line 475 — use the same pattern exactly.

4. **Don't return 404 for unknown server**: The frontend has no special handling for 404; it would just show the error message. Return an empty array instead — consistent with how gateway logs behaves when the buffer is empty.

## Acceptance Criteria

1. Clicking the Logs tab for any MCP server node shows log entries (or an empty state if none exist) — no JSON parse error
2. Log entries shown are filtered to those with `attrs.server == selectedServerName`
3. The `?lines=N` parameter limits the number of entries returned
4. A nil log buffer returns a 200 with an empty array (no panic)
5. POST to `/api/agents/{name}/logs` returns 405
6. All existing tests continue to pass
7. New regression tests for the above cases pass

## References

- `internal/api/api.go:512-555` — `handleGatewayLogs` reference implementation
- `internal/api/api.go:472-491` — `handleMCPServerAction` URL parsing reference
- `internal/api/api_test.go:417-639` — existing gateway log test patterns
- `pkg/mcp/gateway.go:465` — confirms per-server log tagging: `g.logger.With("server", cfg.Name)`
- `pkg/logging/buffer.go:12-20` — `BufferedEntry` struct definition
