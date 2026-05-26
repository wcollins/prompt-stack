# Bug Investigation: Wizard Card Gating Bypass

**Date**: 2026-04-15
**Project**: gridctl
**Recommendation**: Fix immediately
**Severity**: High
**Fix Complexity**: Trivial

## Summary

In stackless mode (`gridctl serve`), the wizard's resource type selection screen fails to gate the MCP Server and Resource cards. All five cards appear at full opacity, show no hover tooltip, and clicking disabled card types navigates forward instead of blocking. The root cause is a single wrong condition in `CreationWizard.tsx` — `connectionStatus === 'connected'` is used where `connectionStatus === 'connected' && gatewayInfo !== null` is required. The correct pattern already exists in `Canvas.tsx`.

## The Bug

**Expected behavior** (per `proto/walkthrough.md` Phase 4.3):
- MCP Server and Resource cards should be dimmed at `opacity-40` with `cursor-not-allowed`
- Hovering either disabled card shows tooltip: `"Requires an active stack — create a Stack first"`
- Clicking a disabled card does nothing — wizard stays on type selection screen

**Actual behavior** (observed in `gridctl serve` mode):
- All 5 cards appear identical — no opacity difference
- Hovering MCP Server card shows no tooltip
- Clicking MCP Server card advances the wizard to template selection

**Discovered by**: Manual UX testing in stackless mode.

## Root Cause

### Defect Location

`web/src/components/wizard/CreationWizard.tsx:523`

```tsx
// WRONG
const hasActiveStack = connectionStatus === 'connected';
```

### Code Path

1. `./gridctl serve` starts — no stack loaded, `gatewayInfo` remains `null`
2. UI polls `/api/status` — succeeds (API server is running)
3. `setGatewayStatus()` fires → sets `connectionStatus = 'connected'` at `useStackStore.ts:91`
4. `TypePicker` evaluates `hasActiveStack = connectionStatus === 'connected'` → `true`
5. `isGated = STACK_GATED_TYPES.includes(rt.type) && !hasActiveStack` → `false` for all cards
6. No dimming, no tooltip, no click guard applied

### Why It Happens

`connectionStatus === 'connected'` indicates the browser successfully reached the API, not that a stack is loaded. In stackless mode, the API still runs and responds, so `connectionStatus` becomes `'connected'` — but `gatewayInfo` stays `null` because no stack is active. The missing `&& gatewayInfo !== null` check makes the gating logic always evaluate as "stack is active."

### Reference Implementation

`Canvas.tsx:169` already uses the correct two-condition check:
```tsx
const hasActiveStack = connectionStatus === 'connected' && gatewayInfo !== null;
```

### Similar Instances

No other gating logic in the codebase uses the wrong single-condition pattern. This is an isolated regression.

## Impact

### Severity Classification

High — Incorrect behavior that bypasses an intentional UX safety gate. Users can navigate into MCP Server or Resource creation without a stack, which is undefined workflow territory.

### User Reach

All users running `gridctl serve` (stackless mode) who open the wizard. This is the primary recommended entry point for new users.

### Workflow Impact

Core path blocker for the "create first stack" onboarding flow. The gating is a deliberate design requirement ensuring users create a Stack before adding MCP Servers or Resources.

### Workarounds

None available. There is no way to achieve the intended gating behavior without the code fix.

### Urgency Signals

The feature was shipped as part of the stackless mode PR (feat: wizard gating and UX polish #461) but the implementation has a logic error. The walkthrough explicitly tests this behavior.

## Reproduction

### Minimum Reproduction Steps

1. `make build && ./gridctl serve`
2. Open `http://localhost:8180`
3. Click `+` to open wizard
4. Observe: all 5 cards at same opacity (no dimming on MCP Server / Resource)
5. Hover over MCP Server card: no tooltip appears
6. Click MCP Server card: navigates to template step (should block)

### Affected Environments

- `gridctl serve` (stackless mode) — any platform

### Non-Affected Environments

- `gridctl apply <stack.yaml>` — `gatewayInfo` is non-null after load, so `connectionStatus === 'connected'` coincidentally works correctly (gating not needed anyway when stack is active)

### Failure Mode

System remains in a recoverable state — no data corruption. UX-only impact.

## Fix Assessment

### Fix Surface

Single file, single line addition:
- `web/src/components/wizard/CreationWizard.tsx:522-523`

### Risk Factors

None. The fix mirrors an already-working pattern in the same codebase.

### Regression Test Outline

Manual (no automated test framework for UI in this project):
1. `gridctl serve` → open wizard → verify MCP Server and Resource cards are dimmed
2. Hover over each → verify tooltip text appears
3. Click each → verify wizard does not advance
4. `gridctl apply <stack.yaml>` → open wizard → verify all 5 cards are enabled and clickable

## Recommendation

Fix immediately. The bug is a trivial one-line correction with zero risk, the correct pattern already exists in `Canvas.tsx:169`, and the broken behavior directly contradicts the documented test walkthrough for a core user flow.

## References

- `proto/walkthrough.md` Phase 4.3 — specifies the expected gating behavior
- `web/src/components/graph/Canvas.tsx:169` — correct reference implementation
- PR #461: feat: wizard gating and UX polish — introduced the gating feature
