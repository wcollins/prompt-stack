# Feature Implementation: Variable Set "Recently Edited" Indicator

## Context

gridctl is a local MCP gateway control plane: a Go backend with a React 19 + TypeScript + Vite + Tailwind web UI (in `web/`). The "Variables" feature (internally still named "vault" in some files for historic reasons) is a unified store of secrets + plaintext config, organized into named **Sets**. Variables and their sets are rendered in three surfaces that share components and a single data hook:

- **Sidebar panel** — `web/src/components/vault/VaultPanel.tsx` → renders `SetGroup`
- **Variables workspace** — `web/src/components/workspaces/VaultWorkspace.tsx` → renders `SetPill`
- **Detached `/var` page** — `web/src/pages/DetachedVaultPage.tsx` → renders `SetGroup`

State lives in a Zustand store (`web/src/stores/useVaultStore.ts`) and all IO routes through one hook (`web/src/hooks/useVaultManager.ts`), which both component trees consume.

## Evaluation Context

This prompt is the scoped-down outcome of a feature-scout evaluation (full report: `feature-evaluation.md` in this folder). Key findings that shaped it:

- **The original ask had two parts; the first already ships.** A per-set variable *count* is already rendered everywhere (`SetGroup.tsx:75-77`, `VaultWorkspace.tsx:761`). Do **not** rebuild it.
- **A real per-set "Last Updated" timestamp was deferred, not chosen.** It would require adding timestamps to the encrypted vault schema (a v2→v3 migration of a security-sensitive store) for a hint that (a) no comparable tool surfaces at the group level, (b) is semantically misleading as a container aggregate, and (c) isn't actionable for secrets (old = normal/good). See the evaluation for the market + UX reasoning.
- **This feature is the actionable slice that survived.** The one genuinely useful recency moment is transient — *"I just edited something; which set did it land in?"* — and it can be captured with **zero backend work** because `useVaultManager` already knows which keys were just mutated. So we ship a **session-scoped "recently edited" dot**, not a timestamp.
- **Mirror the existing "used-by" badge philosophy** (`SecretItem.tsx:181-204`): *absence is the signal* — render nothing when there's nothing to show.

## Feature Description

Add a small **"recently edited" dot** to each variable Set row (in both the sidebar `SetGroup` and the workspace `SetPill`). The dot appears on a set when any of its member variables has been created, updated, imported, or (re)assigned to that set **during the current session**. It is purely client-side and ephemeral: it clears when the vault is locked and on page reload. It gives users at-a-glance feedback about where their recent changes landed, without claiming a false per-set "last modified" precision.

**Who benefits**: anyone managing multiple sets of secrets/config who wants to confirm where a just-made edit went, or to spot which sets they've touched this session.

## Requirements

### Functional Requirements

1. Add session-scoped "recently edited" state to `useVaultStore.ts`:
   - A field `recentlyEdited: Record<string, number>` mapping variable key → epoch-ms of the edit.
   - An action `markRecentlyEdited(keys: string[])` that merges the given keys in with `Date.now()` (immutably — new object).
   - Clearing on lock: extend the existing `setLocked` action so that locking also resets `recentlyEdited` to `{}` (it already wipes `variables`/`sets`/`usage` on lock).
   - (Optional) a `clearRecentlyEdited()` action for completeness.
   - State is **in-memory only** — never persisted to localStorage or disk.
2. Wire mutation chokepoints in `useVaultManager.ts` to record edited keys after each successful, refreshed mutation:
   - `createVar` → mark `[input.key]`
   - `updateVar` → mark `[key]`
   - `assignToSet` → mark `[key]` (after `refresh()` the variable's `.set` is the destination, so the dot correctly appears on the set it moved into)
   - `importVars` → mark `vars.map(v => v.key)`
   - **Do not** mark on `deleteVar` — the variable no longer exists after deletion, so there is no member to flag; a deletion is a removal, not a "recently edited" member.
   - Marking must happen after `refresh()` succeeds, so a failed mutation never produces a dot.
3. Expose `recentlyEdited` (and `markRecentlyEdited`) through `useVaultManager`'s result so consumers can read it. (The hook is the single source of truth both trees use.)
4. In each container that renders sets (`VaultPanel`, `VaultWorkspace`, `DetachedVaultPage`), compute per-set recency and pass it down as a boolean prop:
   - A set is "recently edited" if any variable `v` with `v.set === set.name` has `v.key` present in `recentlyEdited`.
   - Compute this from the already-available `variables` + `recentlyEdited`; pass a `recentlyEdited?: boolean` prop into `SetGroup` / `SetPill`.
5. Render the dot in `SetGroup.tsx` and the `SetPill` component in `VaultWorkspace.tsx`:
   - Place it immediately to the left of the existing count pill.
   - Only render it when the boolean is true (absence = no recent edit).
   - Element: `<span className="h-1.5 w-1.5 rounded-full bg-secondary/70 flex-shrink-0" title="Recently edited" aria-label="Recently edited" />`.
   - Must not break the existing layout (name truncation, count pill, hover-revealed delete affordance must all still work).

### Non-Functional Requirements

- **Zero backend changes.** No Go code, no API changes, no schema/migration. If you find yourself editing anything under `pkg/vault`, `internal/api`, or `proto/`, stop — that's out of scope.
- **Accessibility**: the dot must carry both `title` and `aria-label` ("Recently edited"); never rely on color alone to convey meaning.
- **Visual consistency**: use the `secondary` color token (the set-identity color already used by the `FolderOpen` icon and the count pill), at ~70% opacity so it reads as gentle "activity," not an error/warning status.
- **Performance**: per-set recency is a cheap derived value computed during render; do not add effects, timers, or polling. (No TTL/auto-fade in this scope — keep it until lock/reload.)
- **TypeScript**: no `any`; extend the existing interfaces (`VaultState`, `UseVaultManagerResult`, `SetGroupProps`, `SetPillProps`).

### Out of Scope

- Any backend timestamp, schema version bump, or migration.
- A real "Last Updated" relative-time string on set rows (deferred — see evaluation).
- Changing the existing count display or its `dev (5)` vs pill styling.
- Cross-window sync of the dot (the detached `/var` page runs in a separate window with its own store instance and will track its own edits independently — this is acceptable and expected).
- TTL/auto-expiry/fade-out animations beyond an optional one-shot fade-in.

## Architecture Guidance

### Recommended Approach

Put the ephemeral state in the **shared Zustand store** (not component-local), so the sidebar and workspace stay consistent within a window. Record edits at the **`useVaultManager` mutation chokepoints** rather than scattering calls across UI handlers — the hook already wraps every mutation and is the single source of truth for both trees. Derive the per-set boolean in the container (where `variables` is already in hand) and pass it as a prop, keeping `SetGroup`/`SetPill` dumb presentational components consistent with their current design.

### Key Files to Understand

- `web/src/stores/useVaultStore.ts` — the Zustand store; add the new field/action here and extend `setLocked` to clear it.
- `web/src/hooks/useVaultManager.ts` — single IO hook consumed by both trees; mutation methods (`createVar`/`updateVar`/`assignToSet`/`importVars`) are the chokepoints; also expose the new state through `UseVaultManagerResult`.
- `web/src/components/vault/SetGroup.tsx` — sidebar/detached set row; add `recentlyEdited?: boolean` prop and render the dot near the count pill (count pill at lines 75-77).
- `web/src/components/workspaces/VaultWorkspace.tsx` — contains the `SetPill` component (~lines 811-864) and the set list render (~lines 757-767); add the prop + dot, and compute the per-set boolean where the list maps.
- `web/src/components/vault/VaultPanel.tsx` — sidebar container; computes member lists per set (~lines 400-420); compute and pass the boolean here.
- `web/src/pages/DetachedVaultPage.tsx` — detached container that also renders `SetGroup`; apply the same prop wiring for parity.
- `web/src/components/vault/SecretItem.tsx` (lines 181-204) — the "used-by" badge; reference for badge/sibling-element conventions and the "absence is the signal" principle.
- `web/src/lib/time.ts` — note: `formatRelativeTime` caps at hours; **not used** by this feature, but don't reach for it (it would render `72h ago` for old data — that's the deferred-timestamp trap).

### Integration Points

- `VaultState` interface + store initializer in `useVaultStore.ts` (add `recentlyEdited`, `markRecentlyEdited`, clear-on-lock).
- `UseVaultManagerResult` interface + return object in `useVaultManager.ts` (expose `recentlyEdited`).
- `SetGroupProps` (`SetGroup.tsx`) and `SetPillProps` (`VaultWorkspace.tsx`) — add `recentlyEdited?: boolean`.

### Reusable Components

- The badge/dot styling tokens already in use: `text-[10px] font-mono px-1.5 py-0.5 rounded`, `bg-secondary/10 text-secondary` (count pill), `flex-shrink-0` for right-aligned elements, `opacity-0 group-hover:opacity-100` for hover affordances. The dot reuses the `secondary` token family.
- Optional one-shot appear animation: `animate-fade-in-scale` is already defined and used in `VaultWorkspace.tsx`.

## UX Specification

- **Discovery**: passive — the dot simply appears on a set after the user edits/creates/imports/reassigns a variable in it. No new control or affordance to learn.
- **Activation**: implicit, via existing variable mutations.
- **Interaction**: none — it's a non-interactive indicator. It must not intercept clicks meant for the row's toggle/select button.
- **Feedback**: a small `secondary`-colored dot left of the count pill; tooltip "Recently edited" on hover.
- **Error states**: none introduced. A failed mutation produces no dot (marking happens only after a successful `refresh()`).
- **Lifecycle**: clears on vault lock and on page reload (in-memory state). No manual dismiss.

## Implementation Notes

### Conventions to Follow

- Match the existing functional-component + typed-props style; presentational components stay dumb (state/derivation in containers/hooks).
- Immutable state updates in Zustand (spread into a new object for `recentlyEdited`).
- Use `h-1.5 w-1.5` (not `size-1.5`) for the dot to avoid relying on a newer Tailwind utility; confirm against the project's Tailwind setup.
- Keep diffs small and focused; do not refactor surrounding code.
- Commit conventions (handled by the build/PR skills): signed commits, conventional `feat:` prefix, imperative subject ≤50 chars, no Claude mentions, no Co-authored-by trailers.

### Potential Pitfalls

- **`assignToSet` direction**: marking the key is correct because after `refresh()` the variable's `.set` equals the destination, so the dot lands on the set it moved into. Don't try to also flag the source set — the member left it.
- **Don't mark on delete** — there's no surviving member to attach the dot to.
- **Don't add the dot inside the row's primary `<button>`** in a way that captures its click; render it as a sibling/inline span like the count pill (the count pill sits inside the button as a non-interactive span, which is fine — the dot is also non-interactive, so inline next to the count is acceptable).
- **Two `SetPill` count-pill styles** (active vs inactive) exist in `VaultWorkspace.tsx`; place the dot outside that conditional so it shows in both states.
- **Detached window** has its own store instance — don't attempt cross-window messaging; per-window tracking is the intended behavior.

### Suggested Build Order

1. **Store + hook plumbing**: add `recentlyEdited` + `markRecentlyEdited` to `useVaultStore.ts` (and clear-on-lock); wire the four mutation chokepoints in `useVaultManager.ts` and expose the state. Add unit tests for the store action and clear-on-lock.
2. **Presentational dot**: add the `recentlyEdited?: boolean` prop + dot element to `SetGroup.tsx` and the `SetPill` component. Add component tests asserting the dot renders only when true and carries `title`/`aria-label`.
3. **Container wiring**: compute the per-set boolean and pass it down in `VaultPanel.tsx`, `VaultWorkspace.tsx`, and `DetachedVaultPage.tsx`. Add/extend a workspace or panel test asserting that editing a variable flags its set.

(This is a single cohesive frontend phase; the steps above are sub-steps, not separate PR phases.)

## Acceptance Criteria

1. After creating, updating, importing, or reassigning a variable, the set containing it shows a small `secondary` dot left of its count pill — in both the sidebar `SetGroup` and the workspace `SetPill`.
2. Sets with no edits this session show **no** dot.
3. The dot disappears when the vault is locked and after a page reload.
4. Deleting a variable does **not** leave a dangling dot.
5. The dot has `title="Recently edited"` and `aria-label="Recently edited"`; meaning is not conveyed by color alone.
6. No backend/Go/API/schema files are modified; the diff is confined to `web/`.
7. Existing set-row layout (name truncation, count pill, hover-delete) is visually unchanged aside from the new dot.
8. `npm run build`, `npm run lint`, and the web test suite pass; new tests cover the store action, clear-on-lock, and the dot's conditional render + a11y attributes.

## References

- Full evaluation with market + UX reasoning: `feature-evaluation.md` (this folder)
- Existing "used-by" badge precedent (absence-is-the-signal): `web/src/components/vault/SecretItem.tsx:181-204`
- GitHub Actions per-item "Updated" column (the item-level recency precedent we are *not* matching at group level): https://docs.github.com/en/rest/actions/secrets
- Doppler's default-off age toggle (clutter-management precedent): https://docs.doppler.com/docs/secrets
