# Feature Implementation: Stack Library and Wizard-First Onboarding

## Context

gridctl is a Go + React tool for building and running MCP (Model Context Protocol) server environments. Backend: Go HTTP API in `internal/api/`, controller in `pkg/controller/`, reload in `pkg/reload/`. Frontend: Vite/React/TypeScript in `web/src/`.

**Data model**: `Stack` (parent) contains `MCPServers []MCPServer` and `Resources []Resource`. There is no standalone MCPServer file — servers always live inside a Stack.

**Key existing infrastructure**:
- `~/.gridctl/` base dir with state/, vault/, logs/, pins/, cache/ (`pkg/state/state.go:23-67`)
- `pkg/reload/reload.go` — diff-based hot reload handler; `Reload()` reads stack from disk, diffs against `currentCfg`, applies adds/removes to running gateway
- `pkg/reload/watcher.go` — fsnotify watcher on stack file, triggers `Reload()` on write
- `internal/api/wizard.go` — wizard draft API already works without a stack file
- `web/src/stores/useStackStore.ts` — `connectionStatus: 'disconnected'|'connected'|'error'`

## Evaluation Context

- gridctl currently requires `cobra.ExactArgs(1)` on `apply` — a stack file path is mandatory to start. This creates a bootstrap paradox: the web UI wizard is the best tool for creating a stack, but you need a stack to access the UI.
- The Stack wizard's Deploy button silently returns HTTP 400 (`handleStackAppend` has no `case "stack"`). Stack is download-only but the UI doesn't communicate this.
- The right fix is not "download guidance" — it's runtime stack loading so the wizard can save and load the stack without restart.
- Do NOT add a target-stack dropdown for MCP Server/Resource creation. The wizard is a live tool tied to the canvas; appending to a non-active stack breaks the feedback loop.
- Full evaluation: `prompts/gridctl/stack-library-and-wizard-onboarding/feature-evaluation.md`

## Feature Description

Four phases that together enable wizard-first onboarding:

1. **Stackless startup**: `gridctl serve` (no args) boots the API and web UI without a stack file. Empty canvas surfaces the wizard as the primary CTA.
2. **Stack library backend**: `~/.gridctl/stacks/` directory with list and save endpoints.
3. **Runtime stack loading**: New `POST /api/stack/initialize` endpoint cold-loads a stack into a running stackless daemon — no restart.
4. **Wizard save & load + UX gating**: Stack wizard saves to library and triggers initialize. MCP Server/Resource cards gate on stack state.

---

## Phase 1: Stackless Startup

### Goal
Boot the API server and web UI without requiring a stack file. The gateway starts in a minimal idle state; all wizard and vault endpoints work; stack-dependent endpoints return 503 as they do today.

### Functional Requirements

1. `gridctl serve` (or `gridctl apply` with no positional argument) starts successfully, serving the web UI and API without a stack file.
2. The existing `gridctl apply <stack.yaml>` command continues to work exactly as today — zero regression.
3. In stackless mode, endpoints that require a stack (`/api/stack/plan`, `/api/stack/append`, `/api/mcp-servers`, etc.) return `503 Service Unavailable` with message `"No stack loaded"` — same behavior as today when `s.stackFile == ""`.
4. The gateway process and Docker runtime are NOT started in stackless mode — no wasted resources. Only the HTTP API server and web UI are active.
5. `GET /api/health` returns 200 in stackless mode. `GET /api/ready` returns 503 until a stack is loaded.

### Key Files

- `cmd/gridctl/apply.go` — change `cobra.ExactArgs(1)` to `cobra.MaximumNArgs(1)`; if no arg, start server without calling `controller.Deploy()`
- `pkg/controller/controller.go` — add a `Serve()` method (or equivalent) that starts only the HTTP API server and web UI, skipping `config.LoadStack()` and `runtime.Up()`
- `internal/api/api.go` — `NewServer()` already works without a stack file; `SetStackFile()` / `SetStackName()` remain optional setters; no changes needed here

### Acceptance Criteria

1. `gridctl serve` starts without error and serves the web UI at the configured port
2. `GET /api/health` returns 200; `GET /api/ready` returns 503
3. `GET /api/wizard/drafts` returns 200 (wizard works without stack)
4. `GET /api/stack/spec` returns 503 with `"No stack loaded"`
5. `gridctl apply stack.yaml` behavior is unchanged

---

## Phase 2: Stack Library Backend

### Goal
`~/.gridctl/stacks/` as a named stack library. Three new endpoints for listing, saving, and loading stacks.

### Functional Requirements

1. **`StacksDir`** constant in `pkg/state/state.go` — `filepath.Join(BaseDir, "stacks")`. Follow the exact pattern of existing directory constants.

2. **`GET /api/stacks`** — list all `.yaml` files in `~/.gridctl/stacks/`. Response:
   ```json
   { "stacks": [{ "name": "my-stack", "path": "/Users/alice/.gridctl/stacks/my-stack.yaml" }] }
   ```
   Returns `{ "stacks": [] }` if directory doesn't exist or is empty. Never errors on missing directory.

3. **`POST /api/stacks`** — save a stack YAML to `~/.gridctl/stacks/<name>.yaml`. Request:
   ```json
   { "yaml": "<stack yaml>", "name": "my-stack" }
   ```
   - Validates `name` is alphanumeric + hyphens/underscores only (prevent path traversal)
   - Parses YAML into `config.Stack` to validate before writing (return 400 if invalid)
   - Creates `~/.gridctl/stacks/` if it doesn't exist
   - Overwrites if file exists
   - Response: `{ "success": true, "path": "...", "name": "my-stack" }`

4. **`POST /api/stack/initialize`** — cold-load a stack into a running stackless daemon. Request:
   ```json
   { "name": "my-stack" }
   ```
   - Looks up `~/.gridctl/stacks/<name>.yaml`
   - Returns 404 if not found
   - Sets `s.stackFile` and `s.stackName` on the server
   - Calls the reload handler's load path (see Architecture below)
   - Starts the file watcher on the newly loaded stack file
   - Returns `{ "success": true, "name": "my-stack" }`
   - Returns 409 if a stack is already loaded (stackless → loaded is one-way; use reload for subsequent changes)

### Architecture for `POST /api/stack/initialize`

The existing `reload.Handler.Reload()` in `pkg/reload/reload.go` works by diffing `currentCfg` against a new config loaded from disk. When `currentCfg == nil` (initial load), `ComputeDiff(nil, newCfg)` will treat every MCP server and resource as "added" — which is exactly right for cold initialization.

**Extend `reload.Handler`**:
```go
// Add an Initialize method that sets stackPath and calls Reload with nil currentCfg
func (h *Handler) Initialize(ctx context.Context, stackPath string) (*ReloadResult, error) {
    h.stackPath = stackPath
    h.currentCfg = nil  // ensures full add-all diff
    return h.Reload(ctx)
}
```

Wire `POST /api/stack/initialize` to call `h.reloadHandler.Initialize(ctx, stackPath)`, then set `s.stackFile`, start the file watcher.

**If `reloadHandler` is nil** (daemon started without `--watch`): still write the file and set `s.stackFile`, but skip the watcher. The stack is loaded into memory via the existing runtime machinery; live reload won't be available until restart with `--watch`. Return a response header or field indicating watch status.

### Key Files

- `pkg/state/state.go` — add `StacksDir`
- `internal/api/stack.go` — add `handleStacksList`, `handleStacksSave`, `handleStackInitialize`
- `internal/api/api.go` — register new routes
- `pkg/reload/reload.go` — add `Initialize()` method
- `internal/api/stack_test.go` — add tests following existing table-driven patterns

### Acceptance Criteria

1. `GET /api/stacks` returns `{ "stacks": [] }` when `~/.gridctl/stacks/` doesn't exist
2. `POST /api/stacks` creates the directory if needed and writes the file
3. `POST /api/stacks` returns 400 for invalid YAML or invalid name
4. `POST /api/stack/initialize` loads the stack, starts MCP servers, returns 200
5. `POST /api/stack/initialize` returns 404 for unknown stack name
6. `POST /api/stack/initialize` returns 409 if a stack is already active
7. After `POST /api/stack/initialize`, `GET /api/ready` returns 200
8. All three endpoints have tests

---

## Phase 3: Wizard Save & Load

### Goal
The Stack wizard's review step saves to the library and loads the stack live. No download guidance, no broken Deploy button.

### Functional Requirements

1. In `ReviewStep`, when `resourceType === 'stack'`:
   - Show a **"Save & Load"** button (primary, `ml-auto`) instead of Deploy
   - On click: call `POST /api/stacks` (save), then `POST /api/stack/initialize` (load)
   - On success: toast "Stack loaded — my-stack is now active", close wizard, canvas populates
   - On save error: toast error, stay on review step
   - On initialize error: toast "Saved but could not load — restart with `gridctl apply ~/.gridctl/stacks/<name>.yaml`"
   - Keep Download and Copy as secondary actions

2. If a stack is **already active** (409 from initialize): show "Stack saved to library" toast only — no load attempted, no error shown.

3. "Save & Load" is disabled while `validating` or when `hasErrors`.

### New API Client Functions (`web/src/lib/api.ts`)

```ts
saveStack(yaml: string, name: string): Promise<{ success: boolean; path: string; name: string }>
initializeStack(name: string): Promise<{ success: boolean; name: string }>
```

Follow the existing patterns in `api.ts` (fetch with `buildHeaders`, throw on non-2xx).

### Key Files

- `web/src/components/wizard/steps/ReviewStep.tsx` — replace Deploy with Save & Load for `resourceType === 'stack'`
- `web/src/lib/api.ts` — add `saveStack`, `initializeStack`

### UX Specification

```
[ Valid ]  Spec is valid

  Summary
  Type: stack    Name: my-stack    Lines: 14    Status: Valid

  [ Download ]  [ Copy ]                      [ Save & Load → ]
```

After success: wizard closes, canvas renders the newly loaded stack topology.

### Acceptance Criteria

1. Stack review step shows "Save & Load" (not Deploy, not download guidance)
2. Successful save + load closes wizard and populates canvas
3. If stack already active, shows save-only toast without error
4. Button disabled while validating or spec has errors
5. Download and Copy still work

---

## Phase 4: Wizard Gating and UX Polish

### Goal
Gate MCP Server/Resource cards on stack state. Add ambient active stack indicator.

### Functional Requirements

1. **Card gating in `CreationWizard`**: When `connectionStatus !== 'connected'` (no active stack):
   - `mcp-server` and `resource` type cards render at `opacity-40` with `cursor-not-allowed`
   - Native `title` attribute: `"Requires an active stack — create a Stack first"`
   - Clicking a dimmed card does nothing (`onClick={() => !isDisabled && onSelect(rt.type)}`)
   - Stack, Skill, and Secret cards are always enabled

2. **Active stack name indicator**: Display the active stack name as an ambient label in the app header or status bar. When no stack is loaded, show nothing (or a subtle "no stack" label). Pattern: always visible, never intrusive. This prevents "which stack am I editing?" confusion as the library grows.

3. **Empty canvas CTA**: When `connectionStatus === 'disconnected'` and `gatewayInfo === null` (stackless mode), the canvas empty state should show "Create your first stack" as a button that opens the wizard to the Stack type. (Check if `WorkflowEmptyState` or similar already does this — extend rather than replace.)

### Key Files

- `web/src/components/wizard/CreationWizard.tsx` — card gating logic; uses `useStackStore` already
- `web/src/components/layout/` or header component — active stack name indicator; find where stack name would fit without introducing new layout complexity
- Canvas empty state — extend existing empty state component to surface wizard CTA

### Acceptance Criteria

1. With no active stack: MCP Server and Resource cards are dimmed; tooltip on hover
2. Clicking a dimmed card does nothing
3. With active stack: all 5 cards enabled, behavior unchanged
4. Active stack name visible somewhere persistent in the UI
5. Canvas empty state in stackless mode shows wizard CTA

---

## Global Implementation Notes

### Conventions

- Go: follow patterns in `internal/api/stack.go`, `pkg/state/state.go`; table-driven tests in `internal/api/stack_test.go`
- TypeScript: strict mode, Tailwind + `cn()`, no new dependencies
- API errors: `writeJSONError(w, "message", statusCode)` pattern
- All new Go code gets tests; all new API client functions get TypeScript types

### Build Order

Phases 1 → 2 → 3 → 4. Phases 3 and 4 depend on Phase 2's endpoints. Phase 1 is independent and low-risk — a good confidence-builder for Phase 2's more complex initialize logic.

### Potential Pitfalls

- **`cobra.ExactArgs(1)` → `cobra.MaximumNArgs(1)`**: validate that the no-arg path doesn't call anything that dereferences the stack path
- **`POST /api/stack/initialize` is one-way**: stackless → loaded. Once a stack is loaded, use the existing reload/watch mechanism. Don't try to support "unload" — that's a restart.
- **`reloadHandler` may be nil** if daemon started without `--watch` in stackless mode. The initialize endpoint must handle this: write and set the stack file, but skip the watcher setup gracefully.
- **Network config changes** in `reload.go` return an error requiring restart. On initial load (nil currentCfg), skip this check — there's no previous network to compare against.
- **SSE sessions**: loading a new stack will reset MCP connections. This is expected behavior; no special handling needed.
- **Name validation** in `POST /api/stacks`: reject names with `/`, `..`, or non-alphanumeric/hyphen/underscore chars before using as filename.

## Acceptance Criteria (End-to-End)

1. `gridctl serve` starts without a stack file and serves the web UI
2. Canvas in stackless mode shows "Create your first stack" CTA
3. User completes Stack wizard → "Save & Load" → canvas populates with new stack topology
4. MCP Server/Resource wizard cards are dimmed when no stack is loaded
5. After a stack is loaded, all 5 wizard cards are enabled
6. Active stack name is visible in the header/status bar
7. `gridctl apply stack.yaml` continues to work exactly as before
8. `~/.gridctl/stacks/` is created on first stack save
9. `GET /api/stacks` lists all saved stacks
10. No HTTP 400 errors are reachable through any wizard path

## References

- `pkg/state/state.go:23-67` — directory structure pattern
- `pkg/reload/reload.go:82-155` — Reload() method, the extension point for Initialize()
- `pkg/controller/controller.go:87-119` — startup pipeline to refactor
- `cmd/gridctl/apply.go:42` — `cobra.ExactArgs(1)` to relax
- `internal/api/stack.go:405-472` — handleStackAppend pattern for new handlers
- `internal/api/api.go:697-720` — handleReload, for reference on reload wiring
- `web/src/components/wizard/steps/ReviewStep.tsx` — primary frontend file for Phase 3
- `web/src/components/wizard/CreationWizard.tsx` — card gating for Phase 4
- `web/src/lib/api.ts:533-543` — appendToStack, pattern for new API client functions
