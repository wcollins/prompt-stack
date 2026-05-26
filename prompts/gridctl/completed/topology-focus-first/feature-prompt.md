# Feature Implementation: Topology Focus-First Styling Pass

## Context

`gridctl` is an MCP gateway with a React-based dashboard at `web/`. The dashboard
visualizes the topology of clients (Claude Desktop, Claude Code, Gemini CLI), the
central `gridctl-gateway`, and downstream MCP servers (atlassian, github, gitlab,
zapier) using `@xyflow/react` v12.

**Stack**:
- React 19 + TypeScript + Vite
- Tailwind CSS v4 (no CSS-in-JS, no CSS modules)
- `@xyflow/react` v12 for the topology graph
- Zustand for state (`useStackStore`, `useUIStore`, `usePlaygroundStore`)
- Vitest + React Testing Library

**Design system** (the "Obsidian Observatory" theme, defined in `web/tailwind.config.js`
and mirrored as CSS custom properties in `web/src/index.css`):
- Background: `#08080a` (near black)
- Surface: `#111113`, surface-elevated: `#18181b`, surface-highlight: `#1f1f23`
- Primary (amber): `#f59e0b` — energy, activity, attention
- Secondary (teal): `#0d9488` — technical, data
- Tertiary (purple): `#8b5cf6` — agents, AI
- Status running (emerald): `#10b981`
- Predefined glow shadows: `shadow-glow-primary`, `shadow-glow-secondary`, `shadow-glow-tertiary`
- Predefined node shadows: `shadow-node`, `shadow-node-hover`

## Evaluation Context

This implementation is a **refinement pass** on an existing system, not new
infrastructure. The full evaluation lives at
`<prompts-dir>/topology-focus-first/feature-evaluation.md`.

Key findings that shaped the requirements below:

- **Selection state and dim infrastructure already exist.** The Zustand store
  (`useStackStore.selectNode(id)`), XYFlow's `selected` prop, and the
  `usePathHighlight` hook (which applies `.highlighted` and `.dimmed` classes via
  `index.css`) are wired up. Do not rebuild these — extend them.
- **The original brief specified 40% brand-color borders. This fails WCAG SC
  1.4.11.** Amber at 40% opacity on `#08080a` clears only 2.29:1 contrast (3:1
  is required for UI boundaries). Emerald is worse at 2.09:1. The implementation
  uses a **neutral idle border at full opacity** instead, which preserves the
  muted aesthetic without the contrast regression.
- **Selection deltas that rely only on color/contrast change are a documented
  WCAG common failure (SC 2.4.7 / 2.4.13).** A non-color signal must accompany
  the color shift on selected nodes — typically a border-width change.
- **No shared `<Badge>` primitive should be extracted yet.** Two consumers is
  premature abstraction (Tailwind / Wathan / shadcn philosophy: build with
  utilities first, abstract on the second use). Mirror the Registry's classes
  inline in Topology now; revisit extraction when a third or fourth muted call
  site emerges.
- **PR #559** (commit `d74d9d6`, "refactor: muted-by-default color hierarchy for
  Skills Registry") is the design reference. Read it before starting.

## Feature Description

Apply a Focus-First styling pass to the Topology view so that the user's eye is
drawn immediately to the *selected* node while background nodes stay quiet but
visible. Extend the muted-by-default direction set by PR #559 from the Skills
Registry into the Topology surface.

The four areas of change:

1. **Node borders** — idle nodes use a neutral, full-opacity border instead of
   the current brand-color-at-25% pattern. Selected nodes get a brighter border,
   thicker stroke, and existing glow.
2. **Edges** — connecting paths stay structurally visible at rest using the
   existing `--color-border` token; dimmed edges (when something is selected)
   continue to use the existing `.dimmed` opacity reduction.
3. **Status badges** — "Linked" (in `ClientNode`) and the various "Running"
   indicators in `GatewayNode` and `CustomNode` are unified to match the
   Registry's muted recipe. Steady-state-good badges are muted; abnormal-state
   badges (error/stopped/pending) keep their saturation.
4. **Gateway metric icons** — drop to 70% opacity so the white numerical values
   are the primary read.

## Requirements

### Functional Requirements

1. **Idle node border** — replace the current `border-primary/25`,
   `border-secondary/25`, `border-tertiary/25` (etc.) idle treatments in
   `GatewayNode.tsx`, `ClientNode.tsx`, `CustomNode.tsx`, `SkillNode.tsx`, and
   `SkillGroupNode.tsx` with a single neutral idle border. Recommended:
   `border-white/[0.10]` (or define a `border-idle` token in `tailwind.config.js`
   if you prefer). Border at full opacity.
2. **Selected node border** — keep the existing brand-colored border + glow +
   ring on selection (`border-primary shadow-glow-primary ring-2 ring-primary/20`
   for Gateway/Client; the equivalent for other node types). Add a non-color
   signal: increase border thickness from 1px to 2px on the selected state, OR
   bump `ring-1` to `ring-2` where it isn't already at 2.
3. **Hover state** — keep `hover:shadow-node-hover`. Adjust hover border to
   foreshadow the selected color at lower intensity, e.g.
   `hover:border-primary/50` (passes contrast at 50% on `#08080a`: amber clears
   3.0:1 around 50%). Verify with a contrast checker.
4. **Edges at rest** — leave `.react-flow__edge-path` styling in `index.css` as
   it is (`stroke: var(--color-border)`, `stroke-width: 1.5px`). Do **not** add
   alpha multipliers on top — `--color-border` (`#27272a`) is already a quiet
   structural color. If a softer feel is requested in review, change dash
   geometry (`stroke-dasharray`) before reducing alpha.
5. **Animated/highlighted edges** — leave the existing energy-flow animation
   and `.highlighted` / `.dimmed` opacity rules unchanged. They already work.
6. **Status badge unification** — update inline badge spans in
   `ClientNode.tsx` (the "Linked" span around line 88) and `GatewayNode.tsx` (the
   "Gateway Active" span around lines 155–159) to match the Registry recipe:
   - Background: `bg-{tone}/10` (e.g., `bg-emerald-400/10` or `bg-status-running/10`)
   - Border: `border border-{tone}/25` (or `/20`, matching the existing
     `TestStatusBadge` / `StateBadge` exactly)
   - Text: `text-{tone}` (e.g., `text-emerald-400`)
   - Size: `text-[10px]`, `px-1.5 py-0.5`, `rounded`
   - **Verify against** `web/src/components/registry/StateBadge.tsx` and
     `TestStatusBadge.tsx` — match those classes exactly so the two surfaces look
     identical.
7. **"Running" badges in MCP server nodes** (`CustomNode.tsx`) — same treatment.
8. **Gateway metric icons** — in `GatewayNode.tsx`, the icons inside each stat
   row (Server, Sessions, Clients, etc., wrapped in `bg-primary/10 border
   border-primary/20` containers) currently render at full opacity via
   `text-primary`. Drop the icon's effective opacity to 70%. Implementation
   options (pick one and apply consistently):
   - Add `opacity-70` to the icon element directly.
   - Use `text-primary/70` on the icon.
   The numerical value next to each icon stays at full opacity (`text-text-primary`).
9. **Steady-state-good vs abnormal badge tones** — the muting only applies to
   "everything is fine" badges. Wherever a badge represents an abnormal state
   (`error`, `stopped`, `pending`, "Disconnected", "Failed"), keep the existing
   saturated treatment. Mirror the Registry: `passing` and `failed` stay
   saturated; only `untested` is muted.
10. **`prefers-reduced-motion` guard** — if any hover-driven shadow involves a
    size change or transform, add `@media (prefers-reduced-motion: reduce)` block
    in `index.css` that sets `transition: none` on the relevant selectors. The
    existing `pulse-glow` and `status-pulse` keyframes also need to be neutralized
    in this block.

### Non-Functional Requirements

- **Accessibility**: every visible UI boundary clears 3:1 contrast against its
  immediate background per WCAG SC 1.4.11. Use a contrast checker
  ([WebAIM](https://webaim.org/resources/contrastchecker/)) on the final color
  pairs before merge. Selection state has a non-color signal per SC 2.4.7 / 2.4.13.
- **No new dependencies.**
- **No regression in path-highlighting behavior.** Click a node and verify
  unrelated nodes/edges still dim via `usePathHighlight`.
- **No regression in heat-based styling.** `CustomNode.tsx` applies a dynamic
  amber heat glow based on token consumption; preserve that effect.
- **Visual parity with Registry badges.** A side-by-side of a Registry
  `StateBadge active` and a Topology "Linked" badge should be visually identical.

### Out of Scope

- **Live traffic / edge animation as a focus driver.** Per the user, traffic
  state is its own concern (separate from selection focus). Don't touch edge
  animation logic.
- **Extracting a shared `<Badge>` primitive.** Defer until at least one more
  muted-badge consumer exists outside Registry/Topology.
- **Migrating `Registry` badges to `components/ui/Badge.tsx`** or vice-versa.
- **Theme token reorganization** beyond optionally adding one `border-idle`
  utility.
- **The Skills graph view (`SkillNode`, `SkillGroupNode`)** — apply the idle
  border change for consistency, but do not retheme their internal layout.

## Architecture Guidance

### Recommended Approach

This is a Tailwind class-update PR with a small `index.css` addition for
reduced-motion. No new components, no new hooks, no state changes. Touch the
node components, the badges within them, and `index.css`. Optionally add one
new utility (`border-idle`) to `tailwind.config.js` if it helps consistency.

### Key Files to Understand

- `web/src/components/graph/Canvas.tsx` — main graph wrapper; selection click
  handler; edge defaults.
- `web/src/components/graph/GatewayNode.tsx` — Gateway card layout; metric icons
  (target for 70% dim); "Gateway Active" badge (target for badge unification).
- `web/src/components/graph/ClientNode.tsx` — Claude Desktop / Code / Gemini CLI
  cards; "Linked" badge.
- `web/src/components/graph/CustomNode.tsx` — MCP server / resource cards;
  "Running" badges; heat-glow logic to preserve.
- `web/src/components/graph/SkillNode.tsx`, `SkillGroupNode.tsx` — apply idle
  border change for consistency.
- `web/src/components/registry/StateBadge.tsx` and `TestStatusBadge.tsx` — the
  canonical muted-badge recipe to mirror.
- `web/src/components/registry/SkillCard.tsx` — for the muted card pattern
  (reference only; don't restructure Topology cards to match).
- `web/src/index.css` — `.react-flow__edge-path`, `.dimmed`, `.highlighted`
  rules; add `prefers-reduced-motion` block here.
- `web/tailwind.config.js` — color/glow tokens; possible home for a
  `border-idle` utility.
- `web/src/hooks/usePathHighlight.ts` — read-only reference; understand it before
  changing CSS that affects selection visuals.

### Integration Points

- The `selected` prop on each node component flows from XYFlow → click handler
  in `Canvas.tsx` → `useStackStore.selectNode(id)` → XYFlow re-renders with
  `selected: true` on that node. Keep this contract intact.
- Path highlighting (`usePathHighlight` returning `highlightedNodeIds`,
  `highlightedEdgeIds`) is composed into `node.className` and `edge.className`
  in `Canvas.tsx`. The `.highlighted` and `.dimmed` CSS classes in `index.css`
  drive the visual. Don't change that pipeline.

### Reusable Components

- `cn()` from `web/src/lib/cn.ts` — keep using for class composition.
- Existing `shadow-glow-primary` / `shadow-glow-secondary` / `shadow-glow-tertiary`
  utilities — keep using on selected states.
- Existing color tokens (`text-status-running`, `--color-status-running`, etc.)
  — use these rather than raw hex.

## UX Specification

**Discovery**: no change. The selection model is already discoverable (click
any card, sidebar opens).

**Activation**: no change. Click-to-select.

**Resting state**: every node renders with the same neutral border. The eye
moves to status badges (semantic color), not to borders. Edges are visible but
recede behind the cards.

**Selected state**: clicked node gets a brand-colored border (matching its
node-type accent — amber for gateway/client, violet for MCP server, teal for
resource, purple for skill), a 2px stroke (or ring-2), an outer glow
(`shadow-glow-*`), and any unrelated nodes/edges dim via the existing
`usePathHighlight` mechanism.

**Hover state**: cursor over an unselected node previews the selected color at
lower intensity (~50% border opacity, no glow). Hovered node lifts via
`shadow-node-hover`.

**Error/abnormal state**: badges in error/stopped/pending tones keep full
saturation regardless of selection — they are functional, not focus-related.

**Reduced motion**: hover transitions and pulse animations are disabled when
`prefers-reduced-motion: reduce`.

## Implementation Notes

### Conventions to Follow

- Tailwind utilities only; no inline `style` props except where absolutely
  required (e.g., the existing dynamic `boxShadow` for heat glow in
  `CustomNode.tsx` — leave that alone).
- Use `cn()` from `lib/cn.ts` for conditional class composition.
- Match the Registry's exact class strings (`bg-emerald-400/10
  border-emerald-400/25 text-emerald-400 text-[10px]` etc.) — don't paraphrase;
  visual parity is the goal.
- Imperative commit subjects, max 50 chars; no Co-authored-by trailers; sign
  with `-S`. (See `~/.claude/CLAUDE.md`.)
- This repo uses **fork workflow**, not trunk. Use `/branch-fork` and `/pr-fork`.

### Potential Pitfalls

- **Heat glow in `CustomNode.tsx`** is applied via inline `style` based on
  `heatIntensity`. It's an additive box-shadow on top of the Tailwind shadow.
  Don't strip it.
- **Path highlighting `.dimmed { opacity: 0.25 }`** lives in `index.css`. If you
  add inline opacity to nodes (don't), it will multiply with `.dimmed` and
  produce double-dimmed states.
- **The "Gateway Active" badge sits in the Gateway card footer**, not in the
  status row with the other badges. Don't move it; just restyle.
- **`text-primary/70` vs `opacity-70` on an icon**: `text-primary/70` only
  affects the SVG fill; `opacity-70` affects the entire element. For
  Lucide-style stroked icons rendered with `stroke="currentColor"`,
  `text-primary/70` is the cleaner choice. Verify in browser.
- **Tailwind v4 arbitrary alpha syntax**: `border-white/[0.10]` works; so does
  `border-white/10`. Pick one form and stay consistent.

### Suggested Build Order

1. **Read** `web/src/components/registry/StateBadge.tsx` and
   `TestStatusBadge.tsx`. Note exact classes.
2. **Inspect** `git show d74d9d6` to see what PR #559 actually changed.
3. **Idle borders first** — replace the per-node-type `border-{accent}/25` idle
   classes with a single `border-white/[0.10]`. Verify nothing visually breaks
   in selected/hover states.
4. **Selection thickness** — bump border width or ring on selected variants.
5. **Hover** — adjust hover border tone if needed.
6. **Gateway icons** — add `opacity-70` (or `text-primary/70`) to the metric icons.
7. **Badges** — unify "Linked", "Gateway Active", "Running" with Registry recipe.
   Identify any abnormal-state badges (error/stopped/pending) and confirm they
   remain saturated.
8. **`prefers-reduced-motion`** — add the media query block to `index.css`.
9. **Manual QA** — open the dev server, run through: idle scan, hover each
   node type, click each node type, observe path-highlighting still works,
   resize window, toggle compact cards, run a token-heavy operation to confirm
   heat glow still appears.
10. **Contrast verification** — sample the rendered borders/badges with
    DevTools color picker; check each pairing in WebAIM contrast checker.

## Acceptance Criteria

1. Idle nodes render with a neutral, non-brand border at full opacity that
   clears 3:1 contrast against the canvas background.
2. Selected node has its brand-color border + glow + ring AND a thickness or
   ring-weight change that is visible to a viewer who cannot perceive color
   (verifiable by toggling the page to grayscale in DevTools).
3. "Linked" badge in `ClientNode`, "Gateway Active" badge in `GatewayNode`, and
   "Running" badges in `CustomNode` are visually identical (modulo tone) to
   `StateBadge` / `TestStatusBadge` in the Registry.
4. Abnormal-state badges (error/stopped/pending) retain full saturation.
5. Gateway card icons render at 70% opacity; numerical values render at 100%.
6. Path-highlighting (click → unrelated nodes/edges dim) still works via the
   existing `usePathHighlight` mechanism.
7. Heat-glow on `CustomNode` still appears under load.
8. `prefers-reduced-motion: reduce` disables all hover and pulse animations on
   the topology view.
9. No new dependencies. No new components. No state changes.
10. WebAIM contrast checks recorded in the PR description for: idle border vs
    canvas, hover border vs canvas, selected border vs canvas, each badge tone
    vs its background.

## References

- Feature evaluation: `<prompts-dir>/topology-focus-first/feature-evaluation.md`
- gridctl PR #559 (Skills Registry muted-by-default): commit `d74d9d6`
- W3C SC 1.4.11 Non-text Contrast: https://www.w3.org/WAI/WCAG21/Understanding/non-text-contrast.html
- W3C SC 2.4.13 Focus Appearance: https://www.w3.org/WAI/WCAG22/Understanding/focus-appearance.html
- W3C C40 two-color focus indicator: https://www.w3.org/WAI/WCAG21/Techniques/css/C40
- WebAIM contrast checker: https://webaim.org/resources/contrastchecker/
- xyflow theming: https://reactflow.dev/learn/customization/theming
- Tailwind reusing styles (Wathan): https://tailwindcss.com/docs/reusing-styles
- shadcn/ui Badge: https://ui.shadcn.com/docs/components/badge
- Sara Soueidan, accessible focus indicators: https://www.sarasoueidan.com/blog/focus-indicators/
