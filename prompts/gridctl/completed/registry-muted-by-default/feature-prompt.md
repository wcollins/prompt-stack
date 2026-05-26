# Feature Implementation: Registry "Muted-by-Default" Color Hierarchy

## Context

You are working on **gridctl**, an MCP gateway with a React + TypeScript web UI
under `web/`. The frontend uses Tailwind CSS v4 with `@theme` tokens defined in
`web/src/index.css` and a class palette mirrored in `web/tailwind.config.js`.
The design system is named "Obsidian Observatory" — a dark theme with warm
amber (`#f59e0b`) as the primary brand color.

There is no external component library. UI primitives (`Button`, `IconButton`,
`Badge`) live in `web/src/components/ui/`. The Skills Registry is rendered by
two surfaces that share the same badge / action subcomponents:

- `web/src/pages/DetachedRegistryPage.tsx` — full-page card grid (the surface
  in the user screenshot).
- `web/src/components/registry/RegistrySidebar.tsx` — embedded sidebar list.

Edits to the shared subcomponents (`TestStatusBadge`, `StateBadge`,
`SkillActions`, `IconButton`) propagate to both surfaces. That's intentional —
keep the visual treatment consistent across surfaces.

## Evaluation Context

This refactor came out of a UI critique: the dashboard over-uses warm amber/orange
for both interactive elements and static metadata, flattening the visual
hierarchy. The strategy is **muted-by-default**: every static decoration starts
neutral; the brand color is reserved for primary actions, the active selection,
and interactive feedback (hover / focus).

Two facts to absorb before you start so you don't waste time grep'ing:

1. The `untested` pill in `TestStatusBadge.tsx` uses **`amber-400`**
   (`#fbbf24`), not the brand `primary` token. Visually they're nearly
   indistinguishable, which is why the user reads the badge as "the brand
   orange." Don't be confused when searches for `primary` don't find it.
2. `failed` already uses **`rose-400`**, not amber/orange. The brief's line
   "reserve orange for Failed states" is already satisfied. The actual change
   is just demoting `untested`.

Full evaluation: `prompts/gridctl/registry-muted-by-default/feature-evaluation.md`

## Feature Description

Refactor the styling of the Skills Registry dashboard (and the shared sidebar
components it depends on) so the UI implements a "muted-by-default" color
strategy. Specifically:

1. **Demote** the `untested` test-status badge from amber to a neutral grey.
2. **Demote** static skill-card decoration (idle border, top accent gradient,
   internal book-icon container) from orange to neutral; keep orange only for
   the hover/focus state.
3. **Demote** utility icon buttons (trash, edit, power) so their resting
   appearance is quiet — full color/contrast only on hover.
4. **Preserve** the `+ New Skill` button as the primary orange affordance.
5. **Preserve** the active filter tab as orange; inactive tabs already use
   ghost styling — verify and tighten if needed.
6. **Preserve** white skill titles and dimmed descriptions (already correct).

Solves: visual hierarchy is currently flat because brand orange is used for
both "click here" and "this is a label." Result is faster scanning and clearer
semantic distinction between informational and actionable elements.

## Requirements

### Functional Requirements

1. The `untested` variant of `TestStatusBadge` MUST render with a neutral grey
   palette (text + background + border). It MUST visually distinguish from
   `passing` (emerald) and `failing` (rose) primarily through its icon and
   label, not through warm color.
2. The default border of `SkillCard` MUST be subtle and neutral
   (a low-opacity white or `border-subtle`), not warm amber.
3. The orange border on `SkillCard` MUST appear only on `:hover` and `:focus-within`.
4. The decorative top accent line on `SkillCard` (the `via-primary/40` gradient)
   MUST default to neutral and brighten to orange only on hover/focus.
5. The book-icon container inside each `SkillCard` MUST render in a neutral
   grey treatment by default (or a much-reduced primary tint) — not the
   current `bg-primary/10 border-primary/20 text-primary/70`.
6. Utility icons in `SkillActions` (Power/PowerOff, Pencil, Trash2) MUST render
   at reduced opacity (around 50–60%) in the resting state and reach full
   opacity on `:hover` of the icon button.
7. The `+ New Skill` button in `DetachedRegistryPage.tsx` MUST remain visibly
   the primary orange action. (Current treatment is acceptable; don't dim it.)
8. Filter tabs (All / Active / Draft / Disabled) in `DetachedRegistryPage.tsx`
   MUST render the active tab in orange and inactive tabs in ghost style. The
   inactive count badge MUST NOT use any warm color.
9. The skill title MUST remain `text-text-primary` (high-contrast white).
10. The skill description MUST remain `text-text-secondary` (dimmed).

### Non-Functional Requirements

- No changes to component props, types, or APIs. This is a styling-only refactor.
- No new dependencies.
- No new CSS files. Stay within Tailwind utility classes and the existing
  `@theme` tokens. If a new neutral border value is needed repeatedly, use the
  existing `border-border-subtle` token (`rgba(255, 255, 255, 0.06)`) or
  `border-white/10`.
- Preserve all existing transitions and animations.
- Preserve keyboard focus visibility — focus rings on `IconButton` (currently
  `focus:ring-primary/30`) should remain.
- No regressions to the `RegistrySidebar` view that uses the same shared
  components.

### Out of Scope

- Do **not** change the brand `primary` token value in `index.css` or
  `tailwind.config.js`. Other surfaces depend on it.
- Do **not** rework `RegistrySidebar.tsx` layout or interactions. Verify shared
  components still look correct there; spot-fix only if a class change in a
  shared file makes the sidebar look wrong.
- Do **not** modify other pages (Workflow, Stack, Playground, etc.) even if
  they share components — out of scope for this refactor.
- Do **not** change the `StateBadge` color treatment for `active` (emerald) or
  `disabled` (muted). Only touch `draft` if it causes new visual conflict.
- Do **not** touch the test-status `passing` (emerald) or `failing` (rose)
  styles.
- Do **not** change the `+ New Skill` button to a solid-orange Button primary
  variant — the current tinted treatment is intentional.

## Architecture Guidance

### Recommended Approach

This is a class-string refactor across ~6 files. There is no abstraction to
introduce; the existing component boundaries are correct. The change is:

1. Edit the shared status-badge color map.
2. Edit the card wrapper's border and accent classes.
3. Edit the card's internal icon container.
4. Reduce default opacity on the icon-button cluster.
5. Verify the page-level filter tab and `+ New Skill` styles still match the
   intended hierarchy after the badge/card changes (they probably do).

Do not introduce a new "muted variant" prop on existing components — these
components have a single visual treatment per surface and the change is
universal. Adding a variant prop would create a future trap where someone
re-introduces the loud version.

### Key Files to Understand

Read these first, in this order:

1. `web/src/components/registry/TestStatusBadge.tsx` — the badge with the most
   visible offender (the `untested` color map at line 33).
2. `web/src/components/registry/SkillCard.tsx` — card wrapper, top accent
   line, internal book icon.
3. `web/src/components/registry/SkillActions.tsx` — utility icon cluster.
4. `web/src/components/ui/IconButton.tsx` — the underlying button primitive.
   Note the `ghost` variant already uses `text-text-muted` (acceptable
   default); the per-action `hover:text-*` overrides in `SkillActions` are
   what give each icon its hover identity.
5. `web/src/pages/DetachedRegistryPage.tsx` — the page that hosts everything.
   Filter tabs are inline at lines 370–395; `+ New Skill` is at lines 337–342;
   the `Library` brand icon is at lines 318–320.
6. `web/src/components/registry/RegistrySidebar.tsx` — verify the sidebar still
   looks right after shared-component changes.
7. `web/src/index.css` and `web/tailwind.config.js` — for available tokens
   (`border-subtle`, `text-muted`, `surface-highlight`, etc.).

### Integration Points

All changes are self-contained in component class strings. No store updates,
no API calls, no type changes.

### Reusable Components

Use existing tokens — don't invent new color values:

- `text-text-muted` (`#78716c`) — primary muted-text option.
- `text-text-secondary` (`#a8a29e`) — secondary text.
- `bg-surface-highlight` (`#1f1f23`) — neutral elevated background.
- `border-border` (`#27272a`) — opaque neutral border.
- `border-border-subtle` (`rgba(255, 255, 255, 0.06)`) — subtle white border;
  closest match to the brief's `rgba(255, 255, 255, 0.1)` recommendation. Use
  `border-white/10` if you want exactly the brief's value.

## UX Specification

- **Discovery / activation / interaction**: unchanged — same buttons, same
  positions, same keyboard shortcuts.
- **Feedback**:
  - Cards reveal an orange border on `:hover` and `:focus-within` (the latter
    is important for keyboard users).
  - Utility icons brighten to their existing per-action hover color (the
    Power/PowerOff icon picks up emerald/amber as it does today; Edit picks up
    primary; Delete picks up status-error).
  - Filter tabs: only the active tab carries orange weight.
- **Error states**: unchanged. The `failed` badge keeps rose; the Delete icon
  keeps `hover:text-status-error`.

## Implementation Notes

### Conventions to Follow

- Use the `cn(...)` helper from `web/src/lib/cn.ts` for any multi-class
  composition. Don't hand-concatenate Tailwind strings.
- When picking a muted color, prefer existing tokens (`text-text-muted`,
  `border-border-subtle`) over raw hex.
- Match the project's "single hover transition" idiom:
  `transition-colors` (or `transition-all`) on the parent button/card; never
  on individual children.
- Keep the existing `transition-all duration-200 ease-out` on the
  `SkillCard` wrapper so the new border/accent transition smoothly.

### Concrete Class Suggestions (use these as a starting point — refine as needed)

`TestStatusBadge.tsx:33` — `untested` color:
```diff
- color = 'text-amber-400/80 bg-amber-400/8 border-amber-400/20';
+ color = 'text-text-muted bg-surface-highlight/60 border-border/40';
```

`SkillCard.tsx:42` — wrapper border:
```diff
- 'border-border/60 hover:border-primary/40 hover:shadow-node-hover',
+ 'border-white/[0.08] hover:border-primary/40 focus-within:border-primary/40 hover:shadow-node-hover',
```

`SkillCard.tsx:47` — top accent line: make the gradient muted by default and
fade to orange when the card group is hovered/focused. Add `group` to the
wrapper, then:
```diff
- <div className="absolute top-0 left-0 right-0 h-px bg-gradient-to-r from-transparent via-primary/40 to-transparent" />
+ <div className="absolute top-0 left-0 right-0 h-px bg-gradient-to-r from-transparent via-white/10 to-transparent group-hover:via-primary/40 group-focus-within:via-primary/40 transition-colors duration-200" />
```
(Add `group` to the parent `<div>` className list.)

`SkillCard.tsx:53–55` — internal book-icon container:
```diff
- <div className="p-1.5 rounded-md border bg-primary/10 border-primary/20 flex-shrink-0 mt-0.5">
-   <BookOpen size={14} className="text-primary/70" />
+ <div className="p-1.5 rounded-md border bg-surface-highlight/60 border-border/40 flex-shrink-0 mt-0.5 transition-colors group-hover:bg-primary/10 group-hover:border-primary/20">
+   <BookOpen size={14} className="text-text-muted transition-colors group-hover:text-primary/70" />
```

`SkillActions.tsx` — wrap the icon cluster so it dims at rest and brightens
when the card (or the cluster itself) is hovered. The IconButton primitive
inherits `text-text-muted` for `ghost`, so the simplest path is to add a
parent opacity treatment:
```diff
- <div className={cn('flex items-center gap-0.5', className)}>
+ <div className={cn(
+   'flex items-center gap-0.5 opacity-60 transition-opacity',
+   'group-hover:opacity-100 group-focus-within:opacity-100 hover:opacity-100',
+   className,
+ )}>
```
(Requires the parent `SkillCard` wrapper to have `group` — see above.)

Filter tabs at `DetachedRegistryPage.tsx:370–395` — verify they look right
after the other changes. If the inactive count badge feels too warm against
the new muted cards, swap `bg-surface-highlight text-text-muted` for
`bg-surface text-text-muted/80`.

`+ New Skill` button at `DetachedRegistryPage.tsx:337–342` — leave alone. It's
already a tinted-orange action that doesn't compete with the new muted cards.

`Library` brand icon at `DetachedRegistryPage.tsx:318–320` — leave alone (brand
identifier, not a status signal).

### Potential Pitfalls

- **The shared subcomponents power the sidebar too.** After editing
  `TestStatusBadge`, `StateBadge`, or `SkillActions`, open `RegistrySidebar.tsx`
  and verify the sidebar list still looks correct. If a change makes the
  sidebar wrong, scope the fix to the call site (e.g., add a
  `density` or `surface` prop) instead of reverting the badge change.
- **Don't strip the brand-color cues that aren't noise.** The
  small `Library` icon in the header, the active filter tab, and the
  `+ New Skill` button are all *correct* uses of orange. The brief is about
  removing orange from *static metadata*, not from the brand surface as a
  whole.
- **`group` on SkillCard wrapper** is required for the suggested
  `group-hover:` and `group-focus-within:` selectors to work. Add it once on
  the outer `<div>`.
- **The `RegistrySidebar` selected-row treatment** (`border-primary/40
  shadow-[0_0_0_1px_rgba(245,158,11,0.25)]`) is a *selection* signal, not
  static metadata — leave it orange.

### Suggested Build Order

1. Edit `TestStatusBadge.tsx` (smallest, most-visible win — verify the user
   immediately sees the difference in both the dashboard and the sidebar).
2. Edit `SkillCard.tsx` (border, accent line, internal icon container; add
   `group` to wrapper).
3. Edit `SkillActions.tsx` (icon cluster opacity; depends on `group` from
   step 2).
4. Open the dashboard and the sidebar in the dev server side-by-side and tune.
5. Verify the page-level toolbar (`+ New Skill`, filter tabs, library icon)
   still reads the way the brief asks for, given the now-quieter cards.

## Acceptance Criteria

1. The `untested` test-status badge renders in a neutral grey treatment in
   both the dashboard cards and (where it appears) the sidebar.
2. A skill card at rest has a subtle, neutral border (white at low opacity, or
   `border-border-subtle`) — not the current warm amber tint.
3. A skill card on `:hover` or `:focus-within` shows an orange border —
   confirming interactivity.
4. The decorative top-edge gradient on each card is neutral at rest and warms
   to orange on hover/focus.
5. The trash, edit, and power icons in each card render at reduced opacity
   while the card is at rest, and reach full opacity (and their per-action
   hover color) when the card or icon is hovered.
6. The `+ New Skill` button is unchanged — visibly orange and the strongest
   element in the toolbar.
7. The active filter tab is the only orange tab; inactive tabs render in
   ghost style with neutral count badges.
8. The `Library` brand icon and the `passing` / `failing` test badges are
   unchanged.
9. The `RegistrySidebar` view (open it from the main app) still renders
   correctly with no visual regressions.
10. `npm run typecheck` and `npm run lint` (or whatever the project's
    equivalents are; check `web/package.json`) pass with zero new errors or
    warnings.
11. Visual QA: the dashboard's "high alert" feel is gone; the eye lands on
    skill titles and the `+ New Skill` button rather than every badge at once.

## References

- Source brief: user-provided UI Refinement Brief (2026-05-05)
- Tailwind tokens: `web/tailwind.config.js`
- Theme tokens: `web/src/index.css` (`@theme` block)
- Shared design vocabulary: "Obsidian Observatory" comments in `index.css`
