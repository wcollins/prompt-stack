# Feature Implementation: Vault Secret Visibility for MCP Servers/Agents

## Context

gridctl is a CLI/UI tool for managing MCP (Model Context Protocol) server stacks. It has a Go backend (API gateway at `internal/api/`) and a React 19 + TypeScript frontend (`web/src/`). State management uses Zustand. The UI uses Tailwind CSS with a custom dark theme and lucide-react icons. No component library — all UI components are custom.

The vault system stores encrypted secrets that can be organized into named variable sets. MCP servers and agents reference secrets via `${vault:KEY}` in their environment variable maps, or receive them automatically via `secrets.sets` in the stack config.

## Evaluation Context

- **Market insight**: No MCP tooling surfaces secret-to-service relationships. Even traditional infrastructure tools (Vault, Portainer, K8s Dashboard) don't do this well. Only Doppler's global search comes close. This is genuinely differentiating.
- **UX decision rationale**: The sidebar's existing `AccessItem` card pattern (colored header bar with item rows) provides a proven visual template. Tertiary/purple color is already associated with vault throughout the app.
- **Risk mitigations**: Read-only feature — never exposes secret values, only key names. No data mutation, no architectural changes.
- Full evaluation: `prompts/gridctl/vault-secret-visibility/feature-evaluation.md`

## Feature Description

Add a "Secrets" section to the sidebar detail panel that appears when viewing an MCP server or agent. The section shows:
1. Which vault variable sets the node's secrets belong to (displayed as cards)
2. The secret key names grouped by set (listed inside each card)
3. Whether sets are auto-injected (`secrets.sets`) or explicitly referenced (`${vault:KEY}`)
4. A visual bridge to the existing secret heatmap overlay via shared-secret color dots

This gives users operational visibility into secret dependencies without leaving the node detail view.

## Requirements

### Functional Requirements

1. Extend `GET /api/stack/secrets-map` to include variable set metadata for each secret key in the response
2. Add a collapsible "Secrets" `Section` to `Sidebar.tsx` between Actions and Tools, visible for both MCP servers and agents
3. Group secret keys by their variable set in card components (one card per set)
4. Show an "Unassigned" card for keys not assigned to any variable set
5. Display a count badge in the section header showing total secret key count
6. Distinguish auto-injected sets (`secrets.sets`) from explicit `${vault:KEY}` references with an "Auto-injected" pill
7. Clicking a variable set name opens the vault panel (filtered context)
8. Do not render the Secrets section if the node has zero vault references
9. When the vault is locked, show keys as a flat list (from config parsing) with a lock indicator noting set grouping is unavailable

### Non-Functional Requirements

1. Never expose secret values — only key names
2. Section should be collapsed by default (consistent with Token Usage and Tools sections)
3. Visual style must match existing sidebar patterns (Section component, AccessItem card pattern)
4. Use tertiary/purple color palette for vault-related elements (consistent with VaultPanel and heatmap)
5. Use `KeyRound` icon for the section and individual keys (already imported in Sidebar.tsx)

### Out of Scope

- Editing or assigning secrets from the sidebar (vault panel handles this)
- Showing secret values or masked values
- Adding secrets info to the graph node cards (CustomNode, AgentNode)
- Modifying the SecretHeatmapOverlay component
- Adding new vault API endpoints beyond extending secrets-map

## Architecture Guidance

### Recommended Approach

**Backend**: Extend `handleStackSecretsMap` to include set membership per key. The vault store already has `List()` which returns secrets with their `Set` field, and the stack config has `Secrets.Sets` for auto-injection. Merge this data into the existing response.

**Frontend**: Create a `SecretsSection` component (or inline in Sidebar) that fetches the extended secrets-map data and the vault store's sets. Group keys by set and render using the AccessItem card pattern.

### Key Files to Understand

| File | Why |
|------|-----|
| `internal/api/stack.go:241-283` | `handleStackSecretsMap` — the endpoint to extend. Currently builds `secretToNodes` and `nodeToSecrets` maps from `${vault:KEY}` references in config. |
| `internal/api/vault.go` | Vault API handlers — understand how vault state is accessed via `s.vaultStore`. |
| `pkg/vault/types.go` | `Secret` struct has `Key`, `Value`, `Set` fields. `Set` struct has `Name`, `Description`. |
| `pkg/config/types.go:23-26` | `Secrets` struct with `Sets []string` — stack-level auto-injection config. |
| `pkg/config/expand.go` | `ExpandString` — how `${vault:KEY}` references are parsed. |
| `web/src/lib/api.ts:564-569` | `fetchSecretsMap()` — current return type `{ secrets: Record<string, string[]>; nodes: Record<string, string[]> }`. |
| `web/src/components/layout/Header.tsx:25` | `showVault` state is local here via `useState`. Must be lifted to `useUIStore` so the Sidebar can open the vault panel. |
| `web/src/components/layout/Sidebar.tsx:497-506` | `AccessItem` component — the visual pattern to reuse for set cards. |
| `web/src/components/layout/Sidebar.tsx:521-556` | `Section` component — collapsible section used throughout sidebar. |
| `web/src/stores/useUIStore.ts` | Global UI state store. Vault visibility and filter state should be added here. |
| `web/src/stores/useVaultStore.ts` | Zustand store with `secrets: VaultSecret[]`, `sets: VaultSet[]`, `locked: boolean`. |
| `web/src/components/vault/VaultPanel.tsx` | Vault panel component — currently uses local `searchQuery` state. Needs to accept an initial filter set from the store. |
| `web/src/components/spec/SecretHeatmapOverlay.tsx` | `SECRET_COLORS` palette and `fetchSecretsMap()` usage — for shared-secret color coordination. |

### Integration Points

**Backend — `internal/api/stack.go`**:

Extend `handleStackSecretsMap` to:
1. After building `secretToNodes`/`nodeToSecrets`, look up each key's set membership from `s.vaultStore.List()` (if vault is unlocked)
2. Also check `stack.Secrets.Sets` to identify auto-injected sets and enumerate their member keys via `s.vaultStore.GetSetSecrets()` (if vault implements `VaultSetLookup`)
3. Add to response: `sets` field mapping set names to their member keys, and `keyToSet` mapping each key to its set name

Extended response shape:
```json
{
  "secrets": { "API_KEY": ["server-a", "agent-b"] },
  "nodes": { "server-a": ["API_KEY", "DB_HOST"] },
  "keyToSet": { "API_KEY": "production", "DB_HOST": "production" },
  "autoInjectedSets": ["production"],
  "vaultLocked": false
}
```

**Frontend — `web/src/lib/api.ts`**:

Update `fetchSecretsMap()` return type to include the new fields.

**Frontend — Vault panel state lift (`useUIStore.ts`, `Header.tsx`, `VaultPanel.tsx`)**:

The `showVault` state is currently local to `Header.tsx` (line 25: `useState(false)`). This must be lifted to `useUIStore` so the Sidebar can open the vault panel when a set name is clicked.

1. Add to `useUIStore.ts`:
   - `vaultOpen: boolean` (default `false`) — replaces `showVault` in Header
   - `setVaultOpen: (open: boolean) => void`
   - `vaultFilterSet: string | null` (default `null`) — pre-filters vault panel to a specific set
   - `setVaultFilterSet: (set: string | null) => void`
   - `openVaultToSet: (set: string) => void` — convenience action that sets both `vaultOpen: true` and `vaultFilterSet: set`

2. Update `Header.tsx`:
   - Replace local `showVault` / `setShowVault` with `useUIStore` selectors (`vaultOpen`, `setVaultOpen`)
   - Pass vault open/close through the store instead of local state

3. Update `VaultPanel.tsx`:
   - On mount, read `vaultFilterSet` from `useUIStore`. If set, initialize `searchQuery` to that value
   - Clear `vaultFilterSet` in the store when the panel closes (so it doesn't persist across opens)
   - The `onClose` callback should call `setVaultOpen(false)` and `setVaultFilterSet(null)`

**Frontend — `web/src/components/layout/Sidebar.tsx`**:

Add a Secrets section after Actions, before Tools. The section:
1. Uses `fetchSecretsMap()` data to get the current node's secret keys (from `nodes[data.name]`)
2. Uses `keyToSet` to group keys by set
3. Uses `autoInjectedSets` to show "Auto-injected" pills
4. Handles `vaultLocked` by showing flat list with lock indicator
5. On set name click, calls `openVaultToSet(setName)` from `useUIStore`

### Reusable Components

- `Section` component (Sidebar.tsx:521) — use directly for the collapsible container
- `AccessItem` card pattern (Sidebar.tsx:563) — replicate the visual structure for set cards: colored header bar + item rows
- `Badge` component (`web/src/components/ui/Badge.tsx`) — for count/status badges
- `KeyRound` icon from lucide-react — already imported in Sidebar.tsx
- `cn` utility — for conditional className merging

## UX Specification

### Layout Structure

```
[KeyRound] Secrets                                    [5]  >
--------------------------------------------------------------
(when expanded)

[FolderOpen] production                           3 keys
[Auto-injected]
┌──────────────────────────────────────────────────────┐
│  [KeyRound] DB_HOST                                  │
│  [KeyRound] DB_PASSWORD                              │
│  [KeyRound] API_KEY                                  │
└──────────────────────────────────────────────────────┘

[Package] Unassigned                              2 keys
┌──────────────────────────────────────────────────────┐
│  [KeyRound] CUSTOM_TOKEN                             │
│  [KeyRound] WEBHOOK_SECRET                           │
└──────────────────────────────────────────────────────┘
```

### Styling Tokens

| Element | Tailwind Classes |
|---------|-----------------|
| Set card container | `rounded-lg bg-surface-elevated border border-border/40 overflow-hidden` |
| Set header bar | `px-3 py-2 bg-tertiary/10 flex justify-between items-center` |
| Set name | `text-xs font-medium text-tertiary` with `FolderOpen` at 12px |
| Auto-injected pill | `text-[9px] px-1.5 py-0.5 rounded font-medium uppercase tracking-wider border border-tertiary/30 text-tertiary bg-tertiary/5` |
| Key count badge | `text-[10px] text-text-muted bg-surface-elevated px-1.5 py-0.5 rounded-md font-mono` |
| Key row | `flex items-center gap-2 px-2 py-1.5 rounded bg-background/50` |
| Key name | `text-xs font-mono text-text-primary truncate` |
| Unassigned header | Same structure but `bg-surface-highlight/30`, icon and text in `text-text-muted` |
| Empty state | `text-xs text-text-muted italic px-2` — "No vault secrets referenced" |
| Locked indicator | `text-[10px] text-text-muted flex items-center gap-1.5 mb-2` with `Lock` icon at 10px |

### Interactions

- **Expand/collapse**: Clicking section header toggles visibility (handled by Section component)
- **Set name click**: `cursor-pointer` with `hover:bg-tertiary/15` on header — triggers opening vault panel
- **Key name hover**: Show tooltip with other nodes sharing this key (if any)
- **Empty state**: Section not rendered at all when node has zero vault refs

### Error States

- **Vault locked**: Render keys as flat list (no set grouping). Show lock indicator: "Vault locked — set grouping unavailable"
- **Secrets-map fetch failure**: Section not rendered (same as empty state)
- **Node has refs but keys not in vault**: Show key names normally — they come from config parsing, not vault lookup

## Implementation Notes

### Conventions to Follow

- Use the existing `Section` component — do not create a new collapsible pattern
- Match the `AccessItem` visual structure for set cards
- Use `fetchJSON` wrapper from `web/src/lib/api.ts` for API calls
- Go handlers follow the pattern in `internal/api/vault.go` — use `writeJSON` and `writeJSONError`
- Test Go changes with table-driven tests matching `internal/api/stack_test.go` patterns
- Test React components with Vitest + React Testing Library matching `web/src/__tests__/` patterns

### Potential Pitfalls

- **Vault locked vs config parsing**: The secrets-map endpoint reads `${vault:KEY}` from stack YAML (always available) but set metadata requires the vault to be unlocked. The backend must handle this gracefully — return key-to-node mapping always, set metadata only when vault is unlocked.
- **`secrets.sets` auto-injection**: When `secrets.sets` lists a set name, ALL keys in that set should be included as used by every node. This requires enumerating set members, which needs the vault unlocked. If locked, the backend should still return `autoInjectedSets` (the set names come from stack YAML, not the vault), but `keyToSet` will be incomplete since member enumeration is unavailable. The frontend should show those sets with a "membership unavailable" indicator rather than hiding them entirely.
- **Deduplication**: A key referenced both explicitly (`${vault:API_KEY}`) and via auto-injection (key belongs to an auto-injected set) should appear once, under its set card.
- **Performance**: The secrets-map endpoint re-parses the stack YAML on every call. This is fine — it's a small file and the endpoint is called infrequently (on section expand or overlay toggle).

### Suggested Build Order

1. **Backend first**: Extend `handleStackSecretsMap` in `internal/api/stack.go` to include `keyToSet`, `autoInjectedSets`, and `vaultLocked` fields. Add tests.
2. **API type update**: Update `fetchSecretsMap()` in `web/src/lib/api.ts` with the extended return type.
3. **Lift vault state**: Move `showVault` from `Header.tsx` local state to `useUIStore.ts` (`vaultOpen`, `setVaultOpen`, `vaultFilterSet`, `setVaultFilterSet`, `openVaultToSet`). Update `Header.tsx` to use the store. Update `VaultPanel.tsx` to read `vaultFilterSet` on mount and initialize `searchQuery` from it.
4. **Sidebar section**: Add the Secrets section to `web/src/components/layout/Sidebar.tsx`. Start with a basic version that shows a flat key list per node.
5. **Set grouping**: Add the card-per-set layout with AccessItem-style cards.
6. **Vault locked fallback**: Handle the locked state with flat list + lock indicator. Show auto-injected set names with "membership unavailable" when vault is locked.
7. **Vault panel cross-link**: Wire up set name clicks to call `openVaultToSet(setName)`.
8. **Tests**: Add frontend tests for the new section, including vault locked state and set filtering.

## Acceptance Criteria

1. When an MCP server or agent has `${vault:KEY}` references in its env, the sidebar shows a "Secrets" section with those key names
2. Secret keys are grouped by variable set in cards matching the AccessItem visual pattern
3. Keys not assigned to a set appear in an "Unassigned" card
4. Auto-injected sets (from `secrets.sets`) show an "Auto-injected" pill
5. The section header shows total key count
6. Clicking a set name opens the vault panel filtered to that set
7. Vault panel visibility (`vaultOpen`) and filter state (`vaultFilterSet`) are managed in `useUIStore`, not local component state
8. `VaultPanel` initializes its search query from `vaultFilterSet` on mount and clears it on close
9. Section is collapsed by default
10. Section is not rendered when the node has zero vault references
11. When vault is locked, keys show as a flat list with a lock indicator; auto-injected set names still appear with "membership unavailable" indicator
12. Secret values are never exposed — only key names appear
13. Section appears for both MCP servers and agents (not resources or clients)
14. Go backend tests pass for the extended secrets-map endpoint
15. Frontend tests verify section rendering, set grouping, locked state, and vault panel cross-linking

## References

- [Doppler Workplace Structure](https://docs.doppler.com/docs/workplace-structure) — closest comparable UX for secret grouping
- [OWASP MCP01:2025](https://owasp.org/www-project-mcp-top-10/2025/MCP01-2025-Token-Mismanagement-and-Secret-Exposure) — motivating security standard
- [Badges vs Chips vs Tags](https://smart-interface-design-patterns.com/articles/badges-chips-tags-pills/) — UI pattern guidance
- [Infisical GitHub](https://github.com/Infisical/infisical) — reference implementation for secret dashboard patterns
