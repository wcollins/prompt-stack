# Bug Investigation: Agent Canvas Missing After Deploy

**Date**: 2026-03-27
**Project**: gridctl
**Recommendation**: Fix immediately
**Severity**: High
**Fix Complexity**: Medium

## Summary

After deploying an agent via the Creation Wizard (fixed in PR #312), the deploy succeeds and the YAML spec updates, but the agent node never appears on the React Flow canvas. The root cause is two-part: the backend status endpoint only returns agents with active Docker containers or A2A registration, and `appendToStack` only writes to the YAML config without starting the agent runtime. A secondary frontend wiring bug causes the wizard to call `close()` instead of a canvas-refresh callback after deploy.

## The Bug

**Wrong behavior**: Deploying an agent via the wizard succeeds (success toast fires, YAML spec tab updates with the new agent), but no agent node appears on the canvas — not immediately, not after indefinite polling.

**Expected behavior**: After a successful deploy, an agent node should render on the canvas alongside gateway, MCP server, and client nodes.

**Discovery**: User-reported post-merge of PR #312, which fixed the deploy button wiring in the wizard's ReviewStep.

## Root Cause

### Defect Location

**Primary (backend)**: `internal/api/api.go:609` — `getAgentStatuses()` only returns agents with active Docker containers or A2A registration

**Secondary (frontend)**: `web/src/components/wizard/CreationWizard.tsx:355,384` — `renderStepContent()` called with `close` as the `onDeploy` argument

### Code Path

```
User clicks Deploy
→ ReviewStep.handleDeploy() [ReviewStep.tsx:84]
  → appendToStack(yaml, resourceType) [api.ts:530]
    → POST /api/stack/append
      → handleStackAppend() [api.go:482]
        → Writes agent to stack.yaml ONLY — no container start, no A2A registration
  → onDeploy?.() [ReviewStep.tsx:89]
    → calls close() [wizard callback wired wrong in CreationWizard.tsx:369,398]
      → wizard closes, no refresh triggered

Polling loop continues:
→ poll() [usePolling.ts:22]
  → fetchStatus() → GET /api/status
    → getAgentStatuses() [api.go:609]
      → getContainerAgents() → Docker query → agent has no container → not returned
      → a2aGateway.Status() → agent not registered → not returned
    → returns [] for agents (new agent absent)
  → setGatewayStatus(status) [useStackStore.ts:89]
    → refreshNodesAndEdges() [useStackStore.ts:127]
      → transformToNodesAndEdges(..., agents=[]) → no agent nodes created
→ Canvas never shows agent node
```

### Why It Happens

`handleStackAppend` is a config-only operation — it appends to the YAML and writes to disk. It does not signal the gateway to reconcile, start a container, or register the agent in the A2A system. `getAgentStatuses()` has no knowledge of the config file; it only queries Docker and the A2A gateway. A newly written agent is invisible to both sources until something external starts it.

The YAML spec tab shows the agent because the Spec tab reads the YAML file directly (not via `/api/status`), which creates a misleading split: the config shows the agent but the canvas doesn't.

The frontend wiring issue is a pre-existing bug: `renderStepContent()` accepts `onDeploy: () => void` as its last parameter (line 450), but both call sites pass `close` (lines 369, 398). `ReviewStep.handleDeploy()` calls `onDeploy?.()` which resolves to `close()`, closing the wizard without triggering a poll refresh.

### Similar Instances

The same `appendToStack` flow exists for `mcp-server` and `resource` types. MCP servers likely auto-start via a gateway reconcile mechanism (if one exists) or were pre-existing in the screenshot. The missing-from-canvas issue may also affect newly deployed MCP servers and resources if the gateway doesn't auto-reconcile.

## Impact

### Severity Classification

**High** — Regression on a core user-facing workflow. The feature was explicitly added and fixed in PR #312 (deploy button). The visible result of a successful deploy (agent on canvas) is completely absent.

### User Reach

All users who deploy agents via the Creation Wizard are affected. This is the primary agent creation path in the UI.

### Workflow Impact

Critical path blocker for agent deployment visibility. Users have no feedback that their agent was registered in the topology. There is no error shown, so users may re-deploy repeatedly.

### Workarounds

None available through the UI. A user with filesystem access could manually verify the YAML was updated via the Spec tab. There is no way to manually trigger a runtime start for the agent through the current UI.

### Urgency Signals

- Post-merge regression from PR #312 (merged as a fix)
- Silent failure — users see success but get no result
- No error surfaced to the user

## Reproduction

### Minimum Reproduction Steps

1. Open gridctl UI with a running gateway (MCP servers and clients connected)
2. Click `+` (Create) in the toolbar
3. Select **Agent** resource type
4. Fill the Agent form: any valid name, runtime, and prompt
5. Click **Next** → **Next** → reach **Review** step
6. Click **Deploy**
7. Observe: success toast fires, YAML spec tab shows new agent
8. Observe: canvas does NOT show an agent node — at any point in time

### Affected Environments

All environments — deterministic failure, not environment-dependent.

### Non-Affected Environments

None identified — the bug reproduces on any valid agent deployment.

### Failure Mode

Silent success: the user receives a success toast and sees the YAML config update, but the canvas remains unchanged. No error is displayed. Polling never resolves the gap because the backend status endpoint never returns the unstarted agent.

## Fix Assessment

### Fix Surface

**Backend**:
- `internal/api/api.go:609` — `getAgentStatuses()`: extend to include config-only agents as "pending"
- OR `internal/api/stack.go:482` — `handleStackAppend()`: trigger gateway reconcile/agent start after YAML write

**Frontend**:
- `web/src/components/wizard/CreationWizard.tsx:120` — add `onDeploy?: () => void` to `CreationWizardProps`
- `web/src/components/wizard/CreationWizard.tsx:355,384` — pass a refresh function instead of `close` to `renderStepContent()`
- `web/src/components/layout/Header.tsx` — pass `onDeploy` callback (connected to polling `refresh()`) to `<CreationWizard>`

### Risk Factors

- Backend Option A (include config agents in status): Low risk, additive. Must ensure config-file read doesn't fail silently or add latency to the status endpoint.
- Backend Option B (trigger reconcile on append): Medium risk — depends on gateway reconcile stability and whether all agent runtimes support auto-start.
- Frontend fix: Very low risk — purely additive prop plumbing.

### Regression Test Outline

**Backend**:
- `TestHandleStackAppend_AgentAppearsInStatus`: Call `POST /api/stack/append` with an agent resource, then call `GET /api/status`, assert the new agent appears in `agents[]` (with any status)

**Frontend**:
- After wizard deploy, assert `useStackStore.getState().nodes` contains a node with id `agent-{name}` within one polling cycle
- Assert `onDeploy` callback is invoked with the correct function (not `close`)

## Recommendation

Fix immediately. The bug silently breaks the primary agent deploy workflow that PR #312 was intended to fix. The fix is two-part:

1. **Backend (primary)**: Modify `getAgentStatuses()` to also read agents from the stack config file and include any that aren't in the container/A2A lists with `status: "pending"`. This makes the canvas immediately reflect deployed agents regardless of runtime state. This is the recommended approach over triggering a reconcile, which has higher blast radius.

2. **Frontend (secondary)**: Wire a proper `onDeploy` prop through `Header → CreationWizard → renderStepContent → ReviewStep` that calls the polling `refresh()` function after successful deploy. This ensures the canvas refreshes immediately on deploy rather than waiting for the next polling interval.

## References

- PR #312: `https://github.com/gridctl/gridctl/pull/312` — fixed deploy button but left canvas rendering broken
- Affected commits: `4124321`, `34e7897`, `534e16e`, `ac81613`
