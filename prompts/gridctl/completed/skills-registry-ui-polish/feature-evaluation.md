# Feature Evaluation: Skills Registry UI Polish

**Date**: 2026-04-14
**Project**: gridctl
**Recommendation**: Build with caveats
**Value**: Medium-High
**Effort**: Small-Medium

## Summary

The gridctl Skills Registry (DetachedRegistryPage) is a functional, well-built UI with a polished "Obsidian Observatory" dark theme, but several targeted improvements would meaningfully increase clarity and developer trust. The bento grid concept from the ui_analysis.md writeup is recommended in a modified form — directory-based categorical grouping rather than variable card sizing — alongside concrete border, accessibility, and loading state refinements. The proposed background color change (#08080a → #121212) is explicitly not recommended, as the current deeper black is superior for the existing design system.

## The Idea

The ui_analysis.md document proposes five categories of change to the skills registry: bento grid layout, soft dark color scheme, dual-typeface system, agent card metadata enhancements, and interaction refinements. This evaluation focuses on the ideas with genuine signal: hierarchy through layout, border/surface refinement, accessibility of the "untested" label, skeleton loading states, and icon button touch targets. Typography changes and verification badge tiers are filtered out as misaligned with the project's scope.

## Project Context

### Current State

- **Framework**: React 19 + TypeScript + Tailwind CSS 4 + Vite
- **Registry UI**: `DetachedRegistryPage.tsx` — a popout full-screen window showing a `repeat(auto-fill, minmax(280px, 1fr))` uniform grid of `SkillCard` components
- **SkillCard**: Renders icon, name, state badge, description, test status, and three action icon buttons (power, edit, delete)
- **Color system**: "Obsidian Observatory" — background `#08080a`, surface `#111113`, primary amber `#f59e0b`
- **Search**: Fuse.js fuzzy search filters the displayed grid in real-time
- **State**: Zustand + polling; skills have `state: 'draft' | 'active' | 'disabled'`
- **No skill categorization**: All skills are a flat list with no groups or tiers

### Integration Surface

| File | Role |
|---|---|
| `web/src/pages/DetachedRegistryPage.tsx` | Grid layout, search, filter tabs, skill state management |
| `web/src/components/registry/SkillCard.tsx` | Individual card — border, color, test badge |
| `web/src/components/ui/IconButton.tsx` | Action button sizing |
| `web/tailwind.config.js` | Color tokens, shadows, animations |
| `web/src/types/index.ts` | `AgentSkill` type — `dir` and `metadata` fields available |

### Reusable Components

- `AgentSkill.dir` — already carries directory path (e.g., `git-workflow/branch-fork`), usable for categorical grouping without backend changes
- `AgentSkill.metadata: Record<string, string>` — available for opt-in frontmatter keys like `colspan: 2`
- `cn()` utility — `clsx` + `tailwind-merge` already in place for conditional class composition
- Existing animation classes (`animate-fade-in-scale`, `animate-fade-in-up`) for skeleton and reveal effects
- `border-border/40`, `border-border-subtle/50` tokens for incremental border refinement

## Market Analysis

### Competitive Landscape

- **VS Code Extension Marketplace**: Uniform list/grid with metadata ranking; no bento sizing
- **Slack Marketplace**: Uniform grid with a separate "Featured" category page — hierarchy through curation, not card size
- **Figma Plugin Marketplace**: Uniform grid, sort/filter for discovery
- **Vercel Dashboard**: Standard 12-column grid, hierarchy through vertical placement and grouping — not variable card sizes
- **Linear**: Customizable dashboard with standardized widget sizing; hierarchy through grouping

### Market Positioning

**Bento grids** (2024–2025 trend) are used exclusively in marketing and landing pages — Apple WWDC showcases, SaaS startup hero sections. No functional admin tool, dashboard, or plugin registry uses variable card sizing as a hierarchy signal. Production UIs universally encode hierarchy through **vertical position, grouping, and metadata**.

**Soft dark color systems**: Linear uses `#0f1115`, general industry consensus is `#0a0a0a–#121212` range. The current gridctl `#08080a` is already within this range and is actually better than the proposed `#121212` (deeper, more dramatic for the Obsidian Observatory identity).

### Demand Signals

The ui_analysis.md was generated as a design brief, not from user research. The actual pain points are:
- "untested" label invisibility — directly undermines the security-signal purpose of that field
- Flat grid makes the registry feel undifferentiated as skill count grows
- Loading spinner with no skeleton means content feels slow even on fast connections

## User Experience

### Interaction Model

Users open the detached registry window to:
1. **Find** a specific skill — primary tool is the search bar (Fuse.js), fast and effective
2. **Audit** the full set — scan the grid, check states and test status
3. **Manage** skills — activate/disable/edit/delete via card actions

### Workflow Impact

**Directory grouping with section headers** reduces "visual sameness" without adding cognitive overhead. Users recognize that the `git-workflow` section contains related skills, making auditing faster. The flat list degrades gracefully: if all skills are in the root directory, no headers appear.

**Opt-in column spanning** (via `metadata.colspan`) lets users signal which skills are "central" to their workflow without requiring the system to make editorial judgments. A skill with `colspan: 2` in its frontmatter renders wider — a declaration, not an imposition.

**Skeleton loading** removes the jarring transition from spinner to populated grid. At 18 skills, loading is fast, but the skeleton eliminates layout shift perception entirely.

**Untested label** is a security signal — it tells the user this skill hasn't been validated against its acceptance criteria. At `text-muted/60` opacity, it's nearly invisible against the dark surface. A visible yellow warning badge changes this from decorative to functional.

### UX Recommendations

1. Group skills by top-level directory (from `dir` field) with subtle section headers. Skills without a `dir` fall into an "Uncategorized" or root group.
2. Respect `metadata.colspan === '2'` to span a card across 2 grid columns. Max 2 columns to preserve responsive integrity.
3. Replace "untested" text with an amber/warning badge matching the `status.pending` color (`#eab308`).
4. Add skeleton card shimmer animation on initial load, matching the 2-column+ grid structure.
5. Increase `IconButton size="sm"` padding from `p-1.5` → `p-2` for slightly better click targets.
6. Refine card border from `border-border/40` to `border-border/60` (more defined, maintains dark aesthetic).

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|---|---|---|
| Problem significance | Significant | Untested label is a real accessibility/safety signal failure |
| User impact | Broad+Shallow | Every user benefits; improvements are subtle but compound |
| Strategic alignment | Core mission | Visual polish + accessibility = developer trust in the registry |
| Market positioning | Catch up | Border definition and label contrast lag behind Vercel/Linear standards |

### Cost Breakdown

| Dimension | Rating | Notes |
|---|---|---|
| Integration complexity | Minimal | All changes are frontend-only; no backend or data model changes |
| Effort estimate | Small | Targeted component edits; grouping logic is ~30 lines |
| Risk level | Low | Additive and visual; no logic or API changes |
| Maintenance burden | Minimal | Token-based changes propagate; grouping logic is self-maintaining |

## Recommendation

**Build** the color/border/accessibility/loading refinements with no caveats — these are pure improvements with negligible risk. **Build with caveats** the hierarchy layout changes — implement directory-based grouping rather than the arbitrary editorial bento sizing described in ui_analysis.md, and use opt-in `metadata.colspan` for users who want individual skill prominence.

Explicitly **skip** the background color change (`#08080a` → `#121212`): the current deeper black is better suited to the Obsidian Observatory design system and has already solved the halation problem. The real win is border and surface layer refinement, not the background.

Explicitly **skip** dual-typeface, verification badges, border-beam animations, and waterfall views — these are over-engineered or misaligned with the project's scope as a personal/team developer tool.

## References

- [Bento Grid Design: The Hottest UI Trend of 2026](https://senorit.de/en/blog/bento-grid-design-trend-2025)
- [Dashboard Design Patterns for Modern Web Apps 2026](https://artofstyleframe.com/blog/dashboard-design-patterns-web-apps/)
- [Dark Mode Accessibility: Inclusive Dark Themes](https://www.smashingmagazine.com/2025/04/inclusive-dark-mode-designing-accessible-dark-themes/)
- [PatternFly Dashboard Guidelines](https://www.patternfly.org/patterns/dashboard/design-guidelines/)
- [Linear Dashboards Documentation](https://linear.app/docs/dashboards)
