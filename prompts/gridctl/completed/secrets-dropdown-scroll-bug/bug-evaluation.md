# Bug Investigation: Secrets Dropdown Scroll Bug

**Date**: 2026-04-11
**Project**: gridctl
**Recommendation**: Fix immediately
**Severity**: Medium-High
**Fix Complexity**: Small

## Summary

The secrets selection popover in the StackForm env var section cannot be scrolled, making vault secrets below the first ~6 entries inaccessible. The regression was introduced by PR #435, which added `overflow-y: auto` to the form panel — causing the absolutely-positioned popover to be clipped at the panel boundary. A secondary issue (`overflow-hidden` on the popover's outer container) also clips the inner scroll list.

## The Bug

**Wrong behavior**: When clicking the key icon (🔑) in an env var row to select a vault secret, the dropdown opens but cannot be scrolled. Secrets beyond those fitting in the visible area are inaccessible.

**Expected behavior**: The dropdown should scroll to reveal all available secrets.

**Discovery**: Directly reproduced by user while configuring a new MCP server with existing vault secrets.

## Root Cause

### Defect Location

- Primary: `web/src/components/wizard/CreationWizard.tsx:365` — form panel `overflow-y: auto` clips the popover
- Secondary: `web/src/components/wizard/SecretsPopover.tsx:102` — `overflow-hidden` on outer popover container clips inner scroll list

### Code Path

1. User opens the StackForm configure step
2. User adds an env var row and clicks the 🔑 key icon
3. `SecretsPopover` renders its dropdown as `position: absolute` (`right-0 top-full`)
4. The nearest scroll container ancestor is `CreationWizard.tsx:365` — `flex-1 overflow-y-auto scrollbar-dark`
5. CSS spec: `position: absolute` elements inside `overflow: auto` containers are clipped to that container's visible area
6. When the popover trigger is near the bottom of the form panel, the dropdown extends below the clipping boundary and is cut off
7. Even when partially visible, `overflow-hidden` on the popover outer div (line 102) clips the `max-h-36 overflow-y-auto` inner list's scrollbar interaction area

### Why It Happens

PR #435 ("fix: wizard form name hyphen stripping and panel scroll #435") restructured the form panel to use `overflow-y: auto` for scrolling. This is correct for the panel itself, but floating/absolute-positioned children like `SecretsPopover` were not updated to escape the new scroll container via a React Portal. The `overflow-hidden` issue on line 102 existed before but was less noticeable without the panel scroll boundary.

### Similar Instances

Any other `position: absolute` dropdowns rendered inside the same scrollable form panel would have the same clipping problem. No other instances confirmed in the current codebase, but the `KeyValueEditor` pattern is used across multiple form types.

## Impact

### Severity Classification

UX regression / Incorrect behavior. Not a crash or data loss, but blocks a primary feature workflow.

### User Reach

All users who use vault secrets in env var configuration. Any user with more than ~6 secrets, or whose popover trigger is positioned near the bottom of the form panel, hits this bug.

### Workflow Impact

Common path blocker — env vars + vault secrets is a primary configuration workflow for MCP servers.

### Workarounds

Manually type `${vault:SECRET_KEY}` into the value field if the key name is known. Inadequate — defeats the purpose of the secrets selector, and requires users to know key names exactly.

### Urgency Signals

Directly reported by user; regression introduced by the most recent UI PR (#435). No monitoring signal since this is a UI interaction bug.

## Reproduction

### Minimum Reproduction Steps

1. Open the New MCP Server wizard
2. Navigate to the Configure step (StackForm)
3. Scroll down to the Environment Variables section
4. Add an env var row
5. Click the 🔑 key icon on the value field
6. Attempt to scroll within the secrets dropdown

### Affected Environments

All environments — deterministic, browser-independent. Requires at least 2 vault secrets to trigger, or the popover trigger must be near the bottom of the panel.

### Non-Affected Environments

None identified. Would not reproduce if the form panel had no `overflow-y: auto` constraint (pre-PR #435 behavior).

### Failure Mode

The dropdown is clipped at the form panel's scroll boundary. The inner `max-h-36 overflow-y-auto` scroll list also has its scrollbar clipped by the outer `overflow-hidden` container, making the content unreachable even if the popover is fully visible.

## Fix Assessment

### Fix Surface

- `web/src/components/wizard/SecretsPopover.tsx` — main fix location (Portal + overflow-hidden removal)
- No changes needed to `CreationWizard.tsx`

### Risk Factors

- React Portal changes the DOM mount point, which could affect outside-click detection (the current `mousedown` handler uses `popoverRef`). Must verify the close-on-outside-click behavior still works after portaling.
- Portal requires correct absolute positioning based on the trigger's `getBoundingClientRect()` rather than CSS `top-full right-0`.

### Regression Test Outline

- Test: SecretsPopover renders with many secrets, all are reachable via scroll
- Test: Popover positioned near bottom of a scroll container still renders fully visible
- Test: Outside click closes popover when rendered via Portal

## Recommendation

**Fix immediately.** The fix is small (one component, ~30 lines changed), low-risk when scoped correctly, and directly unblocks a primary user workflow. Two parts:

1. **Remove `overflow-hidden` from the outer popover container** (`SecretsPopover.tsx:102`) — keep `rounded-xl` for styling, clip the header/footer areas individually if needed.
2. **Render the dropdown via a React Portal** at `document.body` — this escapes the `overflow-y: auto` form panel and eliminates viewport clipping. Position using `getBoundingClientRect()` on the trigger button ref.

The Portal approach is the correct architectural solution for floating UI elements inside scroll containers.

## References

- PR #435: "fix: wizard form name hyphen stripping and panel scroll" — introduced the `overflow-y: auto` form panel that exposed this bug
- CSS spec: https://www.w3.org/TR/CSS22/visufx.html#overflow — `overflow` applies to absolute children within the same stacking context
- Floating UI library (alternative): https://floating-ui.com — handles Portal + positioning automatically if the team wants a longer-term solution
