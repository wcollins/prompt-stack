# Feature Implementation: Skills Dashboard Polish

## Context

`gridctl` is a Go CLI + React/TypeScript web frontend (`web/`) for orchestrating
typed agent workflows ("Skills") atop an MCP gateway. The web frontend is a
Vite + React 19 SPA using:

- **Layout**: Tailwind v4, CSS grid + flex, custom design tokens (Obsidian
  Observatory palette via `tailwind.config`).
- **State**: Zustand v5 with `persist` middleware. Cross-workspace UI state
  lives in `web/src/stores/useUIStore.ts` using a slices pattern.
- **Routing**: React Router v7. Three workspaces: `/topology`, `/skills`,
  `/runs`, all rendered inside `web/src/components/shell/AppShell.tsx`.
- **Canvas**: `@xyflow/react` v12 (React Flow). Topology and Skills compose
  the shared `web/src/components/canvas/CanvasBase.tsx` primitive.
- **Already installed and underused**: `react-resizable-panels` v4.10 (used
  only by `CreationWizard.tsx`), uses the new v4 API
  (`Group`, `Separator`, `useDefaultLayout`).

The Skills dashboard at `/skills` was migrated to the unified shell in commit
c23ca15 and has had four follow-up polish commits in the last week. It is the
project's primary IDE-style developer surface ("code is canon, the canvas is
the derived view").

## Evaluation Context

This prompt is shaped by these key findings from the evaluation
(`feature-evaluation.md` in this folder):

- **Vertical bezier connectors** were chosen over an auto-laid DAG because the
  user explicitly asked to keep the vertical layout but make it elegant.
  Pipedream and n8n (both React Flow-based developer tools) use thin solid
  bezier strokes with neutral color and arrow markers — that's the polished
  baseline.
- **Hand-rolled JSON tokenizer** was chosen over a library because the project
  already hand-rolls YAML highlighting in `SpecTab.tsx` (~250 LOC, regex-based,
  Tailwind classes, `<table>` for line numbers). Mirroring that pattern produces
  a unified Inspector aesthetic across Topology and Skills — a quality signal
  harder to copy than any individual library feature.
- **`useDefaultLayout` over Zustand** for panel widths, because it has built-in
  150ms write debounce, snap/collapse semantics, and conditional-panel ordering
  that you'd reinvent in Zustand. Zustand keeps "what's open / active" state.
- **Per-workspace persistence** because IDE-class tools (VS Code, JetBrains,
  Cursor) persist widths per-workspace; only productivity tools (Linear,
  Figma) persist globally per-user, and Topology/Skills/Runs are workspace-
  shaped.
- **Risk-mitigated scope**: Topology is NOT migrated to the new shared shell
  in v1, even though that's the engineering-correctness win. Reason: Topology
  is the most-used workspace and a layout regression there has the largest
  blast radius. Adopt the shared shell in Skills + Runs; file a follow-up
  issue for Topology.

## Feature Description

Four targeted UI improvements to the `/skills` dashboard:

1. **Remove redundant sidebar header** — the left rail's "gridctl / agent ide /
   phase F / Code is canon..." block double-brands the app and adds marketing
   copy to a developer surface. Delete it; preserve the tagline only on the
   empty-state Welcome screen where new users actually need it.

2. **Redesign the canvas connectors** — current `smoothstep` edges + `y = i * 100`
   spacing reads as a list with right-angle joins. Switch to bezier curves
   (`type: 'default'`), widen vertical spacing to `y = i * 160`, add small
   arrow markers, hide the React Flow handle dots (this is a read-only
   canvas), and remove the `animated: true` flag — animation should fire only
   on the *incoming* edge of a *currently running* node.

3. **Format run output as a real code viewer** — the Inspector currently dumps
   JSON into a styled `<pre>` tag. Replace with a `<CodeViewer>` component
   that gives line numbers, syntax-highlighted JSON tokens (matching the
   `SpecTab.tsx` YAML treatment), and a toolbar (Copy / Pretty-Raw / Wrap /
   size badge / font-size zoom).

4. **Resizable rails + font zoom via a shared primitive** — build
   `<WorkspaceShell>` over `react-resizable-panels` v4 with workspace-scoped
   persistence keys, double-click-to-reset, and `[`/`]` keyboard toggles for
   the rails. Adopt in Skills and Runs. Mount `<ZoomControls>` (already exists)
   in the Skills Inspector header to control the `<CodeViewer>` font size.

Ship as **three sequenced PRs** to keep review surface small.

## Requirements

### Functional Requirements (PR 1 — Visual Polish)

1. Delete the entire `<header>` element in
   `web/src/components/agent/ide/SkillSidebar.tsx` (currently lines 54-69).
   The Skills/Runs `<InspectorTabList>` should now sit at the top of the
   `<aside>`, with the existing top padding on the rail body adjusted so the
   tabs don't stick to the AppShell's bottom border.
2. In `web/src/components/agent/ide/Canvas.tsx`:
   - Change `ROW_HEIGHT` from `100` to `160`.
   - Change `type: 'smoothstep'` on edges to `type: 'default'`.
   - Add `markerEnd: { type: MarkerType.ArrowClosed, width: 14, height: 14 }`
     on every edge. Import `MarkerType` from `@xyflow/react`.
   - Remove `animated: trace[src.id]?.status === 'running'` from the global
     edge config. Move animation to a single conditional: when a node has
     `status === 'running'`, set `animated: true` on its *incoming* edge only
     (the edge whose `target` is that node). Idle/completed/failed edges are
     never animated.
   - Hide the `<Handle>` elements visually: change the existing `className="!bg-border !border-0 !w-2 !h-2"` to also include `!opacity-0 !pointer-events-none`. (Don't remove the handles — React Flow needs them to exist for edges to anchor.)
3. In `web/src/components/workspaces/SkillsWorkspace.tsx`:
   - Leave the `Welcome` component (lines 374-393) alone — the "Code is canon"
     tagline lives there. That copy is correct for an empty state.

### Functional Requirements (PR 2 — CodeViewer + Inspector toolbar)

4. Move `web/src/components/log/ZoomControls.tsx` to
   `web/src/components/ui/ZoomControls.tsx`. Update all imports
   (`grep -rn "components/log/ZoomControls"` to find them).
5. Create `web/src/components/ui/CodeViewer.tsx`:
   - Props: `{ content: string; language: 'json' | 'yaml' | 'plain'; toolbarSlot?: React.ReactNode; fontSize?: number; wrap?: boolean; ariaLabel?: string }`.
   - Layout: outer `<div>` with optional toolbar row at top, then a scrollable
     `<table>`-based code body matching `SpecTab.tsx:195-253`.
   - Line numbers in a fixed-width left column (`w-12 pr-3 text-right text-text-muted/40 select-none align-top`).
   - Code column with per-token spans (`whitespace-pre` when `wrap=false`,
     `whitespace-pre-wrap` when `wrap=true`).
   - Apply `style={{ fontSize: \`\${fontSize}px\` }}` on the `<table>` if
     `fontSize` provided; otherwise inherit.
   - For `language: 'json'`: implement a JSON tokenizer that returns
     `{ text, className }[]` tokens per line. Token classes:
     - keys (`"foo":`) → `text-secondary-light` (matches YAML key color)
     - strings → `text-primary-light`
     - numbers → `text-primary`
     - booleans/`null` → `text-tertiary-light`
     - punctuation (`{}[],:`) → `text-text-muted`
     - everything else → `text-text-primary`
     Implementation hint: `JSON.parse` the content; if parse succeeds, walk
     the AST to emit a styled stringification with newlines (you control
     formatting). If parse fails (e.g., malformed JSON, primitive string),
     fall back to plain text. Mirror the structure of `highlightYAMLLine`
     in `SpecTab.tsx`.
   - For `language: 'yaml'`: lift the `highlightYAMLLine` function from
     `SpecTab.tsx:13-66` and reuse. SpecTab should then import from CodeViewer
     instead of declaring it locally — but **only refactor SpecTab if it does
     not increase risk to that view**; otherwise leave SpecTab alone and
     duplicate the function in CodeViewer with a `TODO: dedupe` comment.
   - For `language: 'plain'`: each line as a single span, no tokenizing.
6. In `web/src/components/agent/ide/RunOutputView.tsx`:
   - Replace the `<OutputPayload>` `<pre>` block (lines 260-276) with
     `<CodeViewer content={text} language="json" wrap={wrap} fontSize={fontSize} ariaLabel="run output" />`.
   - Add a toolbar row above the CodeViewer with: Copy button, Pretty/Raw
     toggle (Pretty default; Raw shows the original `output` value as a single
     `language="plain"` block when it's a string), Wrap toggle, the existing
     size badge (`<ByteCount>`), and `<ZoomControls>`.
   - Wire `<ZoomControls>` to a `useTextZoom` instance with
     `storageKey: 'gridctl-skills-inspector-font-size'`, `defaultSize: 11`,
     `minSize: 9`, `maxSize: 16`.
   - The existing `tooLong` collapse/expand affordance stays — it sits below
     the CodeViewer.
   - The existing `<ErrorPayload>` red `<pre>` stays as-is. Errors are usually
     short strings; don't force code-viewer treatment on them.

### Functional Requirements (PR 3 — WorkspaceShell)

7. Create `web/src/hooks/useWorkspaceLayout.ts`:
   - Thin wrapper over `react-resizable-panels`' `useDefaultLayout` that
     accepts `{ workspace: Workspace, key: string, defaultSizes: number[] }`
     and namespaces the storage key as `gridctl:layout:${workspace}:${key}:v1`.
8. Create `web/src/components/layout/WorkspaceShell.tsx`:
   - Props: `{ workspace: Workspace; left?: React.ReactNode; right?: React.ReactNode; children: React.ReactNode; defaultLeftPct?: number; defaultRightPct?: number; minLeftPx?: number; minRightPx?: number; }`.
   - Uses `<Group orientation="horizontal">` with three `<Panel>`s and two
     `<Separator>`s.
   - Conditionally renders the left/right panels only if their content is
     provided (use explicit `id` and `order` props per RRP v4 docs to avoid
     layout corruption when panels appear/disappear).
   - Implements double-click-to-reset on each `<Separator>`: capture
     `onDoubleClick` and call the appropriate `setLayout` method via
     `useGroupRef`.
   - Implements `[` and `]` keybindings (window-level `keydown` listener with
     `useEffect`) to toggle left/right panel collapse. Use the Mod+`[`/`]`
     pattern only if `[`/`]` alone conflicts with text-input contexts (i.e.,
     suppress when `e.target` is a text input).
   - Uses the existing `web/src/components/ui/ResizeHandle.tsx` visual styling
     as the body of each `<Separator>` (the visual handle stays; the
     mouse/keyboard logic comes from RRP v4).
9. Refactor `web/src/components/workspaces/SkillsWorkspace.tsx`:
   - Replace the `<div className="grid h-full">` block with
     `<WorkspaceShell workspace="skills" left={<SkillSidebar ...>} right={<NodeDetail ...>}>{<main>...}</main>}</WorkspaceShell>`.
   - Default sizes: left ≈ 18%, right ≈ 24% (compute from existing
     280px/360px defaults at 1440px reference width). Mins: `minLeftPx={220}`,
     `minRightPx={300}`.
   - The `compactMode` toggle remains — when active, it should narrow the
     defaults but the user-resized width takes precedence. Wire this by
     reading `compactMode` and passing different `defaultLeftPct`/`defaultRightPct`
     when first mounted; the persisted user override always wins.
10. Refactor `web/src/components/workspaces/RunsWorkspace.tsx` (look up the
    actual file name) to adopt `<WorkspaceShell workspace="runs">`. Use
    matching defaults for its existing rails.
11. **Do NOT** modify `web/src/components/workspaces/TopologyWorkspace.tsx`
    or `web/src/components/wizard/CreationWizard.tsx`. Both are explicitly out
    of scope. File a follow-up GitHub issue titled "Migrate Topology to
    WorkspaceShell" with a link to PR 3.

### Non-Functional Requirements

- **No new external dependencies** in any of the three PRs. Use libraries
  already in `web/package.json`.
- **Accessibility**:
  - Resize separators must be keyboard-focusable with arrow-key resize
    (RRP v4 ships this — verify it works after wiring).
  - `<CodeViewer>` body must be selectable text (default `<pre>` behavior;
    don't add `user-select: none`).
  - Tree-mode toggle (when added in a future PR) should announce mode change
    via `aria-live`.
- **Persistence keys** must be versioned (suffix `:v1`) so future schema
  changes can introduce `:v2` without breaking existing users.
- **Visual continuity**: `<CodeViewer>` MUST visually match `SpecTab.tsx`
  (same line-number column width, same color palette, same `font-mono text-xs`).
- **Performance**: don't re-render the whole `<CodeViewer>` on every keystroke
  in the toolbar. Memoize the tokenization with `useMemo` keyed by
  `content + language`.

### Out of Scope

- **Tree-mode toggle** for large outputs (lazy-loading `react-json-view-lite`).
  Right long-term UX, ship as a follow-up PR.
- **Font zoom on the canvas** (would re-fit React Flow viewport — too much
  layout-thrash for v1).
- **Font zoom on the sidebar** (would conflict with `compactMode` — too much
  surface for v1).
- **Migrating `TopologyWorkspace`** to `<WorkspaceShell>` — engineering
  correctness win but expands the blast radius of PR 3.
- **Migrating `CreationWizard`** to `<WorkspaceShell>` — unrelated.
- **Search-within the CodeViewer** (Ctrl+F intercept) — nice-to-have, not
  table-stakes for an Inspector.
- **Output download as JSON file** — Temporal-style nice-to-have, defer.

## Architecture Guidance

### Recommended Approach

- **Three independent PRs**, each with its own branch off `main`. Use the
  `/branch-fork` workflow (gridctl uses fork model per `MEMORY.md`).
- **Compose, don't inherit.** `<WorkspaceShell>` wraps RRP, `<CodeViewer>`
  is composed by `<RunOutputView>`, `<ZoomControls>` is composed by both
  Topology Inspector tabs and the new Skills Inspector. No base classes.
- **Visual mirror, not visual fork.** When implementing `<CodeViewer>`,
  open `SpecTab.tsx` side-by-side and copy the `<table>` layout exactly.
  Any visual divergence between Spec (YAML) and Run Output (JSON) is a bug.

### Key Files to Understand

Before writing code, read these in order:

1. `web/src/components/spec/SpecTab.tsx` — the visual reference for
   `<CodeViewer>`. Note: tokenizer L13-66, table layout L195-253, line-issue
   annotation pattern L207-249 (you'll skip annotations in CodeViewer v1).
2. `web/src/hooks/useTextZoom.ts` — confirms the zoom hook is plug-and-play.
3. `web/src/components/log/ZoomControls.tsx` — confirms the UI is reusable
   after the move.
4. `web/src/components/ui/ResizeHandle.tsx` — the visual handle to keep as
   the body of `<Separator>`.
5. `web/src/components/agent/ide/Canvas.tsx` — the file you'll surgically
   edit in PR 1. Note `ROW_HEIGHT`, `NODE_WIDTH`, edge construction (L83-98),
   handle declarations in `AgentFlowNode` (L173, L214).
6. `web/src/components/agent/ide/RunOutputView.tsx` — current `<pre>` is at
   L260-276; toolbar will go above it.
7. `web/src/components/agent/ide/SkillSidebar.tsx` — header to delete is at
   L54-69.
8. `web/src/components/workspaces/TopologyWorkspace.tsx` — read it but DO NOT
   modify it. It's the reference pattern for what the existing hand-rolled
   ResizeHandle looks like in production.
9. `web/src/components/workspaces/SkillsWorkspace.tsx` — the file you'll
   refactor in PR 3.
10. `web/src/components/wizard/CreationWizard.tsx` — read the import line
    only (`Panel, Group as PanelGroup, Separator as PanelResizeHandle from 'react-resizable-panels'`)
    to confirm v4 API. DO NOT touch this file.
11. `web/src/stores/useUIStore.ts` — slices pattern + `compactMode` per-workspace
    map. Don't add panel widths here; they belong in RRP `useDefaultLayout`
    storage.

### Integration Points

- `<WorkspaceShell>` must coexist with the existing `compactMode` toggle in
  `useUIStore`. When `compactMode=true`, mount with narrower default sizes
  but never override a user-persisted size.
- `<CodeViewer>` consumes `--text-zoom-size` from `useTextZoom`'s
  `containerProps.style`. Wire the `containerProps.ref` onto the
  `<RunOutputView>`'s outer container so Ctrl+Scroll works inside the
  inspector.
- `editorURL()` from `lib/agent-api` and the existing `Welcome` component
  remain untouched.

### Reusable Components

- `web/src/components/ui/ResizeHandle.tsx` — keep its visual body, drop its
  raw mouse-event logic in favor of RRP `<Separator>`.
- `web/src/components/ui/EmptyState.tsx` — already used by Canvas, no change.
- `web/src/components/inspector/InspectorTabList.tsx`,
  `InspectorTabButton.tsx` — Skills sidebar already uses these for
  Skills/Runs tabs; they stay.
- `web/src/lib/cn.ts` — keep using for className merges.

## UX Specification

### Discovery

- **Sidebar header gone**: zero-discovery — users just see more skills.
- **Canvas redesign**: zero-discovery — first time users see it, it just
  reads as deliberate.
- **CodeViewer**: visible in the Inspector immediately on any completed run.
- **Resize**: hover the gap between rails → grip dots fade in → drag.
  Already familiar from Topology.
- **Font zoom**: −/value/+ chip in the Inspector header (top-right of header
  row). Ctrl+Scroll inside the Inspector body also works.
- **`[` / `]` keybindings**: Linear-style; document in any keyboard-shortcut
  help panel that exists. If none exists, defer mention.

### Activation

- **Resize**: drag → release. Width persists immediately (RRP debounces
  writes by 150ms).
- **Reset**: double-click separator → snap back to default.
- **Toggle rail**: `[` toggles left, `]` toggles right (suppress if focus is
  in a text input).
- **Copy output**: click Copy button → flash "copied" state on button for
  ~1.5s.
- **Pretty/Raw**: toggle button; Pretty re-tokenizes; Raw renders the
  unparsed string.

### Feedback

- **Resize active**: handle shows full opacity grip dots + accent color
  (already implemented in `ResizeHandle.tsx`).
- **Copy success**: button label flips to "✓ copied" briefly.
- **Mode toggle**: button styled as active/inactive pair (use existing
  `ViewToggle` pattern in `SkillsWorkspace.tsx:315`).
- **Run-edge animation**: subtle marching-ants ONLY on the incoming edge of
  the currently running node. No animation when idle/completed/failed.

### Error states

- **CodeViewer parse failure**: when JSON is malformed (or content is a
  primitive), fall back to `language="plain"` rendering. No error UI; the
  raw text is still shown.
- **No run / no node selected**: existing `RunOutputView.InFlightCard` and
  empty-state copy stay.
- **Run errored**: existing `<ErrorPayload>` red `<pre>` stays.

## Implementation Notes

### Conventions to Follow

- **Commit conventions** (per `~/.claude/CLAUDE.md`):
  - Use `feat:`, `fix:`, `refactor:`, `docs:`, `chore:` prefixes.
  - Imperative mood, ≤50 chars subject.
  - Sign all commits with `-S`.
  - **No `Co-authored-by` trailers, no Claude mentions in version control.**
- **Branch naming**: `refactor/skills-canvas-polish`, `feat/skills-inspector-codeviewer`,
  `feat/workspace-shell-shared-primitive`.
- **Workflow**: gridctl uses fork-and-pull. Use `/branch-fork`, `/pr-fork`,
  `/reset-fork` skills (per `MEMORY.md`).
- **Code style**: Tailwind utility classes via `cn()`. No inline styles
  except CSS custom properties (e.g., `--text-zoom-size`) and React Flow's
  required `style` props. Match existing component file structure
  (default function export at top, types above, helpers below).
- **Comment style**: from project CLAUDE.md — concise, meaningful, brief.
  Don't over-explain. Match the existing terse style in `SpecTab.tsx` and
  `Canvas.tsx`.

### Potential Pitfalls

1. **React Flow handles must exist for edges to render.** Hide them with
   `opacity: 0 + pointer-events: none`, do not remove them entirely.
2. **`react-resizable-panels` v4 conditional panels**: when `left` or `right`
   prop is `undefined`, render the panel with explicit `id` and `order`
   props OR don't render it at all. Mixing causes layout corruption per
   maintainer guidance (issue #438 on GitHub).
3. **Storage debounce**: RRP writes localStorage 150ms after the last
   resize event. In tests, mock or wait for the debounce.
4. **`compactMode` interaction**: don't fight RRP's persistence. When the
   user toggles compact mode after resizing, just change the
   `defaultLeftPct`/`defaultRightPct` props — RRP uses these on first mount
   only when no persisted value exists.
5. **Canvas re-fit**: the existing `useEffect` calls `fitView()` on
   `graph.nodes.length` change. With wider spacing (`y = i * 160`),
   `fitView({ padding: 0.2 })` should still center; verify with a 5+ node
   skill.
6. **JSON tokenizer edge cases**: handle `null`, primitive root values
   (`"a string"`, `42`), arrays, deeply-nested objects, very long strings
   (already collapse-gated upstream by `COLLAPSE_THRESHOLD = 10_000`).
7. **`[`/`]` keybindings collision**: suppress when `e.target` is `INPUT`,
   `TEXTAREA`, or has `contenteditable`.
8. **Don't touch `SpecTab` if uncertain.** If lifting `highlightYAMLLine`
   into `CodeViewer` would risk SpecTab regression, duplicate the function
   with a `TODO: dedupe` comment. The unified Inspector aesthetic is more
   important than DRY here.

### Suggested Build Order

For each PR independently:

**PR 1 (Visual Polish)**
1. Run `make build && ./gridctl agent dev --port 8181` and load `/skills`
   in a browser to confirm baseline.
2. Edit `SkillSidebar.tsx` — delete header. Visually verify in browser.
3. Edit `Canvas.tsx` — change `ROW_HEIGHT`, edge type, marker, hide
   handles, scope animation. Verify in browser with the `repo-audit` skill
   that the layout is correct and arrows render.
4. Run `npm run lint && npm test` in `web/`.
5. Open PR.

**PR 2 (CodeViewer)**
1. Move `ZoomControls.tsx` from `log/` to `ui/`. Update imports. Run
   `npm run build` to catch broken imports.
2. Build `CodeViewer.tsx`. Unit-test the JSON tokenizer (small
   `__tests__/CodeViewer.test.tsx`).
3. Refactor `RunOutputView.tsx` to consume `CodeViewer` + add toolbar.
   Wire `useTextZoom` for font sizing.
4. Run a skill in the dev server and verify the Inspector renders the
   output as line-numbered, syntax-highlighted JSON.
5. Verify Pretty/Raw, Copy, Wrap toggles work.
6. Run `npm run lint && npm test`.
7. Open PR.

**PR 3 (WorkspaceShell)**
1. Build `useWorkspaceLayout` hook + `WorkspaceShell` component.
2. Add basic Vitest coverage for the storage-key namespacing.
3. Refactor `SkillsWorkspace.tsx` to consume `WorkspaceShell`. Verify in
   browser: drag both rails, refresh, widths persist; double-click resets;
   `[`/`]` toggles work.
4. Refactor `RunsWorkspace.tsx` similarly.
5. Verify `TopologyWorkspace.tsx` still works unchanged (no regression).
6. Run `npm run lint && npm test`.
7. Open PR. In the description, link a follow-up issue: "Migrate Topology
   to WorkspaceShell".

## Acceptance Criteria

### PR 1
1. Loading `/skills` shows no "agent ide / phase F / Code is canon..."
   header in the left rail.
2. The Skills/Runs tabs appear at the top of the rail, properly padded.
3. The empty-state Welcome screen still shows the "Code is canon" tagline.
4. The canvas in the `repo-audit` skill (3 nodes) shows curved bezier
   connectors, not right-angle smoothstep, with visible arrow markers
   at the bottom of each edge.
5. Vertical gap between cards is visibly larger (~80–96px clear space).
6. No React Flow handle dots are visible on nodes.
7. When a run is in flight, only the incoming edge of the currently
   running node animates. All other edges are static.
8. `npm run lint` and `npm test` pass; `npm run build` succeeds.

### PR 2
1. The Skills Inspector renders completed-run JSON output with line numbers,
   syntax-highlighted keys/values/punctuation matching the Topology Spec
   tab visual style.
2. A toolbar above the code viewer shows: Copy, Pretty/Raw toggle, Wrap
   toggle, size badge, font-size +/− controls.
3. Clicking Copy copies the entire output to the clipboard with visual
   feedback.
4. Pretty/Raw toggle switches between tokenized JSON and plain string.
5. Wrap toggle switches between `whitespace-pre` and `whitespace-pre-wrap`.
6. Font zoom buttons increment/decrement font size; Ctrl+Scroll inside
   the Inspector body also zooms; size persists across reloads.
7. Error payloads still render as the existing red `<pre>` block — no
   regression there.
8. The existing >10KB collapse/expand affordance still works below the
   CodeViewer.
9. `npm run lint` and `npm test` pass; `npm run build` succeeds.

### PR 3
1. `<WorkspaceShell>` is implemented over `react-resizable-panels` v4 in
   `web/src/components/layout/WorkspaceShell.tsx`.
2. `useWorkspaceLayout` hook namespaces storage keys as
   `gridctl:layout:${workspace}:${key}:v1`.
3. SkillsWorkspace consumes `<WorkspaceShell workspace="skills">` and the
   left and right rails are draggable.
4. RunsWorkspace consumes `<WorkspaceShell workspace="runs">` similarly.
5. Resized widths persist across page reloads, scoped per workspace.
6. Double-clicking a separator resets that pair to default sizes.
7. `[` and `]` toggle the left and right rails (suppressed when focus is
   in a text input).
8. `compactMode` defaults are still respected on first mount; user resizes
   override them.
9. TopologyWorkspace renders unchanged (no regression).
10. CreationWizard renders unchanged (no regression).
11. A GitHub issue exists titled "Migrate Topology to WorkspaceShell"
    referencing this PR.
12. `npm run lint` and `npm test` pass; `npm run build` succeeds.

## References

- [Feature evaluation document](./feature-evaluation.md)
- [react-resizable-panels GitHub](https://github.com/bvaughn/react-resizable-panels)
- [react-resizable-panels v4 API examples](https://react-resizable-panels.vercel.app/)
- [shadcn/ui Resizable (wraps RRP)](https://ui.shadcn.com/docs/components/radix/resizable)
- [React Flow Edge Types](https://reactflow.dev/examples/edges/edge-types)
- [React Flow AnimatedSvgEdge](https://reactflow.dev/ui/components/animated-svg-edge)
- [react-json-view-lite (deferred Tree mode)](https://github.com/AnyRoad/react-json-view-lite)
- Project file: `web/src/components/spec/SpecTab.tsx` — the visual reference
- Project file: `web/src/hooks/useTextZoom.ts` — the zoom hook to reuse
- Project file: `web/src/components/ui/ResizeHandle.tsx` — visual handle to retain
