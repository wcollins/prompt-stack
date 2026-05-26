# Feature Implementation: Skills Registry UI Polish

## Context

gridctl is a local MCP (Model Context Protocol) gateway for AI agent orchestration. It's a Go binary that embeds a React 19 + TypeScript + Tailwind CSS 4 + Vite frontend. The frontend communicates with a Go backend via REST API. The project uses Zustand for state management, Lucide React for icons, and a custom design system called "Obsidian Observatory" (deep black + warm amber + teal + purple accents).

The Skills Registry is a detached popup window (`DetachedRegistryPage`) that shows all Claude Code skills as a uniform grid of `SkillCard` components. The registry supports fuzzy search (Fuse.js), state filtering (all/active/draft/disabled), and CRUD operations on skills.

**Tech stack summary:**
- React 19.2 + TypeScript 5.9
- Tailwind CSS 4.1 with custom theme tokens in `tailwind.config.js`
- Vite 8 build
- Zustand state, Fuse.js search, Lucide React icons
- `cn()` utility using `clsx` + `tailwind-merge` at `web/src/lib/cn.ts`
- Custom UI primitives in `web/src/components/ui/`

## Evaluation Context

- Bento grid variable sizing (as described in ui_analysis.md) is a marketing-page pattern with no precedent in functional admin UIs or plugin registries. Replaced with directory-based categorical grouping — the pattern used by VS Code, Slack Marketplace, and similar tools.
- Background color (`#08080a` → `#121212`) is skipped: the current deeper black is better suited to the Obsidian Observatory system. The actionable improvement is the border and surface layer.
- "untested" label at `text-muted/60` fails contrast for a security-relevant signal. Changed to a warning badge.
- Full evaluation: `prompt-stack/prompts/gridctl/skills-registry-ui-polish/feature-evaluation.md`

## Feature Description

Improve the Skills Registry UI across five targeted areas:

1. **Directory-based skill grouping** — Group skills by their top-level directory (`AgentSkill.dir` field) with subtle section headers, replacing the flat undifferentiated grid.
2. **Opt-in column spanning** — Skills with `metadata.colspan: "2"` in their frontmatter render at 2-column width, letting users declare which skills are central to their workflow.
3. **Card border + surface refinement** — Increase card border visibility and add a slightly warmer surface gradient to improve card definition against the dark background.
4. **"Untested" label accessibility** — Replace the near-invisible muted text with a visible amber warning badge, making the security signal actually functional.
5. **Skeleton loading states** — Replace the full-screen spinner with skeleton cards that mirror the grid layout, eliminating perceived layout shift.
6. **Icon button touch targets** — Increase `sm` icon button padding slightly for better clickability.

## Requirements

### Functional Requirements

1. Skills are grouped by the first path segment of `AgentSkill.dir` (e.g., `git-workflow/branch-fork` → group `git-workflow`). Skills with no `dir` or a flat `dir` (no slash) are placed in a group derived from `dir` itself or labeled as their standalone category.
2. Each group renders a subtle section header above its card grid. The header shows the group name in title case (replace hyphens with spaces) and the count of skills in that group.
3. When search is active, grouping is preserved — groups with zero matching skills are hidden; groups with matches show only matching cards.
4. When all skills are in one group (or all ungrouped), no section headers render — the UI degrades to the current flat grid.
5. A skill with `metadata.colspan === "2"` spans 2 grid columns. Cards spanning 2 columns still participate in the same grouped grid.
6. The "untested" test status badge changes from muted text to a visible amber warning badge with icon.
7. On initial data load, skeleton cards render in place of the spinner. The skeleton grid respects the same column structure as the real grid.
8. `IconButton size="sm"` padding increases from `p-1.5` to `p-2`.
9. Card border opacity increases from `border-border/40` to `border-border/60` (hover stays at `hover:border-primary/40`).

### Non-Functional Requirements

- All changes are frontend-only. No backend or API changes.
- No new npm dependencies. Use existing Tailwind utilities and animation classes.
- Existing keyboard shortcuts, search behavior, and CRUD actions are unchanged.
- The detached window remains responsive at typical popup widths (800px–1400px).
- Skeleton cards must not produce layout shift when real cards load — their dimensions should match the actual card dimensions.
- No changes to the background color token (`#08080a`), font families, or existing animation timing.

### Out of Scope

- Background color change (`#08080a` → `#121212`)
- Dual-typeface system (Satoshi / JetBrains Mono swap)
- Verification badges (Gray/Gold trust tiers)
- Border-beam animations
- Waterfall view for MCP calls
- Backend categorization or tagging system
- Changes to `RegistrySidebar.tsx` (sidebar is a separate view)

## Architecture Guidance

### Recommended Approach

**Grouping logic**: Derive groups from `AgentSkill.dir` at render time. No store changes needed.

```typescript
// Derive group key from dir field
function getGroupKey(dir?: string): string {
  if (!dir) return '';
  const parts = dir.split('/');
  return parts[0]; // top-level directory
}

// Group skills preserving display order
function groupSkills(skills: AgentSkill[]): Map<string, AgentSkill[]> {
  const groups = new Map<string, AgentSkill[]>();
  for (const skill of skills) {
    const key = getGroupKey(skill.dir);
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key)!.push(skill);
  }
  return groups;
}
```

Only render group headers when there are 2+ distinct groups. Single-group and zero-group cases render the flat grid (current behavior).

**Column spanning**: Read `skill.metadata?.colspan` in `SkillCard`. Apply `col-span-2` via `cn()` conditional. The grid in `DetachedRegistryPage` must use `grid-cols-[repeat(auto-fill,minmax(280px,1fr))]` (already in place) — CSS Grid handles `col-span-2` naturally within auto-fill.

**Skeleton cards**: Create a `SkillCardSkeleton` component that renders a shimmer placeholder matching `SkillCard`'s structure (header area, description area, footer area). Use Tailwind `animate-pulse` for shimmer. Render N skeletons (8–12) during `isLoading`.

**Section headers**: Render as a full-width element that spans all grid columns: `grid-column: 1 / -1`. Style with small uppercase label + count badge.

### Key Files to Understand

| File | Why it matters |
|---|---|
| `web/src/pages/DetachedRegistryPage.tsx` | Grid layout container, loading state, search + filter logic |
| `web/src/components/registry/SkillCard.tsx` | Card component to modify (border, colspan, untested badge) |
| `web/src/components/ui/IconButton.tsx` | Touch target fix (p-1.5 → p-2 for sm size) |
| `web/tailwind.config.js` | Color tokens — do not change `background`, `surface`, or `primary` |
| `web/src/types/index.ts` | `AgentSkill` type — `dir?: string` and `metadata?: Record<string, string>` |
| `web/src/lib/cn.ts` | Class merging utility for conditional span classes |
| `web/src/index.css` | Global animation classes — `animate-fade-in-scale`, `animate-fade-in-up` available |

### Integration Points

- **`DetachedRegistryPage.tsx` lines 316–337**: Replace the flat grid render with grouped grid render. Add skeleton render during `isLoading`.
- **`SkillCard.tsx`**: Add `col-span-2` conditional based on `metadata.colspan`; update `TestStatusBadge` untested case; update card border class; card component needs to accept an optional `className` prop to pass `col-span-2`.
- **`IconButton.tsx` line 24**: Change `sm: 'p-1.5'` to `sm: 'p-2'`.
- **New component** `SkillCardSkeleton.tsx` (or inline in DetachedRegistryPage): Skeleton placeholder for loading state.

### Reusable Components

- `animate-pulse` (Tailwind built-in) for skeleton shimmer
- `animate-fade-in-scale` (custom, defined in `tailwind.config.js`) for group header entrance
- `cn()` for conditional class composition
- `border-border` and `border-border-subtle` tokens — use these, don't hardcode hex values

## UX Specification

### Directory Grouping

**Discovery**: Users scanning the registry immediately see categorical clusters (e.g., "Git Workflow", "Development", "Content") rather than an alphabetical flat list.

**Activation**: Automatic — derived from `dir` field. No user action required. Users who want their skills grouped must organize them in subdirectories under `~/.claude/skills/`.

**Section header design**:
```
git workflow                    4 skills
─────────────────────────────────────────
[card] [card] [card] [card]

development                     6 skills
─────────────────────────────────────────
[card] [card] ...
```
- Header: `text-[10px] uppercase tracking-widest text-text-muted font-medium`
- Count badge: `text-[10px] px-1.5 rounded-full bg-surface-highlight text-text-muted`
- Separator: `border-b border-border/30` running full width
- Header spans full grid width with `col-span-full` or `grid-column: 1 / -1`

**Count label behavior**: When no search is active, show `N skills`. When a search query is active, show `N matched` to communicate that the count reflects filtered results, not the total group size.

**Interaction**: Both search filtering and tab state (active/draft/disabled) can reduce a group to zero visible items. Groups with zero visible items must be hidden entirely — including the section header — to avoid "ghost sections" (headers with no cards beneath them). Apply this check after both the Fuse.js search filter and the tab state filter are applied. If only one group remains after filtering, suppress headers entirely.

### Opt-in Column Spanning

**Activation**: User adds `metadata.colspan: "2"` to their `SKILL.md` frontmatter.

**Effect**: That skill's card is wider (2 columns). No badge or visual indicator that it's "featured" — the size itself is the signal. Works naturally within CSS Grid auto-fill.

**Fallback**: At narrow viewports where 2 columns don't fit (< 580px effective), the span collapses naturally via CSS Grid's auto-fill behavior.

### Untested Badge

**Before**: `<Minus size={11} /> untested` in `text-text-muted/60` — nearly invisible.

**After**: Amber warning badge matching the `status.pending` color:
```tsx
<span className="flex items-center gap-1 text-[10px] font-medium text-amber-400/80 bg-amber-400/8 border border-amber-400/20 rounded px-1.5 py-0.5">
  <Minus size={10} />
  untested
</span>
```

### Skeleton Loading

**Layout**: Render 8 skeleton cards in the same grid as real cards. Each skeleton must exactly match `SkillCard`'s padding and internal structure — use the same `p-3` body padding, `px-3 pb-3 pt-2` footer padding, and `gap-2` internal gap — so the skeleton and card occupy identical dimensions and no layout shift occurs on replacement. Each skeleton has:
- Header area: `h-4 w-24 rounded bg-surface-elevated animate-pulse`
- Description area: 2 lines `h-3 rounded bg-surface-elevated animate-pulse`
- Footer separator (`border-t border-border-subtle/50`) + 2 placeholder footer elements

**Transition**: When data loads, replace skeletons with real cards using `animate-fade-in-scale` on each card.

### Error States

No changes — existing error handling in `DetachedErrorBoundary` is adequate.

## Implementation Notes

### Conventions to Follow

- Use `cn()` for all conditional classes — never string interpolation with template literals for Tailwind classes
- Tailwind classes only — no inline styles except where CSS variables are needed (the `--log-font-size` pattern)
- Color tokens from `tailwind.config.js` — never hardcode hex values in components
- Icons from `lucide-react` only
- Memoize new components with `memo()` if they receive stable props (follow `SkillCard` pattern)
- Test status changes in `SkillCard` should preserve the `TestStatusBadge` component structure

### Potential Pitfalls

- **`col-span-2` and auto-fill**: `grid-column: span 2` only works if the grid has at least 2 columns. At narrow viewports with `minmax(280px, 1fr)`, the grid may be 1 column wide — the span will be clamped by the browser automatically, but test at ~320px viewport to confirm no overflow.
- **Section header spanning**: Use `style={{ gridColumn: '1 / -1' }}` rather than a Tailwind `col-span-*` class for full-width headers, since the column count is dynamic (auto-fill).
- **Group ordering**: `Map` preserves insertion order. Skills are returned from the API in alphabetical order by name. Groups will appear alphabetically by their key — this is the desired behavior.
- **Single group edge case**: If all skills share the same `dir` prefix (or all have no `dir`), the grouping produces one group. Detect this and suppress headers. `groups.size <= 1` is the check.
- **Search + grouping interaction**: Apply search filter first (Fuse.js result), then tab filter, then group. Don't group first and search within groups — this would break Fuse.js scoring.
- **Ghost sections**: After applying all filters (search + tab), any group with zero remaining skills must be removed from the rendered output entirely — header and all. Check `group.skills.length === 0` and skip. This applies to both search and tab filter scenarios.
- **Skeleton count**: 8–12 skeletons is enough. Don't try to match the exact future skill count.

### Suggested Build Order

1. `IconButton.tsx` — change `sm: 'p-1.5'` to `sm: 'p-2'` (1 line, no risk)
2. `SkillCard.tsx` — card border opacity, untested badge, add `className` prop for col-span passthrough
3. `SkillCardSkeleton` — new component or inline function in `DetachedRegistryPage`
4. `DetachedRegistryPage.tsx` — grouping logic, section headers, skeleton render, col-span class passthrough
5. Manual test at various viewport widths and with skills in/not in subdirectories

## Acceptance Criteria

1. Skills with a common `dir` top-level prefix are visually grouped under a labeled section header in the registry grid.
2. Section headers show the group name (hyphens replaced with spaces, title case) and a count of skills in that group.
3. When only one group exists (or all skills are ungrouped), no section headers render and the layout matches the current flat grid.
4. Active search and tab state filters preserve grouping: groups with zero visible cards after filtering are hidden entirely ("ghost sections" do not appear). Group count badges show "N skills" at rest and "N matched" when a search query is active.
5. A skill with `metadata.colspan: "2"` in its frontmatter renders at double the standard card width.
6. Column-spanning degrades gracefully at narrow viewport widths (no horizontal overflow).
7. The "untested" test status label is rendered as a visible amber warning badge, distinguishable from the passing (green) and failing (red) states.
8. During initial data load, skeleton placeholder cards render in the grid instead of a full-screen spinner.
9. Skeleton cards do not produce layout shift when real cards load.
10. `IconButton size="sm"` has `p-2` padding (was `p-1.5`).
11. Card border base opacity is `border-border/60` (was `border-border/40`).
12. No changes to background color, font families, or existing animation timing.
13. No new npm dependencies introduced.
14. Existing tests in `web/src/__tests__/` continue to pass.

## References

- [CSS Grid auto-fill and col-span interaction](https://css-tricks.com/auto-sizing-columns-css-grid-auto-fill-vs-auto-fit/)
- [WCAG contrast requirements for non-text elements](https://www.w3.org/WAI/WCAG21/Understanding/non-text-contrast.html)
- [Tailwind animate-pulse documentation](https://tailwindcss.com/docs/animation)
- Full evaluation: `prompt-stack/prompts/gridctl/skills-registry-ui-polish/feature-evaluation.md`
