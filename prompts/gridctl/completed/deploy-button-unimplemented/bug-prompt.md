# Bug Fix: Deploy Button Unimplemented in Wizard Review Step

## Context

gridctl is a Go + React application that manages MCP (Model Context Protocol) server stacks. The backend is a Go HTTP server (`internal/api/`) that manages a `stack.yaml` file; the frontend is a React/TypeScript SPA (`web/src/`). The creation wizard (`CreationWizard.tsx`) walks users through selecting and configuring a resource type (agent, mcp-server, resource, stack, skill, secret) and generates a YAML spec. The final "Review" step shows the spec, validates it, and presents Download, Copy, and **Deploy** actions.

The hot-reload system (`pkg/reload/watcher.go`) uses `fsnotify` to watch `stack.yaml` for writes and auto-reloads the stack after a 300ms debounce — no explicit reload call is needed after writing the file.

Tech stack: Go 1.22+, `gopkg.in/yaml.v3`, `github.com/stretchr/testify`, React 18, TypeScript, Zustand, `lucide-react`, Tailwind CSS.

## Investigation Context

- Root cause confirmed: Deploy button at `web/src/components/wizard/steps/ReviewStep.tsx:222` has no `onClick` handler
- No matching backend endpoint exists — confirmed by reviewing `internal/api/stack.go:20-38`
- No frontend API client function exists — confirmed in `web/src/lib/api.ts`
- Risk mitigation: YAML merge must map `resourceType` string to the correct Go struct field; must handle missing `stackFile` with 503
- Reproduction confirmed: 100% deterministic — open wizard → Review step → click Deploy → nothing
- Full investigation: `prompt-stack/prompts/gridctl/deploy-button-unimplemented/bug-evaluation.md`

## Bug Description

The Deploy button on the wizard Review step is inert. When a user completes the wizard and the spec passes validation (green "Spec is valid" indicator), the Deploy button becomes active but clicking it does nothing — no network request, no toast, no UI change, no error.

**Expected:** Deploy POSTs the YAML to the backend, which appends the new resource to `stack.yaml`. The file watcher detects the write and reloads the stack. The frontend shows a success toast and closes the wizard.

**Actual:** Nothing happens. The button has no `onClick` handler.

**Affected users:** All users who complete the wizard and click Deploy.

## Root Cause

Three-layer gap, all unimplemented:

1. `web/src/components/wizard/steps/ReviewStep.tsx:222` — `<Button>` has no `onClick`
2. `web/src/lib/api.ts` — no function to POST to a deploy/append endpoint
3. `internal/api/stack.go:20-38` — no `POST /api/stack/append` route or handler

## Fix Requirements

### Required Changes

1. **Backend: Add `POST /api/stack/append` endpoint** in `internal/api/stack.go`
   - Accept JSON body: `{ "yaml": "<resource YAML string>", "resourceType": "agent" | "mcp-server" | "resource" }`
   - Read and unmarshal `s.stackFile` into `config.Stack`
   - Parse the incoming YAML into the appropriate Go type (`config.Agent`, `config.MCPServer`, `config.Resource`)
   - Append to the correct slice (`stack.Agents`, `stack.MCPServers`, `stack.Resources`)
   - Re-marshal to YAML and write back to `s.stackFile` atomically
   - Return `{ "success": true, "resourceType": "...", "resourceName": "..." }`
   - Register the new case in the `handleStack` router switch

2. **Frontend API client: Add `appendToStack()` in `web/src/lib/api.ts`**
   - Function signature: `appendToStack(yaml: string, resourceType: string): Promise<{ success: boolean; resourceType: string; resourceName: string }>`
   - POST to `/api/stack/append` with JSON body `{ yaml, resourceType }`
   - Follow the same fetch + error pattern as `validateStackSpec()` directly above it

3. **Frontend component: Wire `ReviewStep.tsx`**
   - Add optional prop `onDeploy?: () => void` to `ReviewStepProps`
   - Add `[deploying, setDeploying]` state (boolean)
   - Add `handleDeploy` async function: call `appendToStack(yaml, resourceType)`, on success call `showToast('success', ...)` then `onDeploy?.()`, on error call `showToast('error', ...)`
   - Add `onClick={handleDeploy}` to the Deploy button
   - Update `disabled` to also disable while `deploying`: `disabled={hasErrors || validating || deploying}`
   - Show a `Loader2` spinner icon on the button while `deploying` is true

4. **Wizard orchestration: Pass callback in `CreationWizard.tsx`**
   - In the `review` case of `renderStepContent`, pass `onDeploy={close}` to `ReviewStep`
   - `close` comes from `useWizardStore` (already destructured at line 128)
   - `renderStepContent` must receive `close` as a new parameter (add it to the function signature and all call sites at lines 355 and 383)

### Constraints

- The endpoint must return 503 if `s.stackFile == ""` (no stack configured)
- The endpoint must return 400 if `resourceType` is `"stack"` or `"skill"` or `"secret"` (unsupported for append — only agent/mcp-server/resource make sense)
- The endpoint must return 400 if the YAML fails to parse into the expected resource type
- The file write must not corrupt `stack.yaml` on partial failure — write to a temp file and rename, or use `os.WriteFile` which is atomic on the same filesystem
- Do not call `POST /api/reload` explicitly — the file watcher handles reload automatically

### Out of Scope

- Supporting `resourceType == "stack"` (full stack overwrite) — return 400 for now
- Duplicate name detection (appending an agent with the same name as an existing one) — leave for a follow-up
- Undo/rollback of the append operation

## Implementation Guidance

### Key Files to Read

1. `internal/api/stack.go` — router switch pattern (lines 20-38) and `handleStackValidate` as the implementation template (lines 42-69)
2. `web/src/components/wizard/steps/ReviewStep.tsx` — full component; Deploy button at lines 222-230; `handleDownload`/`handleCopy` as onClick pattern
3. `web/src/components/wizard/CreationWizard.tsx` — `renderStepContent` function (lines 434-492); how `close` is available
4. `web/src/lib/api.ts` — `validateStackSpec()` at line 508 as the exact fetch pattern to follow; `triggerReload()` at line 274 as a POST-with-no-body pattern
5. `pkg/config/stack.go` or equivalent — `config.Stack`, `config.Agent`, `config.MCPServer`, `config.Resource` struct definitions to understand YAML field names
6. `internal/api/stack_test.go` — test patterns: `writeTestStack()` helper, `httptest.NewRequest`, `httptest.NewRecorder`, `assert.NoError`

### Files to Modify

| File | Change |
|---|---|
| `internal/api/stack.go` | Add `case path == "append" && r.Method == http.MethodPost: s.handleStackAppend(w, r)` to switch + full handler implementation |
| `web/src/lib/api.ts` | Add `appendToStack()` function after `validateStackSpec()` |
| `web/src/components/wizard/steps/ReviewStep.tsx` | Add `onDeploy` prop, `deploying` state, `handleDeploy` function, wire onto button |
| `web/src/components/wizard/CreationWizard.tsx` | Add `close` param to `renderStepContent`; pass `onDeploy={close}` to `ReviewStep` |

### Reusable Components

- `handleStackValidate` in `stack.go` — exact template for reading YAML body, unmarshaling, returning JSON
- `handleStackSpec` in `stack.go` — template for `os.ReadFile(s.stackFile)` with the 503 guard
- `handleDownload` / `handleCopy` in `ReviewStep.tsx` — pattern for `showToast` usage and async handlers
- `writeJSON` / `writeJSONError` helpers — already used throughout `stack.go`

### Conventions to Follow

- Go: handler methods on `*Server`, method name `handleStack<Action>`, registered in the `handleStack` switch
- Go: use `io.LimitReader(r.Body, 1<<20)` for request body reads
- Go: return `writeJSONError(w, msg, status)` for errors; `writeJSON(w, data)` for success
- TypeScript: `async function`, `await fetch(...)`, check `!response.ok` and throw; matches `validateStackSpec` pattern
- TypeScript: API base via `API_BASE` constant, headers via `buildHeaders()`
- React: `useState` for loading state; `showToast('success'|'error', message)` for user feedback

### Backend Handler Sketch

```go
// handleStackAppend appends a resource to the current stack.yaml.
// POST /api/stack/append
func (s *Server) handleStackAppend(w http.ResponseWriter, r *http.Request) {
    if s.stackFile == "" {
        writeJSONError(w, "No stack file configured", http.StatusServiceUnavailable)
        return
    }

    body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
    if err != nil {
        writeJSONError(w, "Failed to read request body: "+err.Error(), http.StatusBadRequest)
        return
    }

    var req struct {
        YAML         string `json:"yaml"`
        ResourceType string `json:"resourceType"`
    }
    if err := json.Unmarshal(body, &req); err != nil {
        writeJSONError(w, "Invalid JSON: "+err.Error(), http.StatusBadRequest)
        return
    }

    // Load current stack
    stack, _, err := config.ValidateStackFile(s.stackFile)
    if err != nil {
        writeJSONError(w, "Failed to load stack: "+err.Error(), http.StatusInternalServerError)
        return
    }

    // Parse and append resource
    var name string
    switch req.ResourceType {
    case "agent":
        var r config.Agent
        if err := yaml.Unmarshal([]byte(req.YAML), &r); err != nil {
            writeJSONError(w, "Invalid agent YAML: "+err.Error(), http.StatusBadRequest)
            return
        }
        stack.Agents = append(stack.Agents, r)
        name = r.Name
    case "mcp-server":
        var r config.MCPServer
        if err := yaml.Unmarshal([]byte(req.YAML), &r); err != nil {
            writeJSONError(w, "Invalid mcp-server YAML: "+err.Error(), http.StatusBadRequest)
            return
        }
        stack.MCPServers = append(stack.MCPServers, r)
        name = r.Name
    case "resource":
        var r config.Resource
        if err := yaml.Unmarshal([]byte(req.YAML), &r); err != nil {
            writeJSONError(w, "Invalid resource YAML: "+err.Error(), http.StatusBadRequest)
            return
        }
        stack.Resources = append(stack.Resources, r)
        name = r.Name
    default:
        writeJSONError(w, "Unsupported resourceType: "+req.ResourceType, http.StatusBadRequest)
        return
    }

    // Marshal and write back
    out, err := yaml.Marshal(stack)
    if err != nil {
        writeJSONError(w, "Failed to marshal stack: "+err.Error(), http.StatusInternalServerError)
        return
    }
    if err := os.WriteFile(s.stackFile, out, 0o644); err != nil {
        writeJSONError(w, "Failed to write stack file: "+err.Error(), http.StatusInternalServerError)
        return
    }

    writeJSON(w, map[string]any{
        "success":      true,
        "resourceType": req.ResourceType,
        "resourceName": name,
    })
}
```

Note: `json` package import is already present in `wizard.go` — confirm it's imported in `stack.go` or add it.

## Regression Test

### Test Outline

Add to `internal/api/stack_test.go`:

```
TestHandleStackAppend_Agent:
  - writeTestStack(t) → path to temp stack.yaml with 1 existing agent
  - Server{stackFile: path}
  - POST /api/stack/append with body { "yaml": "name: agent-new\nruntime: claude-code\nprompt: test\n", "resourceType": "agent" }
  - Assert 200 OK
  - Read path, unmarshal into config.Stack
  - Assert len(stack.Agents) == 2
  - Assert stack.Agents[1].Name == "agent-new"

TestHandleStackAppend_MCPServer:
  - Similar, resourceType="mcp-server", assert MCPServers grows

TestHandleStackAppend_NoStackFile:
  - Server{} (no stackFile)
  - POST /api/stack/append
  - Assert 503

TestHandleStackAppend_InvalidResourceType:
  - POST with resourceType="stack"
  - Assert 400

TestHandleStackAppend_InvalidYAML:
  - POST with resourceType="agent", yaml="!!not valid yaml!!"
  - Assert 400
```

### Existing Test Patterns

See `internal/api/stack_test.go` — use `writeTestStack(t)` helper, `httptest.NewRequest` + `httptest.NewRecorder`, `assert.NoError`, `assert.Equal`. The `Server` struct is instantiated directly: `s := &Server{stackFile: path}`.

## Potential Pitfalls

1. **YAML re-serialization:** `yaml.Marshal(stack)` will reformat the entire file — key order, comments, and formatting from the original file will be lost. This is acceptable for now but worth noting in the PR description.
2. **`config.Stack` struct field names:** Verify the exact field names for `MCPServers`, `Agents`, `Resources` in the config package before implementing the switch — they may differ from the YAML key names.
3. **`json` import in stack.go:** `stack.go` currently only imports `io`, `net/http`, `os`, `strings`, and the config/state packages. You'll need to add `"encoding/json"` for `json.Unmarshal`.
4. **`renderStepContent` signature change:** This function is called in two places (lines 355 and 383 in `CreationWizard.tsx`) — both call sites must be updated when adding the `close` parameter.
5. **Deploy button loading state:** Without a spinner on the Deploy button during the POST, repeated clicking is possible. The `deploying` state guard on `disabled` prevents double-submission, but showing a `Loader2` spinner (matching the `validating` state pattern already in the component) improves UX.

## Acceptance Criteria

1. Clicking Deploy in the Review step (with a valid spec) triggers a POST to `/api/stack/append`
2. The new resource appears in `stack.yaml` after the request completes
3. The file watcher triggers a stack reload within 300ms of the file write
4. A success toast appears: e.g., "Agent 'agent0' deployed to stack"
5. The wizard closes after successful deploy
6. Clicking Deploy while deploying is in progress is a no-op (button disabled)
7. If the backend returns an error, an error toast appears and the wizard stays open
8. If no stack is configured (`stackFile == ""`), the endpoint returns 503 and the frontend shows an error toast
9. `TestHandleStackAppend_Agent`, `_MCPServer`, `_NoStackFile`, `_InvalidResourceType`, `_InvalidYAML` all pass

## References

- Full investigation: `prompt-stack/prompts/gridctl/deploy-button-unimplemented/bug-evaluation.md`
- `handleStackValidate` implementation pattern: `internal/api/stack.go:42-69`
- File watcher: `pkg/reload/watcher.go` (auto-reloads on write, no explicit trigger needed)
- Existing toast usage: `ReviewStep.tsx:68,75,78` (`showToast('success'|'error', message)`)
