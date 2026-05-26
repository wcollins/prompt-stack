# Feature Implementation: Skills Registry UX Polish

## Context

gridctl is an MCP (Model Context Protocol) orchestration and infrastructure management tool. The web frontend lives in `web/` and is built with:

- React 19.2 + Vite 8
- TypeScript strict mode (`strict: true`, `noUnusedLocals`, `noUnusedParameters`)
- Zustand for state (stores in `web/src/stores/`)
- Tailwind CSS 4 with a custom design system called "Obsidian Observatory" (amber/teal/violet on near-black, glass panels, IBM Plex Mono for identifiers)
- Vitest 4 + jsdom for tests
- `cmdk` (command palette), `fuse.js` (fuzzy search), `lucide-react` (icons)

The Skills Registry is one of the most-developed surfaces in the product, spanning a sidebar list view (`RegistrySidebar.tsx`), a detached grid window (`DetachedRegistryPage.tsx`), and a full-featured modal editor (`SkillEditor.tsx`). It's stable, actively maintained, and recently received a polish pass (`c80201e`).

Shared UI primitives live in `web/src/components/ui/` (`Modal`, `Button`, `IconButton`, `Badge`, `Toast`, `StatusDot`, `ResizeHandle`, `PopoutButton`).

## Evaluation Context

This prompt is driven by an external UX review that scored the registry at B+/86 and proposed 15 concrete fixes. Verification against the current codebase confirmed 13 of the 15 claims; two were partially wrong and have been dropped from scope (see Out of Scope below).

Key findings that shaped this prompt:

- **`Modal.tsx` already exists and handles Escape**, but it has no focus trap and no `aria-modal` or `role="dialog"` attributes. The leverage move is to upgrade `Modal` first, then build `ConfirmDialog` on top — `SkillEditor`, the wizard, and every future modal all benefit from the a11y upgrade.
- **Three surfaces share the same ad-hoc inline-confirm-dialog pattern** (`RegistrySidebar`, `VaultPanel`, `MetricsTab`). A shared `ConfirmDialog` primitive removes duplication in all three.
- **`IconButton` already passes WCAG 2.2 SC 2.5.8** (30–32px hit area via `p-2`). Don't blanket-raise hit areas; only audit the inline test-status toggle and a few ad-hoc buttons.
- **Registry components have zero Vitest coverage today.** Add tests alongside the refactor to prevent regression loops.
- **`role="alertdialog"` is the stricter correct choice** for destructive confirmations (per WAI-ARIA APG), not `role="dialog"`.

The work is split into two PRs. PR 1 is a readability + accessibility pass that can ship standalone. PR 2 is the compounding refactor — unified primitives + keyboard navigation — that every future registry feature inherits.

Full evaluation: `prompts/gridctl/registry-ux-polish/feature-evaluation.md`.

## Feature Description

Apply a curated set of UX polish changes to the Skills Registry:

1. Eliminate sub-10px typography and replace opacity-stacked hint text with full-opacity `text-muted` to clear WCAG 2.2 AA.
2. Upgrade `Modal` with focus trap + `aria-modal` + `role="dialog"`; build a new `ConfirmDialog` primitive on top using `role="alertdialog"`; migrate the three ad-hoc confirms to the new primitive with destructive-action name-echo.
3. Swap the destructive-button gradient for a solid color.
4. Unify the divergent `SkillCard` and `SkillItem` dialects by extracting shared `StateBadge`, `TestStatusBadge`, and `SkillActions` primitives.
5. Promote the active/disable toggle onto the collapsed sidebar row (from two clicks to one).
6. Add list-level keyboard navigation via a `useListNav` hook (↑/↓, Enter, `/` focus search, `n` new, `e` edit, `d` toggle).
7. Live-detect the `workflow:` block in the editor so Visual/Test tabs appear without save/reopen.
8. Fix the split-pane grip visibility at rest, the detached-footer status-dot color collision, and the animation cascade on the card grid.

The visual language stays untouched — this is tuning, not redesign.

## Requirements

### Functional Requirements

**PR 1 — Registry polish: dialogs, destructive, typography**

1. `Modal` (at `web/src/components/ui/Modal.tsx`) renders with `role="dialog"` and `aria-modal="true"` (set on the panel, not the backdrop).
2. `Modal` traps Tab/Shift+Tab focus inside the panel while open and restores focus to the opener element on close.
3. New `ConfirmDialog` primitive at `web/src/components/ui/ConfirmDialog.tsx` accepts: `isOpen`, `onClose`, `onConfirm`, `title`, `message` (ReactNode), `confirmLabel` (string), `variant` ('danger' | 'default'), optional `autoFocus` ('cancel' | 'confirm', default 'cancel').
4. `ConfirmDialog` renders with `role="alertdialog"`, `aria-modal="true"`, `aria-labelledby` bound to the title, and `aria-describedby` bound to the message.
5. `ConfirmDialog` autofocuses the Cancel button by default, traps focus, and closes on Escape.
6. `ConfirmDialog` in `variant="danger"` mode uses solid `bg-status-error` (no gradient, no glow) with a ring on hover.
7. The three existing inline confirms — `RegistrySidebar.tsx`, `DetachedRegistryPage.tsx`, `VaultPanel.tsx`, `MetricsTab.tsx` (any of these that exist) — are migrated to `ConfirmDialog`.
8. The destructive button in the skill-delete `ConfirmDialog` reads `Delete "<skillname>"` (skill name in the project's mono font or `text-primary`), not just `Delete`.
9. All `text-[8px]` and `text-[9px]` class usages in `web/src/components/registry/` and `web/src/pages/DetachedRegistryPage.tsx` are removed; minimum size is `text-[10px]`.
10. All `text-text-muted/50` and `text-text-muted/60` usages in registry code are replaced with full-opacity `text-text-muted` (or `text-muted`, whichever the project's convention uses).
11. `SkillItem`'s delete button in `RegistrySidebar.tsx:535` is re-skinned to solid `bg-status-error` (no gradient, no lift-on-hover glow shadow).
12. The `DetachedRegistryPage.tsx` footer status-dot no longer uses `bg-status-running` (which collides with the global "running" semantic); replace with `text-muted` pulse or a neutral surface color.
13. Card animations in the detached grid use a staggered `animation-delay` (e.g., 30ms per card, capped at 300ms) and are gated behind `motion-safe:` so they fully disable under `prefers-reduced-motion`.
14. Vitest coverage for `ConfirmDialog` (renders with correct ARIA, autofocuses Cancel, closes on Escape, calls `onConfirm`).

**PR 2 — Registry unified primitives + keyboard nav**

15. New shared primitive `web/src/components/registry/StateBadge.tsx` renders the active/inactive/error state. Both `SkillCard` and `SkillItem` consume it. Bordered style wins (per reviewer).
16. New shared primitive `web/src/components/registry/TestStatusBadge.tsx` renders the test pass/fail/pending state without the decorative `FlaskConical` overlay. Click-to-expand affordance (if kept) moves to a separate caret.
17. New shared primitive `web/src/components/registry/SkillActions.tsx` renders the activate/edit/delete cluster. Takes a `density` prop ('compact' for sidebar, 'card' for grid) that adjusts padding/spacing but not dialect.
18. `SkillCard.tsx` and the inline `SkillItem` in `RegistrySidebar.tsx` both consume the three new primitives. Both surfaces use icon-only actions with tooltips (matching `SkillCard`'s current approach).
19. On the collapsed `SkillItem` row, the power-toggle (activate/disable) icon button is rendered inline on the right. Edit and delete remain inside expansion.
20. New hook `web/src/hooks/useListNav.ts` accepts a ref array (or a ref-map), a `selectedIndex` setter, and handlers for Enter/`d`/`e`; the hook handles ↑/↓ Home/End navigation and skips when focus is in an input/textarea.
21. `RegistrySidebar.tsx` wires `useListNav` into its `SkillsList`. Global keybindings: `/` focuses the search input, `n` opens the new-skill editor. These should register via the existing `useKeyboardShortcuts` hook if its API supports it, otherwise via a local effect.
22. `SkillEditor.tsx` re-checks `hasWorkflowBlock(body)` live (debounced 300ms) against the editor body state, not only against the persisted `skill` prop. Visual/Test tabs appear as soon as the user types `workflow:`.
23. The split-pane grip in `SkillEditor.tsx:385` is visible at rest at `opacity-30` (not `opacity-0`) and upgrades to `opacity-100` on hover.
24. The inline test-status toggle and any non-`IconButton` action controls in the registry are padded to at least 28×28 effective hit area.
25. Vitest coverage for `StateBadge`, `TestStatusBadge`, `SkillActions`, and `useListNav`.

### Non-Functional Requirements

- **TypeScript strict mode must pass.** Project uses `noUnusedLocals` + `noUnusedParameters`; new primitives must be fully typed.
- **No new runtime dependencies.** Use existing tree (`lucide-react`, `cmdk`, `fuse.js`).
- **Tailwind tokens only.** No inline hex. Follow existing `primary`/`secondary`/`tertiary`/`status-*`/`text-*`/`surface-*`/`border` tokens.
- **Respects `prefers-reduced-motion`.** Global rule exists in `index.css`; component-level animations must additionally be gated with `motion-safe:` where they exceed reasonable.
- **WCAG 2.2 AA for all new/modified interactive elements.** Target size ≥ 24×24; contrast ≥ 4.5:1 for normal text.
- **No change to the persistent visual language.** Amber/teal/violet palette, glass panels, IBM Plex Mono for identifiers all remain.
- **No regression of existing flows.** `SkillEditor` save, popout, Cmd/Ctrl+S, backdrop-click-to-close, `Modal` Escape-blur-on-input all continue to work.

### Out of Scope

The following items from the external review are intentionally deferred or dropped:

- **New `text-hint` token.** Use full-opacity `text-muted` (4.92:1 on surface). Only introduce a new token if design explicitly needs a third gradation later.
- **Blanket 28×28 hit-area raise.** `IconButton` is already 30–32px. Only audit the inline test-status toggle and any non-`IconButton` controls.
- **Persist split-pane ratio and preview-toggle preference** (reviewer item 11). Defer until user demand.
- **Sort control on the detached window** (reviewer item 13). Defer until catalog-size friction surfaces.
- **Per-skill tag chips** (reviewer item 14). Defer — requires authoring-side UX to encourage `tags:` in frontmatter first.
- **Keyboard shortcut overlay (`?` reveal)** (reviewer item 15). Defer until keyboard nav has been in the product long enough to create discoverability pressure.
- **Any change to the visual language itself** (colors, fonts, glass panels, gradient-on-primary-positive). Out of scope for this initiative.
- **Touching vault or workflow surfaces beyond the `ConfirmDialog` migration.** Those features may benefit from similar polish later, but scope is registry-first.

## Architecture Guidance

### Recommended Approach

**Order of operations — PR 1:**

1. Upgrade `ui/Modal.tsx` in place: add `role="dialog"`, `aria-modal="true"`, focus trap (use a small local implementation: capture focusable elements, wrap Tab/Shift+Tab), restore focus on close via a ref to `document.activeElement` captured in a mount effect.
2. Build `ui/ConfirmDialog.tsx`. It does **not** wrap `Modal` — it re-uses the focus-trap logic (extract to a small `useFocusTrap` hook that both share) but renders `role="alertdialog"` with a distinct layout appropriate for short confirmations. `Modal` is for long-lived interactive content; `ConfirmDialog` is for urgent, short decisions.
3. Create `hooks/useFocusTrap.ts` — shared by `Modal` and `ConfirmDialog`.
4. Migrate `RegistrySidebar.tsx` delete confirm, `DetachedRegistryPage.tsx` delete confirm, `VaultPanel.tsx` delete confirm, `MetricsTab.tsx` clear confirm (only those that exist) to `ConfirmDialog`.
5. Sweep `text-[8px]` and `text-[9px]` in `components/registry/` and `pages/DetachedRegistryPage.tsx`. Bump to `text-[10px]` minimum.
6. Sweep `text-text-muted/50` and `text-text-muted/60` in the same scope. Replace with full-opacity `text-text-muted` (or `text-muted`).
7. Skin change on `SkillItem` delete button; drop the gradient + shadow.
8. Detached footer dot color fix.
9. Card animation stagger + `motion-safe:`.
10. Vitest for `ConfirmDialog` + `useFocusTrap`.

**Order of operations — PR 2:**

1. Extract `StateBadge`, `TestStatusBadge`, `SkillActions` into `components/registry/`. Design the props API first — write `.tsx` stubs + types, then copy the winning visual implementation from `SkillCard`.
2. Migrate `SkillCard` to consume the three primitives. Verify visual parity with screenshots before/after.
3. Migrate `SkillItem` (inline in `RegistrySidebar.tsx`) to consume the three primitives. This is where most of the dialect-collapse happens.
4. Add the power-toggle to the collapsed `SkillItem` row.
5. Build `hooks/useListNav.ts`. Test it in isolation (Vitest) before wiring.
6. Wire `useListNav` into `SkillsList`. Add `/`, `n` global keybindings.
7. Debounced live `hasWorkflowBlock` detection in `SkillEditor.tsx` — change the `useMemo` to a `useEffect` or add `body` to its deps with `useDebounce` (already in tree? verify; if not, inline a 300ms debounce).
8. Split-pane grip at `opacity-30`.
9. Audit non-`IconButton` touch targets in registry; pad where below 28×28.
10. Vitest for new primitives + `useListNav`.

### Key Files to Understand

Read first, in this order:

1. `web/src/components/registry/RegistrySidebar.tsx` — the 605-line sidebar. Contains the inline `SkillItem`, the `SkillsList`, both `StateBadge` + `TestStatusBadge` inline, and the current delete confirm.
2. `web/src/components/registry/SkillCard.tsx` — the grid card. Has the other flavor of `StateBadge` + `TestStatusBadge`. This is the visual language that wins in the unification.
3. `web/src/components/ui/Modal.tsx` — the existing modal primitive. Keep its API (Escape-blur-on-input, backdrop-click, popout, expand). Add focus-trap + ARIA.
4. `web/src/components/registry/SkillEditor.tsx` — the 960-line editor. `hasWorkflow` memo is at lines ~460–473; save-disabled is ~677–687; split-pane grip is ~385; name input is ~784–790.
5. `web/src/pages/DetachedRegistryPage.tsx` — the detached grid, the second delete-confirm, the footer dot, the animation cascade.
6. `web/src/components/ui/IconButton.tsx` — verify the sizes before proposing any hit-area change.
7. `web/tailwind.config.js` — token palette. Familiarize before touching colors.
8. `web/src/index.css` — keyframes, `prefers-reduced-motion` rule, any other globals.
9. `web/src/hooks/useKeyboardShortcuts.ts` — the existing page-level hook. The new `useListNav` is row-level; understand the boundary.
10. `web/src/components/palette/CommandPalette.tsx` — reference for keyboard-driven list interaction patterns (`cmdk`-based).

### Integration Points

- **`Modal` upgrade ripples to:** `SkillEditor`, `SkillImportWizard` (if it uses `Modal`), and any other modal consumer. Run the full frontend test suite after the `Modal` change.
- **`ConfirmDialog` consumers:** `RegistrySidebar`, `DetachedRegistryPage`, `VaultPanel`, `MetricsTab`. Verify each still behaves correctly after migration.
- **`StateBadge` / `TestStatusBadge` / `SkillActions`:** only `SkillCard` and `RegistrySidebar`'s inline `SkillItem` consume them. No other callsites expected — search for emerald-400 / status-running inline styles to confirm.
- **`useListNav`:** only `RegistrySidebar`'s `SkillsList` for now. Pattern is reusable for `VaultPanel` later but out of scope.

### Reusable Components

- `ui/Modal.tsx` — upgrade, don't replace.
- `ui/IconButton.tsx` — already variant- and size-parameterized. `SkillActions` should consume it.
- `ui/Button.tsx` — has a `danger` variant; use it for `ConfirmDialog`'s destructive button.
- `ui/Badge.tsx` — check if generic enough to serve as the base for `StateBadge` or if `StateBadge` should be purpose-built.
- `hooks/useKeyboardShortcuts.ts` — global/page-level. `useListNav` complements it.
- `cn` helper at `web/src/lib/cn.ts` — use for conditional class composition (already project convention).

## UX Specification

**Discovery:**

- Registry is opened via the main sidebar (primary entry) or via the activity-bar amber badge.
- The detached window is opened via the popout button in the sidebar header.
- Keyboard shortcuts are undocumented in this initiative — the `?` overlay is deferred. That's acceptable for PR 2 because the audience is developer-tool users who try common keys.

**Activation:**

- Clicking a `SkillItem` header toggles expansion (unchanged).
- Clicking the power-toggle (new, on collapsed row) fires the activate/disable action immediately with no confirm (activate is safe; disable is recoverable).
- Clicking Edit opens the editor modal (unchanged).
- Clicking Delete opens `ConfirmDialog` (new flow, name-echoed destructive button).
- Focusing the list (Tab, click, or page load default) and pressing ↑/↓ moves selection; Enter expands/collapses; `d` toggles power; `e` opens editor; `/` focuses search; `n` opens new-skill editor.

**Interaction:**

- Sidebar and detached grid now look like the same product. `StateBadge`, `TestStatusBadge`, and `SkillActions` render identically in both (with density variance).
- In the detached grid, arrow keys are *not* required for PR 2 — the grid layout doesn't map cleanly to ↑/↓. (Future work could add Tab/Shift+Tab wrapping.)

**Feedback:**

- `ConfirmDialog` announces itself to screen readers via `role="alertdialog"` + `aria-labelledby` + `aria-describedby`.
- Destructive button reads `Delete "<skillname>"` so users re-read the name before committing.
- Save button in the editor gets a `title` attribute describing what's missing ("Name and description are required" when disabled).

**Error states:**

- No new error surfaces. `ErrorBoundary` at the detached page keeps working. Deletion errors still toast through the existing error-toast mechanism.

## Implementation Notes

### Conventions to Follow

- **File layout:** primitives for the registry belong in `web/src/components/registry/`. Generic primitives (`ConfirmDialog`, upgraded `Modal`) belong in `web/src/components/ui/`.
- **Naming:** PascalCase components, camelCase props, `use`-prefix hooks.
- **Imports:** use existing `cn` helper from `web/src/lib/cn`. Use `lucide-react` for icons — `Power`, `Edit2`, `Trash2`, `GripVertical` are the likely additions.
- **Tests:** colocate or put under `web/src/__tests__/` per existing convention. Use `@testing-library/react` patterns matching existing tests (e.g., `RegistryPanel.test.tsx`).
- **Styling:** Tailwind utility classes, not CSS modules. Tokens only.
- **Commit style:** follow the user's global conventions — `feat:`/`fix:`/`refactor:`, imperative, ≤50 char subject, signed.

### Potential Pitfalls

- **Focus trap implementation is subtle.** Common failure mode: missing focus when the modal has no natively focusable children. Ensure the `ConfirmDialog` container has a `tabIndex={-1}` fallback and that focus moves to the Cancel button on mount. Test with a keyboard-only walkthrough.
- **`Modal` backdrop click vs. focus trap.** Backdrop is currently clickable to close. That's fine — but don't let backdrop clicks escape the focus trap logic before the modal unmounts.
- **Restoring focus on close.** Capture `document.activeElement` at mount, restore it on unmount. If the element no longer exists (unmounted), fall back to `document.body`.
- **Animation cascade staggering.** Don't use JavaScript-side `setTimeout` — set `animation-delay: calc(var(--i) * 30ms)` inline via `style={{ animationDelay: `${Math.min(i, 10) * 30}ms` }}` or equivalent. Cap the cascade so a 100-skill grid doesn't animate for 3 seconds.
- **`hasWorkflowBlock` live-detection.** The current memo depends on the persisted `skill` prop. Switching to `body` state as a dep risks expensive re-parsing on every keystroke. Debounce to 300ms.
- **Unifying `StateBadge`.** The `SkillCard` version uses `emerald-400`; the sidebar uses `status-running`. These *might* be different tokens intentionally — verify with the design tokens before standardizing. If `status-running` is #10b981 and `emerald-400` is #34d399, pick one and use it everywhere.
- **Dialect drift risk.** During the unification, it's tempting to also "improve" the card. Resist — the initiative is consistency, not a third dialect.
- **Test coverage gap.** Registry has zero tests today. Adding tests for the new primitives is in scope; retrofitting tests for existing components is not — but if you accidentally regress `SkillEditor` during the `Modal` upgrade, you'll want at least a smoke test covering "editor opens and Save is reachable."

### Suggested Build Order

**PR 1:**

1. `hooks/useFocusTrap.ts` + unit tests (pure logic, easiest to get right first)
2. Upgrade `Modal` with focus trap + ARIA; run full frontend build + tests
3. `ui/ConfirmDialog` + unit tests
4. Migrate three ad-hoc confirms to `ConfirmDialog`
5. Typography sweep (`text-[8px]`, `text-[9px]`, opacity-stacked hints)
6. Destructive-button skin + footer-dot color
7. Animation stagger + motion-safe
8. Full visual QA pass in the browser

**PR 2:**

1. Design the `StateBadge`/`TestStatusBadge`/`SkillActions` props API in types-only form
2. Implement `StateBadge` + unit tests; migrate `SkillCard` first (smaller surface)
3. Implement `TestStatusBadge` + unit tests; migrate `SkillCard`
4. Implement `SkillActions` + unit tests; migrate `SkillCard`
5. Migrate `SkillItem` in `RegistrySidebar.tsx` to consume all three
6. Add power-toggle to collapsed row
7. `hooks/useListNav.ts` + unit tests
8. Wire into `SkillsList`; add `/` + `n` global bindings
9. Live-`hasWorkflowBlock` in `SkillEditor`
10. Split-pane grip at rest
11. Touch-target audit for non-`IconButton` controls
12. Full visual + keyboard QA pass

## Acceptance Criteria

**PR 1:**

1. `Modal` panel has `role="dialog"` and `aria-modal="true"`; Tab/Shift+Tab cycles within the modal; Escape closes (unchanged behavior); focus restores to the opener on close.
2. `ConfirmDialog` renders with `role="alertdialog"`, autofocuses Cancel, traps focus, closes on Escape, and fires `onConfirm` only when the destructive button is activated.
3. Three inline confirm dialogs (registry delete, detached-registry delete, vault delete, metrics clear — whichever exist) render via `ConfirmDialog` instead of an absolute-positioned div.
4. The skill-delete destructive button reads `Delete "<skillname>"` (name in project's mono font or `text-primary`).
5. `rg 'text-\[8px\]|text-\[9px\]' web/src/components/registry/ web/src/pages/DetachedRegistryPage.tsx` returns no matches.
6. `rg 'text-text-muted/(50|60)' web/src/components/registry/ web/src/pages/DetachedRegistryPage.tsx` returns no matches.
7. `SkillItem` delete button uses solid `bg-status-error`; no gradient, no shadow glow.
8. Detached-window footer dot no longer uses `bg-status-running`.
9. Card grid animates with staggered `animation-delay`, capped, and fully disables under `prefers-reduced-motion`.
10. Vitest: new `ConfirmDialog.test.tsx` and `useFocusTrap.test.ts` pass.
11. `npm run build` + `npm run test` + `npm run lint` in `web/` all green.
12. Manual keyboard-only walkthrough of the delete flow succeeds (Tab to delete → Enter → focus lands on Cancel → Tab to Destructive → Enter → skill deleted → focus returns to opener).

**PR 2:**

1. `StateBadge`, `TestStatusBadge`, `SkillActions` primitives exist in `components/registry/` with Vitest coverage.
2. `SkillCard.tsx` and `SkillItem` (inline in `RegistrySidebar.tsx`) both consume the three new primitives; inline implementations of the replaced pieces are removed.
3. Visual diff between sidebar and detached card shows consistent state-badge, test-badge, and action-cluster styling (screenshots attached to PR).
4. Collapsed `SkillItem` row renders an inline power-toggle icon button; clicking it toggles the skill without requiring expansion.
5. Arrow-down from a focused `SkillItem` moves focus to the next item; arrow-up moves back; Home/End jump to extremes; these bindings do not fire when focus is in search input.
6. Pressing `/` focuses the search input; `n` opens the new-skill editor; `e` opens the editor for the selected item; `d` toggles active state.
7. In `SkillEditor`, typing `workflow:` into the markdown body surfaces the Visual/Test tabs within ~300ms without saving/reopening.
8. Split-pane grip is visible at rest (`opacity-30`) and upgrades to `opacity-100` on hover.
9. All non-`IconButton` action controls in registry components have ≥28×28 effective hit area.
10. Vitest: new `StateBadge.test.tsx`, `TestStatusBadge.test.tsx`, `SkillActions.test.tsx`, `useListNav.test.ts` pass.
11. `npm run build` + `npm run test` + `npm run lint` in `web/` all green.
12. Manual visual parity check: open sidebar, pop out detached window, scan 5 skills in each — badges and action clusters read as the same object.

## References

- Full evaluation: `prompts/gridctl/registry-ux-polish/feature-evaluation.md`
- External UX review (Phase 1 intake — source document)
- WCAG 2.2 SC 2.5.8 Target Size (Minimum): https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum.html
- WAI-ARIA APG Alertdialog pattern: https://www.w3.org/WAI/ARIA/apg/patterns/alertdialog/
- WAI-ARIA APG Dialog pattern: https://www.w3.org/WAI/ARIA/apg/patterns/dialog-modal/
- Internal: `web/src/components/ui/Modal.tsx`, `web/src/components/ui/IconButton.tsx`, `web/tailwind.config.js`, `web/src/index.css`
