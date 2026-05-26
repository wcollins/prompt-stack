# Feature Implementation: Library Workspace + "Stage" Rename

## Context

**gridctl** is an open-source MCP (Model Context Protocol) gateway and agent control plane. The repo is at `~/code/gridctl` and uses a fork-based workflow (origin = your fork, upstream = main repo). The web UI lives under `web/` (Vite + React + TypeScript + Tailwind, with `react-router-dom`, `@xyflow/react`, zustand stores, Vitest). The Go backend exposes REST + SSE APIs from `cmd/gridctl/...` and `internal/...`.

The web UI is organized around a **unified app shell** (`web/src/components/shell/AppShell.tsx`) that hosts three workspaces today:
- `/topology` — `TopologyWorkspace`: live graph of MCP servers, clients, resources (React Flow canvas)
- `/skills` — `SkillsWorkspace`: per-skill **Agent IDE** (typed graph editor for a single skill, list + canvas views, run launcher, run trace overlay)
- `/runs` — `RunsWorkspace`: run history + SSE live stream

Workspaces are declared in `web/src/types/workspace.ts:WORKSPACE_CONFIG`, which auto-drives the top-nav switcher (`WorkspaceSwitcher.tsx`) and keyboard shortcuts (`useKeyboardShortcuts.ts`).

Project conventions to honor:
- Fork-based git workflow (use `/branch-fork` / `/pr-fork` skills)
- Signed commits (`-S`), no Co-authored-by trailers, no mention of Claude in commits / PRs / branches
- Conventional Commits (`feat:`, `fix:`, etc.); imperative subject ≤50 chars, no trailing period
- Branch naming: `feature/<slug>`
- ESLint + TypeScript strict; tests live in `web/src/__tests__/` (Vitest); run `npm test` from `web/`
- Go: `make build` produces `./gridctl`; `make test` runs the Go suite; `golangci-lint run` for lint
- See `AGENTS.md`, `CLAUDE.md`, `README.md` for project-level guidance

## Evaluation Context

Full evaluation: `prompts/gridctl/library-workspace/feature-evaluation.md`.

Key findings that shape this prompt:

- The current "Skills" tab is the **per-skill Agent IDE**, not a registry. The current Registry (skills catalog) is buried 3 clicks deep behind a sidebar popout. This is a real discoverability problem.
- The project is mid-migration to a workspace model: `c194783` (unified shell), `74b67e5` (real runs workspace), `c23ca15` (agent IDE migrated to `/skills`). **Use `c23ca15` as the direct implementation template** — it promoted a detached page into a workspace with the same shape we need here.
- Market analysis (Flowise / AutoGen Studio / Dify / Backstage / Pulumi) shows top-nav placement for the skill/tool library is **table stakes**. Tools that bury it (Claude Desktop, Cursor) get persistent user complaints.
- Global polling (`web/src/hooks/usePolling.ts:88-107`) already fetches registry data — no new polling needed.
- The user-facing rename is internally consistent: **Stage** (where you author one skill) vs **Library** (where you manage all skills). The internal `registry` model (API, store, components) **does not need to be renamed** in this PR — only the user-facing labels and route change. Call this out in the PR description so reviewers don't expect a wholesale rename.

## Feature Description

**Two coordinated user-facing changes shipped in one PR:**

1. **Rename the existing "Skills" top-nav tab to "Stage"** — the per-skill Agent IDE. Same route (`/skills`), same behavior, new label and updated copy where it surfaces (welcome string, command palette commands).
2. **Add a new 4th top-nav tab "Library"** at `/library` — the existing Skills Registry promoted from sidebar / detached-page to a first-class workspace. Skill catalog as cards, with search, state filter (all / active / draft / disabled), create / edit / delete / activate / disable / import / update-all.

**Final top-nav order: `[ Topology ] [ Stage ] [ Library ] [ Runs ]`**

The four tabs form a **discovery-to-development loop**:
- **Library** answers "What can my grid do?" — browse, discover, install, toggle
- **Stage** answers "How does *this* skill work?" — edit, debug, trace one skill
- **Topology** answers "How are these skills distributed?" — infrastructure
- **Runs** answers "What is happening right now?" — execution history + live stream

Today this loop is broken at the first step: the only "full" view of the catalog is a detached browser tab, which forces a cross-window context switch when the user wants to drill into a skill in the IDE. After this PR, the default Library view is in-app — the popout is a power-user second-monitor affordance, not the only path.

Problem solved: skill management was buried 3 clicks deep behind "select a gateway node → look in the sidebar → click popout." Discoverability and daily-driver ergonomics improve significantly. The rename eliminates the naming collision where two tabs (the IDE and the registry) both concerned "skills." State writes (activate / disable / create / delete) flow through the existing in-app `useRegistryStore`, so the Stage sidebar and Topology graph see updates instantly — no more cross-window `BroadcastChannel` reliance for primary access.

Beneficiaries: every user — new users finding the registry on first launch, demo viewers seeing it without prompting, daily drivers managing skills in one click instead of three.

## Requirements

### Functional Requirements

1. **Add a 4th workspace** and **align shortcut keys to visual order** in `web/src/types/workspace.ts`. The final `WORKSPACE_CONFIG` array order must match visual nav order so the auto-derived shortcuts make intuitive sense:

   | Position | id | label | icon | shortcutKey |
   |----------|----|-------|------|-------------|
   | 1 | `'topology'` | Topology | Network | `'1'` |
   | 2 | `'skills'` | Stage | Code | `'2'` |
   | 3 | `'library'` | Library | Library (lucide-react) | `'3'` |
   | 4 | `'runs'` | Runs | PlayCircle | `'4'` |

   **Important behavior change**: Runs moves from Cmd+3 → Cmd+4. This is a deliberate muscle-memory break in favor of "visual order matches shortcut number." Call this out explicitly in the PR description so existing Cmd+3-Runs users are aware. The trade-off is worth it: the user reading the nav left-to-right gets shortcuts 1-2-3-4 in the same order, which is the convention every multi-workspace app the user has seen (VS Code, Slack, Linear, etc.).

2. **Rename "Skills" label to "Stage"** in `WORKSPACE_CONFIG`. Workspace id stays `'skills'` and route stays `/skills` — only the human-facing `label` changes. This minimizes blast radius (URLs, tests, the workspace id used in storage keys all keep working).

3. **Wire the `/library` route** in `web/src/routes.tsx`:
   - Lazy-load `LibraryWorkspace` like the other three workspaces
   - Mount inside `<AppShell />` so it gets the header / status bar / bottom panel
   - The existing detached `/registry` route must be **renamed to `/library-window`** to free `/library` for the workspace
   - Keep a redirect from `/registry` → `/library-window` to avoid breaking any open windows or bookmarks (use `<Navigate to="/library-window" replace />`)

4. **Create `web/src/components/workspaces/LibraryWorkspace.tsx`**:
   - Follow the shape of `SkillsWorkspace.tsx` and `RunsWorkspace.tsx`
   - Use the `WorkspaceShell` primitive from `web/src/components/layout/WorkspaceShell.tsx`
   - Center pane: the skill card grid (`GroupedSkillGrid` lifted from `DetachedRegistryPage.tsx:111-161`)
   - Header bar: search input + filter tabs (All / Active / Draft / Disabled) + "New Skill" button + Refresh + Popout button
   - Empty states (no skills, no matches) — port from `DetachedRegistryPage.tsx:419-448`
   - **State must be URL-encoded** using `useSearchParams`:
     - `?q=<search>` for search query
     - `?filter=active|draft|disabled` (omitted = all)
     - This preserves filtering across tab switches, deep-links, and popout
   - **Deep-link to a single skill** via path param: `/library/:skillName` opens the workspace with that skill focused and the SkillEditor mounted (or the skill row scrolled into view + selected, depending on UX preference). `/library` alone shows the unfocused catalog. Add this route as a nested route under `/library` in `routes.tsx`. The intent: `/library/incident-triage` feels modern and lets the Stage workspace deep-link "Open in Library" cleanly
   - **Deep-link initialization**: on mount (and on `useParams` change), look up the skill by name in `useRegistryStore.skills`. If found, set `editingSkill` to that skill and open the editor (matching the `setEditingSkill(s); setShowEditor(true)` pattern at `DetachedRegistryPage.tsx:457`). If not found *and* the registry has finished loading (avoid false negatives mid-fetch), show a `showToast('error', 'Skill "${name}" not found')` and `navigate('/library', { replace: true })` so the URL bar reflects the fallback. Guard against re-firing the toast on every re-render — only trigger when the params actually change
   - **No zoom controls in the workspace header**: the detached `/library-window` page keeps its `ZoomControls` (it's a standalone surface with its own font sizing needs), but the in-app `LibraryWorkspace` does NOT include `ZoomControls`. Workspaces use the browser zoom; detached log/metrics/library windows have their own local zoom because they live in their own browser tab without the rest of the chrome. Keep the header clean

5. **Refactor to share code between workspace and detached window**:
   - Extract a `LibraryGrid` (or `RegistryGrid`) component that takes skills + handlers as props and renders the grid + group sections — used by both `LibraryWorkspace` and `DetachedRegistryPage`
   - Extract the editor / delete-confirm modal handling into a shared hook (`useLibraryActions`) or co-locate in `LibraryWorkspace` and pass to grid
   - Goal: eliminate the current duplication between `DetachedRegistryPage.tsx` and `RegistrySidebar.tsx`

6. **Reframe the popout** (keep, but as a power-user affordance — not the default discovery path):
   - `web/src/hooks/useWindowManager.ts` (or wherever `openDetachedWindow('registry')` resolves the URL) — point the `'registry'` window key to `/library-window`
   - `web/src/components/registry/RegistrySidebar.tsx:93-95` and any other callers — the popout still works, just lands at the renamed route
   - The new `LibraryWorkspace` header should also expose a popout button that calls the same `openDetachedWindow('registry')` (or rename the key to `'library'` if it's clean to do so — but `'registry'` is fine since the key is internal)
   - The user-facing tooltip on the popout button should say "Open in new window" — avoid "Detach Registry" copy
   - **Important framing**: this PR's main effect is that users no longer *need* to popout to see the catalog at full size. The popout is now a "I want this on my second monitor while coding in Stage" affordance, not the only way to get a full-page view. Reflect this in the PR description copy

7. **Update keyboard shortcuts** in `web/src/hooks/useKeyboardShortcuts.ts`:
   - Shortcuts are auto-mapped from `WORKSPACE_CONFIG.shortcutKey` (see `WORKSPACE_BY_KEY` ~lines 22-24). With the requirement #1 reassignment, the bindings become: Cmd+1=Topology, Cmd+2=Stage, **Cmd+3=Library (NEW)**, **Cmd+4=Runs (MOVED from Cmd+3)**
   - **Remove** the existing Cmd+4 quick-jump that switches the bottom panel to "traces" (current `useKeyboardShortcuts.ts` ~lines 86-90). Traces remains accessible by clicking the tab in the bottom panel and via the command palette
   - Update the relevant tests in `web/src/__tests__/useKeyboardShortcuts.test.tsx` (or similar) — both the Cmd+4 → traces assertion (remove) and any assertion that Cmd+3 navigates to Runs (update to Cmd+4 → Runs, add Cmd+3 → Library)

8. **Update the Gateway sidebar** (`web/src/components/gateway/GatewaySidebar.tsx`):
   - Replace `<RegistrySidebar embedded />` at line 61 with a small, clean CTA: an inline button or link that navigates to `/library` ("Manage Skills →"). Use `Link` from `react-router-dom` and the existing button styling
   - **Include a count badge** for at-a-glance value: read `useRegistryStore.skills` and render the total skill count next to the label, e.g., **"Manage Skills (12) →"**. This preserves the "at-a-glance" benefit the embedded sidebar used to provide without the visual clutter. Use the existing badge styling from elsewhere in the inspector / sidebar. Skeleton placeholder if the store hasn't loaded yet (e.g., "Manage Skills →" with no count)
   - Remove the popout button at lines 46-49 (it now lives inside the Library workspace itself)
   - Keep the rest of the GatewaySidebar (header, OptimizeSection) intact
   - This eliminates ~50 lines of duplicated UI

9. **Add a workspace-scoped command palette hook** at `web/src/components/library/useLibraryCommands.ts`:
   - Model on `web/src/components/skills/useSkillsCommands.ts`
   - Commands to register:
     - "Library: New Skill" — opens the SkillEditor
     - "Library: Refresh" — calls `fetchRegistrySkills` / `fetchRegistryStatus`
     - "Library: Show All" — clears filter + search
     - "Library: Filter Active" / "Filter Draft" / "Filter Disabled"
     - "Library: Open in New Window" — same as popout button
   - Registered on workspace mount, torn down on unmount

10. **Update copy and welcome text where "Skills" → "Stage" appears**:
   - `SkillsWorkspace.tsx`: `Welcome()` component (`agent ide` eyebrow text + heading) — adjust the copy so it doesn't say "Skills" if it currently does. The "Agent IDE" eyebrow is fine to keep (it accurately describes the per-skill view)
   - Any inline "Skills" labels in `WorkspaceShell` props, breadcrumbs, error messages
   - Do NOT rename: the route, the workspace id, the storage keys (`'skills'`), the test files, the Go API endpoints, the `useRegistryStore`, the `registry/` directory, or the `/api/registry` HTTP routes. **Only user-visible labels change.**

### Non-Functional Requirements

- TypeScript strict mode — no `any`, no unchecked narrowing
- Tailwind classes only; no new CSS files
- No new top-level dependencies
- Existing tests must continue to pass; add tests for new behavior (URL state, route redirect, workspace switching with 4 tabs, keyboard shortcuts)
- Lint clean (`npm run lint` in `web/`)
- Accessibility: 4th nav pill must inherit `role="tab"` + `aria-selected` from the existing `WorkspacePill` component; the popout button keeps its existing aria-label
- Performance: no new polling loops; reuse the global `usePolling` registry fetch

### Out of Scope

- Renaming internal model code (`registry/` → `library/`, `useRegistryStore` → `useLibraryStore`, `/api/registry` → `/api/library`). Note this in the PR as deferred for a follow-up cleanup if desired.
- Backend API changes
- New Registry features (telemetry, version diffing, dependency graph, sharing, remote marketplace)
- Mobile / narrow-viewport handling beyond what existing workspaces support
- Animations or visual polish beyond what the existing detached page already has
- Migrating away from `RegistrySidebar` entirely — leave the file in place; just stop embedding it inside `GatewaySidebar`. A future PR can remove or repurpose it if no other consumer remains

## Architecture Guidance

### Recommended Approach

Follow the **c23ca15 template** (the `/skills` workspace migration commit) almost line-for-line:

1. Extract the detached page's core content into a reusable component
2. Create a workspace that wraps that content with `WorkspaceShell` and URL state
3. Update `WORKSPACE_CONFIG`, `routes.tsx`, keyboard shortcuts
4. Update callers of the old detached route
5. Add workspace-scoped palette commands

The detached page is **kept**, not deleted — it's still useful as a popout target. The shared `LibraryGrid` component is the dedup mechanism.

### Key Files to Understand (read in this order)

1. `web/src/types/workspace.ts` — workspace declaration model
2. `web/src/components/shell/WorkspaceSwitcher.tsx` — auto-derives pills from `WORKSPACE_CONFIG`
3. `web/src/routes.tsx` — workspace + detached routes
4. `web/src/components/workspaces/SkillsWorkspace.tsx` — closest workspace template
5. `web/src/components/workspaces/RunsWorkspace.tsx` — second template, simpler URL state example
6. `web/src/components/layout/WorkspaceShell.tsx` — the shared shell primitive (left/center/right rails)
7. `web/src/pages/DetachedRegistryPage.tsx` — body of the existing detached registry; primary source for the grid + filter + search UI
8. `web/src/components/registry/RegistrySidebar.tsx` — sidebar registry; CRUD action handlers to reuse / extract
9. `web/src/components/registry/SkillCard.tsx`, `SkillEditor.tsx`, `SkillActions.tsx`, `StateBadge.tsx`, `SkillCardSkeleton.tsx` — reusable as-is
10. `web/src/hooks/usePolling.ts:88-107` — global registry polling (confirms no new polling needed)
11. `web/src/components/skills/useSkillsCommands.ts` — palette commands template
12. `web/src/hooks/useKeyboardShortcuts.ts` — keyboard shortcut wiring + the Cmd+4 traces shortcut to remove
13. `web/src/components/gateway/GatewaySidebar.tsx` — where the embedded RegistrySidebar lives today (line 61)
14. `web/src/hooks/useWindowManager.ts` — popout / detached window plumbing
15. `git show c23ca15` — read this commit. It's the direct precedent

### Integration Points

- `web/src/types/workspace.ts`: add 4th entry, rename label, ensure order produces `Topology / Stage / Library / Runs` in the rendered nav
- `web/src/routes.tsx`: add `/library` lazy route, rename `/registry` → `/library-window`, add `<Navigate>` redirect from `/registry`
- `web/src/components/workspaces/`: new `LibraryWorkspace.tsx`
- `web/src/components/library/`: new directory; `useLibraryCommands.ts` lives here
- `web/src/components/registry/LibraryGrid.tsx` (or a similar shared file): extracted grid component
- `web/src/components/gateway/GatewaySidebar.tsx`: replace embedded registry with a "Manage Skills →" link
- `web/src/hooks/useKeyboardShortcuts.ts`: remove Cmd+4 → traces; add workspace shortcut tests
- `web/src/__tests__/`: update affected tests, add tests for new behavior

### Reusable Components

Already decoupled — use these directly:
- `SkillCard`, `SkillActions`, `SkillEditor`, `StateBadge`, `SkillCardSkeleton`, `SkillFileTree` (all under `web/src/components/registry/`)
- `useRegistryStore` (state) — name stays, no rename
- API: `fetchRegistryStatus`, `fetchRegistrySkills`, `activateRegistrySkill`, `disableRegistrySkill`, `deleteRegistrySkill`, `fetchSkillUpdates`, `updateSkillSource`, all in `web/src/lib/api.ts`
- `WorkspaceShell` (`web/src/components/layout/WorkspaceShell.tsx`)
- `useFuzzySearch` hook for search filtering
- `useLogFontSize` hook if you want zoom controls (the detached page has them; the workspace can optionally include)

## UX Specification

### Discovery
A "Library" pill in the top nav, between "Stage" and "Runs." Single click, no prerequisite. Icon: `Library` from `lucide-react`. Keyboard: Cmd/Ctrl + 4.

### Activation
Click the pill → router navigates to `/library`. State (search / filter) preserved via URL params.

### Interaction
- Search input filters skills as user types (existing `useFuzzySearch` behavior)
- Filter tabs (All / Active / Draft / Disabled) sub-filter on state; counts update live
- Skill cards expose: state badge, name, description, action menu (edit / activate / disable / delete)
- "New Skill" button opens the existing SkillEditor modal
- "Refresh" forces a registry re-fetch
- "Open in new window" popout — opens `/library-window` in a detached browser window

### Feedback
- Loading: existing `SkillCardSkeleton` grid
- Empty (no skills): existing empty state ("No skills registered" + "Create a SKILL.md to get started")
- Empty (no matches): existing "No skills match" state with clear-search affordance
- Success / failure: existing `showToast` calls in the CRUD handlers

### Error States
- Registry fetch failure: silent (global polling already handles this gracefully — leave existing behavior)
- CRUD operation failure: toast with error message (existing handler pattern in `RegistrySidebar.tsx:138-153`)

## Implementation Notes

### Conventions to Follow

- `useSearchParams` is the project's standard for URL state (see `SkillsWorkspace.tsx`, `RunsWorkspace.tsx`)
- Workspace-scoped palette commands are registered via a workspace-mounted hook (see `useSkillsCommands.ts`)
- Workspaces use the `WorkspaceShell` primitive with `workspace="<id>"` so compact-mode and resize-state are scoped
- Lucide icons; no inline SVG
- Tests follow the existing patterns in `web/src/__tests__/`: render the component, simulate user interaction, assert on output / router navigation

### Potential Pitfalls

- **Route precedence**: `/library` (workspace) and `/library-window` (detached) both exist. The workspace route lives inside `AppShell`; the detached route is outside. Verify both render correctly and `<Navigate>` from `/registry` doesn't accidentally redirect to the workspace
- **`WORKSPACE_CONFIG` order**: the array order determines render order. Ensure `Topology / Stage(skills) / Library / Runs` produces correctly in `WorkspaceSwitcher`
- **`shortcutKey: '4'`** must not collide with an existing handler. Audit `useKeyboardShortcuts.ts` carefully — the current Cmd+4 → traces handler **must** be removed, not just shadowed
- **Storage keys**: `LAST_WORKSPACE_GLOBAL_KEY` and `LAST_WORKSPACE_PER_STACK_PREFIX` (in `web/src/lib/landing-workspace.ts`) persist the workspace id — `'library'` is a new value. Ensure stale stored values (e.g., `'skills'`) still resolve correctly
- **`useUIStore.compactMode`**: the per-workspace compact mode state is a typed object keyed by workspace id. You **must** add `library: boolean` (initialized to `false`) to the type definition and the initial state in `web/src/stores/useUIStore.ts`, or `WorkspaceShell` will throw a TypeScript error when it reads `compactMode.library`. Also verify any selectors or actions that touch `compactMode` to ensure they don't have a hardcoded key list. Same audit applies to any other workspace-keyed state shapes in `useUIStore` (resize widths, last-selected items, etc.) — grep for the existing workspace ids (`'topology'`, `'skills'`, `'runs'`) and extend any that need a `'library'` peer
- **Test brittleness**: tests that explicitly assert "3 workspace pills" need updating. Search for `WorkspaceSwitcher` test references
- **Gateway sidebar copy**: the old `<RegistrySidebar embedded />` provided in-context skill management on the topology canvas; replacing it with a "Manage Skills →" link is a small regression for users who liked the inline access. Acceptable trade-off given the discoverability win, but consider including a small skill count badge in the CTA ("Manage Skills (21)") to preserve some context

### Suggested Build Order

1. **Branch**: `feature/library-workspace` (use `/branch-fork` skill)
2. **Read the precedent**: `git show c23ca15` end-to-end
3. **Extract `LibraryGrid` component** from `DetachedRegistryPage.tsx`. Verify the detached page still renders identically using the extracted component
4. **Add `'library'` to `WORKSPACE_CONFIG`** with the new entry and the "Stage" rename. Verify the 4th pill appears in the header (route 404s — that's expected at this step)
5. **Create `LibraryWorkspace.tsx`** wrapping `LibraryGrid` in `WorkspaceShell`; add URL state via `useSearchParams`
6. **Wire `/library` route** in `routes.tsx`; rename `/registry` route to `/library-window` and add `<Navigate>` from `/registry`
7. **Update `useWindowManager.ts`** so the popout points to `/library-window`
8. **Remove the Cmd+4 → traces shortcut** from `useKeyboardShortcuts.ts`; the workspace auto-mapping picks up Cmd+4 for Library
9. **Update `GatewaySidebar.tsx`** — replace embedded registry with "Manage Skills →" link
10. **Add `useLibraryCommands.ts`** and call it from `LibraryWorkspace.tsx`
11. **Sweep copy** — find remaining "Skills" labels in the IDE workspace's UI strings; rename to "Stage" where user-facing only
12. **Update tests**:
    - `__tests__/WorkspaceSwitcher.test.tsx` (assuming it exists) — 4 tabs now
    - `useKeyboardShortcuts.test.tsx` — Cmd+4 → Library, no traces
    - `RegistryPanel.test.tsx` — still passes
    - Add `LibraryWorkspace.test.tsx` — URL state, search, filter, popout
    - Add a routing test asserting `/registry` → `/library-window` redirect
13. **Manual verification**:
    - Run `cd web && npm run dev` (or use `make dev`)
    - Confirm all 4 tabs render in the expected order
    - Cmd+1/2/3/4 cycle Topology / Stage / Library / Runs
    - Library URL state survives refresh and tab switch
    - Popout opens `/library-window` and behaves identically to the previous detached page
    - `/registry` URL redirects to `/library-window`
    - Topology gateway-node click shows the "Manage Skills →" CTA and navigates correctly
14. **Lint + test**: `cd web && npm run lint && npm test`
15. **Commit + PR**: use `/pr-fork`. PR title: `feat: add Library workspace and rename Skills tab to Stage`. PR body should explicitly call out:
    - The user-facing rename (Skills → Stage; Registry popout name → Library)
    - The route rename (`/registry` → `/library-window` with redirect)
    - That internal model naming (`registry/`, `useRegistryStore`, `/api/registry`) is intentionally unchanged in this PR

## Acceptance Criteria

1. Top nav renders exactly four pills in this order, left to right: **Topology**, **Stage**, **Library**, **Runs**
2. The "Stage" pill links to `/skills` (unchanged route) and renders the existing per-skill Agent IDE
3. The "Library" pill links to `/library` and renders a workspace with a skill card grid, search input, state filter tabs (All / Active / Draft / Disabled), New Skill button, Refresh button, and popout button. `/library/:skillName` deep-links open the workspace with that skill focused (editor mounted or row selected)
4. Cmd/Ctrl + 1/2/3/4 navigate to Topology / Stage / Library / Runs respectively (note: Runs moves from Cmd+3 to Cmd+4 — this is intentional, called out in the PR description)
5. Cmd/Ctrl + 4 no longer toggles the bottom panel "traces" tab; traces remains accessible by clicking the tab and via the command palette
6. The Library workspace persists search query and active filter in URL params (`?q=...&filter=...`); reloading the page restores both
7. The popout button in the Library workspace opens `/library-window` in a new window with the same content as the previous `/registry` detached page. The popout is reachable but not required — a user who never clicks it can perform every Library operation (browse, search, filter, create, edit, delete, activate, disable) from the in-app workspace
8. `/registry` URL is preserved via a redirect to `/library-window` (so existing bookmarks and open windows continue to work)
9. The Topology gateway-sidebar no longer embeds the registry sidebar; it shows a "Manage Skills (N) →" CTA (with the live skill count from `useRegistryStore`) that navigates to `/library` instead
10. The command palette includes Library-scoped commands when the Library workspace is active (New Skill, Refresh, Show All, Filter Active/Draft/Disabled, Open in New Window); these commands are absent when on other workspaces
11. The `DetachedRegistryPage` route at `/library-window` continues to function (same UI as today, including its existing `ZoomControls` — keep those on the detached page only; do NOT add zoom controls to the in-app workspace) and now reuses the same `LibraryGrid` component as the workspace — no duplicated grid/filter logic between the two
12. `/library/:skillName` deep-links open the workspace with the named skill's editor mounted; a non-existent skill name shows a toast and redirects to `/library` cleanly (no infinite redirect loop, no stuck error state)
13. Existing tests pass; new tests cover (a) workspace switcher renders 4 tabs in the correct order, (b) Cmd+3 navigates to Library and Cmd+4 navigates to Runs, (c) URL state in Library survives a refresh, (d) `/library/:skillName` deep-link mounts the editor + falls back gracefully on a bad name, (e) `/registry` redirects to `/library-window`, (f) Gateway sidebar renders the CTA link with skill count
14. `npm run lint` passes with no new warnings; `npm test` passes; `tsc --noEmit` passes
15. PR description explicitly lists the deferred internal rename (`registry/` → `library/`) as out of scope, with rationale (smaller blast radius, easier review)
16. Manual smoke test confirms the workspace switcher renders correctly at typical desktop widths (1280–1920px) without label wrapping or pill overflow

## References

- Project precedent commit: `c23ca15` — "feat: migrate agent IDE into unified shell at /skills" (2026-05-15). Direct template for this PR
- Project workspace primitive: `d99132c` — "feat: add WorkspaceShell shared primitive"
- Project registry refactor: `95c96c9` — "refactor: registry-driven workspace metadata"
- Full evaluation: `prompts/gridctl/library-workspace/feature-evaluation.md`
- Market analogs:
  - Flowise (top-level Marketplace / Tools / Assistants nav)
  - AutoGen Studio (Build / Playground / Gallery tabs)
  - Dify (Studio / Explore / Knowledge tabs)
  - Backstage (Catalog as primary surface)
  - Pulumi Cloud Registry (dedicated nav entry)
- Lucide icons: `Library`, `Code`, `Network`, `PlayCircle`
- React Router v7: `useSearchParams`, `Navigate`, lazy routes
