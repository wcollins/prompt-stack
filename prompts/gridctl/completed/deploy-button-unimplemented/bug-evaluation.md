# Bug Investigation: Deploy Button Unimplemented

**Date**: 2026-03-27
**Project**: gridctl
**Recommendation**: Fix immediately
**Severity**: High
**Fix Complexity**: Small

## Summary

The Deploy button in the agent builder wizard's Review step has no `onClick` handler and is therefore completely inert — clicking it does nothing. This is not a regression but an unimplemented feature that was scaffolded (disabled logic, icon, styling) but never wired up. The fix requires three coordinated changes: a backend `POST /api/stack/append` endpoint, a frontend API client function, and an `onClick` handler in `ReviewStep.tsx`.

## The Bug

**What is wrong:** Clicking the Deploy button in the wizard's Review step produces no effect — no network request, no toast notification, no UI state change.

**Expected behavior:** Clicking Deploy should POST the generated YAML to the backend, which reads the current `stack.yaml`, appends the new resource (agent, mcp-server, or resource) to the appropriate section, writes the file back atomically, and returns success. The frontend shows a success toast and closes the wizard. The file watcher auto-detects the write and reloads the stack.

**Actual behavior:** Button renders, respects disabled state (blocked while validating or when errors exist), but has no `onClick` — it is cosmetic.

**How it was discovered:** Code review of `ReviewStep.tsx` confirmed the button lacked an `onClick` handler, and a search of the backend confirmed no matching endpoint exists.

## Root Cause

### Defect Location

- `web/src/components/wizard/steps/ReviewStep.tsx:222-230` — Deploy `<Button>` missing `onClick` prop
- `web/src/components/wizard/CreationWizard.tsx:479-490` — `ReviewStep` rendered with no `onDeploy` callback
- `web/src/lib/api.ts` — no `deployResource()` or `appendToStack()` function exists
- `internal/api/stack.go:20-38` — no `POST /api/stack/append` case in the router switch

### Code Path

```
User clicks Deploy button
  → ReviewStep.tsx:222 — Button has no onClick (dead end)

Expected path:
  → handleDeploy() in ReviewStep
  → POST /api/stack/append { yaml, resourceType }
  → internal/api/stack.go — handleStackAppend()
    → os.ReadFile(s.stackFile)
    → yaml.Unmarshal into config.Stack
    → append resource to stack.MCPServers / .Agents / .Resources
    → yaml.Marshal
    → os.WriteFile (atomic)
    → return success JSON
  → pkg/reload/watcher.go — fsnotify detects write, fires onChange() after 300ms debounce
  → frontend: showToast('success', ...) + close wizard
```

### Why It Happens

The feature was scaffolded — the button exists with correct disabled logic (`disabled={hasErrors || validating}`), the Rocket icon, and the amber primary styling — but the implementation was never completed. The `ReviewStepProps` interface only exposes `yaml`, `resourceType`, and `resourceName`; no `onDeploy` callback was ever added. Correspondingly, the backend stack router has only read-oriented endpoints with no write path for appending resources.

### Similar Instances

No other wizard steps have unimplemented primary actions. The Download and Copy buttons in the same component both have fully implemented handlers (`handleDownload`, `handleCopy`). The Deploy button is the sole unimplemented action.

## Impact

### Severity Classification

**High — Critical path blocker.** The wizard's entire purpose is to build and deploy a resource. The Deploy button is the final step. Users who discover it doesn't work are left with no in-UI path to deploy their configured resource.

### User Reach

All users who complete the wizard flow are affected. The button renders for every resource type (agent, mcp-server, resource). It is the most prominent action on the final step — rendered amber/primary to draw attention.

### Workflow Impact

Complete path blocker for wizard-driven resource deployment. Users cannot deploy via the UI wizard; they must fall back to:
1. Download the YAML → manually merge into `stack.yaml`
2. Copy the YAML → manually paste into `stack.yaml`

Both workarounds require context-switching out of the UI and understanding the stack file structure.

### Workarounds

- **Download:** Use the Download button on the Review step to get the YAML file, manually merge it into the appropriate section of `stack.yaml`
- **Copy:** Use the Copy button to copy YAML to clipboard, paste directly into `stack.yaml` under the correct section header
- **Neither is adequate** for new users or users unfamiliar with YAML structure

### Urgency Signals

- The button's existence communicates a promise the UI doesn't keep — users will retry clicking before giving up
- No error message or "coming soon" indicator; the button becomes active when spec is valid (disabled=false), strongly implying it will work

## Reproduction

### Minimum Reproduction Steps

1. Open the gridctl web UI
2. Open the creation wizard (any "+" or create trigger)
3. Select a resource type — e.g., **Agent**
4. Fill in the form (Name: `agent0`, leave other fields at defaults)
5. Click **Next** to advance to the Review step
6. Observe "Spec is valid — Ready to generate" with green checkmark
7. Click the amber **Deploy** button
8. **Nothing happens** — no network request, no toast, no UI change

### Affected Environments

All environments where the web UI is served. Confirmed by code: the button has no `onClick` in any code path.

### Non-Affected Environments

N/A — defect is in source code, not environment-specific.

### Failure Mode

Silent no-op. The button click is swallowed with no feedback. The system remains in a consistent state (stack.yaml untouched).

## Fix Assessment

### Fix Surface

| File | Change |
|---|---|
| `internal/api/stack.go` | Add `POST /api/stack/append` case + `handleStackAppend()` handler |
| `web/src/lib/api.ts` | Add `appendToStack(yaml: string, resourceType: string)` function |
| `web/src/components/wizard/steps/ReviewStep.tsx` | Add `onDeploy?: () => void` prop + `handleDeploy` + `onClick` on button |
| `web/src/components/wizard/CreationWizard.tsx` | Pass `onDeploy` callback (with `close()`) to `ReviewStep` |

### Risk Factors

- **YAML merge correctness:** The backend must parse the resource snippet and append it to the right section of `stack.yaml` without corrupting the file. The `yaml.Marshal(config.Stack{})` path may reorder or reformat keys compared to what the user originally wrote. Use atomic write (`os.WriteFile` with `os.O_TRUNC`) or a temp-file rename.
- **ResourceType mapping:** The incoming `resourceType` string (`"agent"`, `"mcp-server"`, `"resource"`) must be correctly mapped to the Go struct fields (`Agents`, `MCPServers`, `Resources`).
- **No stackFile configured:** If the server has no `s.stackFile`, the endpoint must return a clear 503 rather than panic.
- **Stack type:** If `resourceType == "stack"`, appending semantics are undefined — the endpoint should reject this case or treat it as a full overwrite (out of scope for this fix; just return 400).

### Regression Test Outline

**Backend (Go):**
```
TestHandleStackAppend_Agent:
  - Write a temp stack.yaml with one existing agent
  - POST /api/stack/append with a new agent YAML + resourceType="agent"
  - Assert 200 OK
  - Read stack.yaml, unmarshal, assert len(Agents) == 2 and new agent name is correct

TestHandleStackAppend_NoStackFile:
  - Server with no stackFile set
  - POST /api/stack/append
  - Assert 503

TestHandleStackAppend_InvalidYAML:
  - POST /api/stack/append with malformed YAML
  - Assert 400
```

**Frontend (integration/E2E):**
- Complete wizard → Review step → click Deploy → assert POST called → assert wizard closed → assert success toast shown

## Recommendation

Fix immediately. This is the primary action of the most prominent UI flow in gridctl. The fix is well-scoped (4 files, ~80-100 lines total), the risk is manageable with careful YAML merge logic, and the existing infrastructure (watcher, validate endpoint, existing stack handlers) provides a solid pattern to follow. The `handleStackValidate` function is a direct template for the new append handler — same YAML read, same unmarshal pattern, just add merge + write.

## References

- `web/src/components/wizard/steps/ReviewStep.tsx` — Deploy button at line 222
- `web/src/components/wizard/CreationWizard.tsx` — ReviewStep render at line 479
- `internal/api/stack.go` — existing stack handlers (validate pattern at line 42)
- `pkg/reload/watcher.go` — auto-reload on file write (300ms debounce)
- `web/src/lib/api.ts` — `triggerReload()` at line 274 (existing API pattern)
- `internal/api/stack_test.go` — test patterns for stack handlers
