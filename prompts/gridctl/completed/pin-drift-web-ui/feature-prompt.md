# Feature Implementation: Pin Drift Web UI

## Context

gridctl is a production-grade MCP (Model Context Protocol) gateway written in Go with an embedded React/TypeScript Web UI. The Web UI uses:
- **@xyflow/react** for the canvas graph visualization (MCP server nodes)
- **Zustand** for state management
- **Tailwind CSS** with custom semantic color tokens (`status-running`, `status-error`, `status-pending`)
- **Lucide React** for icons
- **Polling** via `usePolling.ts` (3s main cycle) and per-component intervals

The project uses trunk-based development with signed commits. The TOFU (Trust On First Use) pinning system ships fully in the backend — this feature is purely UI work.

## Evaluation Context

- **Market insight**: Terraform Cloud and ArgoCD validate the badge + detail panel + action pattern as industry standard for drift visualization. No comparable MCP tool does this yet.
- **UX decision**: Inline approve button (not just a CLI link) because `POST /api/pins/{server}/approve` already exists; removing the CLI anti-pattern is minimal extra work.
- **Risk mitigation**: Toast extension is intentionally minimal — add `warning` type and optional `action` prop only; don't redesign the toast system.
- **Differentiation**: Use `LockOpen` icon (not `AlertTriangle`) to visually separate pin drift from spec drift, which uses `AlertTriangle` in the existing `DriftOverlay.tsx`.
- Full evaluation: `/Users/william/code/prompt-stack/prompts/gridctl/pin-drift-web-ui/feature-evaluation.md`

## Feature Description

Surface TOFU schema pin drift in the gridctl Web UI. When MCP server tool definitions change after initial pinning, users on the default "warn" policy have zero visibility unless they tail logs. This feature adds:

1. **Status bar badge** — `PinDriftBadge` in `StatusBar.tsx` showing drift count in amber, a lock icon, and clickable to open a Pins bottom panel tab
2. **Canvas node overlay** — inline drift indicator on drifted server nodes inside `CustomNode.tsx`
3. **Toast notification** — on first drift detection, with an optional "View" action opening the Pins panel
4. **Pins bottom panel tab** — lists drifted servers with per-server inline approve buttons

The backend is complete. Data flows through `GET /api/pins` which returns `map[string]*ServerPins`. Each `ServerPins` has a `Status` field that equals `"drift"` when tool definitions have changed.

## Requirements

### Functional Requirements

1. `GET /api/pins` is called on the main polling cycle (every 3 seconds) and results are stored in a `usePinsStore` Zustand store
2. `PinDriftBadge` renders in `StatusBar.tsx` after the `SpecHealthBadge` divider; shows "Pins: N drifted" in `text-status-pending` (amber) when any server has `status: "drift"`, or green with a checkmark when all are clean; hidden entirely when the pin store has no data (pins feature not enabled)
3. `PinDriftBadge` clicking opens the bottom panel "pins" tab
4. `CustomNode.tsx` renders a drift indicator block for MCP server nodes when `pinStatus === "drift"` — a lock icon with amber color and tooltip text "Schema drift detected — approve to resume"
5. `CustomNode.tsx` renders a "blocked" indicator for servers with `pinStatus === "blocked"` (when `pinAction === "block"`) — uses `status-error` (red) coloring
6. A toast notification fires when the pins store transitions from no-drift to drift state (not on every poll); uses a new `warning` type and includes an optional "View" action that opens the Pins panel
7. A "Pins" tab exists in the bottom panel, listing each server's pin state: name, status, tool count, last verified timestamp, and an "Approve" button
8. The "Approve" button calls `POST /api/pins/{server}/approve`; on success shows a `success` toast and refreshes the pins store; on failure shows an `error` toast
9. `MCPServerNodeData` in `types/index.ts` gets two new optional fields: `pinStatus?: 'pinned' | 'drift' | 'blocked' | 'approved_pending_redeploy'` and `pinDriftCount?: number`
10. These fields are populated in `usePolling.ts` by cross-referencing the pins store with the server name after each poll cycle

### Non-Functional Requirements

- Pins polling must not add a new `setInterval` — integrate into the existing `usePolling.ts` 3-second cycle
- The Toast extension must be backward-compatible — existing calls to `showToast('success', msg)` and `showToast('error', msg)` must continue working unchanged
- Pin drift indicators must not appear in compact card mode (respect the `isCompact` toggle)
- Approve action must debounce to prevent double-clicks

### Out of Scope

- Tool-level diff visualization (showing which specific tool fields changed) — show only that drift was detected, not the per-tool hash details
- `DELETE /api/pins/{server}` (reset pins) — not exposed in the UI
- Integration with the existing `DriftOverlay.tsx` spec-drift overlay — pin drift gets its own separate visual treatment
- Backend changes of any kind

## Architecture Guidance

### Recommended Approach

Model `usePinsStore.ts` exactly after `useSpecStore.ts` — a Zustand store with `subscribeWithSelector`, a `pins` state field (the full `map[string]*ServerPins` response), a `setPins` setter, and a derived selector `useDriftedServers()` that filters to servers with `status === "drift"`.

Model `PinDriftBadge.tsx` exactly after `SpecHealthBadge.tsx` — same polling-in-component approach is acceptable, but prefer adding pins fetching to `usePolling.ts` instead so drift appears within the same 3s cycle as server status.

### Key Files to Understand

| File | Why It Matters |
|------|---------------|
| `web/src/components/spec/SpecHealthBadge.tsx` | Exact template for `PinDriftBadge.tsx` — polling, Zustand selector, color-coded dot, click handler |
| `web/src/components/layout/StatusBar.tsx` | Where to add `PinDriftBadge` — after existing SpecHealthBadge divider at line 126-129 |
| `web/src/components/graph/CustomNode.tsx` | Node health indicator at lines 209–223 — exact template for pin drift indicator |
| `web/src/stores/useSpecStore.ts` | Template for `usePinsStore.ts` |
| `web/src/hooks/usePolling.ts` | Where to add `fetchServerPins()` call and populate `MCPServerNodeData.pinStatus` |
| `web/src/lib/api.ts` | Where to add `fetchServerPins()` — use the existing `fetchJSON<T>()` wrapper |
| `web/src/types/index.ts` | `MCPServerNodeData` (line 144) — add `pinStatus?` and `pinDriftCount?`; add `ServerPins` type |
| `web/src/components/ui/Toast.tsx` | Extend with `warning` type and `action` prop |
| `internal/api/pins.go` | Backend reference — `handleListPins` returns `map[string]*ServerPins` |
| `pkg/pins/types.go` | Backend types — `StatusDrift = "drift"`, `StatusPinned = "pinned"`, `ServerPins` fields |

### Integration Points

**`web/src/lib/api.ts`** — Add:
```typescript
export interface ServerPins {
  server_hash: string;
  pinned_at: string;
  last_verified_at: string;
  tool_count: number;
  status: 'pinned' | 'drift' | 'approved_pending_redeploy';
  tools: Record<string, PinRecord>;
}

export interface PinRecord {
  hash: string;
  name: string;
  description?: string;
  pinned_at: string;
}

export async function fetchServerPins(): Promise<Record<string, ServerPins>> {
  return fetchJSON<Record<string, ServerPins>>('/api/pins');
}

export async function approveServerPins(serverName: string): Promise<void> {
  const response = await fetch(`/api/pins/${encodeURIComponent(serverName)}/approve`, {
    method: 'POST',
    headers: buildHeaders(),
  });
  if (response.status === 401) throw new AuthError('Authentication required');
  if (!response.ok) throw new Error(`API error: ${response.status}`);
}
```

**`web/src/stores/usePinsStore.ts`** — New file:
```typescript
import { create } from 'zustand';
import { subscribeWithSelector } from 'zustand/middleware';
import type { ServerPins } from '../lib/api';

interface PinsState {
  pins: Record<string, ServerPins> | null;
  setPins: (pins: Record<string, ServerPins>) => void;
}

export const usePinsStore = create<PinsState>()(
  subscribeWithSelector((set) => ({
    pins: null,
    setPins: (pins) => set({ pins }),
  }))
);

export const useDriftedServers = () =>
  usePinsStore((s) => {
    if (!s.pins) return [];
    return Object.entries(s.pins)
      .filter(([, sp]) => sp.status === 'drift')
      .map(([name, sp]) => ({ name, ...sp }));
  });
```

**`web/src/hooks/usePolling.ts`** — In the main poll function, after fetching status and tools, add:
```typescript
try {
  const pins = await fetchServerPins();
  usePinsStore.getState().setPins(pins);
} catch {
  // pins endpoint may be unavailable (feature not enabled)
}
```

Also update the `mcpServers` mapping step to cross-reference `usePinsStore.getState().pins` and populate `pinStatus` and `pinDriftCount` on each server's node data.

**`web/src/types/index.ts`** — In `MCPServerNodeData` (around line 164), add:
```typescript
pinStatus?: 'pinned' | 'drift' | 'blocked' | 'approved_pending_redeploy';
pinDriftCount?: number;
```

**`web/src/components/ui/Toast.tsx`** — Minimal extension:
- Add `'warning'` to the `type` union
- Add `action?: { label: string; onClick: () => void }` to the toast object interface
- Render the action as a `<button>` inside the toast when present
- Update `showToast` signature to accept optional options: `showToast(type, message, options?: { action?, duration? })`
- Backward-compatible: all existing call sites continue working unchanged

**`web/src/components/spec/SpecHealthBadge.tsx`** — Reference only; do not modify.

**`web/src/components/layout/StatusBar.tsx`** — After the divider at line 125-126, add:
```tsx
{/* Divider before pin drift */}
<div className="w-px h-3 bg-border/50" />
<PinDriftBadge />
```
(Only render the additional divider when `PinDriftBadge` has data to show — or let `PinDriftBadge` return `null` when no pins data, matching `SpecHealthBadge` behavior.)

**`web/src/components/graph/CustomNode.tsx`** — After the existing health indicator block (lines 209–223), add:
```tsx
{/* Pin drift indicator */}
{isServer && !isCompact && (data as MCPServerNodeData).pinStatus === 'drift' && (
  <div className="flex items-center gap-1.5 px-2 py-1.5 rounded-md bg-status-pending/5 border border-status-pending/15">
    <LockOpen size={11} className="text-status-pending flex-shrink-0" />
    <span className="text-xs text-status-pending/80 font-mono truncate">
      Schema drift detected
    </span>
  </div>
)}
{isServer && !isCompact && (data as MCPServerNodeData).pinStatus === 'blocked' && (
  <div className="flex items-center gap-1.5 px-2 py-1.5 rounded-md bg-status-error/5 border border-status-error/15">
    <Lock size={11} className="text-status-error flex-shrink-0" />
    <span className="text-xs text-status-error/80 font-mono truncate">
      Blocked — schema drift
    </span>
  </div>
)}
```
Import `LockOpen` and `Lock` from `lucide-react`.

### Reusable Components

- `SpecHealthBadge.tsx` → copy as starting point for `PinDriftBadge.tsx`; swap icon to `LockOpen`, update store/fetch references, update click handler to open 'pins' tab
- `fetchJSON<T>()` in `api.ts` → use for `fetchServerPins()`
- Existing bottom panel tab system → add a "pins" tab following the same pattern as other tabs; look at how "spec" tab is structured

## UX Specification

**Discovery**: `PinDriftBadge` in status bar; shows only when pins data is available and at least one server has drifted. Uses amber (`text-status-pending`) when drifted, green (`text-status-running`) when all clean.

**Badge label formats**:
- `Pins: 2 drifted` — amber, `LockOpen` icon, pulsing dot
- `Pins: OK` — green, `Lock` icon, solid dot (only show when at least one server is pinned)
- Hidden when no pins data (pinning feature not configured)

**Activation**: Click badge → `useUIStore.getState().setBottomPanelTab('pins')`

**Node overlay**: Lock icon indicator appears in the node body (not header) to avoid clutter; not shown in compact mode. Tooltip: "Schema drift detected — approve in the Pins panel"

**Pins panel tab**:
- Table/list of all servers with pins data
- Columns: Server name | Status | Tools | Last verified | Actions
- "Approve" button per row; disabled while approving; shows spinner
- On success: row updates to `pinned` status; success toast fires
- On error: error toast with message

**Notification**: Toast fires when `usePinsStore` transitions from 0 drifted → N drifted; use `showToast('warning', 'Schema drift detected on N server(s)', { action: { label: 'View', onClick: () => openPinsPanel() }, duration: 6000 })`. Guard this transition with a ref to avoid re-firing on every poll.

**Error states**: If `GET /api/pins` returns 503 (pin store not available — pinning not configured), suppress all pin drift UI silently. This is a valid deployment state.

## Implementation Notes

### Conventions to Follow

- Component files: `PascalCase.tsx` in the appropriate `web/src/components/` subdirectory
- Store files: `useCamelCase.ts` in `web/src/stores/`
- Imports: use the `../../` relative path style already used in the codebase (not path aliases)
- No default exports for components in this codebase (see `SpecHealthBadge`, `DriftOverlay` — all named exports)
- Tailwind color tokens: use `status-pending`, `status-error`, `status-running` semantic tokens, not raw Tailwind colors
- Do not add trailing comments like `// added for pin drift` — keep code clean

### Potential Pitfalls

- **Double-toast on every poll**: Guard the drift detection toast with a `useRef<boolean>` that tracks whether you've already fired a toast for the current drift state. Only fire when transitioning from clean to drifted.
- **Pins API 503**: When `pinStore == nil` on the backend, `handleListPins` returns a 503. The frontend should catch this and treat it as "feature not available" — no UI shown, no error logged.
- **MCPServerNodeData population timing**: The pins store is populated after the status store in the polling cycle. When mapping server node data, pull from `usePinsStore.getState().pins` at map time to avoid stale references.
- **Bottom panel tab registration**: Look at how other tabs (spec, logs, metrics) are registered in the bottom panel and follow the exact same pattern.
- **`approveServerPins` needs re-fetch**: After approval, call `fetchServerPins()` and update the store — don't rely on the next poll cycle to clear the drift indicator.

### Suggested Build Order

1. **Types first**: Add `pinStatus?`, `pinDriftCount?` to `MCPServerNodeData` in `types/index.ts`; add `ServerPins`, `PinRecord` interfaces to `api.ts`
2. **API function**: Add `fetchServerPins()` and `approveServerPins()` to `api.ts`
3. **Store**: Create `usePinsStore.ts` with `pins` state and `useDriftedServers()` selector
4. **Polling integration**: Add `fetchServerPins()` call in `usePolling.ts`; populate `pinStatus` on server node data
5. **Toast extension**: Add `warning` type and `action` prop to `Toast.tsx` (backward-compatible)
6. **PinDriftBadge**: Create `web/src/components/pins/PinDriftBadge.tsx` mirroring `SpecHealthBadge.tsx`
7. **StatusBar**: Wire `PinDriftBadge` into `StatusBar.tsx`
8. **CustomNode**: Add pin drift/blocked indicator blocks to `CustomNode.tsx`
9. **Pins panel tab**: Create the pins bottom panel tab with the approve button
10. **Drift toast**: Add the transition-guarded drift notification to the polling callback

## Acceptance Criteria

1. When a server's pin status is `"drift"`, the status bar shows "Pins: N drifted" in amber within one polling cycle (≤3s)
2. Clicking the `PinDriftBadge` opens the bottom panel "Pins" tab
3. Canvas nodes with `pinStatus === "drift"` show a `LockOpen` amber indicator in their body; nodes with `pinStatus === "blocked"` show a `Lock` red indicator
4. Pin drift indicators do not appear in compact card mode
5. The Pins panel tab lists all servers with pin data, showing their status, tool count, and last verified time
6. Clicking "Approve" on a drifted server calls `POST /api/pins/{server}/approve`; on success the row clears drift state and a success toast appears; on failure an error toast appears
7. A warning toast fires once when drift is first detected (not on every subsequent poll)
8. When `GET /api/pins` returns 503, all pin drift UI is silently suppressed
9. Existing `showToast('success', ...)` and `showToast('error', ...)` call sites compile and behave identically after `Toast.tsx` changes
10. The feature works correctly when no servers are pinned (pins store returns empty map) — badge hidden, no overlays

## References

- `pkg/pins/types.go` — Backend types: `StatusDrift`, `StatusPinned`, `ServerPins`, `PinRecord`
- `internal/api/pins.go` — API handlers; `handleListPins` returns `map[string]*ServerPins`
- `web/src/components/spec/SpecHealthBadge.tsx` — Badge pattern reference
- `web/src/components/spec/DriftOverlay.tsx` — Canvas overlay pattern reference
- `web/src/components/graph/CustomNode.tsx` — Node indicator pattern (lines 209–223)
- `web/src/stores/useSpecStore.ts` — Zustand store pattern reference
- `web/src/hooks/usePolling.ts` — Where to add pins polling
- [Terraform Cloud Drift Detection](https://www.hashicorp.com/en/lp/drift-detection-for-terraform-cloud)
- [ArgoCD Status Badge](https://argo-cd.readthedocs.io/en/stable/user-guide/status-badge/)
