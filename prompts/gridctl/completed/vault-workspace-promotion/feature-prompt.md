# Feature Implementation: Variables (Vault) as First-Class Workspace

## Context

**Project**: gridctl — a Go CLI + React/TypeScript web UI for orchestrating MCP (Model Context Protocol) servers and skills used by Claude and other AI coding agents. Single-user local app, not multi-tenant SaaS.

**Tech stack (web)**: React 18, TypeScript, Vite, React Router 6, Zustand, Tailwind CSS, lucide-react icons. Tests with Vitest.

**Tech stack (backend)**: Go HTTP API serving `/api/var/*` for variable CRUD, sets, lock/unlock, and bulk import. Server-side envelope encryption (Argon2id + XChaCha20-Poly1305).

**Current web architecture**: Two top-nav workspaces — Topology (graph canvas of running MCP servers) and Library (catalog of installed skills). A third workspace, Vault, is being added.

**Workspace shell pattern**: Workspaces are defined in a single `WORKSPACE_CONFIG` array in `web/src/types/workspace.ts`. Adding an entry auto-wires the switcher pill, keyboard shortcut, and labels. Each workspace is a lazy-loaded React component mounted in `web/src/routes.tsx`.

## Evaluation Context

This prompt reflects a **reshaped** version of the original proposal. The original asked for a mechanical "create VaultWorkspace, register in WORKSPACE_CONFIG, polish UI" sequence. Evaluation surfaced four findings that reshaped the work:

1. **Existing 2-file duplication**: `VaultPanel.tsx` (1,030 lines) and `DetachedVaultPage.tsx` (1,035 lines) are near-twins. A third surface without refactor = triplication. **Mitigation**: refactor first, extract shared hooks/atoms, both existing surfaces and the new workspace consume them.

2. **Peer-parity risk**: Topology (canvas) and Library (catalog) are visually rich resource views; a CRUD table would read as a promoted settings page. **Mitigation**: ship a signature feature (bulk `.env` paste-to-import) that justifies the workspace's existence beyond "same thing in a bigger box."

3. **Workflow regression risk**: Topology → Cmd+3 → vault → Cmd+1 tears down canvas state. The sidebar preserves it. **Mitigation**: keep the sidebar for quick-lookup (scope it down), add a Topology-node deep-link into the workspace filtered to that server's variables.

4. **Duplicated-state anti-pattern**: if sidebar and workspace both offer full management, users have two parallel UIs. **Mitigation**: explicit division of labor — sidebar owns single-variable quick-actions; workspace owns bulk operations and set management.

Full evaluation: `prompts/gridctl/vault-workspace-promotion/feature-evaluation.md`.

## Feature Description

Promote the Variables (Vault) feature into a top-level workspace at `/vault`, alongside Topology and Library. The workspace is a "management" surface (bulk import/export, Variable Set management, search across many keys, lock/unlock controls). The existing sidebar remains as a "quick lookup" surface (search, reveal, copy, single-variable add/edit/delete). The Header icon currently labeled "Settings" (which toggles the sidebar) keeps that role; do **not** repurpose it to navigate to `/vault`.

A Topology server node gets a new "Secrets" affordance that deep-links into the Vault workspace filtered to that server's referenced variables.

## Requirements

### Functional Requirements

**Refactor (Phase 1)**:
1. Extract a `useVaultManager()` hook from the logic currently duplicated between `VaultPanel.tsx` and `DetachedVaultPage.tsx`. The hook owns: fetch (variables + sets + status), create, update, delete, set-create, set-delete, assign-to-set, lock, unlock. Returns state (variables, sets, loading, error, locked, encrypted) and action callbacks.
2. Extract shared presentation atoms used by both surfaces: at minimum, the secret/variable row component (currently `SecretItem` or equivalent), the inline `NewSetForm`, the lock prompt wrapper, and the reveal-with-timeout primitive. Each atom is one focused component file under `web/src/components/vault/`.
3. Refactor `VaultPanel.tsx` to consume the shared hook and atoms. Net line count must decrease (target: <600 lines).
4. Refactor `DetachedVaultPage.tsx` to consume the shared hook and atoms. Net line count must decrease (target: <600 lines).
5. The two existing surfaces must remain behaviorally identical after refactor. Snapshot any test that exercises them; tests must pass without behavior changes.

**Sidebar scope-down (Phase 2)**:
6. Remove Variable Set creation/deletion UI from the sidebar (`VaultPanel`). Inline `NewSetForm` is removed; set assignment dropdown stays (users can still tag a variable into an existing set when creating/editing) but set *management* moves to the workspace.
7. Remove lock/unlock controls from the sidebar. (Lock-state badge can remain as a read-only indicator; the action moves to the workspace header.)
8. Add a small inline hint at the bottom of the sidebar: "Manage sets and bulk-import in the Variables workspace →" linking to `/vault`.

**Workspace (Phase 3)**:
9. Add `vault` to the `Workspace` union in `web/src/types/workspace.ts` and append to `WORKSPACE_CONFIG`:
   ```ts
   { id: 'vault', label: 'Variables', icon: KeyRound, shortcutKey: '3' }
   ```
10. Create `web/src/components/workspaces/VaultWorkspace.tsx`. Uses `WorkspaceShell` (the same pattern Library uses, not Topology's bespoke layout). Lazy-loaded.
11. Add a route in `web/src/routes.tsx`:
    ```tsx
    <Route path="/vault" element={
      <Suspense fallback={<WorkspaceLoadingShell />}>
        <VaultWorkspace />
      </Suspense>
    } />
    ```
12. Add a `vault` entry to `COMPACT_MODE_DEFAULTS` in `web/src/stores/useUIStore.ts`.
13. Workspace layout:
    - **Header strip** (consistent with LibraryWorkspace's header): "Variables" label, total count, lock-state badge ("Locked"/"Unlocked"/"Unencrypted"), lock/unlock action button, "Import .env" CTA, refresh button.
    - **Left rail** (via `WorkspaceShell`): "All variables" + one row per Variable Set, with counts. Selecting a set filters the main pane. "+ New set" inline action at the bottom of the rail.
    - **Main pane**: searchable, sortable table of variables. Columns: name, type badge, set, last updated, actions (reveal / copy / edit / delete). Click-to-reveal with 10-second auto-hide. Copy-to-clipboard without revealing.
14. **Signature feature — bulk `.env` import**: a modal triggered from the header CTA. Accepts:
    - Pasted text in `.env` syntax (`KEY=value`, comment lines, multi-line values via `\n` or quoted strings).
    - File drop / file picker for a `.env` file.
    - Preview step before commit: shows parsed key/value pairs with type detection, conflict indicators (key already exists), and per-row "skip" / "overwrite" / "merge into set" controls.
    - Single "Import" action that calls `POST /api/var/import`.
15. Empty state on the workspace nudges the bulk-import path, not single-add. ("Import from `.env` →" as the primary CTA, "Add one manually" as secondary.)
16. Lock/unlock controls live in the workspace header. The action invokes `POST /api/var/lock` and `POST /api/var/unlock` per existing API surface.

**Topology bridge (Phase 4)**:
17. On Topology server nodes, add a "Secrets" affordance (context menu item or inspector panel button — choose what fits existing inspector patterns) that navigates to `/vault?filter=server:<server-name>` or equivalent param scheme.
18. The Vault workspace reads the filter param and pre-applies it (filter the main pane to variables consumed by that server). If consumption tracking doesn't exist server-side, the filter degrades gracefully to "show all variables, but highlight which ones match the requested server name in their key" — and an inline note documents the limitation. (See "Potential Pitfalls" below.)
19. Removing the filter clears the URL param.

### Non-Functional Requirements

- **Performance**: `useVaultManager()` must not introduce duplicate polling. The hook reads from `useVaultStore` and triggers an explicit refresh; AppShell's global polling cycle remains the data source. Workspace mount = single fetch, not a polling loop.
- **Accessibility**: workspace switcher remains `role="tablist"` with three tabs. Bulk-import modal must be keyboard-navigable (Tab through preview rows, Enter to confirm, Esc to cancel). Reveal-with-timeout must announce state change via `aria-live="polite"`.
- **Security**: bulk import must never log values to console. The preview step shows values as dots by default with explicit reveal per row.
- **Compatibility**: existing localStorage values for `gridctl:last-workspace` must continue to resolve correctly. `vault` joining the `Workspace` union is additive; `isWorkspace()` validation already exists. No migration needed.
- **Compact mode**: when active, workspace header collapses to one row; left rail can be hidden behind a toggle. Test in compact mode before merging.

### Out of Scope

- Variable consumption tracking server-side (the "which servers use this variable" graph). The bridge filter is intentionally degraded if this doesn't exist yet — do NOT build a consumption-tracking system as part of this feature.
- Doppler-style missing-key diff between sets.
- Vercel-style "sensitive" (write-only) variables.
- Railway-style `${{ ... }}` reference variables.
- Audit log / rotation history.
- Multi-user RBAC or environment promotion.
- Mobile-specific layout work (gridctl is desktop-first; compact mode is sufficient).
- Removing or repurposing the Header "Settings" icon that toggles the sidebar.
- Removing the `/var` detached window route. It remains as a "pop out" target.

## Architecture Guidance

### Recommended Approach

**Refactor-first, ship-incrementally.** Each phase is independently mergeable:

- Phase 1 ships as its own PR — pure refactor, no user-visible change. Reviewers compare behavior, not screenshots.
- Phase 2 ships separately — sidebar scope-down is user-visible; needs release-notes coverage.
- Phase 3 ships when the workspace is functional and the bulk-import flow is polished.
- Phase 4 ships last, once Topology integration is stable.

Do **not** combine phases into a single PR. The refactor PR should be reviewable on its own merits; mixing it with new functionality makes review impossible.

### Key Files to Understand

Read these in order before writing code:

1. `web/src/types/workspace.ts` — workspace contract, single source of truth, `isWorkspace()` validator.
2. `web/src/components/shell/WorkspaceSwitcher.tsx` — switcher rendering; auto-derives from config.
3. `web/src/components/shell/AppShell.tsx` — URL ↔ store sync, persistence to localStorage, polling setup.
4. `web/src/components/workspaces/LibraryWorkspace.tsx` — **the closest reference pattern**. VaultWorkspace should mirror its structure: `WorkspaceShell` + header strip + search/filter bar + main grid/table + modals for edit. Library is closer than Topology because Library is a catalog with header chrome; Topology is a bespoke canvas layout.
5. `web/src/components/layout/WorkspaceShell.tsx` — left/right rail layout the workspace will use.
6. `web/src/components/vault/VaultPanel.tsx` — the 1,030-line file being split. All shared logic lives here today.
7. `web/src/pages/DetachedVaultPage.tsx` — the 1,035-line near-duplicate. Diff against `VaultPanel.tsx` to identify the shared logic core vs. the chrome-specific shell.
8. `web/src/stores/useVaultStore.ts` — the existing Zustand store. Keep it; `useVaultManager()` wraps it.
9. `web/src/lib/api.ts` (the vault section, lines ~539–640) — typed API client functions. Reuse all; do not duplicate.
10. `internal/api/vault.go` — backend reference; confirms `POST /api/var/import` exists and accepts both `{variables: [...]}` and legacy `{secrets: {...}}` shapes.
11. `web/src/hooks/useKeyboardShortcuts.ts` — auto-derives shortcuts from `WORKSPACE_CONFIG`; no edit needed once `vault` has `shortcutKey: '3'`.
12. `web/src/__tests__/WorkspaceSwitcher.test.tsx`, `web/src/__tests__/useUIStore-workspace.test.ts`, `web/src/__tests__/useKeyboardShortcuts.test.tsx` — three test files with hardcoded "two workspace" assertions that must be updated.

### Integration Points

- **`WORKSPACE_CONFIG`**: append `{ id: 'vault', label: 'Variables', icon: KeyRound, shortcutKey: '3' }`. The `KeyRound` icon import is already in vault files; add to `web/src/types/workspace.ts` imports.
- **`routes.tsx`**: add the lazy import and `<Route path="/vault">`.
- **`useUIStore.ts` — `COMPACT_MODE_DEFAULTS`**: add `vault: false` (or whichever default matches Library).
- **`landing-workspace.ts`**: no change required — `isWorkspace()` derives from `WORKSPACES`.
- **`Header.tsx`**: no change required. The existing sidebar-toggle icon stays. The sidebar component (`VaultPanel`) is what gets scoped down.
- **Topology bridge**: add the "Secrets" item wherever the existing Topology inspector / node-action menu lives. Use `useNavigate()` to push `/vault?...`.

### Reusable Components

After Phase 1, the workspace must consume — not re-implement:

- `useVaultManager()` — new shared hook.
- `useVaultStore` — unchanged Zustand store.
- All `web/src/components/vault/` atoms: `VariableTypeBadge`, `VariableVisibilityIcon`, `VariableTypeSelector`, `VariableSecretToggle`, `VaultLockPrompt`, plus the newly extracted `SecretItem`/`VariableRow`, `NewSetForm`, reveal primitive.
- `web/src/components/layout/WorkspaceShell.tsx` — left/right rail layout.
- `web/src/components/ui/IconButton`, `Button`, `ConfirmDialog`, `Toast` — existing UI primitives.
- `web/src/lib/api.ts` — `fetchVariables`, `createVariable`, `updateVariable`, `deleteVariable`, `fetchVariableSets`, `createVariableSet`, `deleteVariableSet`, `assignVariableToSet`, `fetchVariableStoreStatus`, `unlockVariableStore`, `lockVariableStore`, plus the existing `POST /api/var/import` client wrapper (or add one if it doesn't exist).

## UX Specification

**Discovery**: a third pill labeled "Variables" with the `KeyRound` icon appears in the workspace switcher, between Library and (any future workspaces). `Cmd+3` activates it.

**Activation**: clicking the pill or pressing `Cmd+3` navigates to `/vault`. Initial state shows all variables in a table; left rail lists Variable Sets.

**Primary interaction — bulk import**:
1. User clicks "Import .env" in the header (or, from the empty state, the primary CTA).
2. Modal opens. Two input modes: paste text, or drag/drop a `.env` file. File-picker fallback.
3. On parse, modal shows a preview table: each row = one variable. Columns: key, value (dotted by default, click to reveal), type (auto-detected, editable), set assignment (defaults to current filter or none), conflict indicator if key exists, per-row "skip" toggle.
4. Footer shows "X new, Y conflicts, Z skipped" counts and an "Import" button.
5. On import, modal closes; toast confirms; table refreshes.

**Primary interaction — quick lookup (sidebar)**:
1. User in Topology or Library clicks the sidebar icon in Header.
2. Sidebar opens. Search field auto-focuses.
3. User types key prefix; results filter live.
4. Click a result to reveal value (10-second timeout) or copy to clipboard.
5. For larger management tasks, the sidebar footer hint says "Manage sets and bulk-import in the Variables workspace →".

**Primary interaction — Topology bridge**:
1. User configures an MCP server in Topology, sees a "Secrets" affordance on the node.
2. Click → navigates to `/vault?filter=server:<name>`.
3. Workspace opens with main pane filtered. User can clear the filter to see all variables.

**Feedback**:
- Loading: skeleton rows in the table.
- Error: inline error banner in header with retry.
- Success on import: toast with "X variables imported."
- Lock/unlock: badge updates immediately; table re-fetches.

**Error states**:
- Locked vault: show lock prompt in main pane (not a modal — the workspace is non-functional until unlocked, so it owns the viewport).
- API error: error banner, retry button, do not clear existing data.
- Import parse error: highlight the failing row in the preview; do not allow import until corrected or skipped.

## Implementation Notes

### Conventions to Follow

- **Branch naming**: `feature/vault-workspace-promotion-phase-N` (one branch per phase).
- **Commit style**: gridctl uses conventional commits (`feat:`, `fix:`, `refactor:`, `chore:`, etc.) with imperative mood, ≤50-char subject, signed (`-S`). No `Co-authored-by` trailers. No mention of Claude in version control. See `~/.claude/CLAUDE.md` for full conventions.
- **PR style**: short title (<70 chars), bulleted summary, test plan checklist. See gridctl's recent PRs (#681, #685, #687) for tone.
- **File layout**: vault atoms under `web/src/components/vault/`. The new workspace under `web/src/components/workspaces/VaultWorkspace.tsx`. The new hook under `web/src/hooks/useVaultManager.ts`.
- **Styling**: Tailwind classes, follow the design tokens used elsewhere (`bg-surface`, `border-border`, `text-text-primary`, etc.). No new CSS files.
- **State**: continue using Zustand. Do not introduce Redux, Jotai, or other state libraries.
- **Tests**: Vitest. Update the three workspace tests identified in "Key Files." Add a smoke test for `VaultWorkspace` (renders, switches sets, opens import modal). Add a unit test for the `.env` parser if it's non-trivial.

### Potential Pitfalls

- **The `useVaultManager()` hook must be a true single source of truth.** If both `VaultPanel` and `VaultWorkspace` create separate hook instances that fetch independently, you've recreated the duplicated-state problem in a different layer. The hook must read from `useVaultStore` and any refresh is a store mutation.
- **Reveal-with-timeout state belongs to the row, not the store.** Don't put per-row reveal timers in Zustand; they're local UI state and will cause unnecessary re-renders if shared.
- **Lock state transitions clear data.** `useVaultStore` already clears `variables` and `sets` on lock (line 36). Both the sidebar and the workspace must handle this gracefully — re-render to the lock-prompt state without flashing stale data.
- **Topology consumption filter has no server-side counterpart yet.** Decide the filter scheme early. Recommendation: implement as a client-side filter that matches variable keys against a server's expected env vars (which Topology already knows from its server config). If that information isn't in the Topology state, the filter degrades to "show all" with an inline note ("Filter is approximate — variable consumption tracking is not yet implemented"). Do NOT build server-side consumption tracking as part of this feature.
- **Three test files have hardcoded "two workspace" expectations.** Find and update:
  - `web/src/__tests__/WorkspaceSwitcher.test.tsx` — assertion `toHaveLength(2)` becomes `toHaveLength(3)` (or better, derive from `WORKSPACES.length`).
  - `web/src/__tests__/useUIStore-workspace.test.ts` — workspace cycle test hardcodes `['topology', 'library']`.
  - `web/src/__tests__/useKeyboardShortcuts.test.tsx` — explicit assertion that `Cmd+3` does **not** fire needs inversion.
  Prefer driving these tests from `WORKSPACES` / `WORKSPACE_CONFIG` so future additions are mechanical.
- **Bulk-import value escaping.** `.env` parsing has well-known edge cases: quoted strings, `\n` escapes, `=` inside values, comments inline. Use a tested parser (e.g., a small custom function with explicit cases) — do not handle this with a regex-only approach. If a npm dependency like `dotenv` is acceptable to the project, use its parser directly. Otherwise write a small focused parser with unit tests.
- **Sidebar scope-down is a behavior change.** Users who previously used the sidebar to create sets will lose that affordance. Surface this in the inline footer hint and call it out in the PR description so it lands in release notes.
- **Don't repurpose the Header "Settings" icon.** The user has been explicit: the sidebar stays, the Header icon keeps toggling it. Don't get clever.

### Suggested Build Order

This is the canonical sequence. Stick to it:

**Phase 1 — Refactor (PR #1)**
1. Read `VaultPanel.tsx` and `DetachedVaultPage.tsx` side-by-side. Identify the shared core.
2. Write `web/src/hooks/useVaultManager.ts` — a hook that exposes state + actions. Both surfaces will call it.
3. Extract presentation atoms one at a time: `SecretItem` / `VariableRow`, `NewSetForm`, reveal-timeout component.
4. Refactor `VaultPanel.tsx` to consume the hook and atoms. Verify behavior unchanged (visual + keyboard + edge cases like locked-state rendering).
5. Refactor `DetachedVaultPage.tsx` similarly.
6. Run tests; no test changes expected.
7. Open PR. This PR has zero user-visible changes.

**Phase 2 — Sidebar scope-down (PR #2)**
1. Remove set creation UI from `VaultPanel`.
2. Remove lock/unlock controls from `VaultPanel`.
3. Add inline footer hint linking to `/vault` (placeholder route until Phase 3; OK if it 404s during the PR's review window — Phase 3 lands before deploy).
4. Update any sidebar tests.
5. Open PR. Call out the behavior change in the description.

**Phase 3 — Workspace + bulk import (PR #3)**
1. Add `vault` to `WORKSPACE_CONFIG` and route.
2. Scaffold `VaultWorkspace.tsx` using `WorkspaceShell`. Mirror Library's header + layout structure.
3. Wire main pane to `useVaultManager()`. Render table of variables.
4. Add left-rail set navigation. Wire filter state to URL search params.
5. Build the bulk-import modal: parse, preview, conflict handling, commit.
6. Add lock/unlock controls in workspace header.
7. Update the three workspace tests; add a smoke test for `VaultWorkspace` and a unit test for the `.env` parser.
8. Open PR.

**Phase 4 — Topology bridge (PR #4)**
1. Identify the existing Topology node action / inspector surface.
2. Add the "Secrets" affordance.
3. Wire navigation to `/vault?filter=server:<name>`.
4. Wire `VaultWorkspace` to read the filter param and apply it.
5. Document the consumption-tracking limitation in an inline note or release-notes line.
6. Open PR.

## Acceptance Criteria

**Phase 1 (Refactor)**:
1. `VaultPanel.tsx` line count is below 600.
2. `DetachedVaultPage.tsx` line count is below 600.
3. `useVaultManager()` hook exists and is consumed by both surfaces.
4. All existing vault tests pass with no behavior changes.
5. Manual QA: sidebar and detached window behave identically to pre-refactor baseline (lock/unlock, create var, edit var, delete var, create set, assign to set, reveal value, copy value, all unchanged).

**Phase 2 (Sidebar scope-down)**:
6. Sidebar no longer renders `NewSetForm` or set-deletion UI.
7. Sidebar no longer renders lock/unlock action (badge may remain as read-only).
8. Sidebar shows footer hint linking to `/vault`.
9. Single-variable CRUD in the sidebar is unchanged.

**Phase 3 (Workspace)**:
10. `/vault` route mounts `VaultWorkspace`.
11. Workspace switcher shows three pills; `Cmd+3` activates Vault.
12. Workspace renders header, left rail with sets, main pane table.
13. Bulk `.env` import modal works end-to-end: paste, preview with conflict detection, commit. Imported variables appear in the table immediately.
14. Lock/unlock in workspace header functions correctly; locked-state shows lock prompt in main pane.
15. Empty state shows "Import from .env" as primary CTA.
16. Three previously hardcoded workspace tests are updated and pass.
17. Compact-mode rendering is functional (left rail collapses or hides; table remains usable).

**Phase 4 (Bridge)**:
18. Topology server nodes expose a "Secrets" action.
19. Clicking it navigates to `/vault?filter=server:<name>` (or equivalent param scheme).
20. Workspace applies the filter on mount; clearing the filter clears the URL param.

**Cross-cutting**:
21. No regressions in existing workspace tests, vault behavior, or compact-mode handling.
22. Lint clean (`golangci-lint` for any Go changes; web lint passes).
23. Build clean (`go build`, `npm run build`).
24. All four PRs land before the next release tag, in sequence.

## References

**Industry patterns to mirror**:
- Doppler bulk-import flow: https://docs.doppler.com/docs/importing-secrets
- Vercel env vars UI (table + scope chips): https://vercel.com/docs/environment-variables
- Render's "Add from .env" empty-state pattern: https://render.com/changelog/bulk-add-environment-variables
- Railway raw-editor mode for bulk paste: https://docs.railway.com/variables
- n8n credentials as top-nav peer (the closest IA precedent): https://docs.n8n.io/integrations/builtin/credentials/

**gridctl code references**:
- Full evaluation: `prompts/gridctl/vault-workspace-promotion/feature-evaluation.md`
- Architecture: `web/src/components/README.md` (Shell architecture section)
- Conventions: `~/.claude/CLAUDE.md`
