# Feature Evaluation: stdlib ServeMux Routing

**Date**: 2026-04-07
**Project**: gridctl
**Recommendation**: Build
**Value**: High
**Effort**: Medium

## Summary

Replace 24 instances of manual `strings.TrimPrefix` + `strings.SplitN` path parsing across 8 API handlers with Go 1.22's enhanced `net/http.ServeMux` named parameters and `r.PathValue()`. The project is already on Go 1.25.8, no new dependencies are required, and the existing 2,771-line test suite provides a strong regression safety net. This is a pure maintainability refactor that eliminates a class of latent routing bugs with no user-facing behavior change.

## The Idea

gridctl's `internal/api/` HTTP layer uses `net/http.ServeMux` for route registration but dispatches all parameterized routes through catch-all prefix patterns (`/api/vault/`, `/api/pins/`, etc.). Path parameters (server name, vault key, skill name, etc.) are extracted manually inside each handler using `strings.TrimPrefix` + `strings.SplitN`, index-based segment access, and multi-way switch dispatch. Go 1.22 made this pattern obsolete by adding `{name}` wildcards and `r.PathValue()` to stdlib `ServeMux`. This feature replaces the manual parsing with idiomatic Go, moving routing logic from inside handler bodies into the `Handler()` registration method where it belongs.

**Problem**: Manual path parsing is brittle — off-by-one index errors, route precedence bugs from switch reordering, and empty-string confusion silently misroute requests. Adding new sub-routes requires coordinated changes in 3+ locations per endpoint.

**Beneficiary**: Contributors and maintainers of gridctl's API layer.

## Project Context

### Current State

gridctl is a production-grade MCP (Model Context Protocol) gateway that aggregates tools from multiple MCP servers into a single unified endpoint. The `internal/api/` package is the sole HTTP layer — all routes flow through `api.Server.Handler()`. The project is on **Go 1.25.8** (well above the 1.22 requirement). No third-party router is in use; everything is stdlib.

Manual path parsing is present in 8 handler functions across 9 files:

| Handler | Route pattern | Parsing technique |
|---------|--------------|-------------------|
| `handleAgentAction` | `/api/agents/{name}/{action}` | `TrimPrefix` + `SplitN` |
| `handleMCPServerAction` | `/api/mcp-servers/{name}/{action}` | `TrimPrefix` + `SplitN` |
| `handleTraces` | `/api/traces/{traceId}` | `TrimPrefix` presence check |
| `handlePins` | `/api/pins/{server}[/{action}]` | `TrimPrefix` + `SplitN(3)` |
| `handleVault` | `/api/vault/{key}`, `/api/vault/sets/{name}`, `/api/vault/{key}/set` | `TrimPrefix` + `SplitN(3)` + exclusion list |
| `handleStack` | `/api/stack/{action}` | `TrimPrefix` + switch on literal |
| `handleSkills` | `/api/skills/sources/{name}[/{action}]` | `TrimPrefix` + nested `SplitN` |
| `handleRegistry` | `/api/registry/skills/{name}[/{action}]`, `/api/registry/skills/{name}/files/{path}` | `TrimPrefix` + nested `HasPrefix` + `SplitN` |

### Integration Surface

- `internal/api/api.go` — `Handler()` mux registration; `handleAgentAction`, `handleMCPServerAction`
- `internal/api/vault.go` — `handleVault` (62-line routing dispatcher)
- `internal/api/pins.go` — `handlePins`
- `internal/api/traces.go` — `handleTraces`
- `internal/api/stack.go` — `handleStack`
- `internal/api/skills.go` — `handleSkills`
- `internal/api/registry.go` — `handleRegistry`, `handleRegistrySkillAction`
- `internal/api/wizard.go` — `handleWizard`

### Reusable Components

- `writeJSON`, `writeJSONError` helper functions (already present)
- All existing sub-handlers (e.g., `handleVaultList`, `handleVaultCreate`, `handleGetServerPins`) remain unchanged — only the dispatch wiring changes
- Existing `authMiddleware` and `corsMiddleware` wrap the mux and are unaffected

## Market Analysis

### Competitive Landscape

Go 1.22 (February 2024) added method-qualified patterns (`GET /path`) and named wildcards (`{name}`, `{name...}`) to `net/http.ServeMux`, along with `r.PathValue()` for extraction. The Go team's own routing enhancements blog post uses exactly the manual-parsing pattern gridctl employs as the motivating example of what to replace.

gorilla/mux — the most common alternative — was archived in early 2023. chi remains active and is the community-preferred third-party option, but its key value props (per-group middleware, `r.Mount`, route-scoped middleware chains) are not currently needed by gridctl's flat auth/CORS middleware model.

### Market Positioning

**Table-stakes for maintainability.** For an internal API consumed only by the project's own frontend and CLI, this is not a competitive differentiator — but the manual parsing pattern is already considered obsolete Go practice post-1.22. Leaving it in place accrues maintenance debt with each new route added.

### Ecosystem Support

- `r.PathValue(name string) string` — stdlib, Go 1.22+
- `r.SetPathValue(name, value string)` — stdlib, Go 1.22+; lets third-party routers populate standard request params
- Wildcard syntax: `{name}` (one segment), `{name...}` (remainder), `{$}` (exact trailing-slash anchor)
- Method routing: `"GET /api/foo"` — stdlib, Go 1.22+; auto-handles HEAD, returns 405 with `Allow` header for wrong methods
- **Zero new dependencies required**

### Demand Signals

Multiple high-signal Go community references (Alex Edwards, Eli Bendersky, Ben Hoyt) cite Go 1.22 ServeMux as the right replacement for manual path parsing. JetBrains Go ecosystem data shows gorilla/mux adoption declining from 36% → 17% since 2020. The pattern is actively recommended in the official Go blog.

## User Experience

### Interaction Model

This is a pure internal refactor — no end-user-visible change. The HTTP API surface (URLs, methods, response shapes) is identical before and after. The only change is how the server internally routes requests to handler functions.

### Workflow Impact

**For contributors:**
- **Before**: Adding a new sub-route requires: (1) understanding the catch-all registration in `api.go`, (2) finding the routing dispatch in the handler file, (3) adding a new case to the switch, (4) writing the handler. Off-by-one errors in step 2 silently misroute.
- **After**: Adding a new sub-route requires: (1) adding one `HandleFunc` line in `Handler()`, (2) writing the handler. The route is self-documenting.

### UX Recommendations

- Keep `Handler()` as the single authoritative route map — do not split registration across files
- Use method-prefixed patterns everywhere (`"GET /api/..."`) to get automatic 405 handling at the mux level, eliminating per-handler `r.Method` guards
- For `handleRegistry`'s file path (`/api/registry/skills/{name}/files/{path...}`), use the `{path...}` remainder wildcard — one `strings.SplitN` on the remainder is acceptable and documented clearly at the registration site

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Significant | 24 manual parsing instances; real latent bug risk on every route change |
| User impact | Narrow+Deep | Only contributors affected, but they feel it on every API change |
| Strategic alignment | Core mission | Internal code quality; no feature scope |
| Market positioning | Catch up | Standard Go practice since Feb 2024 |

### Cost Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Moderate | 8 handlers across 9 files; vault and registry are most complex |
| Effort estimate | Medium | 16–24 eng hours; safely done in 3–4 incremental PRs |
| Risk level | Low | 2,771 lines of tests; 64% coverage floor; CI gated by golangci-lint + race detector |
| Maintenance burden | Minimal | Code is simpler post-refactor; ongoing cost decreases |

## Recommendation

**Build.** The value is high (eliminates a bug class, dramatically improves discoverability), the risk is low (comprehensive tests, no behavior change, gradual migration possible), and the effort is medium but well-scoped. The Go version prerequisite is already satisfied.

The one nuance: `handleRegistry`'s file path nesting (`/api/registry/skills/{name}/files/{path...}`) requires a remainder wildcard plus one `strings.SplitN` to separate the skill name from the file path. This is a known limitation of Go 1.22 ServeMux (wildcards must be full path segments, and a wildcard-after-wildcard pattern requires the `{path...}` form). The correct approach is to register `"/api/registry/skills/{name}/files/{path...}"` and call `r.PathValue("path")` for the file path — no segment-index arithmetic needed.

Recommended build order: stack → traces → wizard → pins → agents/mcp-servers → skills → vault → registry.

## References

- [Routing Enhancements for Go 1.22 — go.dev/blog](https://go.dev/blog/routing-enhancements)
- [Better HTTP server routing in Go 1.22 — Eli Bendersky](https://eli.thegreenplace.net/2023/better-http-server-routing-in-go-122/)
- [Which Go Router Should I Use? — Alex Edwards](https://www.alexedwards.net/blog/which-go-router-should-i-use)
- [Go's ServeMux Enhancements — Ben Hoyt](https://benhoyt.com/writings/go-servemux-enhancements/)
- [URL Path Parameters in Go 1.22 — willem.dev](https://www.willem.dev/articles/url-path-parameters-in-routes/)
- [go-chi/chi — GitHub](https://github.com/go-chi/chi)
