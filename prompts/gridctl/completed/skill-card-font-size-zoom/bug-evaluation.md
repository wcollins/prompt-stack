# Bug Investigation: Skill Card Font Size Zoom

**Date**: 2026-04-14
**Project**: gridctl
**Recommendation**: Fix immediately
**Severity**: Low-Medium
**Fix Complexity**: Trivial

## Summary

The `+` and `−` font size controls on the Registry (Agent Skills) page are completely non-functional. The controls update internal state and set a CSS custom property correctly, but `SkillCard` text elements use hardcoded Tailwind size classes that never consume the variable. A 2-4 line change in `SkillCard.tsx` resolves the issue entirely.

## The Bug

**Description**: On the Registry page, the top-right font size adjuster (`— 17px +`) has no visible effect when clicked.

**Expected**: Clicking `+` or `−` increases or decreases the text size of skill card content (name, description, status badges).

**Actual**: Nothing changes. The pixel counter increments/decrements but card text stays fixed.

**Discovered**: User observation via screenshot.

## Root Cause

### Defect Location

`web/src/components/registry/SkillCard.tsx:93,100` — hardcoded Tailwind font-size classes on text elements.

### Code Path

1. User clicks `+` → `ZoomControls` fires `onZoomIn()` → `useLogFontSize` hook updates `fontSize` state → `fontSize` increments (display updates correctly ✓)
2. `DetachedRegistryPage.tsx:277` applies `style={{ '--log-font-size': `${fontSize}px` }}` to `<main>` container ✓
3. `SkillCard` renders text with `text-sm` (name, line 93) and `text-xs` (description, line 100) — both hardcoded Tailwind utilities that ignore `--log-font-size` ✗
4. `index.css:699` defines `.log-text { font-size: var(--log-font-size, 11px) }` — but this class is never applied to any SkillCard element ✗

### Why It Happens

When the Registry page was built, the font size control was wired up using the same `useLogFontSize` / `ZoomControls` infrastructure as the Logs page. However, the SkillCard component was styled with static Tailwind classes rather than the `.log-text` class that consumes the CSS variable. The control appears functional (state updates, counter changes) but has no downstream effect on rendered text.

### Similar Instances

- `TracesTab.tsx` uses `useTextZoom` with `--text-zoom-size`. If trace content elements don't apply `.text-zoom`, the same bug may exist there.
- All pages using `ZoomControls` should verify their content components apply the corresponding CSS class.

## Impact

### Severity Classification

Incorrect behavior — UI control is visually present and interactive but has zero effect. Not a crash, not data loss.

### User Reach

All users who visit the Registry page. This is a primary navigation destination for anyone managing skills.

### Workflow Impact

Non-blocking — users can still manage skills. The broken control creates confusion (the pixel counter moves but nothing changes) and makes the feature appear glitchy.

### Workarounds

None. Users cannot resize skill card text.

### Urgency Signals

Prominent, always-visible control that is fully broken. Low urgency (no security/data risk) but high visibility.

## Reproduction

### Minimum Reproduction Steps

1. Open gridctl web UI
2. Navigate to the Registry (Agent Skills) page
3. Click `+` or `−` in the font size control (top-right, shows `— 17px +`)
4. Observe: pixel counter changes but card text size does not change

### Affected Environments

All environments — deterministic, not platform-specific.

### Non-Affected Environments

N/A — reproduces 100% of the time everywhere.

### Failure Mode

State updates correctly, CSS variable is set on the container, but SkillCard text elements never read it. No errors thrown.

## Fix Assessment

### Fix Surface

- `web/src/components/registry/SkillCard.tsx` — replace hardcoded `text-sm`/`text-xs` on name and description with `log-text` class (and optionally scale badge sizes)

### Risk Factors

Very low. Change is isolated to one presentational component. No logic, no API, no state affected.

### Regression Test Outline

- Mount SkillCard inside a container with `--log-font-size: 20px` CSS variable set
- Assert the skill name element's computed `font-size` equals `20px`
- Assert the description element's computed `font-size` equals `20px`

## Recommendation

Fix immediately. The root cause is confirmed, the fix is 2-4 lines, and the risk is negligible. The control is prominently visible to all Registry users and is entirely non-functional. This should be included in the next release.

## References

- Working pattern: `web/src/pages/DetachedLogsPage.tsx` — uses `.log-text` class on log line content, zoom works correctly there
- CSS definition: `web/src/index.css:699` — `.log-text { font-size: var(--log-font-size, 11px) }`
- CSS variable set: `web/src/pages/DetachedRegistryPage.tsx:277`
