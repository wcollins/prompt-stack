# Feature Evaluation: Pin Drift Web UI

**Date**: 2026-04-04
**Project**: gridctl
**Recommendation**: Build
**Value**: High
**Effort**: Small

## Summary

The TOFU pinning system is production-complete but entirely invisible to Web UI users — schema drift surfaces only as a structured log warning. This feature closes that gap by adding a status bar badge, per-node canvas overlays, and an actionable notification, all using data from `GET /api/pins` which already exists. Every pattern needed has a near-identical existing implementation to mirror.

## The Idea

Surface TOFU schema pin drift in the gridctl Web UI. When an MCP server's tool definitions change after initial pinning, users running the default "warn" policy currently have no visibility unless they tail logs. The feature adds:

1. **Status bar badge** — mirrors the existing `SpecHealthBadge` pattern; shows drift count in amber/red with a lock icon, clickable to open a Pins panel
2. **Canvas node overlay** — inline indicator on drifted server nodes inside `CustomNode.tsx`, following the existing health error indicator pattern
3. **Notification** — toast on drift detection linking to `gridctl pins approve <server>`; enhanced with an optional inline approve button via `POST /api/pins/{server}/approve`

## Project Context

### Current State

gridctl is a mature MCP gateway CLI/Web tool at v0.1.0-beta.3. The TOFU pinning system shipped fully on the backend (SHA256 per-tool hashing, drift detection, warn/block policy, approval workflow). The Go API exposes `GET /api/pins`, `POST /api/pins/{server}/approve`, and `DELETE /api/pins/{server}`. The Web UI (React + TypeScript + Zustand + @xyflow/react) has zero pin state visualization.

### Integration Surface

| File | Change Needed |
|------|--------------|
| `web/src/lib/api.ts` | Add `fetchServerPins()` function |
| `web/src/types/index.ts` | Add `ServerPins`, `PinRecord`, `PinDriftStatus` types; add `pinStatus?` to `MCPServerNodeData` |
| `web/src/stores/usePinsStore.ts` | New Zustand store (mirrors `useSpecStore` shape) |
| `web/src/hooks/usePolling.ts` | Add pins polling alongside existing status/tools fetch |
| `web/src/components/spec/SpecHealthBadge.tsx` | Reference/copy for new `PinDriftBadge.tsx` |
| `web/src/components/layout/StatusBar.tsx` | Add `PinDriftBadge` after existing divider |
| `web/src/components/graph/CustomNode.tsx` | Add pin drift indicator block (lines 210–223 pattern) |
| `web/src/components/ui/Toast.tsx` | Extend with `warning` type and optional `action` prop |

### Reusable Components

- `SpecHealthBadge.tsx` — exact template for `PinDriftBadge.tsx` (polling, Zustand, color, click-to-open)
- `DriftOverlay.tsx` — canvas overlay pattern (summary banner with `AlertTriangle`)
- `CustomNode.tsx` health indicator block (lines 209–223) — template for per-node pin drift indicator
- `useSpecStore.ts` — template for `usePinsStore.ts`
- `fetchJSON<T>()` in `api.ts` — generic fetch wrapper; just add a new function

## Market Analysis

### Competitive Landscape

- **Terraform Cloud / Pulumi**: Both treat drift as a first-class property with dedicated dashboard tabs, status badges, and approval workflows — the exact three-layer pattern proposed here (badge + detail + action)
- **ArgoCD**: Status badge auto-updates sync state (Synced/OutOfSync/Unknown) — validates the status bar badge as an industry-standard discovery mechanism
- **Kong / Linkerd**: No native drift UI — rely on external dashboards (Prometheus/Grafana)
- **MCP ecosystem**: No comparable tool does schema drift visualization; there is an open GitHub issue in the MCP spec repo for tool versioning (`modelcontextprotocol/modelcontextprotocol#1039`) — gridctl is ahead of the curve

### Market Positioning

**Differentiator.** No other MCP client or gateway surfaces TOFU schema drift visually. The canvas node overlay pattern applied to an @xyflow/react graph is particularly novel — most comparable tools use list/grid UIs.

### Ecosystem Support

No external libraries needed. All required patterns (badge, overlay, store, polling) are already in the codebase. Lucide React (already used) provides `LockOpen`, `ShieldAlert`, `Lock` icons suitable for TOFU state signaling.

### Demand Signals

The MCP ecosystem is rapidly expanding, and tool definition security (rug-pull prevention) is an active concern. The TOFU model is well-established (SSH known_hosts, npm integrity, go.sum) — surfacing it visually is a natural expectation once users know pinning exists.

## User Experience

### Interaction Model

**Discovery**: Status bar badge ("Pins: 2 drifted") in amber — same visual weight as `SpecHealthBadge`. Users notice it during normal operation without requiring log inspection.

**Detail + Action**: Badge click opens a bottom panel "Pins" tab listing drifted servers with per-server approve buttons (calling `POST /api/pins/{server}/approve`). No CLI required.

**Node-level**: Canvas nodes with drift show a lock icon indicator (like the health error indicator), with hover tooltip explaining the drift. Clicking the indicator navigates to the Pins panel filtered to that server.

**Notification**: On first drift detection, a toast fires with an optional "View" action that opens the Pins panel.

### Workflow Impact

Reduces friction significantly. Currently the only path to awareness is log tailing. After this feature, drift surfaces within the normal UI workflow without any additional steps.

### UX Recommendations

1. **Differentiate from spec drift visually**: Use `LockOpen` icon (not `AlertTriangle`) for pin drift. Spec drift uses `AlertTriangle` in primary/cyan; pin drift should use `LockOpen` in amber/red. Clear semantic separation.

2. **Inline approve button over CLI link**: `POST /api/pins/{server}/approve` already exists. An in-UI button is 10x faster than copy-pasting a CLI command and eliminates the "leaky abstraction" anti-pattern.

3. **Extend Toast**: Current `Toast.tsx` supports `'success' | 'error'` only, no links, 3s auto-dismiss. Add `'warning'` type and optional `action?: { label: string; onClick: () => void }` for the notification to be actionable.

4. **Polling**: Add to the existing `usePolling.ts` 3-second cycle (not a separate 10s interval) — pin drift is a stability signal that benefits from low-latency detection.

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Significant | Default warn policy = silent drift; the TOFU security promise is invisible without UI |
| User impact | Broad+Deep | All pinning users affected; security-conscious users need this for the feature to be meaningful |
| Strategic alignment | Core mission | Completes a shipped backend feature; TOFU is a key differentiator |
| Market positioning | Leap ahead | No comparable MCP tool does schema drift visualization |

### Cost Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Minimal | Data pipe exists; every UI pattern has a near-identical template in the codebase |
| Effort estimate | Small | ~2-3 days; purely UI work, no backend changes |
| Risk level | Low | No data integrity or security risk from UI additions |
| Maintenance burden | Minimal | Follows existing patterns; well-bounded change surface |

## Recommendation

**Build.** This completes a shipped backend feature that is currently invisible. The value is high, the cost is minimal, and every implementation pattern already exists in the codebase. The implementation is essentially: create `PinDriftBadge.tsx` (mirror `SpecHealthBadge.tsx`), add a drift indicator block to `CustomNode.tsx` (mirror the health indicator), add a `usePinsStore.ts` (mirror `useSpecStore.ts`), wire up `fetchPins()` in `api.ts`, and extend `Toast.tsx` with a `warning` type and action prop.

The one scope enhancement worth including: add an inline approve button in a Pins bottom panel tab rather than just linking to the CLI command. The API endpoint exists, the effort delta is small, and it eliminates the CLI-in-UI anti-pattern that would otherwise create friction for non-terminal users.

## References

- [Terraform Cloud Drift Detection](https://www.hashicorp.com/en/lp/drift-detection-for-terraform-cloud)
- [Pulumi Drift Detection](https://www.pulumi.com/blog/drift-detection/)
- [ArgoCD Status Badge](https://argo-cd.readthedocs.io/en/stable/user-guide/status-badge/)
- [MCP Tool Versioning Feature Request](https://github.com/modelcontextprotocol/modelcontextprotocol/issues/1039)
- [Carbon Design System - Status Indicator Pattern](https://carbondesignsystem.com/patterns/status-indicator-pattern/)
- [PatternFly Alert Pattern](https://www.patternfly.org/components/alert/design-guidelines/)
- [SSH Host Key Change Warning (TOFU precedent)](https://kinsta.com/blog/warning-remote-host-identification-has-changed/)
