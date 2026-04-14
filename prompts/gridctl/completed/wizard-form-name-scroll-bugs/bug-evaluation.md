# Bug Investigation: Wizard Form Name Hyphen + Scroll Bugs

**Date**: 2026-04-10
**Project**: gridctl
**Recommendation**: Fix immediately
**Severity**: High (scroll blocker) + Medium (hyphen UX)
**Fix Complexity**: Trivial

## Summary

Two bugs in the Create wizard form affect all non-skill/non-secret resource creation. First, the name field strips hyphens on every keystroke, contradicting its own "Kebab-case identifier" hint. Second, the form panel cannot be scrolled when the YAML preview split-panel is open, blocking access to all fields below the fold. Both are trivial fixes with low risk.

## The Bug

### Bug 1: Hyphens stripped from name field

The name input in all three wizard forms (MCPServerForm, StackForm, ResourceForm) uses a `toKebabCase()` transformer on every keystroke via `onChange`. The final step of this transformer strips trailing hyphens with `.replace(/^-|-$/g, '')`. When a user types `test-stack`, the hyphen is always trailing at the moment it's typed, so it is immediately removed. The user sees `test` instead of `test-`. The field hint reads "Kebab-case identifier for this server," which implies hyphens should be accepted.

- **Expected**: Typing `test-stack` produces `test-stack`
- **Actual**: Typing `test-` immediately strips to `test`, making hyphenated names impossible

### Bug 2: Form panel cannot scroll

When the wizard shows a non-skill/non-secret form, the YAML preview panel appears and the layout switches to a horizontal `PanelGroup` from `react-resizable-panels`. The form content is placed inside:

```
Panel > div.h-full.overflow-y-auto
```

For `h-full` to create a scroll container, the `Panel` element must have an explicit, constrained height. In a horizontal `PanelGroup`, panels are flex/grid children and may not propagate an explicit pixel height down to the inner div. As a result, `overflow-y: auto` never activates. Fields below the fold (Environment & Secrets, Advanced) are inaccessible via scroll.

- **Expected**: Form panel scrolls when content exceeds panel height
- **Actual**: No scroll; content below fold is unreachable
- **Discovery**: User report during normal form usage

## Root Cause

### Bug 1: Defect Location

- `web/src/components/wizard/steps/MCPServerForm.tsx:162-164` — `toKebabCase()` function
- `web/src/components/wizard/steps/StackForm.tsx:36-38` — identical function
- `web/src/components/wizard/steps/ResourceForm.tsx:83-85` — identical function (approximate lines)

### Bug 1: Code Path

```
User types character in name input
  → onChange fires: onChange({ name: toKebabCase(e.target.value) })
  → toKebabCase:
      .toLowerCase()                   // fine
      .replace(/[^a-z0-9-]/g, '-')     // converts non-alphanumeric to hyphen
      .replace(/-+/g, '-')             // collapses multiple hyphens
      .replace(/^-|-$/g, '')           // ← strips leading/trailing hyphens
  → React controlled input re-renders with hyphen stripped
```

### Bug 1: Why It Happens

The trailing-hyphen strip is correct for the *final* value (e.g., prevent `test-` being saved) but is wrong to apply mid-typing. The user is always mid-typing when the hyphen is first entered, so it's always trailing and always stripped.

### Bug 2: Defect Location

- `web/src/components/wizard/CreationWizard.tsx:361-391` — PanelGroup/Panel layout for form step

### Bug 2: Code Path

```
CreationWizard renders showPreviewPanel path:
  PanelGroup orientation="horizontal" className="h-full"
    Panel defaultSize={55} minSize={40}
      div className="h-full overflow-y-auto scrollbar-dark px-6 py-4"
        MCPServerForm / StackForm / ResourceForm
```

### Bug 2: Why It Happens

`react-resizable-panels` v4 sizes panels via CSS flex/grid for width. The Panel element's height in a horizontal group is inherited from the PanelGroup via flex stretch. However, `h-full` on a child div inside the Panel may not resolve to the Panel's flex-computed height because the Panel itself may not have an explicit `height` CSS property — only a flex-based one. The result: `overflow-y: auto` sees either an unresolved `h-full` or a height larger than its container, and scroll never activates.

The non-preview path (`else` branch at line 393) renders the same div directly in the `flex-1 min-h-0` container and works correctly because `flex-1 min-h-0` is a proper flex child with established height.

### Similar Instances

Bug 1 (trailing hyphen strip) exists identically in all three form files:
- `MCPServerForm.tsx:164`
- `StackForm.tsx:38`
- `ResourceForm.tsx` (same pattern)

Bug 2 (scroll) affects all forms when `showPreviewPanel` is true — all resource types except skill and secret in the form step.

## Impact

### Severity Classification

- Bug 1: Incorrect behavior — validation logic contradicts the documented format
- Bug 2: Critical path blocker — fields below the fold are completely inaccessible without a workaround

### User Reach

All users creating any MCP Server, Stack, or Resource are affected by Bug 1. All users on the form step (with YAML preview visible) are affected by Bug 2.

### Workflow Impact

Bug 1: Every user who reads the "Kebab-case identifier" hint and tries to type a hyphenated name. Degraded UX; forces non-kebab workarounds.

Bug 2: Environment variables, Advanced configuration (network, output format, tool filtering, mTLS, etc.) are below the fold and unreachable via scroll. A user filling out a complete server configuration cannot access these sections without switching to YAML mode.

### Workarounds

- Bug 1: Type run-on names (`teststack` instead of `test-stack`). Ugly, but functional.
- Bug 2: Switch to YAML mode (expert mode toggle in header) or manually resize the split panel. Not obvious to new users.

### Urgency Signals

Both bugs affect the primary onboarding flow (creating your first MCP server/stack). They combine to create a particularly bad first-time experience: you can't type proper names AND you can't see advanced config fields.

## Reproduction

### Bug 1 — Minimum Reproduction Steps

1. Open the Create wizard
2. Select any resource type (MCP Server, Stack, or Resource)
3. Reach the form step (Identity section visible)
4. In the Name field, type `test-stack`
5. Observe: the hyphen disappears immediately on each keystroke; value shows `teststack` or `test` depending on cursor position

### Bug 2 — Minimum Reproduction Steps

1. Open the Create wizard
2. Select any non-skill, non-secret resource type
3. Reach the form step (YAML preview panel appears on the right)
4. Attempt to scroll the left form panel with mouse wheel or trackpad
5. Observe: form does not scroll; Advanced and Environment sections are unreachable

### Affected Environments

All platforms/browsers — Bug 1 is pure JS logic. Bug 2 is CSS layout behavior that affects all browsers consistently.

### Failure Mode

Bug 1: Input value snaps back on every hyphen keystroke. Deterministic.
Bug 2: Scroll events either do nothing or are absorbed without scrolling the form content. Deterministic.

## Fix Assessment

### Fix Surface

**Bug 1** — 3 files, identical change in each:
- `web/src/components/wizard/steps/MCPServerForm.tsx` (~line 162-164)
- `web/src/components/wizard/steps/StackForm.tsx` (~line 36-38)
- `web/src/components/wizard/steps/ResourceForm.tsx` (~line 83-85)

Change: don't strip trailing hyphens in `toKebabCase`. Move that cleanup to an `onBlur` handler, or use a separate `finalizeKebabCase` function called only on blur/submit.

**Bug 2** — 1 file:
- `web/src/components/wizard/CreationWizard.tsx` (~line 363-364)

Change: ensure the Panel has explicit `overflow: hidden` and height propagation so the inner scrollable div works. Options:
- Add `style={{ overflow: 'hidden' }}` to the `Panel` component
- Or restructure the Panel content div to not use `h-full` but instead use `flex: 1` with the Panel itself set as `display: flex; flex-direction: column`

### Risk Factors

- Bug 1 fix: None. The onChange transformer just needs to not strip trailing hyphens. The final validation/cleanup can still reject trailing hyphens on submission via the existing validation schema.
- Bug 2 fix: Low. The Panel layout change is isolated to the form step of CreationWizard. No data logic is affected.

### Regression Test Outline

**Bug 1**: In `MCPServerForm.test.tsx`, add a test that fires onChange with `test-` and verifies the value remains `test-` (trailing hyphen preserved mid-type). Verify that submitting `test-` still fails validation (if applicable).

**Bug 2**: Visual/integration test that the form panel is scrollable when YAML preview is open. Could be a Playwright/Cypress test that scrolls the panel and verifies content below fold becomes visible.

## Recommendation

Fix immediately. Both bugs are trivial (2-4 lines of code each) with zero risk. They directly impact the primary user workflow — creating resources — and combine to create a poor first-time experience. The hyphen bug is a 1-line fix per file (3 files). The scroll bug is a 1-2 line CSS/style addition. Both should be in the same PR.

## References

- `react-resizable-panels` v4 docs: overflow and scroll patterns for Panel content
- `web/src/__tests__/MCPServerForm.test.tsx` — existing kebab-case test to extend
- `web/src/__tests__/StackForm.test.tsx` — existing kebab-case test to extend
