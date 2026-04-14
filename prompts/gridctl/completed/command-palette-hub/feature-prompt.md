# Feature Implementation: Command Palette Hub

## Context

**gridctl** is a hybrid CLI + web application that acts as a gateway and orchestration platform for MCP (Model Context Protocol) servers. The web UI is a React 19 + TypeScript + Vite + Tailwind CSS 4 application. It shows an MCP server stack as an interactive node graph on a canvas using `@xyflow/react`.

**Tech stack:**
- React 19.2, TypeScript, Vite 7
- Tailwind CSS 4 (PostCSS; custom design tokens in `index.css`)
- Zustand 5 for state management
- React Router v7 (8 routes: main app + detached panel windows)
- Lucide React for icons
- Custom component library (no shadcn/radix/headlessui)
- Vitest + React Testing Library for tests

**Architecture summary:**
- The app is state-driven, not page-based. Navigation between sections (Traces, Vault, Registry, Logs, Metrics) opens/closes panels, not pages.
- `useUIStore` (Zustand) owns all panel open/close state with Zustand persist.
- `useKeyboardShortcuts.ts` is a hook that registers window-level keyboard handlers (Cmd+0, Cmd+J, Escape, etc.).
- `Modal.tsx` is the existing overlay component (z-50, `animate-fade-in-scale`, backdrop blur, Escape to close).
- Each section has its own Zustand store: `useTracesStore`, `useVaultStore`, `useRegistryStore`, `useStackStore`.

**Design system:** "Obsidian Observatory" dark theme. Key CSS variables: `--color-primary` (amber), `--color-secondary` (teal), `--color-tertiary` (violet). Tailwind classes: `glass-panel-elevated`, `animate-fade-in-scale`, `scrollbar-dark`, `text-text-muted`, `text-text-primary`, `surface-highlight`.

## Evaluation Context

- **Market insight**: Cmd+K is table-stakes for developer tooling in 2025-2026. GitHub reversed a deprecation decision under developer pressure. `cmdk` has 3.8M weekly downloads and is confirmed React 19 compatible.
- **Library choice driven by evaluation**: Use `cmdk` (not `kbar`). It is headless and unstyled, pairs perfectly with gridctl's custom design system, and handles ARIA combobox correctly out of the box. Do not adopt the shadcn/ui Command component — gridctl has no shadcn dependency and should not start one. Use `cmdk` directly.
- **UX decision**: Default state must show frecent items, not a blank search box. This is the most common failure mode in command palette implementations.
- **Architectural analog**: Retool's context-aware scoping model most closely matches gridctl's multi-section architecture. Default scoping follows the active section; power users can override with prefix characters (`t:`, `v:`, `r:`).
- **Risk mitigation**: The command registry must be implemented as a centralized pattern so new sections don't require modifying `CommandPalette.tsx`. Define a `Command` type and a registration hook.
- Full evaluation: `/Users/william/code/prompt-stack/prompts/gridctl/command-palette-hub/feature-evaluation.md`

## Feature Description

Build a `Cmd+K` / `Ctrl+K` command palette for gridctl that gives keyboard-first developers fast access to:

1. **Navigation** — jump to any section (Traces, Vault, Registry, Logs, Metrics, Canvas)
2. **Section search** — find a specific trace by server name, a vault secret by key, a skill by name
3. **Canvas actions** — zoom to fit, refresh, toggle overlays, select/navigate to a node
4. **Toggle commands** — compact cards, heatmap, drift overlay, spec mode
5. **Global actions** — open YAML editor, open wizard, deploy

The palette opens with `Cmd+K` / `Ctrl+K`, shows frecent items by default, supports fuzzy search, and allows context-aware scoping with prefix overrides (`t:`, `v:`, `r:`).

## Requirements

### Functional Requirements

1. `Cmd+K` (macOS) and `Ctrl+K` (Linux/Windows) open the palette from any context except when the user is typing in an `<input>` or `<textarea>`.
2. `Escape` closes the palette and restores focus to the element that had focus before opening.
3. The default state (no search input) shows three groups: **Recent** (last 3-5 items), **Current Context** (actions relevant to the active section), **Navigate To** (all sections).
4. Typing filters results with fuzzy matching. Group headers collapse during active search. Each result shows a subtle section badge (e.g., `VAULT`, `TRACES`).
5. `↑` / `↓` navigate through results. `Enter` executes the selected command.
6. Keyboard shortcuts are displayed inline next to commands that have standalone shortcuts (e.g., `Cmd+0` next to "Zoom to fit").
7. Prefix-based scoping: `t:` → Traces, `v:` → Vault, `r:` → Registry, `>` → actions only.
8. Frecency scoring persists across sessions via `localStorage`. Commands used frequently or recently surface higher in results.
9. A visible search button in the Header opens the palette on click, making the feature discoverable.
10. Empty state ("No results for 'X'") is non-blank with a helpful suggestion.
11. Each section contributes dynamic commands: trace IDs from `useTracesStore`, vault keys from `useVaultStore`, server node names from `useStackStore`.

### Non-Functional Requirements

- Search results appear within 50ms of typing (synchronous local filtering; no debounce for local commands).
- ARIA combobox pattern: `role="combobox"` on input, `aria-activedescendant` for keyboard highlight (no DOM focus movement to options), `role="listbox"` on results, `role="option"` on items, `role="group"` + `aria-label` on group headers, `aria-live="polite"` for result count.
- The palette is a proper focus trap: `Tab` cycles within the palette, `Escape` exits.
- The palette overlay sits at `z-60` (above existing `z-50` modals).
- No new CSS framework dependencies. All styling via Tailwind CSS and the existing design token variables.
- Add `cmdk` to `web/package.json` as the only new runtime dependency.

### Out of Scope

- Nested/sub-palettes for node-level actions (this is a v2 enhancement).
- Voice input or natural language command parsing.
- Server-side command search (all commands are client-side registered).
- Admin/settings-level commands (user management, API key rotation).
- Any changes to the Go backend.

## Architecture Guidance

### Recommended Approach

Use `cmdk` as the primitive. It provides the combobox ARIA, keyboard navigation (arrow keys, enter, escape), and fuzzy filtering. Wrap it in a custom `CommandPalette` component styled with gridctl's Tailwind design tokens.

Implement a **centralized command registry** as a React context + hook (`useCommandRegistry`). Each section registers its commands imperatively on mount. This keeps `CommandPalette.tsx` decoupled from individual sections — it only renders what the registry provides.

**Command shape:**
```ts
interface PaletteCommand {
  id: string;               // unique, stable ID for frecency tracking
  label: string;            // display text
  section: 'traces' | 'vault' | 'registry' | 'canvas' | 'logs' | 'metrics' | 'global';
  icon?: React.ReactNode;   // Lucide icon element
  shortcut?: string[];      // e.g., ['Cmd', '0'] for Zoom to fit
  keywords?: string[];      // additional fuzzy match terms
  onSelect: () => void;     // action to execute
}
```

**Frecency storage:** A `Map<string, { count: number; lastUsed: number }>` keyed by command ID, persisted to `localStorage` as JSON under `gridctl-palette-frecency`. Update on every `onSelect` call.

### Key Files to Understand

| File | Why it matters |
|------|---------------|
| `web/src/hooks/useKeyboardShortcuts.ts` | The pattern for Cmd+Key shortcuts; extend with `onOpenPalette` |
| `web/src/App.tsx` | Where to mount `<CommandPalette>`; where `useKeyboardShortcuts` is called |
| `web/src/stores/useUIStore.ts` | Add `commandPaletteOpen` state and `toggleCommandPalette()` action |
| `web/src/components/ui/Modal.tsx` | Reference for overlay z-index, backdrop blur, and animate-fade-in-scale usage |
| `web/src/components/layout/Header.tsx` | Where to add the visible palette trigger button |
| `web/src/stores/useTracesStore.ts` | Dynamic command source: trace IDs, server filters |
| `web/src/stores/useVaultStore.ts` | Dynamic command source: vault key names |
| `web/src/stores/useRegistryStore.ts` | Dynamic command source: skill names, agent names |
| `web/src/stores/useStackStore.ts` | Dynamic command source: MCP server names, node IDs |
| `web/src/index.css` | Design tokens: colors, glass panel classes, animations |

### Integration Points

**`useKeyboardShortcuts.ts`** — add `onOpenPalette?: () => void` to `ShortcutOptions`. Wire `Cmd+K` / `Ctrl+K`:
```ts
if (isMod && e.key === 'k') {
  e.preventDefault();
  options.onOpenPalette?.();
}
```

**`useUIStore.ts`** — add:
```ts
commandPaletteOpen: boolean;
setCommandPaletteOpen: (open: boolean) => void;
toggleCommandPalette: () => void;
```
Do NOT persist `commandPaletteOpen` — it should always start closed.

**`App.tsx`** — mount the palette at the bottom of the return, passing `isOpen` and `onClose` from `useUIStore`. Pass `onOpenPalette` to `useKeyboardShortcuts`.

**`Header.tsx`** — add a search/command button (magnifying glass or terminal icon) that calls `toggleCommandPalette()`. Show `⌘K` hint on hover using the existing `IconButton` tooltip pattern.

### Reusable Components

- `cn()` from `lib/cn.ts` — class merging utility
- `IconButton` from `components/ui/IconButton.tsx` — for the header trigger button
- Lucide icons already imported throughout the app: `Search`, `Activity`, `Key`, `Library`, `Terminal`, `BarChart2`, `Layers`, `Clock`, `Command`, `ArrowRight`
- Existing CSS classes: `glass-panel-elevated`, `animate-fade-in-scale`, `scrollbar-dark`, `border-border/30`

## UX Specification

**Discovery**: A small search button in the Header (right side, near the refresh button) shows `⌘K` in a tooltip. This follows Grafana's lesson: the keyboard shortcut alone is invisible to new users.

**Activation**: `Cmd+K` / `Ctrl+K` from any context (except active input/textarea). The palette opens centered on screen with backdrop blur. Focus moves to the search input immediately.

**Default state**:
```
[Search commands...    ⌘K]

  RECENT
  ↳ [icon] Open Traces
  ↳ [icon] Pin Schema: auth-service
  ↳ [icon] View Node: github-mcp

  CURRENT CONTEXT
  ↳ [icon] Zoom to fit         ⌘0
  ↳ [icon] Refresh             ⌘⇧R
  ↳ [icon] Toggle bottom panel ⌘J

  NAVIGATE TO
  ↳ [icon] Traces
  ↳ [icon] Vault
  ↳ [icon] Registry
  ↳ [icon] Logs
  ↳ [icon] Metrics
```

**Active search** (user types "trac"):
```
[trac               ]

  Open Traces                      NAVIGATE
  Search: github-mcp traces        TRACES
  Filter traces by error           TRACES
  Activity — Traces tab            CANVAS
```
Group headers are gone. Each result has a subtle section badge. Results are ranked by relevance × frecency.

**Keyboard flow**: `↑`/`↓` highlight result (amber highlight matching the primary color token). `Enter` executes. `Escape` closes, focus returns to wherever it was.

**Prefix scoping**: If user types `v: auth`, only Vault commands matching "auth" appear. A chip shows `Vault` with an `×` to clear the scope filter.

**Empty state**: "No results for 'deploystack'" — then: "Try `>` to search actions, or `v:` for Vault secrets."

**Error states**: If a section store fails to load (e.g., traces API down), its commands still appear but show a subtle "unavailable" state when selected (toast error matching the existing toast pattern).

## Implementation Notes

### Conventions to Follow

- Zustand store actions use the `set((s) => ...)` functional form for derived updates.
- Component props interfaces are defined inline in the same file (not in `types/index.ts` unless shared).
- Tailwind classes use the `cn()` helper for conditional application.
- All keyboard event handling checks `e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement` before acting (pattern established in `useKeyboardShortcuts.ts`).
- Icons are always from `lucide-react` at size 14-16px.
- Animations use the existing Tailwind utility classes (`animate-fade-in-scale`, `transition-all`, `duration-200`).
- Tests live in `web/src/` next to the component being tested (`CommandPalette.test.tsx`).

### Potential Pitfalls

1. **`cmdk` and React 19**: `cmdk` v1.x is React 19 compatible. Pin to `^1.0.0` or later. Do not use v0.x — it uses deprecated `forwardRef` patterns.
2. **Focus restoration on close**: When `Escape` closes the palette, focus must return to the element that held focus *before* the palette opened. Capture `document.activeElement` on open; call `.focus()` on it on close. Failing this breaks keyboard-only navigation.
3. **`aria-activedescendant` vs DOM focus**: `cmdk` uses `aria-activedescendant` to track the highlighted option — focus stays on the input, not the list items. Do not override this behavior. Screen readers depend on it.
4. **Z-index**: The palette overlay should be `z-60`. The existing auth overlay is `z-50`. Do not reuse z-50 or the auth modal will overlap the palette.
5. **Frecency persistence**: Only persist frecency data, not palette open/close state. The `commandPaletteOpen` field in `useUIStore` should be excluded from the `partialize` persist filter (follow the existing pattern).
6. **Command ID stability**: Frecency scores are keyed by command ID. IDs for navigation commands must be stable strings like `"navigate:traces"`. IDs for dynamic commands (e.g., a specific trace) should include a stable entity identifier: `"trace:abc123"`.
7. **Prefix parsing edge case**: If the input is exactly `t:` with nothing after it, show all Traces commands (don't show an empty state).
8. **Canvas context detection**: To provide "Current Context" commands, you need to know which section is currently active. Use `useUIStore`'s `bottomPanelTab` and the open/close states of section panels to determine context. The Canvas is the default context when no section panel is active.

### Suggested Build Order

1. **Add `cmdk` dependency** — `cd web && npm install cmdk`
2. **Extend `useUIStore`** — add `commandPaletteOpen`, `setCommandPaletteOpen`, `toggleCommandPalette`
3. **Extend `useKeyboardShortcuts`** — add `onOpenPalette` callback and `Cmd+K` binding
4. **Define the `PaletteCommand` type** — in `web/src/types/index.ts` or a dedicated `types/palette.ts`
5. **Build `useCommandRegistry` hook** — context + hook for command registration; frecency scoring logic
6. **Build `CommandPalette.tsx`** — the UI component using `cmdk`; wire to `useUIStore` for open/close
7. **Wire palette into `App.tsx`** — mount component, pass `onOpenPalette` to `useKeyboardShortcuts`
8. **Register static commands** — navigation, canvas actions, toggles (directly in `App.tsx` or a dedicated `useGlobalCommands` hook)
9. **Register dynamic commands** — section stores contribute entity-level commands (trace IDs, vault keys, server names)
10. **Add Header trigger button** — visible search button in `Header.tsx`
11. **Add tests** — keyboard trigger, open/close, command execution, frecency update, ARIA attributes
12. **Empty state and error states** — last, after core flow is working

## Acceptance Criteria

1. `Cmd+K` (macOS) and `Ctrl+K` (Linux/Windows) open the palette from any non-input context in the app.
2. `Escape` closes the palette and restores focus to the previously focused element.
3. The palette opens with frecent items in a "Recent" group; no blank default state.
4. Typing filters results with fuzzy matching; results appear within 50ms.
5. All 6 sections (Canvas, Traces, Vault, Registry, Logs, Metrics) are represented with at least navigation and 2-3 action commands each.
6. Dynamic entities from live stores appear: server node names from `useStackStore`, visible trace IDs from `useTracesStore`.
7. Keyboard shortcuts are displayed inline next to commands that have them.
8. Prefix scoping works: `t:`, `v:`, `r:`, `>` filter to the correct section/type.
9. A visible Header button opens the palette on click with `⌘K` tooltip hint.
10. Empty state displays a helpful non-blank message with suggestions.
11. ARIA attributes are present and correct: `role="combobox"`, `aria-activedescendant`, `role="listbox"`, `role="option"`, `aria-live="polite"`.
12. Frecency data persists across page refresh (`localStorage` key: `gridctl-palette-frecency`).
13. All existing keyboard shortcuts (`Cmd+J`, `Cmd+0`, etc.) continue to work when the palette is closed.
14. At least one test covers: palette opens on `Cmd+K`, selects a command on `Enter`, closes on `Escape`, and restores focus.

## References

- [cmdk — GitHub](https://github.com/pacocoursey/cmdk)
- [cmdk — npm](https://www.npmjs.com/package/cmdk)
- [Command K Bars — Maggie Appleton](https://maggieappleton.com/command-bar)
- [How to build a remarkable command palette — Superhuman Blog](https://blog.superhuman.com/how-to-build-a-remarkable-command-palette/)
- [Designing a Command Palette — destiner.io](https://destiner.io/blog/post/designing-a-command-palette/)
- [Command Palette Interfaces — Philip Davis](https://philipcdavis.com/writing/command-palette-interfaces)
- [Retool Command Palette docs](https://docs.retool.com/apps/concepts/command-palette)
- [New in Grafana 9: command palette](https://grafana.com/blog/2022/06/22/new-in-grafana-9-introducing-the-command-palette/)
- [Introducing the Datadog quick nav menu](https://www.datadoghq.com/blog/datadog-quick-nav-menu/)
- [WAI-ARIA APG Combobox Pattern](https://www.w3.org/WAI/ARIA/apg/patterns/combobox/)
- [Nailing the Activation Behavior of a Command Palette — Multi](https://multi.app/blog/nailing-the-activation-behavior-of-a-spotlight-raycast-like-command-palette)
- [Full evaluation: feature-evaluation.md](./feature-evaluation.md)
