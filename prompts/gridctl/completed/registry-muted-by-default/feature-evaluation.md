# Feature Evaluation: Registry "Muted-by-Default" Color Hierarchy

**Date**: 2026-05-05
**Project**: gridctl
**Recommendation**: Build
**Value**: Medium-high
**Effort**: Small

## Summary

Refactor the Skills Registry dashboard styling to demote static metadata (the
`untested` badge, idle card borders, top accent line, utility icons, decorative
brand icons) from the loud orange/amber palette to neutral greys. Reserve the
brand orange for primary actions (`+ New Skill`), active selections (the
selected filter tab), and interactive feedback (card hover/focus). Small,
low-risk CSS-class refactor across ~6 files with no API or type changes.

## The Idea

The Skills Registry page currently uses primary orange (`#f59e0b`) and a near-
identical amber (`#fbbf24`) for both interactive elements *and* static metadata.
The result: every card screams for attention, the visual hierarchy flattens,
and the user can't quickly distinguish "click here" from "this is just a label."

The proposed fix is a "muted-by-default" strategy:

- Status badges that are *neutral information* (`untested`) become quiet grey.
- Card borders/icons stay neutral until the user hovers or focuses them.
- Filter tabs ghost-style when inactive; only the active tab carries weight.
- The `+ New Skill` button keeps its primary-orange treatment because it *is* a
  primary action.

Beneficiary: anyone scanning the Skills Registry — fewer competing color blocks
means faster recognition of the few elements that actually matter.

## Project Context

### Current State

- The frontend is a React + TypeScript SPA at `web/`.
- Tailwind CSS v4 with `@theme` tokens defined in `web/src/index.css` and the
  Tailwind class palette in `web/tailwind.config.js`.
- Design system is named "Obsidian Observatory" — a dark theme with warm amber
  as the primary brand color.
- No external component library; primitives (Button, IconButton, Badge) live in
  `web/src/components/ui/`.
- The Skills Registry has two surfaces that share the same badge / action
  components:
  - **Detached dashboard** (`web/src/pages/DetachedRegistryPage.tsx`) — the
    full-page card grid the user screenshotted.
  - **Sidebar** (`web/src/components/registry/RegistrySidebar.tsx`) — the
    embedded list view.

### Integration Surface

| File | Role |
|------|------|
| `web/src/components/registry/TestStatusBadge.tsx` | The `untested` / `passing` / `failing` pill — primary target |
| `web/src/components/registry/SkillCard.tsx` | Per-skill card: borders, top accent line, internal book icon |
| `web/src/components/registry/StateBadge.tsx` | The `active` / `draft` / `disabled` pill — already restrained, light touch only |
| `web/src/components/registry/SkillActions.tsx` | Trash / edit / power icon cluster |
| `web/src/components/ui/IconButton.tsx` | Icon button primitive — `ghost` variant defaults are mostly fine |
| `web/src/pages/DetachedRegistryPage.tsx` | Header (`+ New Skill`, library icon), search bar, filter tabs |
| `web/src/components/registry/RegistrySidebar.tsx` | Same patterns; verify changes flow through cleanly |

### Reusable Components

The badge and action components are already shared between the dashboard and
sidebar — single edits propagate to both surfaces. No need to duplicate.

## Market Analysis

Skipped per user direction (Path A: compressed scout). The brief is a concrete,
prescriptive design solution rather than an open exploration; market research
would not change the requirements. Modern dark dashboards (Linear, Vercel,
GitHub Projects) all follow some variant of "muted-by-default with accent
reservation" — the proposal is in line with prevailing convention.

## User Experience

### Interaction Model

No change to user workflows. The features (filter, search, hover, edit, delete,
toggle, create) all behave identically. What changes is *visual weight*: less
ambient orange noise, so the eye can find the few elements that demand action.

### Workflow Impact

- **Scanning the grid**: faster — the eye is no longer pulled to every card
  equally; the title (white, high-contrast) becomes the genuine entry point.
- **Distinguishing states**: clearer — `failing` (rose) and `passing`
  (emerald) read as semantically meaningful because they're no longer
  competing with `untested` for attention.
- **Finding the primary action**: easier — `+ New Skill` is the only orange
  block in the toolbar, so it gets the visual priority it deserves.

### UX Recommendations

- Keep the active filter tab visibly orange (it conveys current state). The
  brief already specifies this.
- Don't fully strip the brand color from the header — the small `Library` icon
  in `bg-primary/10` is a brand cue, not a status signal. Leave or only gently
  reduce.
- Card hover/focus must remain noticeably orange so interactivity stays
  discoverable.

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Significant | Affects every interaction with the Registry — a core surface |
| User impact | Broad+Shallow | Every user every visit; small per-visit gain that compounds |
| Strategic alignment | Core | Visual polish of a flagship surface; feeds directly into product feel |
| Market positioning | Maintain | Brings gridctl in line with modern dark-UI convention; not differentiating, but the current treatment is conspicuously off-trend |

### Cost Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Minimal | Class-string changes in 6 files; no logic changes |
| Effort estimate | Small | A focused 1-2 hour pass plus visual QA on both surfaces |
| Risk level | Low | No API, no types, no state; worst case is rolled-back styling |
| Maintenance burden | Minimal | Reduces ad-hoc per-element color choices; pushes toward a stricter token contract |

## Recommendation

**Build.** This is the cheapest, most-impactful UI change available right now —
a self-contained styling pass with no architectural cost. Two clarifications
worth knowing before implementation:

1. **The "untested" badge is `amber-400`, not the brand `primary`.** The brief
   reads as if the badge uses the brand orange, but the code (`TestStatusBadge.tsx:33`)
   uses `text-amber-400/80 bg-amber-400/8 border-amber-400/20`. Visually they're
   close enough that the user perception is correct — both register as a "loud
   warm tone." The fix is the same; just don't be surprised when grep'ing for
   `primary` doesn't find the badge.

2. **`failed` already uses `rose-400`, not orange.** The brief says "Orange
   should be reserved for Failed states." That's already true today — `failed`
   uses rose; nothing to change there. The actual cleanup is just demoting
   `untested` to neutral grey.

The implementation prompt at `feature-prompt.md` contains the precise class
swaps and the verification checklist for both surfaces.

## References

- Design tokens: `web/src/index.css` (`@theme` block, lines 4–67)
- Tailwind palette: `web/tailwind.config.js`
- Source brief: user-provided UI Refinement Brief (2026-05-05)
