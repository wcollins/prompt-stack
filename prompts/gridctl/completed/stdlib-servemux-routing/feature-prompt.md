# Feature Implementation: stdlib ServeMux Routing

## Context

gridctl is a production-grade MCP (Model Context Protocol) gateway written in Go. It aggregates tools from multiple MCP servers into a single unified endpoint and exposes a REST API consumed by its own embedded web frontend and CLI. The project is on **Go 1.25.8** and uses only stdlib for HTTP routing (`net/http.ServeMux`). The API layer lives entirely in `internal/api/`.

Tech stack: Go 1.25.8, `net/http`, React frontend (separate build), SQLite-backed stores.

## Evaluation Context

- **Root problem**: Manual `strings.TrimPrefix` + `strings.SplitN` path parsing is the textbook use case Go 1.22 enhanced ServeMux was designed to replace. 24 parsing instances across 8 handlers.
- **Go 1.22 is available**: Project is on 1.25.8 — no version work needed.
- **Zero new dependencies**: `r.PathValue()` is stdlib. This is explicitly required (project policy: no new dependencies for internal routing).
- **Registry file path caveat**: Go 1.22 wildcards must be full path segments. Use the `{path...}` remainder wildcard for `/api/registry/skills/{name}/files/{path...}` — this leaves one `r.PathValue("path")` call but eliminates all segment-index arithmetic.
- **Tests don't need to change**: Existing test URLs and handler signatures are unchanged. The refactor only moves extraction from manual parsing to `r.PathValue()` inside handlers.
- Full evaluation: `prompts/gridctl/stdlib-servemux-routing/feature-evaluation.md`

## Feature Description

Replace all manual URL path parameter extraction in `internal/api/` with Go 1.22 `net/http.ServeMux` named wildcards and `r.PathValue()`. This involves:

1. Changing catch-all prefix registrations (`/api/vault/`) to explicit named-parameter patterns (`GET /api/vault/{key}`)
2. Replacing routing dispatcher functions (e.g., `handleVault`'s 62-line switch) with direct handler registrations in `Handler()`
3. Replacing `strings.TrimPrefix` + `strings.SplitN` + index access inside handlers with `r.PathValue("name")`
4. Adding HTTP method prefixes to all route patterns (`"GET /api/..."`) to get automatic 405 handling at the mux level

No behavior change. No new dependencies. No test rewrites.

## Requirements

### Functional Requirements

1. All routes currently handled by manual parsing must be explicitly registered in `Handler()` with named-parameter patterns
2. All `r.URL.Path` manual parsing (`strings.TrimPrefix`, `strings.SplitN`, segment index access) must be removed from handler bodies
3. Path parameters must be extracted exclusively via `r.PathValue("name")`
4. All route registrations must include the HTTP method prefix (`"GET /api/..."`, `"POST /api/..."`, etc.)
5. `handleVault`'s routing dispatcher function must be replaced by explicit per-route registrations; `handleVaultStatus`, `handleVaultUnlock`, `handleVaultLock` must be registered as separate explicit routes so the lock-state guard lives inside each handler, not in a shared dispatcher
6. `handleStack`'s 8-way path+method switch must be replaced by 8 individual `HandleFunc` registrations pointing directly to the sub-handlers
7. `handleRegistry`'s file path routes must use the `{path...}` remainder wildcard: `"GET /api/registry/skills/{name}/files/{path...}"` — `r.PathValue("path")` returns the remainder after `files/`
8. The existing middleware chain (`authMiddleware` wrapping `corsMiddleware`) must be preserved unchanged
9. All existing tests must pass without modification

### Non-Functional Requirements

- No new imports beyond what is already in `internal/api/`
- `Handler()` in `api.go` must remain the single source of truth for all route registrations — do not split registrations across files
- After refactor, golangci-lint must pass clean (run `golangci-lint run ./internal/api/...`)
- Tests must pass with race detector: `go test -race ./internal/api/...`

### Out of Scope

- Changing any handler's business logic or response shapes
- Adding new API endpoints
- Changing test files (they should pass as-is)
- Adopting a third-party router (chi, gorilla/mux, etc.)
- Changing middleware behavior or the auth/CORS model

## Architecture Guidance

### Recommended Approach

Go 1.22 ServeMux pattern matching rules:
- `{name}` matches exactly one path segment (no slashes)
- `{name...}` matches all remaining path segments including slashes — must be the last element
- `{$}` anchors a trailing-slash pattern to the exact path
- Literal segments take precedence over wildcard segments — so `GET /api/vault/status` will correctly match before `GET /api/vault/{key}` with no ordering concerns
- Method prefix (`"GET "`, `"POST "`, etc.) causes the mux to return `405 Method Not Allowed` automatically for wrong methods; registering `GET` also handles `HEAD`

**Handler() migration pattern:**

```go
// BEFORE (catch-all):
mux.HandleFunc("/api/vault/", s.handleVault)
mux.HandleFunc("/api/vault", s.handleVault)

// AFTER (explicit named-parameter routes):
mux.HandleFunc("GET /api/vault", s.handleVaultList)
mux.HandleFunc("POST /api/vault", s.handleVaultCreate)
mux.HandleFunc("POST /api/vault/import", s.handleVaultImport)
mux.HandleFunc("GET /api/vault/status", s.handleVaultStatus)
mux.HandleFunc("POST /api/vault/unlock", s.handleVaultUnlock)
mux.HandleFunc("POST /api/vault/lock", s.handleVaultLock)
mux.HandleFunc("GET /api/vault/sets", s.handleVaultSetsList)
mux.HandleFunc("POST /api/vault/sets", s.handleVaultSetsCreate)
mux.HandleFunc("DELETE /api/vault/sets/{name}", s.handleVaultSetsDelete)
mux.HandleFunc("GET /api/vault/{key}", s.handleVaultKeyGet)
mux.HandleFunc("PUT /api/vault/{key}", s.handleVaultKeyPut)
mux.HandleFunc("DELETE /api/vault/{key}", s.handleVaultKeyDelete)
mux.HandleFunc("PUT /api/vault/{key}/set", s.handleVaultAssignSet)
```

**PathValue extraction pattern:**

```go
// BEFORE:
path := strings.TrimPrefix(r.URL.Path, "/api/vault")
path = strings.TrimPrefix(path, "/")
segments := strings.SplitN(path, "/", 3)
key := segments[0]

// AFTER:
key := r.PathValue("key")  // always non-empty when route matched
```

**Registry file path pattern:**

```go
// In Handler():
mux.HandleFunc("GET /api/registry/skills/{name}/files/{path...}", s.handleRegistrySkillFileGet)
mux.HandleFunc("PUT /api/registry/skills/{name}/files/{path...}", s.handleRegistrySkillFilePut)
mux.HandleFunc("DELETE /api/registry/skills/{name}/files/{path...}", s.handleRegistrySkillFileDelete)
mux.HandleFunc("GET /api/registry/skills/{name}/files", s.handleRegistrySkillFileList)

// In handler:
func (s *Server) handleRegistrySkillFileGet(w http.ResponseWriter, r *http.Request) {
    name := r.PathValue("name")
    filePath := r.PathValue("path")  // e.g., "config/settings.yaml"
    // ...
}
```

### Key Files to Understand

- `internal/api/api.go` — `Handler()` method (lines ~182–240): all mux registrations live here; also contains `handleAgentAction` and `handleMCPServerAction` inline
- `internal/api/vault.go` — most complex dispatcher (lines 18–80): `handleVault` routes to sub-handlers based on parsed segments
- `internal/api/registry.go` — second most complex: `handleRegistry` → `handleRegistrySkillAction` two-level dispatch
- `internal/api/pins.go` — medium complexity: `handlePins` with optional second segment
- `internal/api/skills.go` — `handleSkills` with nested source routing
- `internal/api/stack.go` — `handleStack` switch on literal action names (simplest to convert)
- `internal/api/traces.go` — `handleTraces` with optional traceId (simplest to convert)
- `internal/api/wizard.go` — `handleWizard` with draft ID (simplest to convert)
- `internal/api/api_test.go` — 1,371 lines of integration tests; do not modify
- `internal/api/vault_test.go` — vault-specific tests; do not modify

### Integration Points

The only file that needs new route registrations is `internal/api/api.go` (`Handler()` method). Handler files (`vault.go`, `pins.go`, etc.) lose their routing dispatcher logic and gain `r.PathValue()` calls.

When removing a dispatcher function (e.g., `handleVault`), check if any test file calls it directly. If so, the test will need to call the specific sub-handler instead — but based on the evaluation, tests call handlers via `httptest` with full URLs, so the test path goes through the mux and will continue to work.

### Reusable Components

- `writeJSON(w, v)` — already present, use for all JSON responses
- `writeJSONError(w, msg, status)` — already present, use for all error responses
- All existing sub-handlers (e.g., `handleVaultList`, `handleVaultCreate`, `handleGetServerPins`) keep their signatures and bodies — they just get registered directly instead of being called from a dispatcher

## UX Specification

This feature has no end-user-visible UX. The HTTP API surface is identical before and after. The developer UX improvement is:

- **Discovery**: Opening `api.go` → `Handler()` shows every route the server handles, with method and path, in one place
- **Adding routes**: One `HandleFunc` line in `Handler()` + one handler function; no dispatcher modification needed
- **Debugging**: A 404 or 405 from the mux tells you exactly which pattern failed to match; no silent fallthrough into a default switch case

## Implementation Notes

### Conventions to Follow

- All commits: `refactor: ...` type prefix per project convention
- Handler function names: keep existing names for sub-handlers; only remove dispatcher functions
- Method guards inside handlers: if the route registration already has a method prefix, remove the redundant `if r.Method != http.MethodGet { ... }` guard from the handler body — the mux handles it
- Do not add comments to unchanged handler bodies

### Potential Pitfalls

1. **Literal vs wildcard precedence**: Go 1.22 ServeMux resolves ambiguity in favor of the more specific pattern — literals beat wildcards. `GET /api/vault/status` will always match before `GET /api/vault/{key}`. No manual ordering required.
2. **Conflicting patterns**: If two patterns could both match the same request (e.g., two different wildcards at the same position), the mux panics at startup. Test with `go test ./internal/api/...` to catch this immediately.
3. **Trailing slash behavior**: The old catch-all `mux.HandleFunc("/api/vault/", ...)` matched anything under that prefix. The new explicit routes do not. Any URL not matching an explicit pattern will 404. This is the correct behavior — verify all routes are covered.
4. **Vault lock guard**: `handleVault` currently gates most operations on `s.vaultStore.IsLocked()` in the dispatcher. After removing the dispatcher, each sub-handler that requires an unlocked vault must include its own lock guard. `handleVaultStatus`, `handleVaultUnlock`, and `handleVaultLock` are exceptions — they work regardless of lock state.
5. **Registry `handleRegistrySkillAction`**: This function receives a `subpath` string argument. After refactoring, it will no longer be called with a subpath — the mux delivers named parameters directly. You will likely split it into individual handlers per action, or keep it as a shared handler that uses `r.PathValue("name")` and a switch on the action name from a separate `{action}` parameter.
6. **`{path...}` and trailing slashes**: The remainder wildcard `{path...}` matches the empty string too. Guard against empty file paths where the API doesn't intend to list files via a wildcard route.

### Suggested Build Order

Build in this order — each step is independently testable:

1. **`handleStack`** (stack.go) — 8 literal action routes, no parameters. Simplest conversion.
2. **`handleTraces`** (traces.go) — single optional `{traceId}` parameter.
3. **`handleWizard`** (wizard.go) — single `{id}` parameter.
4. **`handlePins`** (pins.go) — `{server}` with optional `/approve` action.
5. **`handleAgentAction` + `handleMCPServerAction`** (api.go) — `{name}/{action}` two-segment pattern.
6. **`handleSkills`** (skills.go) — nested source routing with optional action.
7. **`handleVault`** (vault.go) — most complex dispatcher; move lock guard to each sub-handler.
8. **`handleRegistry`** (registry.go) — use `{path...}` for file routes; split `handleRegistrySkillAction` by action.

Run `go test -race ./internal/api/...` after each step.

## Acceptance Criteria

1. All `strings.TrimPrefix` and `strings.SplitN` calls used for URL path parsing are removed from handler bodies in `internal/api/`
2. All path parameters are extracted via `r.PathValue()` only
3. All route registrations in `Handler()` include an HTTP method prefix
4. `Handler()` is the single source of truth for all routes — no routing dispatch logic exists in handler files
5. `go test -race ./internal/api/...` passes with no failures
6. Coverage does not drop below the project's 64% floor (`scripts/check-coverage.sh`)
7. `golangci-lint run ./internal/api/...` passes clean
8. The HTTP API surface is unchanged — all existing URLs, methods, and response shapes work identically

## References

- [Routing Enhancements for Go 1.22 — go.dev/blog](https://go.dev/blog/routing-enhancements)
- [Better HTTP server routing in Go 1.22 — Eli Bendersky](https://eli.thegreenplace.net/2023/better-http-server-routing-in-go-122/)
- [Which Go Router Should I Use? — Alex Edwards](https://www.alexedwards.net/blog/which-go-router-should-i-use)
- [URL Path Parameters in Go 1.22 — willem.dev](https://www.willem.dev/articles/url-path-parameters-in-routes/)
- [net/http.Request.PathValue — pkg.go.dev](https://pkg.go.dev/net/http#Request.PathValue)
- Full evaluation: `prompts/gridctl/stdlib-servemux-routing/feature-evaluation.md`
