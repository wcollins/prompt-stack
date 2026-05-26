# Feature Evaluation: Topology Focus-First Styling Pass

**Date**: 2026-05-05
**Project**: gridctl
**Recommendation**: Build with caveats
**Value**: Medium-High
**Effort**: Small (~half-day)

## Summary

A visual refinement pass on the Topology view to extend the muted-by-default
hierarchy established in PR #559 (Skills Registry). Strategic intent is sound and
the underlying selection/dim infrastructure already exists in `usePathHighlight`
and the Zustand `selectedNodeId` store. However, three of the four specific values
in the original brief (40% brand-color borders, "reduced" edge stroke-opacity,
muted-yet-functional badges) fail WCAG SC 1.4.11 contrast minimums against the
near-black canvas. Build, but with revised values that preserve the aesthetic
intent while clearing accessibility.

## The Idea

Apply a "Focus-First" styling pass to the Topology view so the user's eye is drawn
immediately to the selected node while background nodes stay quiet but visible.
Specifically:

1. **Node borders** — default opacity dropped (brief: 40%); selected node goes to
   100% with an outer glow.
2. **Edges** — dashed connecting paths reduced in stroke-opacity to make nodes the
   primary focus.
3. **Status badges** — "Linked" and "Running" unified with the low-profile badge
   style introduced in the Skills Registry refactor.
4. **Internal metrics** — Gateway card icons dimmed to 70% so the white numerical
   values become the primary read.

**"Active" was clarified by the user** as the *currently selected* node
(click-to-focus). Status badges (Gateway Active, Running) are functional and not
focus-related. Live traffic indication via edge animation is out of scope.

**Problem it solves**: The current Topology view has a flat visual hierarchy —
borders, badges, and edges all compete at similar saturation. There is no visual
cue for which node matters at a given moment. PR #559 set the design direction;
this extends it into the topology surface.

## Project Context

### Current State

The frontend lives in `web/` and is built with React 19 + TypeScript + Tailwind
CSS v4 + `@xyflow/react` v12. Styling is pure Tailwind (no CSS-in-JS), state is
Zustand, and there is a tokenized "Obsidian Observatory" theme in
`web/tailwind.config.js` with semantic colors (primary amber, secondary teal,
tertiary purple, status running/stopped/error/pending) and predefined glow
shadows (`shadow-glow-primary`, `shadow-glow-secondary`, `shadow-glow-tertiary`).

The Topology view is rendered by `web/src/components/graph/Canvas.tsx` and uses
five node types: `GatewayNode`, `ClientNode`, `CustomNode` (MCP servers and
resources), `SkillNode`, and `SkillGroupNode`. Selection is wired through
XYFlow's `selected` prop and the `useStackStore` `selectNode(id)` action.

### Integration Surface

A small set of files carries this work:

- `web/src/components/graph/GatewayNode.tsx` — Gateway card; metric icons; "Gateway Active" badge.
- `web/src/components/graph/ClientNode.tsx` — Claude Desktop / Code / Gemini CLI nodes; "Linked" badge.
- `web/src/components/graph/CustomNode.tsx` — MCP server cards (atlassian/github/gitlab/zapier); "Running" badges.
- `web/src/components/graph/Canvas.tsx` — edge `defaultEdgeOptions`, click-to-select handler.
- `web/src/index.css` — `.react-flow__edge-path`, `.dimmed`, `.highlighted`, energy-flow keyframes.
- `web/tailwind.config.js` — color tokens, predefined glows; possible home for a "muted-default" border utility.

### Reusable Components Already in Place

This is critical context: **most of the focus-first system already exists**.

- ✅ Selection state: `selectedNodeId` in `useStackStore`, click handler in `Canvas.tsx:153–157`.
- ✅ Per-node selected styling: `border-primary shadow-glow-primary ring-2 ring-primary/20` in `GatewayNode.tsx:24`, `ClientNode.tsx:26`, similar in `CustomNode.tsx:54–66`.
- ✅ Path highlighting that dims unrelated nodes/edges: `usePathHighlight` hook applies `.highlighted` (z-index lift) and `.dimmed` (opacity 0.25 nodes / 0.15 edges).
- ✅ Predefined glow utilities in `tailwind.config.js`.
- ✅ Hover brightening: `hover:shadow-node-hover`, `hover:border-primary/40`.
- ✅ A muted-by-default badge precedent: `TestStatusBadge.tsx`, `StateBadge.tsx`, `SkillCard.tsx`.

What this feature actually adds is a **policy change**: the *idle* state should
look closer to the "another node is selected" state, with the selected node
becoming the only fully-saturated element on screen.

## Market Analysis

### Competitive Landscape

| Tool | Idle border | Selected treatment |
|---|---|---|
| xyflow stock (CSS variables) | full opacity | 0.5px box-shadow ring |
| n8n (Vue Flow) | full opacity | 2px solid accent ring |
| Cytoscape demos | full opacity | 2–4px border + saturated color |
| Obsidian Graph (focus mode) | ~15–25% (only when focused) | full opacity |
| **This proposal (literal brief)** | **40% always** | **full + outer glow** |

### Market Positioning

- **Selection glow** → mainstream. Every framework above either ships it or shows
  it as the canonical extension.
- **Always-on muted idle borders** → unusual. Production graph tools keep idle
  nodes at full opacity and dim *in response to* a selection event. Obsidian's
  always-on focus mode is the closest precedent and is itself a feature-request
  flashpoint (forum threads requesting more control over the dim alpha).
- The codebase **already** implements the conventional pattern via
  `usePathHighlight` + `.dimmed`. The brief moves the baseline closer to
  Obsidian's stylistic muted-default.

### Ecosystem Support

No new library needed. xyflow's CSS-variable theming, Tailwind's opacity scale,
and the existing glow shadow utilities cover everything. Badge primitive
question: mature design systems (Radix, shadcn/ui, Primer, Carbon, MUI) all
expose a `subtle | solid` axis, but Tailwind orthodoxy (Wathan, shadcn) is to
build with utilities first and abstract on the second use, which is right for
this case.

### Demand Signals

Single-author (William, repo owner) preference, continuous with PR #559. No
external user request thread visible. This is a design polish initiative, not a
demand-driven feature.

## User Experience

### Interaction Model

Selection already exists (click any node → `selectNode(id)` → opens sidebar). No
new interaction is introduced. This is a visual policy change layered over an
existing behavior.

### Workflow Impact

The productive conflict in the brief: *Focus-First aesthetic* (mute everything by
default) pulls against *status legibility* (a developer scanning the topology to
spot a stopped server, broken link, or error needs status to remain immediately
readable, even when nothing is selected). The brief threads this needle by
declaring status badges remain functional, but does not distinguish between
"steady-state-good" badges (Linked / Running / Gateway Active) and abnormal-state
badges (error / stopped / pending). The Registry already makes this distinction
implicitly: `TestStatusBadge` mutes `untested` and keeps `passing` / `failing`
saturated. The Topology pass should follow the same rule.

### UX Recommendations

1. Use a **neutral idle border** (`border-white/[0.10]` or the existing
   `--color-border` `#27272a`) at full opacity instead of "brand color at 40%."
   Reserve amber/teal/purple for selected. Same muted feel; contrast clears 3:1;
   the selection delta becomes more dramatic (color *appears*, not just brightens).
2. Keep the existing `.dimmed { opacity: 0.25 }` for "another node is selected" —
   already implemented, conventional, conceptually distinct from idle.
3. Edges at rest: keep at full opacity using existing `--color-border`. If a
   softer feel is wanted, prefer dash gap or stroke width changes over alpha.
4. Selection delta: add a non-color signal (border width 1→2 or ring-1→ring-2)
   to satisfy SC 2.4.13.
5. Mute only steady-state-good status badges. Keep error/stopped/pending saturated.
6. Add `prefers-reduced-motion` guard if any hover involves shadow size growth.

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|---|---|---|
| Problem significance | Significant | Real annoyance on every session, not a critical bug |
| User impact | Broad + Shallow | All users see it; cost of not doing it is low |
| Strategic alignment | Core | Direct extension of PR #559 muted-by-default direction |
| Market positioning | Maintain | Selection glow is mainstream; muted-default is stylistic differentiator |

### Cost Breakdown

| Dimension | Rating | Notes |
|---|---|---|
| Integration complexity | Minimal | Selection, dim infra, glow utilities, opacity scale all exist |
| Effort estimate | Small | Half day; ~5 component files + index.css |
| Risk level | Medium | Brief's literal values fail WCAG 1.4.11; mitigated entirely by the revised values |
| Maintenance burden | Minimal | Same component surface, same patterns |

### Accessibility Findings (the load-bearing constraint)

Computed against the actual surface palette:

- Amber `#f59e0b` border @ 40% opacity on `#08080a`: **2.29:1** — fails 3:1.
- Emerald `#10b981` @ 40%: **2.09:1** — fails 3:1.
- Both colors need ≥55% opacity to clear 3:1.
- Dashed edges at "reduced" stroke-opacity (30–40%) also fail; W3C's 1.4.11
  Understanding doc explicitly cites diagram connector lines as required-to-
  understand graphics.
- Selection delta as color/contrast change *only* is a documented WCAG common
  failure (SC 2.4.7 / 2.4.13).
- Icon dim @ 70% on `bg-primary/10` panel: **4.68:1** — passes. Safe to ship.

Sources:

- W3C Understanding SC 1.4.11: https://www.w3.org/WAI/WCAG21/Understanding/non-text-contrast.html
- W3C Understanding SC 2.4.13 (WCAG 2.2): https://www.w3.org/WAI/WCAG22/Understanding/focus-appearance.html
- WebAIM Contrast Checker: https://webaim.org/resources/contrastchecker/

## Recommendation

**Build with caveats.** The intent is right and the codebase is positioned to
absorb it cheaply. Ship the implementation with revised values:

- Idle borders → neutral (`border-white/[0.10]` or `border-border/60`) at full
  opacity, **not** brand color at 40%.
- Edge stroke at rest → keep `--color-border` at full opacity; do not stack alpha
  reductions on top.
- Selection delta → add a non-color cue (border-width 1→2 *or* ring-1→ring-2).
- Gateway icons → 70% as stated. Ship.
- Badges → inline-class match Registry recipe; do **not** extract a shared
  primitive yet (premature abstraction with only two consumers). Mute only
  steady-state-good states; keep abnormal states saturated.
- Add `prefers-reduced-motion` guard for any size-growing shadow on hover.

If the user reverts to the literal 40% brand-color borders, this becomes a "Skip"
because shipping it would regress contrast from the current 25% **pure border
color tokens** (which, while also low, do not advertise "primary brand color" to
sighted users in a way that implies it should be readable).

## References

- W3C Understanding SC 1.4.11 Non-text Contrast — https://www.w3.org/WAI/WCAG21/Understanding/non-text-contrast.html
- W3C Understanding SC 2.4.13 Focus Appearance — https://www.w3.org/WAI/WCAG22/Understanding/focus-appearance.html
- W3C C40 Two-color focus indicator — https://www.w3.org/WAI/WCAG21/Techniques/css/C40
- WebAIM contrast checker — https://webaim.org/resources/contrastchecker/
- Sara Soueidan, Designing accessible focus indicators — https://www.sarasoueidan.com/blog/focus-indicators/
- xyflow theming docs — https://reactflow.dev/learn/customization/theming
- xyflow Turbo Flow example — https://reactflow.dev/examples/styling/turbo-flow
- xyflow selection discussion — https://github.com/xyflow/xyflow/discussions/4648
- n8n canvas architecture (DeepWiki) — https://deepwiki.com/n8n-io/n8n/6.2-workflow-canvas-and-node-management
- Cytoscape view-utilities — https://github.com/iVis-at-Bilkent/cytoscape.js-view-utilities
- Cytoscape selection styling — https://github.com/cytoscape/cytoscape.js/issues/967
- Obsidian graph view — https://obsidian.md/help/plugins/graph
- Tailwind reusing styles — https://tailwindcss.com/docs/reusing-styles
- Kent C. Dodds, AHA Programming — https://kentcdodds.com/blog/aha-programming
- Radix Themes Badge — https://www.radix-ui.com/themes/docs/components/badge
- shadcn/ui Badge — https://ui.shadcn.com/docs/components/badge
- gridctl PR #559 (muted-by-default Skills Registry) — local commit d74d9d6
