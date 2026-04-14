# Bug Fix: Agent Canvas Missing After Deploy

## Context

gridctl is a full-stack infrastructure control plane (Go backend + React/TypeScript frontend). The frontend is a React app in `web/src/` using React Flow for the canvas, Zustand for state management, and a polling loop to refresh data from the backend. The Go backend serves a REST API including `GET /api/status` (topology state) and `POST /api/stack/append` (add resources to the running stack).

## Investigation Context

- Root cause confirmed via code analysis — two independent defects in the deploy → canvas path
- Backend defect: `internal/api/api.go:609` — `getAgentStatuses()` only returns agents with Docker containers or A2A registration; config-only agents are invisible
- Frontend defect: `web/src/components/wizard/CreationWizard.tsx:355,384` — `close` is passed where `onDeploy` is expected
- Reproduction is deterministic on all environments
- Full investigation: `prompt-stack/prompts/gridctl/agent-canvas-missing-after-deploy/bug-evaluation.md`

## Bug Description

After deploying an agent via the Creation Wizard, the deploy succeeds (success toast, YAML spec updates) but no agent node ever appears on the React Flow canvas. The Spec tab shows the agent because it reads the YAML file directly. The canvas reads from `/api/status` which only returns agents with active runtime presence (Docker container or A2A registration). `appendToStack` only writes to the YAML config, never starting the agent's runtime. Therefore `getAgentStatuses()` never returns the newly deployed agent, the canvas state is never updated, and the agent node is never rendered.

## Root Cause

### Defect 1 — Backend: `internal/api/api.go:609`

```go
func (s *Server) getAgentStatuses() []AgentStatus {
    containerAgents := s.getContainerAgents()   // queries Docker — new agent has no container
    a2aStatuses = s.a2aGateway.Status()         // queries A2A — new agent not registered
    // unified list built from Docker + A2A only
    // ❌ never reads stack config file — config-only agents are invisible
}
```

`appendToStack` writes the agent to `stack.yaml` but never starts a container or registers with A2A. `getAgentStatuses()` has no visibility into the config file.

### Defect 2 — Frontend: `web/src/components/wizard/CreationWizard.tsx:355,384`

```tsx
// renderStepContent signature expects onDeploy: () => void as last param
// Both call sites pass close() instead:
renderStepContent(
  currentStep, selectedType, ...,
  close,   // ❌ should be a refresh callback, not close
)
```

`ReviewStep.handleDeploy()` calls `onDeploy?.()` after success, which resolves to `close()`. The wizard closes but no poll refresh is triggered, so the canvas waits for the next automatic polling interval instead of refreshing immediately.

## Fix Requirements

### Required Changes

**Fix 1 — Backend** (`internal/api/api.go`):

Modify `getAgentStatuses()` to also read agents from the stack config file and include any not already present in the Docker/A2A results with a `"pending"` or `"configured"` status:

1. In `getAgentStatuses()`, after building the unified list from Docker and A2A, read `s.stack.Agents` (or equivalent config accessor — check how the server holds the stack config)
2. For each config agent not already in `seen`, append an `AgentStatus` with:
   - `Name`: agent name from config
   - `Status`: `"pending"` (or a suitable status indicating configured-but-not-started)
   - `Variant`: `"local"` (or derive from config fields)
   - `Uses`: agent's uses list from config
3. Keep the existing Docker and A2A merge logic intact — it takes precedence

**Fix 2 — Frontend** (`web/src/components/wizard/CreationWizard.tsx` and `web/src/components/layout/Header.tsx`):

1. Add `onDeploy?: () => void` to the `CreationWizardProps` interface (line 120)
2. Accept `onDeploy` in the `CreationWizard` component destructuring (line 124)
3. Replace `close` with a combined callback at both `renderStepContent` call sites (lines 355–370 and 384–399):
   ```tsx
   const handleDeploy = useCallback(() => {
     close();
     onDeploy?.();
   }, [close, onDeploy]);
   // pass handleDeploy as the last arg to renderStepContent
   ```
4. In `web/src/components/layout/Header.tsx`, pass `onDeploy` to `<CreationWizard>` wired to the polling `refresh()` function:
   ```tsx
   const { refresh } = usePolling();  // or receive it from App.tsx as a prop
   <CreationWizard onOpenVault={...} onDeploy={refresh} />
   ```
   Check how `Header.tsx` currently receives `refresh` — it may already be passed from `App.tsx` as `onRefresh`. Wire it through.

### Constraints

- Do NOT change the deploy flow for MCP servers or resources — only agents are confirmed broken at the backend layer
- Do NOT remove the existing close-after-deploy behavior in the wizard — the wizard should still close on successful deploy
- The `onDeploy` prop must remain optional in `CreationWizardProps` — do not make it required

### Out of Scope

- Triggering container start or gateway reconcile from `handleStackAppend` — this is a larger architectural change
- Changes to how the Spec tab reads the YAML file
- Changes to polling interval or debounce behavior

## Implementation Guidance

### Key Files to Read

| File | Why |
|---|---|
| `internal/api/api.go:609` | `getAgentStatuses()` — where to add config-agent fallback |
| `internal/api/api.go:567` | `getContainerAgents()` — understand the existing Docker query pattern |
| `internal/api/stack.go:480` | `handleStackAppend()` — confirm it only writes YAML, no reconcile |
| `web/src/components/wizard/CreationWizard.tsx:120,355,384,436,450` | Both call sites and the function signature |
| `web/src/components/layout/Header.tsx` | How `CreationWizard` is rendered and what callbacks are available |
| `web/src/App.tsx:100` | Where `usePolling()` is called and `refresh` is available |
| `web/src/hooks/usePolling.ts:108` | The `refresh()` function to call after deploy |

### Files to Modify

1. `internal/api/api.go` — extend `getAgentStatuses()` to include config-only agents
2. `web/src/components/wizard/CreationWizard.tsx` — add `onDeploy` prop, fix both `renderStepContent` call sites
3. `web/src/components/layout/Header.tsx` — pass `onDeploy={refresh}` to `<CreationWizard>`

### Reusable Components

- `AgentStatus` struct already has a `Status` field that accepts string values — use `"pending"` without any type changes
- `seen` map in `getAgentStatuses()` already tracks processed agent names — use it to avoid duplicates when adding config agents
- `usePolling().refresh` is already returned from the hook and consumed in `App.tsx` — do not duplicate the polling logic

### Conventions to Follow

- Go: functions in `api.go` follow the `(s *Server) methodName()` receiver pattern
- TypeScript: `useCallback` for all event handlers in React components; optional props use `?:` syntax
- Frontend props flow top-down: `App → Header → CreationWizard → ReviewStep`
- Commit type: `fix:`

## Regression Test

### Test Outline

**Backend** (add to `internal/api/stack_test.go` or `api_test.go`):

```
TestAgentAppearsInStatusAfterAppend:
  1. Create a test server with a stack file
  2. POST /api/stack/append with a valid agent YAML (name: "test-agent", runtime: "node", prompt: "test")
  3. GET /api/status
  4. Assert: response.agents contains an entry with name "test-agent"
  5. Assert: entry has status "pending" (or any non-empty status)
```

**Frontend** (conceptual — follow existing test patterns in `web/src/`):

```
CreationWizard onDeploy wiring:
  1. Render <CreationWizard onDeploy={mockRefresh} />
  2. Simulate completing the wizard to Review step for an agent
  3. Simulate clicking Deploy (mock appendToStack to succeed)
  4. Assert: mockRefresh was called
  5. Assert: wizard is closed (check isOpen state)
```

### Existing Test Patterns

- Backend tests use `httptest.NewRecorder()` and call handler functions directly; see `internal/api/stack_test.go` for `handleStackAppend` test pattern
- Frontend tests: check `web/src/` for existing component test files (Vitest/Jest)

## Potential Pitfalls

- **Config accessor**: Verify how `getAgentStatuses()` can access the stack config. The server struct (`s`) likely has a `stack` field or `stackFile` string. If only `stackFile` is available, you'll need to parse the YAML file — add error handling so a parse failure doesn't break the entire status endpoint.
- **Duplicate agents**: If an agent has a container AND is in the config, it must not appear twice. The `seen` map already guards against this for A2A — extend the same guard for config agents.
- **Header refresh wiring**: Check whether `Header.tsx` already receives `onRefresh` as a prop from `App.tsx`. If so, reuse it rather than calling `usePolling()` inside `Header.tsx`.
- **reviewStep close order**: The wizard calls `close()` on deploy success. Ensure `onDeploy` (refresh) is called after close to avoid a race where a refresh fires while the modal is still animating closed.

## Acceptance Criteria

1. After deploying an agent via the Creation Wizard, an agent node appears on the canvas (status "pending" or similar) without requiring a manual page refresh
2. The agent node eventually transitions to "running" status when the agent container starts (if applicable to the runtime type)
3. The wizard closes after a successful deploy (existing behavior preserved)
4. A `GET /api/status` immediately after `POST /api/stack/append` returns the new agent in the `agents` array
5. `onDeploy` callback is invoked after successful wizard deploy
6. Deploying MCP servers and resources continues to work correctly (no regression)
7. Regression test passes: `TestAgentAppearsInStatusAfterAppend`

## References

- PR #312: fixed deploy button wiring but left canvas rendering broken
- Investigation report: `prompt-stack/prompts/gridctl/agent-canvas-missing-after-deploy/bug-evaluation.md`
- Affected commits: `4124321` (tests), `34e7897` (ReviewStep wire), `534e16e` (onClick wire), `ac81613` (appendToStack API client)
