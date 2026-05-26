# Feature Evaluation: Skills Dashboard Polish

**Date**: 2026-05-15
**Project**: gridctl
**Recommendation**: Build with caveats
**Value**: High
**Effort**: Medium

## Summary

Four targeted UI improvements to the recently-shipped `/skills` dashboard: remove a
redundant sidebar header, redesign the canvas with curved bezier connectors and
breathing room, format the run output as a real line-numbered code viewer matching
the Topology Spec tab, and make the side rails resizable with font-size zoom — all
backed by a shared layout primitive. Every primitive needed already exists in the
codebase; this is consolidation, not greenfield. Recommended as three sequenced PRs.

## The Idea

The Skills dashboard (introduced in commit c23ca15, "feat: migrate agent IDE into
unified shell at /skills") is the project's newest workspace and its primary IDE-
style developer surface. It currently has four rough edges that hurt first-time
and daily use:

1. **Sidebar header redundancy** — the left rail re-brands "gridctl" and shows
   "agent ide / phase F / Code is canon — the canvas is the derived view", while
   the global header already brands the app. The marketing copy is noise once
   the user is past first-load.
2. **Cramped canvas** — TOOL/TOOL/LLM nodes stack with right-angled `smoothstep`
   edges and `y = i * 100` spacing. Reads as a list, not a flow. The redesign
   should keep the vertical orientation but feel deliberate, with curved
   connectors and visual breathing room.
3. **Raw JSON output** — the Inspector renders run output inside an unstyled
   `<pre>` tag. No syntax highlighting, no line numbers, no toolbar. Inferior to
   the Topology Spec tab, which already gives YAML the line-numbered code-viewer
   treatment.
4. **Fixed-width rails, no font zoom** — Skills sidebars are pinned at 280/360
   pixels (220/300 in compact). Operators can't make panes wider when they need
   more room or zoom the inspector text when reading dense output, even though
   the Topology view's logs/traces already support font-size zoom.

Beneficiaries: every developer who uses the Skills dashboard (current users:
skills authors building agent graphs; near-future users: anyone running TS skills
once the registry expands).

## Project Context

### Current State

- The Skills dashboard is `web/src/components/workspaces/SkillsWorkspace.tsx`,
  rendered at `/skills` inside `AppShell`.
- Three-column CSS grid: `${sidebarWidth}px minmax(0, 1fr) ${inspectorWidth}px`
  with no resize wired in.
- Recent activity (commits 9a1d578, 95c96c9, 29c4d2f, 20ab729, c23ca15) shows
  active polish on this exact surface — UX investment is the current arc.
- Compact mode is per-workspace already (`useUIStore.compactMode`), and Skills
  defaults to compact (the only workspace that does).

### Integration Surface

Files that change for this feature:

- `web/src/components/agent/ide/SkillSidebar.tsx` — remove header block (L54-69).
- `web/src/components/agent/ide/Canvas.tsx` — bezier edges, wider spacing,
  arrow markers, hide handles, kill global animation.
- `web/src/components/agent/ide/RunOutputView.tsx` — replace the `<pre>` block
  with `<CodeViewer>`, add toolbar (Copy / Pretty-Raw / Wrap / size badge).
- `web/src/components/workspaces/SkillsWorkspace.tsx` — replace the CSS-grid
  three-column layout with `<WorkspaceShell>`.
- `web/src/components/workspaces/RunsWorkspace.tsx` (or equivalent) — adopt
  `<WorkspaceShell>` for consistency.

New files:

- `web/src/components/ui/CodeViewer.tsx` — line-numbered, syntax-highlighted
  viewer with a slot for a toolbar; supports `language: 'json' | 'yaml'`.
- `web/src/components/layout/WorkspaceShell.tsx` — `<Group>` wrapper with
  workspace-scoped persistence + double-click-to-reset + `[`/`]` keybindings.
- `web/src/hooks/useWorkspaceLayout.ts` — thin wrapper over `useDefaultLayout`
  that prefixes the storage key with workspace name.

Files moved (not changed):

- `web/src/components/log/ZoomControls.tsx` → `web/src/components/ui/ZoomControls.tsx`
  (lifted from log-specific to general-purpose; no logic change).

### Reusable Components

Everything needed is already in the tree:

- `react-resizable-panels` v4.10 — already a dep, already used by `CreationWizard`.
- `web/src/components/ui/ResizeHandle.tsx` — visual handle to reuse as the
  `<Separator>` body inside `WorkspaceShell`.
- `web/src/hooks/useTextZoom.ts` — generic zoom hook with localStorage persist,
  Ctrl+Scroll, bounds clamp, exposes `containerProps` with `--text-zoom-size`
  CSS var. Plug-and-play.
- `web/src/components/log/ZoomControls.tsx` — −/value/+ UI. Plug-and-play after
  the move.
- `web/src/components/spec/SpecTab.tsx:13-66, 195-253` — the YAML tokenizer +
  `<table>` line-number layout to mirror for JSON.
- `web/src/stores/useUIStore.ts` — Zustand slices pattern with persistence and
  per-workspace migration logic. Use `useDefaultLayout` for widths (built-in
  debounce); `useUIStore` keeps "what is open / active" state.

## Market Analysis

### Competitive Landscape

- **Resizable panels**: VS Code, JetBrains, Cursor persist widths per-workspace;
  Linear and Figma persist globally per-user. Topology/Skills/Runs are workspace-
  shaped, so per-workspace is correct.
- **Run output viewers**: Temporal Web UI, Inngest, Trigger.dev, n8n, Retool
  Workflows all show structured output as a collapsible JSON tree by default
  with a "raw JSON" escape hatch. Flat line-numbered code is the minority
  pattern (used mostly for logs).
- **Vertical workflow canvases**: n8n and Pipedream (also React Flow-based) use
  thin solid bezier strokes with subtle handle dots. Zapier uses straight lines
  with insertion "+" buttons (signals editable). Make.com uses heavy colored
  pipes (toy aesthetic, not developer-tool fit). The polished baseline for a
  developer tool: thin bezier, neutral color, arrow marker, no animation
  except on the currently-running edge.

### Market Positioning

- **Catch up + groundwork**: line-numbered code viewers and resizable panels
  are 2026 table-stakes. The shared-primitive extraction lays groundwork for
  ongoing Runs polish without re-litigating these decisions per-workspace.
- **Differentiator if executed well**: matching the SpecTab visual exactly
  (versus dropping in a third-party JSON viewer with its own design system)
  produces a unified Inspector aesthetic across Topology and Skills — that
  consistency is a quality signal harder to copy than any individual feature.

### Ecosystem Support

- `react-resizable-panels` v4 (Brian Vaughn — React DevTools author) is the
  de-facto React standard. shadcn/ui's `Resizable` wraps it. Built-in
  `useDefaultLayout` hook handles persistence with 150ms write debounce. v4
  renamed `PanelGroup→Group`, `PanelResizeHandle→Separator`; the existing
  `CreationWizard.tsx` already imports the v4 names (aliased back).
- `react-json-view-lite` (~3 KB gz, zero deps) is the smallest collapsible-tree
  viewer. Lazy-loaded for an optional Tree mode in the Inspector.
- For flat code viewing, no library beats hand-rolling at this scale —
  CodeMirror minimal is ~75 KB gz, Shiki is ~700 KB gz, Monaco is megabytes.

### Demand Signals

- The user request itself is the strongest signal — author of the recent commit
  arc is actively polishing the dashboard.
- The Skills view shipped only days ago (commit c23ca15) — fixing first-impression
  rough edges now is materially cheaper than after wider adoption.

## User Experience

### Interaction Model

- **Header cleanup**: invisible win. Users get ~80px more skill rows in the rail.
  Tagline persists in the empty-state Welcome screen where new users actually
  need orientation.
- **Canvas**: same click-to-inspect, double-click-to-jump. Visual change only.
- **CodeViewer**: text remains selectable; Copy button copies-all in one click;
  Pretty/Raw toggle for engineers who want to grep-match against backend logs;
  Wrap toggle for narrow inspector widths; size badge (`12.4 KB · 847 lines`)
  so operators know what they're about to expand.
- **WorkspaceShell**: drag a separator to resize; double-click to reset; press
  `[` or `]` to toggle a rail entirely. Sizes persist per workspace.
- **Font zoom**: −/value/+ in the Inspector header; Ctrl+Scroll inside the
  Inspector body. Persists per workspace via existing `useTextZoom` storage key.

### Workflow Impact

- **Reduces friction** in the most common Skills workflow (run a skill →
  read its output) by making output legible without copy-pasting to an editor.
- **No regression risk** for existing users — every change is additive or a
  visual swap. Default behavior preserves the current widths until the user
  drags a separator.
- **Discoverability of resize** is the one thing to watch — if separators are
  too subtle, users won't try them. Keep the hover-reveal grip dots from the
  existing `ResizeHandle` for the affordance signal.

### UX Recommendations

- Ship per-workspace persistence keys (`gridctl:layout:skills:left`,
  `gridctl:layout:skills:right`). Don't unify across workspaces.
- Default the CodeViewer to **Pretty** mode; the Raw toggle is for the
  engineer-in-a-bug-hunt edge case.
- For the canvas, **never** set `animated: true` globally. Reserve the
  marching-ants pattern for the *incoming edge of the currently running node*
  only — and prefer a subtle pulse over marching ants if implementation cost
  is similar.
- Use `markerEnd: ArrowClosed` (~14×14) on every edge — one cue tells the eye
  "this flows down" without needing animation.

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Significant | First-impression problems on the project's newest dashboard. |
| User impact | Broad + Deep | All Skills users hit this every session. |
| Strategic alignment | Core mission | Skills view is the active polish arc (5 of last 5 commits). |
| Market positioning | Catch up + groundwork | Line-numbered viewers, resizable panels, proper flow connectors are 2026 baseline. |

### Cost Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Moderate | Two new shared components; the rest is in-place edits. No backend or API touched. |
| Effort estimate | Medium | ~2–3 days across three sequenced PRs. |
| Risk level | Low | Read-only UI work. Worst case is a layout regression contained to one workspace. |
| Maintenance burden | Minimal | Hand-rolled JSON tokenizer mirrors an existing pattern. `react-resizable-panels` already a dep. |

## Recommendation

**Build with caveats** — ship as three sequenced PRs:

- **PR 1 — Visual polish (small, ~5 files)**: Remove the redundant sidebar
  header block. Update Canvas: bezier edges (was `smoothstep`), spacing
  `y = i * 160` (was `i * 100`), `markerEnd: ArrowClosed`, hide handle dots,
  drop global `animated: true`. Move the "Code is canon" tagline into the
  empty-state Welcome only. One hour of review.

- **PR 2 — CodeViewer + Inspector toolbar (medium, ~6 files)**: Move
  `ZoomControls` from `components/log/` to `components/ui/`. Build
  `components/ui/CodeViewer.tsx` mirroring SpecTab's pattern with a JSON
  tokenizer and a JSON/YAML language switch. Refactor `RunOutputView.tsx` to
  render the output through `CodeViewer` with a toolbar (Copy / Pretty-Raw /
  Wrap / size badge / ZoomControls).

- **PR 3 — WorkspaceShell (medium, ~6 files)**: Build
  `components/layout/WorkspaceShell.tsx` over `react-resizable-panels` v4
  using `useDefaultLayout` + workspace-scoped storage keys. Add double-click
  reset on the `<Separator>` and `[`/`]` keyboard shortcuts. Adopt in
  `SkillsWorkspace.tsx` and `RunsWorkspace.tsx`. Leave `TopologyWorkspace.tsx`
  on its current pattern with a follow-up issue to migrate.

**Deferred (not in scope for v1)**:

- Tree-mode toggle in the Inspector (lazy-load `react-json-view-lite` for
  outputs >10KB). Right long-term UX, but ships better as a follow-up PR
  once `CodeViewer` is in.
- Font zoom on the canvas and the sidebar — the user said "like I can in the
  main topology view," and Topology only zooms log/trace text. Adding
  canvas-text and sidebar-text zoom introduces layout-thrash and isn't the
  ask.
- Migrating `TopologyWorkspace` to `WorkspaceShell`. Engineering correctness
  win but out of scope for this user request.
- Migrating `CreationWizard` from its direct v4 import to `WorkspaceShell`.
  Unrelated.

## References

- [react-resizable-panels GitHub](https://github.com/bvaughn/react-resizable-panels)
- [react-resizable-panels v4 PR #528](https://github.com/bvaughn/react-resizable-panels/pull/528)
- [react-resizable-panels examples](https://react-resizable-panels.vercel.app/)
- [shadcn/ui Resizable](https://ui.shadcn.com/docs/components/radix/resizable)
- [react-json-view-lite GitHub](https://github.com/AnyRoad/react-json-view-lite)
- [@uiw/react-json-view npm](https://www.npmjs.com/package/@uiw/react-json-view)
- [React Flow Edge Types example](https://reactflow.dev/examples/edges/edge-types)
- [React Flow AnimatedSvgEdge](https://reactflow.dev/ui/components/animated-svg-edge)
- [Tuning Edge Animations in React Flow — Liam ERD](https://liambx.com/blog/tuning-edge-animations-reactflow-optimal-performance)
- [Pipedream workflow-builder-connect (React Flow based)](https://github.com/PipedreamHQ/workflow-builder-connect)
- [Temporal Web UI docs](https://docs.temporal.io/web-ui)
- [n8n Executions docs](https://docs.n8n.io/workflows/executions/)
- [Linear collapsible sidebar changelog](https://linear.app/changelog/unpublished-collapsible-sidebar)
- [JetBrains tool window keyboard resize](https://blog.jetbrains.com/idea/2010/01/resize-tool-windows-with-keyboard/)
