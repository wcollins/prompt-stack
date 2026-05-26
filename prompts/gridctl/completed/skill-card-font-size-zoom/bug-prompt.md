# Bug Fix: Skill Card Font Size Zoom

## Context

gridctl is a Kubernetes/infrastructure control plane with a React + TypeScript frontend (Vite, Tailwind CSS). The web UI includes a Registry page that displays "Agent Skills" as cards in a grid layout. The app uses Zustand for global state and custom hooks for UI preferences like font size.

The font size zoom system works via a CSS custom property (`--log-font-size`) set on a container element. Text elements that should scale must apply the `.log-text` CSS class, which is defined as `font-size: var(--log-font-size, 11px)`.

## Investigation Context

- Root cause confirmed: `SkillCard.tsx` text elements use hardcoded Tailwind size classes (`text-sm`, `text-xs`) instead of the `.log-text` CSS class that consumes `--log-font-size`
- Risk: Low — isolated to one presentational component, no logic or API changes needed
- The identical pattern works correctly on the Logs page (`DetachedLogsPage.tsx`) which applies `.log-text` to log line content
- Full investigation: `prompts/gridctl/skill-card-font-size-zoom/bug-evaluation.md`

## Bug Description

On the Registry (Agent Skills) page, the font size control (`— 17px +`) in the top-right corner has no effect when clicked. The pixel counter updates (state works) and the CSS variable `--log-font-size` is set on the container (variable works), but `SkillCard` text elements use hardcoded Tailwind font-size classes that ignore the variable entirely.

**Expected**: Clicking `+`/`−` increases/decreases text size in skill cards (name, description, badges).
**Actual**: Nothing changes visually.

## Root Cause

`web/src/components/registry/SkillCard.tsx:93` — skill name uses `text-sm`
`web/src/components/registry/SkillCard.tsx:100` — description uses `text-xs`

These Tailwind classes set a static `font-size` that overrides (or is not replaced by) the CSS variable. The `.log-text` class (`font-size: var(--log-font-size, 11px)`, defined at `web/src/index.css:699`) is never applied to any SkillCard element.

## Fix Requirements

### Required Changes

1. In `SkillCard.tsx`, replace the hardcoded `text-sm` class on the skill name element (line 93) with the `log-text` class
2. In `SkillCard.tsx`, replace the hardcoded `text-xs` class on the description element (line 100) with the `log-text` class
3. Verify the `cn()` utility is used correctly — `log-text` is a plain CSS class, not a Tailwind utility, so it passes through `cn()` unchanged

### Constraints

- Do NOT change the card layout, padding, spacing, or non-text visual styling
- Do NOT change the icon sizes (`BookOpen size={14}`, etc.) — only text content should scale
- Do NOT modify `StateBadge` or `TestStatusBadge` font sizes unless explicitly asked — keep those fixed
- Do NOT change `ZoomControls`, `useLogFontSize`, or `DetachedRegistryPage` — they are working correctly

### Out of Scope

- Fixing a similar potential bug in `TracesTab.tsx` (separate investigation needed)
- Adding localStorage persistence for registry-specific font size (already handled by `useLogFontSize`)
- Changing the default font size or min/max zoom range

## Implementation Guidance

### Key Files to Read

1. `web/src/components/registry/SkillCard.tsx` — the file to modify; understand the current class structure
2. `web/src/index.css:695-710` — see `.log-text` and `.log-text-detail` definitions to understand what's available
3. `web/src/pages/DetachedLogsPage.tsx` — working reference: search for `.log-text` usage to see the correct pattern

### Files to Modify

**`web/src/components/registry/SkillCard.tsx`**

Line 93 — skill name span:
```tsx
// Before
<span className="font-semibold text-sm text-text-primary truncate flex-1 min-w-0 leading-tight mt-0.5">

// After
<span className="font-semibold log-text text-text-primary truncate flex-1 min-w-0 leading-tight mt-0.5">
```

Line 100-103 — description paragraph:
```tsx
// Before
<p className={cn(
  'text-xs leading-relaxed line-clamp-2',
  skill.description ? 'text-text-secondary' : 'text-text-muted/40 italic',
)}>

// After
<p className={cn(
  'log-text leading-relaxed line-clamp-2',
  skill.description ? 'text-text-secondary' : 'text-text-muted/40 italic',
)}>
```

### Reusable Components

- `cn()` from `../../lib/cn` — already imported, use it for conditional class merging
- `.log-text` CSS class — already defined in `index.css`, no new CSS needed
- `useLogFontSize` hook — already wired up in `DetachedRegistryPage`, no hook changes needed

### Conventions to Follow

- Use `cn()` for any conditional className expressions
- Keep Tailwind utilities for layout/color/spacing; use `.log-text` only for font-size that should scale
- Do not add inline `style` props for font size — use the CSS class approach

## Regression Test

### Test Outline

File: `web/src/components/registry/SkillCard.test.tsx` (create if it doesn't exist)

```
Test: "SkillCard text scales with --log-font-size CSS variable"
- Render SkillCard inside a div with style={{ '--log-font-size': '20px' }}
- Query the skill name element
- Assert its computed font-size is 20px
- Query the description element
- Assert its computed font-size is 20px
```

### Existing Test Patterns

Check `web/src` for existing `*.test.tsx` files to match the assertion style and import conventions used in the project.

## Potential Pitfalls

- **CSS specificity**: If Tailwind's generated utilities appear later in the CSS than `.log-text`, the Tailwind class wins. Confirm that `.log-text` (defined in `index.css`) overrides Tailwind when both are present. To be safe, remove the Tailwind size class rather than adding `.log-text` alongside it.
- **`line-height`**: `text-sm` and `text-xs` in Tailwind also set `line-height`. After replacing with `log-text`, check that `leading-relaxed` on the description and `leading-tight` on the name still render correctly (they should, since those classes only set `line-height`).
- **Badge sizes**: `StateBadge` uses `text-[9px]` and `TestStatusBadge` uses `text-[10px]` — do not change these unless the user explicitly requests badge scaling.

## Acceptance Criteria

1. Clicking `+` on the Registry page increases the visible text size of skill card names and descriptions
2. Clicking `−` decreases the visible text size
3. The pixel counter in the control matches the actual rendered font size
4. Card layout (padding, icon sizes, badge sizes, grid spacing) is unchanged
5. Font size preference persists across page navigation (already handled by localStorage in the hook — verify it still works)

## References

- CSS variable pattern: `web/src/index.css:699` — `.log-text { font-size: var(--log-font-size, 11px) }`
- Working reference implementation: `web/src/pages/DetachedLogsPage.tsx` (search for `log-text`)
- Bug evaluation: `prompts/gridctl/skill-card-font-size-zoom/bug-evaluation.md`
