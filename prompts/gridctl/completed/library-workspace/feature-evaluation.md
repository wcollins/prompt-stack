# Feature Evaluation: Library Workspace (Skills Registry as a First-Class Tab)

**Date**: 2026-05-19
**Project**: gridctl
**Recommendation**: **Build**
**Value**: High
**Effort**: Small

## Summary

Promote the Skills Registry from a buried sidebar / popout into a first-class top-nav workspace called **Library**, and rename the existing per-skill Agent IDE tab from **Skills** to **Stage**. Proposed top nav order: `[ Topology ] [ Stage ] [ Library ] [ Runs ]`. The change is architecturally cheap, on the project's active migration trajectory (the `/skills` workspace itself was promoted from a detached page on 2026-05-15), aligns with table-stakes navigation patterns in comparable tools (Flowise, AutoGen Studio, Dify, Backstage), and removes a real discoverability problem.

Today the only "full" view of the Registry is a popped-out browser tab (`/registry`). After this change, the in-app workspace is the default; the popout becomes a power-user affordance for a second-monitor workflow (browse skills in Library on one screen, edit in Stage on the other) — not the discovery path.

### Workspace Roles (Discovery-to-Development Loop)

The four tabs map onto a coherent operator workflow:

| Tab | Question it answers |
|-----|---------------------|
| **Library** | "What can my grid do?" — browse, discover, install, toggle |
| **Stage** | "How does *this* skill work?" — edit, debug, trace one skill |
| **Topology** | "How are these skills distributed?" — infrastructure / live graph |
| **Runs** | "What is happening right now?" — execution history + live stream |

Today this loop is broken at the first step: discovery requires popping out a detached window, which forces a disjointed cross-window context switch when the user wants to drill into a skill in Stage. Promoting Library closes the loop inside one shell.

## The Idea

The Skills Registry — a catalog of all agent skills with state (active / draft / disabled), search, create / edit / delete, and bulk-update — currently lives behind a discovery wall:

1. Open Topology workspace
2. Click a gateway or skill-group node
3. The Registry section appears inside the right-rail Gateway sidebar
4. Click the popout button to open `/registry` as a detached window

This is **3 clicks plus a prerequisite mental model** ("I have to select the gateway node first"). For new users, demo viewers, and daily drivers managing skills, the path is unintuitive.

The proposal is to elevate the Registry to a **top-nav workspace** ("Library"), making it a one-click peer to Topology / Stage / Runs. Simultaneously, the current "Skills" tab — which is actually the per-skill **Agent IDE** (typed graph editor for a single skill) — gets renamed to **Stage** to eliminate naming confusion between "the IDE for one skill" and "the catalog of all skills."

Beneficiaries:
- **New users / demo viewers**: see the catalog at a glance instead of having to be shown it
- **Daily drivers**: 1 click to toggle / create / edit skills instead of 3
- **Anyone parsing the nav**: "Stage" and "Library" are unambiguous — one is where you author one skill, the other is where you manage all of them

## Project Context

### Current State

- Top nav lives in `web/src/types/workspace.ts`, declaratively driven by `WORKSPACE_CONFIG`. Three entries today: Topology / Skills / Runs with `shortcutKey: '1' | '2' | '3'`.
- Workspace switcher (`web/src/components/shell/WorkspaceSwitcher.tsx:43`) maps over `WORKSPACE_CONFIG` — adding a 4th entry produces a 4th pill automatically.
- Routes are wired in `web/src/routes.tsx`. Three workspace routes (`/topology`, `/skills`, `/runs`) inside `AppShell`, plus detached frameless routes outside (`/registry`, `/logs`, `/sidebar`, `/editor`, `/metrics`, `/var`, `/traces`).
- Registry currently has two co-existing surfaces:
  - `web/src/components/registry/RegistrySidebar.tsx` — sidebar version, embedded inside `GatewaySidebar` via `<RegistrySidebar embedded />` at `GatewaySidebar.tsx:61`
  - `web/src/pages/DetachedRegistryPage.tsx` — full-screen detached version at `/registry`, opened via `useWindowManager().openDetachedWindow('registry')`
- Global polling (`web/src/hooks/usePolling.ts:88-107`) already fetches `fetchRegistryStatus()` + `fetchRegistrySkills()` and writes to `useRegistryStore`. **A Library workspace inherits this for free** — no new polling required.

### Active Architectural Trajectory

This change rides a pattern the team is already executing:

| Commit | Date | What |
|--------|------|------|
| `c194783` | 2026-05-14 | Add unified app shell with workspace router |
| `74b67e5` | 2026-05-14 | Add real runs workspace with global SSE bus |
| `c23ca15` | 2026-05-15 | **Migrate agent IDE into unified shell at /skills** — promoted from a detached page to a workspace |
| `d99132c` | 2026-05-15 | Add WorkspaceShell shared primitive |
| `95c96c9` | 2026-05-16 | Refactor: registry-driven workspace metadata |

Library-as-workspace is the obvious next step on the same path. `c23ca15` is a direct template — promoting a detached page into a workspace, ~398 lines added, ~477 removed (mostly dedup).

### Integration Surface

Files that need to be edited or created:

**Edit (small):**
- `web/src/types/workspace.ts` — extend `Workspace` union with `'library'`, rename `'skills'` label to "Stage", append `library` entry with icon (Library from lucide-react) and `shortcutKey: '4'`
- `web/src/routes.tsx` — add lazy-loaded `LibraryWorkspace` route at `/library`; rename detached `/registry` route to `/library-window` so the workspace path is free
- `web/src/hooks/useKeyboardShortcuts.ts:79-90` — drop the Cmd+4 quick-jump to traces panel (auto-mapping from `WORKSPACE_CONFIG` will then bind Cmd+4 to Library)
- `web/src/hooks/useWindowManager.ts` — update the registry popout to open `/library-window` instead of `/registry`
- `web/src/components/gateway/GatewaySidebar.tsx:46-61` — replace embedded `<RegistrySidebar embedded />` with a slim affordance ("Open Library →") OR keep the embedded preview if the user wants in-context access on the topology canvas
- `web/src/lib/landing-workspace.ts` — verify the landing-workspace heuristic still routes correctly; no hardcoded list, so likely no change

**Create:**
- `web/src/components/workspaces/LibraryWorkspace.tsx` — new workspace; clones the structure of `SkillsWorkspace.tsx` but renders the registry grid. The cleanest implementation extracts the body of `DetachedRegistryPage.tsx` (`DetachedRegistryContent`) into a shared `LibraryGrid` primitive and re-uses it from both the workspace and the detached window
- `web/src/components/library/useLibraryCommands.ts` — workspace-scoped command palette commands (Create skill, Filter active/draft/disabled, Refresh, etc.), modeled on `web/src/components/skills/useSkillsCommands.ts`

**Rename (code-level):**
- `web/src/components/registry/*` → consider renaming to `library/*` for consistency. **Defer**: not required for this PR; the underlying API endpoint stays `/api/registry` and the store stays `useRegistryStore`. The user-facing name is what changes; the internal "registry" model is fine. (Note this in the PR description so reviewers don't expect a wholesale rename.)
- Pages: `DetachedRegistryPage.tsx` stays; just its route mounts at `/library-window` instead of `/registry`

### Reusable Components

These are already nicely decoupled and ready to lift into a workspace as-is:

- `web/src/components/registry/SkillCard.tsx`
- `web/src/components/registry/SkillActions.tsx`
- `web/src/components/registry/SkillEditor.tsx`
- `web/src/components/registry/StateBadge.tsx`
- `web/src/components/registry/SkillCardSkeleton.tsx`
- `web/src/components/registry/SkillFileTree.tsx`
- `web/src/stores/useRegistryStore.ts`
- `web/src/lib/api.ts` registry API helpers (`fetchRegistryStatus`, `fetchRegistrySkills`, `activateRegistrySkill`, `disableRegistrySkill`, `deleteRegistrySkill`, `fetchSkillUpdates`, `updateSkillSource`)
- `web/src/components/layout/WorkspaceShell.tsx` (shared primitive, used by all three current workspaces)

## Market Analysis

### Competitive Landscape

Cross-tool survey of how the "skill / tool / agent library" surfaces in primary navigation:

| Tool | Library naming | Placement |
|------|----------------|-----------|
| Flowise | Marketplace, Chatflows, Agentflows, Tools, Assistants | Top-level sidebar (always visible) |
| AutoGen Studio | Build / Playground / **Gallery** | Three top tabs |
| Dify | Studio / **Explore** / Knowledge | Top tabs |
| n8n | Workflows / **Templates** / Credentials | Left sidebar |
| Backstage | **Catalog** / Plugin Marketplace | Catalog is the primary surface of the app |
| Pulumi Cloud | **Registry** as a top-level Platform section | Dedicated nav entry |
| Continue.dev | **Hub** (agents / rules / MCP servers) | Top-level hub |
| LangSmith | Prompt **Hub** + Studio | Top-level |
| VS Code | Extensions | Dedicated activity-bar entry |
| Claude Desktop | Connectors (buried in Customize) | Settings — *anti-pattern, frequent forum complaints* |
| Cursor | Tools & MCP (Settings) | Settings — *same anti-pattern* |

### Market Positioning

For control-plane / builder-style tools (gridctl's category), surfacing the library in the persistent nav is **table stakes**, not a differentiator. Tools that bury it (Claude Desktop, Cursor) receive ongoing user pushback. gridctl shipping without it is currently a minor *minus* against analogs; shipping with it brings parity.

The naming choice matters:

- **"Library"** (chosen) — clean, broad recognition (VS Code-adjacent vocabulary), pairs cleanly with "Stage." Avoids the implication of remoteness that "Hub" or "Marketplace" carry.
- **"Registry"** — strong control-plane vocabulary (Pulumi / Backstage / k8s), but easily confused with the internal `registry` API and store naming. Loses external warmth.
- **"Marketplace"** — implies install-from-remote, which doesn't fit the local-skills story today.

### Demand Signals

Strong qualitative signals from the surrounding project:
- The existing detached `/registry` page exists because the sidebar version is too cramped — i.e., users *already* want a full-page view
- The popout button (`web/src/components/registry/RegistrySidebar.tsx:93-95`) is a workaround for the missing top-level surface
- The active workspace-migration commits show the team has already decided "first-class workspace > buried surface" as a pattern

### Platform Positioning (Card-Grid as Dashboard Home)

Card-grid catalogs are the de facto "Home" view for modern developer SaaS — Vercel projects, Stripe dashboard, Render services, Railway projects, GitHub repos. Promoting the Library card grid into the top nav signals **platform** rather than **utility**: gridctl shifts from "MCP debugger you sometimes use" to "control plane you live in." This is the same instinct that drove `c194783` (unified app shell) — the Library elevation completes the move.

## User Experience

### Interaction Model

**Discovery (today)** — 3 clicks + prerequisite knowledge:
1. Land on Topology
2. Click gateway / skill-group node
3. Click popout button on sidebar

**Discovery (proposed)** — 1 click:
1. Click "Library" in top nav

**Daily-driver workflow (proposed):**
- Stage = author one skill at depth (typed graph, run launcher, node inspector — the existing IDE experience, just renamed)
- Library = browse / search / filter / toggle / create / delete / import / update skills at breadth
- The two roles are now lexically distinct: you Stage one, you browse the Library

### Workflow Impact

- **Positive**: removes friction for every skill-management operation (toggle active/draft, edit metadata, new skill wizard, import updates)
- **Positive**: removes the requirement to be on Topology + have a gateway selected
- **Positive**: demo / first-impression moments now expose the Library without effort
- **Neutral**: no workflow regression — the existing topology gateway-sidebar entry point can either keep an "Open Library →" link (recommended) or stay with the embedded preview

### UX Recommendations (Specifics)

1. **Mirror `SkillsWorkspace` shape**: left rail (sidebar of skills or filters), center (card grid), optional right rail (selected skill detail / preview) — use the existing `WorkspaceShell` primitive
2. **URL-encode state**: search query and active filter belong in URL params (e.g., `/library?q=blog&filter=active`). This preserves context across tab switches, deep-links, and popout
3. **Keep the popout — but reframe it**: rename the detached route to `/library-window`; the Library workspace header retains a popout button. The popout is now a *power-user* second-monitor affordance ("browse Library on one screen, edit in Stage on the other"), no longer the *only* path to a full-page view. The default discovery path is the in-app workspace
4. **Empty state**: the Library workspace inherits the existing `BookOpen` empty state from `DetachedRegistryPage.tsx:421-428`
5. **Command palette**: add `useLibraryCommands.ts` to register: Create skill, Search skills, Refresh, Filter (active/draft/disabled), Update all
6. **Gateway sidebar (topology)**: replace the embedded Registry with a small CTA — "Manage Skills →" — that navigates to `/library` (with the current skill-group context as a filter if applicable). Keeps the Topology canvas clean.
7. **Icon**: use `Library` from `lucide-react` (already imported elsewhere in the registry files)
8. **Accessibility**: the existing `WorkspacePill` (`WorkspaceSwitcher.tsx:9-32`) already provides `role="tab"` + `aria-selected`; the 4th pill inherits this

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Significant | Buried 3-click discovery for a core, high-frequency surface |
| User impact | Broad + Deep | Every user category benefits (new, demo, daily) |
| Strategic alignment | Core mission | Direct continuation of the c194783 / c23ca15 / 74b67e5 migration |
| Market positioning | Catch up + slight leap | Table stakes vs Flowise / AutoGen / Dify / Backstage; ahead of Claude Desktop / Cursor |

### Cost Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Minimal | `WORKSPACE_CONFIG` is declarative; switcher / shortcuts auto-derive |
| Effort estimate | Small | ~2-4 hours of focused work plus tests; precedent in c23ca15 |
| Risk level | Low | Localized; existing test files (`RegistryPanel.test.tsx`, `SkillActions.test.tsx`) cover key surfaces; route rename is the only externally visible change beyond UI |
| Maintenance burden | Minimal | Likely *reduces* maintenance by consolidating Registry-sidebar + detached-Registry duplicate code paths |

## Recommendation

**Build.** This is one of the cheapest, highest-value UI changes available to the project right now:

- **Cheap**: the workspace primitive is in place, polling is already global, the registry components are already decoupled, and the c23ca15 commit is a literal template
- **High value**: solves a real, ongoing discoverability problem and aligns with table-stakes navigation in the closest analogs
- **On-trajectory**: the team is mid-migration to the workspace model; doing Library now is consistent with `c194783` → `74b67e5` → `c23ca15` and arguably overdue

**Locked decisions (per user direction):**
- Tab order: `[ Topology ] [ Stage ] [ Library ] [ Runs ]`
- Current "Skills" tab renamed to **Stage**
- New 4th tab named **Library** (the existing popped-out Registry)

**Locked decisions for build:**
- **Shortcuts match visual order**: Cmd+1=Topology, Cmd+2=Stage, **Cmd+3=Library**, **Cmd+4=Runs**. Runs moves from Cmd+3 → Cmd+4 — intentional muscle-memory break in favor of left-to-right alignment (the convention in VS Code, Slack, Linear, etc.). Drop the existing Cmd+4 → traces panel quick-jump; traces stays reachable via click + palette
- Keep the popout but reframe it: rename detached route from `/registry` to `/library-window`. Default is in-app workspace; popout is a power-user second-monitor option
- Library workspace state (search + filter) lives in URL params (`?q=…&filter=…`)
- Library uses deep-linkable skill paths (`/library/<skill-name>` opens the workspace with that skill focused / its editor open). Non-existent skill → toast + redirect to `/library`
- State writes (activate / disable / create / delete) flow through the existing `useRegistryStore` so the Stage sidebar and Topology graph see updates instantly — no more cross-window `BroadcastChannel` reliance for primary access
- Replace the embedded `<RegistrySidebar embedded />` in `GatewaySidebar` with a "Manage Skills (N) →" link to `/library` (count badge preserves the at-a-glance value the embedded panel provided)
- Zoom controls stay on the detached `/library-window` only; in-app workspace uses browser zoom
- `useUIStore.compactMode` and any other workspace-keyed state must add a `library` entry to avoid TypeScript errors in `WorkspaceShell`

## References

- Project commits showing migration pattern: `c194783`, `74b67e5`, `c23ca15`, `d99132c`, `95c96c9` (gridctl repo, May 2026)
- Comparable tools surveyed:
  - [Flowise Marketplace](https://deepwiki.com/FlowiseAI/Flowise/11.1-marketplace-and-template-flows)
  - [AutoGen Studio (Build / Playground / Gallery)](https://microsoft.github.io/autogen/stable/user-guide/autogenstudio-user-guide/usage.html)
  - [Dify Studio / Explore](https://docs.dify.ai/en/use-dify/tutorials/workflow-101/lesson-10)
  - [n8n Editor + Templates](https://docs.n8n.io/courses/level-one/chapter-1/)
  - [Backstage Plugin Marketplace](https://backstage.io/plugins/)
  - [Backstage Software Catalog](https://backstage.io/docs/features/software-catalog/)
  - [Pulumi Registry](https://www.pulumi.com/registry/)
  - [Continue.dev Hub](https://www.continue.dev/hub?type=agents)
  - [LangSmith Prompt Hub](https://smith.langchain.com/hub)
  - [LangSmith Studio](https://docs.langchain.com/langsmith/studio)
  - [VS Code Extension Marketplace](https://code.visualstudio.com/docs/editor/extension-marketplace)
  - [Cline MCP Marketplace](https://cline.bot/mcp-marketplace)
- Anti-pattern references:
  - [Claude Desktop MCP Connectors (buried)](https://support.claude.com/en/articles/10949351-getting-started-with-local-mcp-servers-on-claude-desktop)
  - [Cursor MCP Settings panel](https://cursor.com/docs/cli/mcp)
