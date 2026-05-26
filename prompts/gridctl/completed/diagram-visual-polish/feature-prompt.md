# Feature Implementation: Topology Diagram Visual Polish

## Context

**Project**: `gridctl` — an MCP (Model Context Protocol) gateway with a web UI served by `gridctl serve`. The UI is a Vite + React + TypeScript app located at `web/`.

**Surface**: The topology canvas in the Topology workspace. It uses **React Flow (`@xyflow/react`)** to render a left-to-right node graph: MCP servers on the left, a central `gridctl-gateway` card, clients/skills on the right. Edges are SVG paths managed by React Flow.

**Design system**: "Obsidian Observatory" — dark theme defined in `web/src/index.css` via Tailwind v4 `@theme` CSS variables and mirrored in `web/src/lib/constants.ts` (`COLORS` object). Primary brand color is warm amber (`#f59e0b`); secondary is teal (`#0d9488`); tertiary is purple (`#8b5cf6`). Cards use glassmorphism (`backdrop-filter: blur(16-20px)` + semi-transparent backgrounds + gradient overlays).

**Icon library**: `lucide-react`. Icons take color via `className` (e.g., `text-primary/70`).

**Layout**: Dagre auto-layout (left-to-right, LR). Edges default to `smoothstep` bezier. A toggle on the canvas switches between bezier (`default`) and straight (`straight`) edges; both should support the new styling.

## Evaluation Context

This work is the implementation phase of a pre-development evaluation. Key findings that shaped the requirements below:

- **Icon hierarchy**: Every major design system (Material 3, Apple HIG, Carbon, Polaris, Fluent 2) plus Linear/Vercel/Datadog norms agree — accent color should be reserved for action and identity, not decoration. The current "amber on every stat icon" is a textbook dilution antipattern. Demoting both glyph and container halo follows these conventions.
- **Glass elevation**: Pushing backdrop blur past ~20px hurts framerate on a 30-node canvas with animated SVG edges, and the perceptual gain is marginal. The inset top-edge highlight delivers the depth gain at near-zero cost. Blur is intentionally **not** bumped in this bundle.
- **Directional edges**: The original idea was per-edge SVG `<linearGradient>` strokes, but research surfaced (a) an open xyflow bug ([#4822](https://github.com/xyflow/xyflow/issues/4822)) where gradient strokes fail to render after auto-layout passes — gridctl uses dagre auto-layout, so this would bite immediately — and (b) the SVG-gradient "angle problem" where gradients cut a straight chord through bezier curves, looking visibly wrong on long horizontal edges. The pivot to **solid stroke (source color) + arrowhead marker (target color)** achieves the same source→target cognitive mapping while sidestepping both issues. This is also the established pattern in Unreal Blueprints, Blender Geometry Nodes, and ComfyUI.
- **Bundled cleanups**: A rogue cyan in the canvas sub-grid color (`rgba(0, 202, 255, ...)`) is not a defined palette token; it gets swapped to the teal palette during this work. The amber `Zap` flourish at the bottom of the gateway card is removed because it is neither identity nor action and the adjacent status dot already communicates the same thing.

Full evaluation: `prompts/gridctl/diagram-visual-polish/feature-evaluation.md`.

## Feature Description

Three composed visual refinements to the topology canvas plus two small cleanups:

1. **Icon color hierarchy** — Static informational icons in node cards (stat rows, secondary indicators) shift to neutral colors. Amber is reserved for (a) gateway/entity identity, (b) interactive intent (Code Mode badge, hover affordances), and (c) active data flow (selection, animated edges).
2. **Inset top-edge highlight** — A 1px semi-transparent top-edge inset shadow is added to glass nodes to fake the "light catching a bevel" depth cue. Backdrop blur is unchanged.
3. **Directional edge coloring** — Default edges render with a solid stroke in the **source node's accent color** and an SVG arrowhead marker in the **target node's accent color**. Selected/animated/highlighted edges retain existing behavior.
4. **Remove the redundant `Zap` flourish** in the gateway card's status row.
5. **Recolor the sub-grid** from rogue cyan to the existing teal palette token.

## Requirements

### Functional Requirements

**R1 — Demote informational icon glyphs to neutral**
In `GatewayNode.tsx`, the six stat-row icons (`Server`, `Database`, `Radio`, `Monitor`, `Wrench`, `Library`) currently use `text-primary/70`. Change to `text-text-secondary`. The `Code Mode` badge icon and the gateway header `Activity` logo are **not** affected — they remain `text-primary`.

**R2 — De-tint the informational icon containers**
Each stat-row icon sits in a `div` with `bg-primary/10 border border-primary/20`. Change these to `bg-white/[0.04] border border-[var(--color-border-subtle)]`. The `group-hover:bg-primary/15` on each row may stay (hoverable affordance) but its container is no longer amber-tinted by default. The `Code Mode` badge's container (`bg-primary/10 border-primary/20`) is **not** affected.

**R3 — Apply the same demotion pattern to other node components**
- `ClientNode.tsx`: in both compact and full modes, the `Monitor` icon and its container currently use `bg-primary/10 border-primary/25` + `text-primary`. The icon `Monitor` is the primary identity element for this node — keep as amber. **Only** demote any *informational* sub-icons. If ClientNode has none, leave it alone except verify nothing else over-uses amber for chrome.
- `CustomNode.tsx` (MCP Server / Resource nodes): identify any informational stat icons (similar pattern to GatewayNode) and apply the same demotion. The node's primary identity icon (Server / Database) stays in the node's accent color.
- The principle is: **identity icons keep the node's accent color; informational icons go neutral.**

**R4 — Inset top-edge highlight on glass nodes**
In `web/src/index.css`, add `box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.06);` to `.node-glass`, `.node-glass-primary`, `.node-glass-secondary`, and `.node-gateway`. Combine with existing shadows using comma separation (don't overwrite `.node-gateway`'s `box-shadow: var(--shadow-lg)`). For example: `box-shadow: inset 0 1px 0 rgba(255, 255, 255, 0.06), var(--shadow-lg);`.

Also apply the inset to the inline-classed node wrappers that don't use these classes:
- `GatewayNode.tsx` root `div` (the `w-60 rounded-2xl ...` block): add `shadow-[inset_0_1px_0_rgba(255,255,255,0.06)]` to its className, composed with the existing `shadow-lg`.
- `ClientNode.tsx` root `div` (both compact and full variants): same.
- Any other node component using inline className glass (not `.node-glass*` utility classes): same.

Tailwind v4's arbitrary-value shadow syntax should compose; if combining with `shadow-lg` clobbers the lg shadow, use a single arbitrary value: `shadow-[inset_0_1px_0_rgba(255,255,255,0.06),0_8px_32px_rgba(0,0,0,0.5)]` or equivalent.

**R5 — Remove the bottom `Zap` flourish from `GatewayNode.tsx`**
Delete the `<Zap size={14} ... />` element in the status indicator row. Remove `Zap` from the lucide-react import if no other references exist in the file. The `StatusDot status="running"` element and `Gateway Active` label remain.

**R6 — Custom edge type: directional source/target coloring**
Create `web/src/components/graph/DirectionalEdge.tsx`. This is a new custom edge component that:
- Renders the same bezier/straight path React Flow would, based on the `edgeStyle` setting
- Sets `stroke` to the **source node's accent color** at default opacity `0.7`
- Renders an arrowhead `<marker>` at the target end, filled with the **target node's accent color**
- Composes with existing `usePathHighlight` classes (`.highlighted`, `.dimmed`) — those should still override stroke/opacity per `index.css` rules

Register this edge as `directional` in a new `web/src/components/graph/edgeTypes.ts` (mirroring `nodeTypes.ts`). Wire it in `Canvas.tsx` via the `edgeTypes` prop and update `defaultEdgeOptions.type` to `'directional'`. (Note: today edges set `type: edgeStyle`. Move the bezier/straight distinction inside the custom edge — it can read `useUIStore.edgeStyle` and pick `getBezierPath` vs `getStraightPath` from `@xyflow/react`.)

**R7 — Per-node-type accent color map**
Add a helper `web/src/lib/nodeAccent.ts` that exports a function:
```ts
export function nodeAccent(nodeType: string, nodeData?: { external?: boolean; transport?: string }): string
```
returning the appropriate hex from `COLORS`:
- `gateway`, `mcpServer` (default), `client` → `COLORS.primary` (amber)
- `resource` → `COLORS.secondary` (teal)
- `skill`, `skillGroup` → `COLORS.tertiary` (purple)
- `mcpServer` with `data.external === true` → `COLORS.external` (violet)
- SSE transport indicators (if surfaced at the edge level) → `COLORS.transportSse`

`DirectionalEdge.tsx` uses this to resolve source/target colors from the React Flow store (use `useStore` to look up `nodes` by `source` / `target` IDs).

**R8 — Arrowhead marker definitions**
React Flow markers must be defined either via the `markerEnd` prop (using `MarkerType.ArrowClosed` or a custom `<marker>`). Since each edge needs a target-color-specific marker, generate per-color markers in a `<defs>` block and reference them by ID. Two viable patterns:

- **(Preferred) Static defs for the known palette**: Create one `<svg>` once at canvas mount containing `<defs>` with arrowhead markers for each `COLORS.*` accent value (`marker-arrow-primary`, `marker-arrow-secondary`, `marker-arrow-tertiary`, `marker-arrow-external`, `marker-arrow-transport-sse`). The edge component picks `markerEnd={\`url(#marker-arrow-${targetAccentKey})\`}`.
- **Dynamic per-edge defs**: Less clean — defs per edge means duplicate marker IDs across the doc. Avoid.

Use the preferred static pattern. Place the `<defs>` block in `CanvasBase.tsx` or a new `<EdgeMarkers />` component rendered once.

**R9 — Recolor the sub-grid in `Canvas.tsx`**
Line ~212 currently has `color: \`rgba(0, 202, 255, ${0.1 * subGridOpacity})\``. Change to use the teal palette: `color: \`rgba(13, 148, 136, ${0.1 * subGridOpacity})\`` (i.e., `COLORS.secondary` with the same opacity math). Optionally extract the constant to `web/src/lib/constants.ts` or inline it; either is fine.

### Non-Functional Requirements

- **Performance**: No new `backdrop-filter` layers introduced. No per-frame work added to the edge render path beyond what React Flow already does. Verify no framerate regression with 30+ nodes (compact mode + a populated stack — use any existing dev fixture).
- **Accessibility**: Demoted icons must remain readable. Use `text-text-secondary` (#a8a29e), not `text-text-muted` (#78716c). Edge stroke at `0.7` opacity against the `--color-background` (#08080a) backdrop must pass a casual "can you see the line?" eye test at default zoom (1.0). If not, bump to 0.85.
- **Reduced motion**: Existing `@media (prefers-reduced-motion: reduce)` rules in `index.css` are unaffected.
- **No regressions**: Selection states, hover states, path highlighting (`.highlighted` / `.dimmed`), spec mode / drift overlay / wiring mode / secret heatmap visual modes must all continue to work. Verify by toggling each control button in the canvas controls panel.

### Out of Scope

- **No backdrop-blur changes** — explicitly excluded from this bundle.
- **No SVG `<linearGradient>` strokes on edges** — pivoted to markers; do not implement gradients even as a stretch goal.
- **No new toggles in the UI store** — these styling changes are unconditional. No "classic mode" fallback.
- **No changes to backend, API, or data model.**
- **No changes to the workspace switcher, sidebar, command palette, or any non-canvas surface.**
- **No changes to the `Code Mode` badge styling** — it stays exactly as it is (full amber, that's the point).
- **No changes to status dot colors, status pulse animations, or shadow-glow utilities.**

## Architecture Guidance

### Recommended Approach

This is a styling/component refinement, not architectural work. Follow the established patterns:
- **Use existing CSS variables** — don't add new color tokens.
- **Use Tailwind utility classes** for component-level styles; use `index.css` for shared `.node-*` patterns and React Flow overrides.
- **Mirror `nodeTypes.ts` for `edgeTypes.ts`** — same export pattern, registered the same way in `Canvas.tsx`.
- **Single source of truth for node accent colors** — `nodeAccent.ts` helper, consumed by both the edge component and potentially future node-coloring logic.

### Key Files to Understand

Read these first, in this order:

1. **`web/src/components/graph/Canvas.tsx`** — top-level canvas. Owns `defaultEdgeOptions`, the background grid, the control buttons, and all overlay modes. The edge-type registration goes here.
2. **`web/src/components/graph/GatewayNode.tsx`** — the central gateway card; biggest visual surface for the icon hierarchy change. Read carefully to understand which icons are identity, which are info, and which are interactive.
3. **`web/src/components/graph/ClientNode.tsx`** and **`web/src/components/graph/CustomNode.tsx`** — other affected node components. Apply the same demotion logic where it fits.
4. **`web/src/index.css`** — design tokens, `.node-glass*` and `.node-gateway` shared styles, React Flow overrides (edge-path defaults, handle styling, path-highlight rules). The inset shadow lives here.
5. **`web/src/lib/constants.ts`** — `COLORS` object. The `nodeAccent.ts` helper consumes this.
6. **`web/src/components/graph/nodeTypes.ts`** — node registry pattern to mirror for `edgeTypes.ts`.
7. **`web/src/stores/useUIStore.ts`** — `edgeStyle` toggle lives here. The custom edge component reads it.

### Integration Points

- **`Canvas.tsx`** — register `edgeTypes`, mount the `<EdgeMarkers />` `<defs>` component, update `defaultEdgeOptions`, fix the sub-grid cyan.
- **`CanvasBase.tsx`** (if it owns the `<ReactFlow>` mount) — alternatively a good place for the markers defs.
- **Node components** — icon classNames + container classNames; `Zap` removal in GatewayNode; inset shadow composition.
- **`index.css`** — inset shadow on `.node-glass*` and `.node-gateway` rules.

### Reusable Components

- `cn` from `web/src/lib/cn.ts` — already used everywhere for className composition.
- `StatusDot`, `Handle` — unchanged; do not modify.
- Existing `usePathHighlight` hook — composes with the new edge; verify it still works.
- React Flow's `getBezierPath`, `getStraightPath`, `BaseEdge`, `EdgeProps`, `useStore` exports — all standard for custom edge implementation.

## UX Specification

### Discovery
None needed. The visual change is unconditional and immediately visible on next page load.

### Activation
None. No toggles, no settings, no user input.

### Interaction
- **Hover on a stat row** in the gateway card: row background brightens slightly (existing `group-hover:bg-primary/15` behavior preserved on the row, even though the icon container is now neutral).
- **Hover on the Skills row** (which has `cursor-pointer` and an `ExternalLink` icon): unchanged — already opens a detached window.
- **Hover on an edge**: existing CSS hover rule (`.react-flow__edge:hover .react-flow__edge-path`) bumps stroke to `var(--color-text-muted)` and width to 2px. The custom edge should let this rule continue to apply — i.e., don't set inline `stroke` styles that win specificity over the CSS hover rule. Use the `style` prop or a CSS variable that the CSS rule can override.
- **Select a node**: existing `usePathHighlight` behavior unchanged — highlighted edges still get 2.5px amber + drop-shadow per the `.react-flow__edge.highlighted .react-flow__edge-path` rule. The directional coloring only applies in the default state.

### Feedback
Visual only. No toasts, no log entries, no telemetry events. The improvement is in scanability.

### Error States
N/A — purely visual changes with no runtime failure modes.

## Implementation Notes

### Conventions to Follow

- **No new comments unless WHY is non-obvious.** The codebase has clean style and the `index.css` is already heavily annotated by section.
- **Existing className composition style**: multi-line `cn(...)` blocks with one concern per line (see `GatewayNode.tsx` lines 19-26 for the pattern).
- **CSS variable references in TS**: use the `COLORS` object from `lib/constants.ts`, not raw hex literals.
- **React Flow custom edge pattern**: see `https://reactflow.dev/examples/edges/custom-edges` for the canonical structure. Component receives `EdgeProps`, returns `<BaseEdge>` with computed `path` and `markerEnd`.
- **TypeScript strictness**: the codebase uses strict mode; type imports as `import type { ... }` where applicable.

### Potential Pitfalls

1. **Hover stroke override**: React Flow custom edges that set `style={{ stroke: ... }}` inline will win specificity over the `.react-flow__edge:hover .react-flow__edge-path` CSS rule. To preserve hover behavior, pass stroke via a CSS custom property on the path or use a className-based approach. Test hover after implementation.
2. **Highlight class composition**: The existing `.dimmed` rule uses `stroke: var(--color-border) !important;` which will override inline styles. This is **desired** — dimmed edges should go gray regardless of source color. Don't try to "fix" this.
3. **Marker IDs in shadow DOM**: If the canvas is ever rendered inside a shadow root (it isn't today, but detached windows might), `url(#marker-id)` references break across shadow boundaries. For now, this is a non-issue, but worth noting if detached canvas windows ever happen.
4. **Animated edges + per-edge stroke**: The `.react-flow__edge.animated .react-flow__edge-path` rule sets `stroke: var(--color-primary)` with `!important`-equivalent specificity (via CSS source order). When an edge is `animated: true`, the directional coloring should yield to the amber animated stroke. This happens automatically if you don't use `!important` in inline styles.
5. **`subGridOpacity` is a fraction**: The grid color uses `${0.1 * subGridOpacity}` which produces fractional alpha. Use the same multiplier for the new teal color — don't introduce a different opacity scale.
6. **Tailwind v4 arbitrary shadow syntax**: `shadow-[inset_0_1px_0_rgba(255,255,255,0.06)]` works but combining with `shadow-lg` may not compose. Test in browser — if conflict, use a single arbitrary value with both shadows comma-separated.

### Suggested Build Order

1. **Cleanup commits first** (lowest risk, highest immediate clarity):
   - Remove the `Zap` flourish from `GatewayNode.tsx` (R5).
   - Recolor the sub-grid from cyan to teal in `Canvas.tsx` (R9).
2. **Icon hierarchy** (the centerpiece, but mechanical):
   - Demote icon glyphs in `GatewayNode.tsx` (R1).
   - De-tint icon containers in `GatewayNode.tsx` (R2).
   - Apply the same pattern to `ClientNode.tsx` and `CustomNode.tsx` where relevant (R3).
3. **Inset highlight** (one CSS block + className additions):
   - Add inset shadow to `.node-glass*` and `.node-gateway` in `index.css` (R4).
   - Add inline arbitrary-value shadows on the node component roots if needed (R4).
4. **Custom directional edge** (the most code, do it last so cleanup work isn't entangled):
   - Create `nodeAccent.ts` helper (R7).
   - Create the `<EdgeMarkers />` defs component (R8).
   - Create `DirectionalEdge.tsx` (R6).
   - Create `edgeTypes.ts` and wire it into `Canvas.tsx` (R6).
   - Update `defaultEdgeOptions` to use the new edge type (R6).
5. **Manual visual QA**:
   - Run `make build && ./gridctl serve --foreground` (per project memory).
   - Open the topology canvas with a populated stack.
   - Verify each canvas control button mode (zoom, fit, reset, edge style toggle, compact cards, heat map, drift, spec, wiring, secret heatmap) still works.
   - Verify hover on edges, hover on stat rows, selecting a node (path highlight should still show full amber on highlighted edges), and the empty state.
   - Verify Code Mode badge still stands out (amber-on-neutral surroundings is exactly the desired effect).

## Acceptance Criteria

1. **Amber is no longer applied to informational stat icons or their containers** in `GatewayNode.tsx`, `ClientNode.tsx`, or `CustomNode.tsx`. The header logo, `Code Mode` badge, Handle dots, and animated/selected edge strokes still use amber.
2. **The `Zap` icon at the bottom of the gateway card is removed.** No stale import remains.
3. **Glass node cards have a 1px top-edge inset highlight at 6% white opacity**, visible on close inspection but subtle. The existing `shadow-lg` and other shadows are preserved.
4. **Backdrop blur values are unchanged** from current code.
5. **Default edges render with stroke in the source node's accent color** (amber/teal/purple/violet depending on node type) **and an arrowhead in the target node's accent color**. Verifiable by inspecting an edge between a gateway (amber) and a skill (purple) — stroke should be amber, arrowhead purple.
6. **Edge hover still increases stroke width and changes color** per the existing `.react-flow__edge:hover .react-flow__edge-path` rule.
7. **Path highlighting still works**: selecting a node highlights the path with the existing amber 2.5px + drop-shadow style; non-path edges still dim.
8. **Animated edges still use the amber dashed flow style** when `animated: true` is set on an edge.
9. **The sub-grid color uses the existing teal palette** (`rgba(13, 148, 136, X)`), not the previous cyan (`rgba(0, 202, 255, X)`). Visible by zooming above 0.8x.
10. **No new TypeScript errors, no new lint warnings, no console errors** during normal canvas operation including all overlay modes.
11. **Performance is unchanged or better** — visually verify no jank when panning/zooming a populated canvas. (Subjective; no specific FPS target.)
12. **All changes ship as one PR** with screenshots of before/after for the three primary changes (icon hierarchy, inset highlight, edge coloring).

## References

- [React Flow — Custom Edges](https://reactflow.dev/examples/edges/custom-edges)
- [React Flow — Edge Markers](https://reactflow.dev/examples/edges/markers)
- [React Flow — Path Utilities (getBezierPath, getStraightPath)](https://reactflow.dev/api-reference/utils)
- [xyflow/xyflow Issue #4822 — gradient edges fail to render after layout](https://github.com/xyflow/xyflow/issues/4822) (the bug this design avoids)
- [Material Design 3 — Color roles](https://m3.material.io/styles/color/roles)
- [Shopify Polaris — Icon component (subdued vs interactive tones)](https://polaris-react.shopify.com/components/images-and-icons/icon)
- [NN/g — Glassmorphism best practices](https://www.nngroup.com/articles/glassmorphism/)
- [Modern CSS — Expanded use of box-shadow](https://moderncss.dev/expanded-use-of-box-shadow-and-border-radius/) (inset highlight technique)
- [Unreal Material Graph Connector Colors](https://blog.mousefingers.com/post/unreal/connector_colors/) (precedent for source-color edges + target-color caps)
- Full evaluation: `prompts/gridctl/diagram-visual-polish/feature-evaluation.md`
