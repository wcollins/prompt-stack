# Feature Evaluation: Variables (Vault) as First-Class Workspace

**Date**: 2026-05-22
**Project**: gridctl
**Recommendation**: Build with caveats
**Value**: Medium
**Effort**: Medium → Large (~1 work-week, sequenced in 4 phases)

## Summary

Promote the Variables/Vault feature from a Header-toggled sidebar + detached window into a top-level workspace alongside Topology and Library, with `/vault` route, switcher pill, `KeyRound` icon, and `Cmd+3` shortcut. The proposal as written is the wrong shape — it would create a third near-duplicate of an already-duplicated 1,030-line UI, ship a CRUD table next to a graph canvas and a card catalog (peer-parity mismatch), and run against the codebase's recently completed 4→2 workspace consolidation. **Reshaped recommendation: refactor first, scope the sidebar down to quick-lookup, ship the workspace with a signature bulk-import flow, and bridge the gap with a Topology-node deep-link.**

## The Idea

Make Variables a top-level resource in the web UI's information architecture. Reasoning:
- **Discoverability** — new users may not find variables hidden behind a Header icon.
- **Workflow ergonomics** — bulk operations (import .env, manage Variable Sets, search across many keys) need more room than a slide-out sidebar.
- **CLI/UI symmetry** — `gridctl var` is a top-level CLI verb; treating variables as a first-class resource in the UI mirrors the CLI mental model.

Who benefits: single-user developers running gridctl locally who manage many variables across multiple MCP servers and skills. The primary motivation per user input is **strategic UI consistency**, not a specific user complaint.

## Project Context

### Current State

gridctl is a Go CLI with a React/TypeScript web UI (Vite, Zustand, React Router). The web UI has two top-nav workspaces today:
- **Topology** — graph canvas of running MCP servers and clients
- **Library** — catalog of installed skills (cards)

Recent direction has been **consolidation**, not expansion: PRs #681, #682, #684, #685 removed agent/runs/skills-IDE workspaces. The proposal would reverse this within weeks.

### Integration Surface

Adding a third workspace at the **mechanical level** is clean — the architecture explicitly supports it:

- `web/src/types/workspace.ts:19` — `WORKSPACE_CONFIG` is a single source of truth. Appending one entry auto-wires the switcher pill, `Cmd+3` shortcut, and labels.
- `web/src/components/shell/WorkspaceSwitcher.tsx:36` — Maps the config array; no edits needed.
- `web/src/routes.tsx` — One new lazy-loaded `<Route path="/vault">`.
- `web/src/stores/useUIStore.ts` — Add `vault` entry to `COMPACT_MODE_DEFAULTS`.
- `web/src/lib/landing-workspace.ts` — `isWorkspace()` + `resolveLandingWorkspace()` already gracefully fall back to `topology` for unknown localStorage values.

### Reusable Components

The Vault sidebar already uses well-factored atoms that any new surface can consume:
- `useVaultStore` (38 lines, Zustand) — variables, sets, loading, locked, encrypted.
- `VariableTypeBadge`, `VariableVisibilityIcon`, `VariableTypeSelector`, `VariableSecretToggle`, `VaultLockPrompt` — small presentation components.
- `variableTypeHelpers.ts` — validation and placeholder logic.
- Backend (`internal/api/vault.go`) — 13 REST endpoints covering CRUD, sets, lock/unlock, and `POST /api/var/import` (bulk import already supported server-side).

### Critical Finding: Existing Duplication

`web/src/components/vault/VaultPanel.tsx` (**1,030 lines**) and `web/src/pages/DetachedVaultPage.tsx` (**1,035 lines**) are near-twins — same logic, different chrome. The proposal would add a third ~1,000-line surface without a shared-logic foundation. **The single biggest implementation risk is triplicating code that should already have been consolidated.**

## Market Analysis

### Competitive Landscape

Three cohorts; gridctl sits between them:

**MCP-adjacent (Claude Desktop, Continue.dev, Cline, Goose, LibreChat, Open WebUI)** — variables are **hidden**. JSON config, settings sub-tabs, contextual drawers. None elevate to top-nav.

**CLI-to-GUI tools (Stripe, Vercel, Fly, Docker, Heroku, Convex, GitHub Actions)** — uniformly **consolidate**. They do not mirror CLI verbs to top-nav. Fly has `flyctl secrets` as a top-level CLI verb but the dashboard scopes secrets to apps. Vercel buries env in Project Settings. Pattern: resources with identity/lifecycle get top-nav; config that parameterizes other resources gets Settings.

**Integration platforms (n8n, Postman, Insomnia)** — **do elevate**. n8n's "Credentials" is a top-level sidebar peer to Workflows. Postman's Environments are a peer sidebar element. This is the strongest direct precedent for gridctl.

### Market Positioning

gridctl's shape (orchestrating many independently configurable units that consume cross-cutting credentials) is closer to **n8n/Postman than to Vercel/Fly**. Variable Sets mirror n8n's credentials groups. So elevation is **defensible by precedent**, but it is a **mild differentiator, not table-stakes** in the MCP-adjacent cohort.

### Ecosystem Support

No library or framework gap. React Router lazy loading, Zustand state, lucide-react icons, Vite code-splitting are all in place. The work is entirely application-level UI/UX.

### Demand Signals

No direct user complaints surfaced; the proposal is motivated by strategic UI consistency. The strongest indirect demand signal is the existence of the detached `/var` window — someone wanted "more room than the sidebar" enough to build a second surface. That signal points toward "improve the larger-canvas Vault experience," which a workspace can satisfy.

## User Experience

### Interaction Model

**Discovery uplift is modest**. The actual discovery moment for variables is during MCP server configuration, not idle nav exploration. A switcher pill doesn't intercept that moment any better than a sidebar icon. Cheaper interception wins:
- Inline `+ Add variable` affordance in MCP server config forms.
- First-run pulse hint on the sidebar icon.
- Tooltip with the keyboard shortcut.

These would land ~80% of the discovery benefit for ~1 day of work — but they are complementary, not exclusive, with the workspace.

### Workflow Impact

The core workflow that motivates the feature ("configuring an MCP server in Topology, need to add a secret") is **measurably worse** in the naive workspace flow:

- Current: `Topology → sidebar open → add var → sidebar close → resume config` (canvas state preserved).
- Naive workspace: `Topology → Cmd+3 (canvas torn down) → add var → Cmd+1 → re-find server → resume config`.

The sidebar wins this inline-edit case decisively. The workspace must not regress it. **Implication**: the sidebar cannot go away; the workspace must own a *different* set of tasks than the sidebar.

### Peer Parity Risk

Topology = spatial graph canvas. Library = browsable card catalog. The proposal's described shape ("rich table with filtering, search, inline editing, summary stats header") is a **settings-page idiom**. Without something canvas-like, it will *read* as a promoted settings page regardless of where it sits in the IA.

To earn peer status, the workspace needs at least one non-CRUD element:
- **Bulk `.env` paste-to-import** as the signature feature (table-stakes for the dashboard category; what Doppler, Vercel, Render, and Railway all do well).
- **Used-by indicator** per variable showing which Topology nodes consume it (cross-cutting view the sidebar can't offer).
- **Missing-key diff** between Variable Sets (Doppler pattern — only valuable if multi-set usage is common).

### UX Recommendations

Right division of labor between sidebar and workspace:

| Action | Surface |
|---|---|
| Look up by name + reveal + copy | Sidebar |
| Add one variable | Sidebar |
| Edit one variable | Sidebar |
| Delete one variable | Sidebar |
| Bulk `.env` import / export | Workspace |
| Create / delete Variable Sets | Workspace |
| Assign variables to sets in bulk | Workspace |
| Search across hundreds of vars | Workspace |
| Lock / unlock vault | Workspace (it's a session-level action, not in-flow) |
| "Used by" lookup | Workspace |

The sidebar must **lose** features (set creation, lock/unlock) to avoid the duplicated-state anti-pattern. This is a user-visible behavior change and must be communicated in release notes.

### Accessibility & Keyboard

- `Cmd+3` is currently unbound; pattern extends `Cmd+1`/`Cmd+2` cleanly via existing `WORKSPACE_BY_KEY` derivation.
- `role="tablist"` extends to three items without semantic concern; ensure the sidebar is not also announced as a tab.
- Compact-mode behavior must be defined: a CRUD table inside a collapsed right rail is unreadable; the workspace owns the main viewport.

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|---|---|---|
| Problem significance | Minor → Moderate | Sidebar already works for the dominant flow. Real pain is bulk import + managing many vars — narrower than the proposal's framing. Motivation is strategic, not pain-driven. |
| User impact | Broad+Shallow | Everyone sees the third nav pill, but only those with 20+ vars or doing bulk imports benefit deeply. |
| Strategic alignment | Adjacent, with friction | CLI parity supports it; recent 4→2 workspace consolidation argues against re-expansion; industry CLI-to-GUI pattern argues against mirroring CLI verbs to top-nav. |
| Market positioning | Mild differentiator | n8n / Postman precedent supports elevation; MCP-cohort doesn't. Not table-stakes. |

### Cost Breakdown

| Dimension | Rating | Notes |
|---|---|---|
| Integration complexity | Significant | Workspace shell is mechanical; the real complexity is what goes inside. Naive reuse → triplication. Done right requires shared-hook extraction first. |
| Effort estimate | Medium → Large | Phase 1 (refactor): 2–3 days. Phase 2 (sidebar scope-down): 1 day. Phase 3 (workspace + bulk import): 2–3 days. Phase 4 (Topology bridge): 1 day. Total ~1 work-week, more with polish/QA. |
| Risk level | Medium | Vault is security-sensitive (lock/unlock, encryption-at-rest, secret revelation). Refactor must not regress those paths. Three test files have hardcoded "two workspace" assumptions that need updating. Sidebar feature reduction is a user-visible behavior change. |
| Maintenance burden | Moderate (after refactor) | Status quo already carries 2 near-duplicate 1,030-line files. Refactoring first *reduces* total maintenance even after adding a third surface; skipping the refactor *compounds* existing debt. |

### Weighting Notes

- Primary value driver — strategic alignment — is mixed-negative: CLI parity says yes; recent consolidation direction and CLI-to-GUI industry pattern say no.
- Primary cost driver — risk — is manageable with refactor-first sequencing.
- Tiebreaker — broad+shallow user impact — is enough to support "Build" but not "Build as proposed."

## Recommendation

**Build with caveats.** The caveats reshape the proposal into a 4-phase sequence:

### Phase 1: Refactor (Prerequisite)
Extract shared hooks and components from `VaultPanel.tsx` and `DetachedVaultPage.tsx`:
- `useVaultManager()` — single hook owning fetch / create / update / delete / set-assignment / lock-unlock actions, plus loading and error state. Both surfaces consume it.
- Presentation atoms: `VariableRow`, `SetGroup`, `LockUnlockForm`, `NewSetForm` (already inline-duplicated), reveal-with-timeout primitive.
- Both VaultPanel and DetachedVaultPage become thin shells around the shared building blocks.
- **Acceptance criterion**: net line count goes *down*. If it stays flat or grows, the refactor isn't done.

### Phase 2: Scope Down the Sidebar
Remove from the sidebar:
- Variable Set creation/deletion (`NewSetForm` collapsed into workspace).
- Lock / unlock controls (move to workspace header).
- Bulk-style edits (set re-assignment dropdowns, etc.).

Sidebar keeps: search-by-key, reveal, copy, add single var, edit single var, delete single var. **This is a user-visible behavior change** — call it out in release notes.

### Phase 3: Build the Workspace
- Add `vault` to `WORKSPACE_CONFIG` with `KeyRound` icon and `shortcutKey: '3'`.
- Create `web/src/components/workspaces/VaultWorkspace.tsx` consuming the shared `useVaultManager()` hook. Use `WorkspaceShell` (Library's pattern, not Topology's).
- Left rail: variable set navigation.
- Main pane: filterable/searchable table of variables; bulk select; reveal/copy per row.
- Signature feature: **bulk `.env` paste-to-import** — empty-state nudges this; large textarea or file drop accepts `.env`, JSON, or YAML; preview before commit. Mirrors Doppler / Vercel / Railway / Render patterns and is the clearest justification for the workspace's existence.
- Header: total count, encrypted/locked status, lock/unlock action.

### Phase 4: Bridge the Workspaces
- On each Topology server node, add a "Secrets" affordance (gear menu or context-menu item) that deep-links to `/vault?filter=server:<name>` (or equivalent) with the set/filter pre-applied.
- This converts the cross-workspace jump from "accidental UX cost" to "intentional workflow shortcut" and addresses the core configuration-flow regression.

### Why not "Defer"

Defer is defensible (~1 day of sidebar polish would land most discovery benefit), but the codebase already carries the 2-file Vault duplication as latent debt. The refactor-first approach is the only path that *reduces* total system complexity, regardless of whether the workspace ships afterward. Deferring leaves the duplication in place.

### Why not "Build as proposed"

Building verbatim — wrap `VaultPanel` logic in a workspace shell, keep sidebar full-power, add summary stats — triplicates the 1,030-line file, ships a CRUD table next to a graph canvas (peer-parity mismatch), and creates the duplicated-state anti-pattern with two full UIs doing the same thing. It also burns the same ~1 work-week without reducing existing debt.

## References

**Industry / market**
- [n8n credentials (top-level nav)](https://docs.n8n.io/integrations/builtin/credentials/)
- [Postman environments](https://learning.postman.com/docs/getting-started/basics/navigating-postman)
- [Doppler secrets dashboard](https://docs.doppler.com/docs/secrets)
- [Doppler importing secrets](https://docs.doppler.com/docs/importing-secrets)
- [Vercel environment variables](https://vercel.com/docs/environment-variables)
- [Vercel sensitive (write-only) env vars](https://vercel.com/docs/environment-variables/sensitive-environment-variables)
- [Railway variables (Raw Editor / .env paste)](https://docs.railway.com/variables)
- [Render — Bulk add environment variables](https://render.com/changelog/bulk-add-environment-variables)
- [HashiCorp Vault UI navigation](https://developer.hashicorp.com/vault/tutorials/get-started/learn-ui)
- [Fly.io secrets (app-scoped, not global)](https://fly.io/docs/apps/secrets/)
- [GitHub Actions secrets/variables](https://docs.github.com/en/actions/security-guides/using-secrets-in-github-actions)
- [Claude Desktop MCP config (JSON-file based)](https://www.mcpbundles.com/blog/claude-desktop-mcp)
- [Cline MCP env-var UI bug #9065](https://github.com/cline/cline/issues/9065)

**IA / UX literature**
- [NN/g — Minimize Cognitive Load](https://www.nngroup.com/articles/minimize-cognitive-load/)
- [NN/g — Progressive Disclosure](https://www.nngroup.com/articles/progressive-disclosure/)
- [UX Myths — Myth #23: Choices should always be limited to 7±2](https://uxmyths.com/post/931925744/myth-23-choices-should-always-be-limited-to-seven)
- [Stéphanie Walter — Miller's 7±2 is not a menu rule](https://stephaniewalter.design/blog/your-menu-doesnt-need-millers-7-plus-minus-2-rule/)

**gridctl code**
- `web/src/types/workspace.ts` — workspace config single source of truth
- `web/src/components/vault/VaultPanel.tsx` — current 1,030-line sidebar
- `web/src/pages/DetachedVaultPage.tsx` — near-duplicate 1,035-line detached window
- `web/src/stores/useVaultStore.ts` — Zustand store (38 lines)
- `internal/api/vault.go` — backend REST surface
- `cmd/gridctl/var.go` — CLI parity reference
