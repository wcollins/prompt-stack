# Feature Evaluation: MCP Autoscale UI (Wizard + Status Observability)

**Date**: 2026-04-22
**Project**: gridctl
**Recommendation**: Build
**Value**: High
**Effort**: Medium (splits cleanly into two independently shippable slices)

## Summary

PR #512 shipped reactive autoscaling on the backend (`autoscale:` YAML block, live state via `/api/mcp-servers`, new CLI column) but the web UI has no parity — the canvas silently shows `×1` for every autoscaled server and the wizard can't author autoscale configs. This feature closes the gap with two slices: (A) a wizard "Scaling" toggle that lets users author autoscale configs with validated inputs, and (B) a sidebar status surface that renders live autoscale state (current/target, dwell phrase, sparkline, decision feed) when a node is selected. Both slices leverage proven patterns from PR #480 (static replicas UI) and Grafana/Cloud Run/ECS market conventions; risk and complexity are low.

## The Idea

Extend the gridctl web UI to expose the reactive autoscaling capability added in PR #512.

**Problem**: The web UI exists to make MCP orchestration legible without dropping to the CLI. A new backend capability (autoscale) is now invisible to web UI users — they can't configure it, and they can't see it operating. This contradicts the UI's mission.

**Who benefits**: Every web UI operator running MCP servers in the container, local-process, or SSH transports (autoscale is not valid for external URL or OpenAPI). Especially impactful for operators running replica-heavy workloads who currently have to shell into `gridctl status --replicas` to see what's happening.

## Project Context

### Current State

- **Frontend stack**: React 19 + TypeScript + Vite + Tailwind + Zustand, hand-rolled component library (no shadcn), manual `fetch`-based API client, hand-written TypeScript types in `web/src/types/index.ts`. No OpenAPI/go2ts code generation.
- **Wizard**: `web/src/components/wizard/steps/MCPServerForm.tsx` is a ~1,450-line single-page accordion form driven by `MCPServerFormData` from `web/src/lib/yaml-builder.ts`. Field visibility is gated by `getFieldVisibility(serverType)`. The current `replicas` input lives in the Advanced section (lines 1411–1450), gated with `visibility.replicas = true` for container/source/local/ssh and `false` for external/openapi — exact same gating autoscale needs.
- **Status rendering**: `web/src/components/graph/CustomNode.tsx` currently shows a minimal `×N` replica count badge (lines 113–123). The left `Sidebar` component already renders per-server state (health, errors) when `useStackStore.selectedNodeId` is set — no right-side drawer exists, and selection is already first-class.
- **Polling**: `useStackStore` refreshes `/api/status` every 3s via `usePolling`. The response already includes `autoscale` after PR #512 — no polling or endpoint changes required.
- **Validation**: Backend errors emit dotted YAML paths (e.g., `mcp-servers[0].autoscale.min`) that the existing `ReviewStep` error renderer consumes without modification.

### Integration Surface

Wizard slice (Slice A):
- `web/src/lib/yaml-builder.ts` — extend `MCPServerFormData`, add autoscale serialization/parsing.
- `web/src/components/wizard/steps/MCPServerForm.tsx` — extend `FieldVisibility`, add segmented control + autoscale section.
- `web/src/types/index.ts` — add `AutoscaleStatus` interface and `autoscale?` on `MCPServerStatus` and `MCPServerNodeData`.
- `web/src/__tests__/MCPServerForm.test.tsx` — add tests for toggle behavior, validation, YAML round-trip.

Status slice (Slice B):
- `web/src/components/layout/Sidebar.tsx` — add "Scaling" section rendering autoscale state.
- `web/src/components/graph/CustomNode.tsx` — change badge to `×current/target`, add status ring.
- `web/src/lib/graph/nodes.ts` — pass autoscale into `MCPServerNodeData`.
- `web/src/stores/useStackStore.ts` — add bounded ring buffer for sparkline history (per server name, cap 120 samples).
- New component: `web/src/components/status/AutoscalePanel.tsx` (sparkline + decision feed).
- `web/src/__tests__/AutoscalePanel.test.tsx` — render tests with mocked autoscale data.

### Reusable Components

- **Existing wizard primitives**: `Section` accordion (MCPServerForm.tsx:188), `FieldError` component, `inputClass`/`labelClass`/`errorClass` constants, `FieldVisibility` pattern.
- **Existing sidebar health rendering**: health pills + error strings in `Sidebar.tsx` — copy the Tailwind vocabulary for autoscale state.
- **Polling + store**: no extension beyond the ring-buffer addition; `usePolling` already delivers the data.
- **Validation pipeline**: `ReviewStep` error rendering already handles the YAML path format autoscale emits.

No new primitives needed. No new external dependencies needed (sparkline is inline SVG).

## Market Analysis

### Competitive Landscape

**Generic container platforms (config authoring)**:
- Cloud Run: segmented "Auto vs Manual" mode, Min/Max/Max-concurrent-per-instance, implicit scale-to-zero via min=0, clean "Auto (Min, Max)" summary.
- Render: master autoscaling toggle, Min/Max, Target CPU/Memory sub-toggles with documented interaction rule.
- AWS App Runner: versioned named scaling config — Max Concurrency + Min + Max; cleanest field set encountered.
- AWS ECS: raw seconds inputs for cooldowns (anti-pattern); separate screens for desired count vs autoscale config (anti-pattern).
- Azure Container Apps: Scale tab with sliders + named rules; portal hides advanced fields.
- DigitalOcean App Platform: progressive-disclosure "Set containers to autoscale" button; cost estimate updates live.

**Generic Kubernetes (observability)**:
- Grafana HPA mixins (dashboards 22128, 22251, 22595): converged on current+desired+min+max overlaid on a single sparkline plus utilization-vs-threshold chart.
- Lens / Aptakube: HPA detail pane with events, cross-links, throttled-state indicators.
- k9s: dense table; `61%/50%` utilization, `REPLICAS` column for current, no timeline.
- GKE: structured `scalingDecision` log entries in Cloud Logging (log-shaped, not dashboard-shaped — anti-pattern for in-UI consumption).

**Graph-based UIs (node-vs-drawer density)**:
- AWS Step Functions, LangGraph Studio, Temporal UI, n8n: unanimous convention — node = identity + one-glance status chip; detail pane (side drawer, hover card, or bottom panel) carries numbers, timeline, and reasons. React Flow's own `NodeStatusIndicator` formalizes this.

**MCP-specific ecosystem**:
- Stacklok ToolHive: closest analog; replicas on `VirtualMCPServer` CRD, delegates to K8s HPA, configured via YAML only — no typed form UI.
- Smithery, Composio, Pipedream MCP, OpenMCP: marketplace/proxy flavor; no replica-authoring surface.
- Ray Serve MCP deployment: `target_ongoing_requests` vocabulary (intellectual cousin of gridctl's `target_in_flight`) but Python-config only.

### Market Positioning

**Table-stakes** in generic container orchestration (every serious platform ships typed autoscale config + observability). **Open differentiator** in the MCP-specific niche — no other MCP gateway UI ships this today. Shipping both slices puts gridctl visibly first in its category and imports UX expectations operators already carry from Kubernetes/Cloud Run/ECS.

### Ecosystem Support

- No library needed. Inline SVG sparkline is ~40 lines; a ring buffer in Zustand is trivial.
- If a charting library is desired later, `recharts` or `visx` would fit — but out of scope for this build.

### Demand Signals

- Backend work was just merged (PR #512 is 4,400+ additions, 30 files). The team's investment signals this is a priority feature.
- PR #480 (static replicas in the wizard) established the pattern and shipped three weeks ago; autoscale is the obvious next beat.
- Category evidence: every container-orchestration tool of note has a UI for this. Users operating gridctl via the web UI will expect parity.

## User Experience

### Interaction Model

**Wizard (Slice A)**:
1. User opens the creation wizard, picks a server type (container/source/local/ssh).
2. User expands the "Advanced" Section.
3. A segmented **"Scaling"** control sits at the top of the section: `[ Static replicas ] [ Autoscale ]`. Autoscale is disabled with a tooltip when the server type is `external` or `openapi`.
4. Choosing "Static replicas" shows today's Replicas + Replica Policy inputs.
5. Choosing "Autoscale" swaps in: Min, Max, Target concurrent requests per replica, Scale-up dwell, Scale-down dwell, Warm pool, Scale-to-zero checkbox.
6. A live summary line below the fields reads: `Autoscale 1–5 replicas · 10 concurrent/replica`.
7. Invalid inputs surface inline via `FieldError`; backend validation shows in the `ReviewStep` at apply time.

**Status view (Slice B)**:
1. User clicks a server node on the canvas → `useStackStore.selectedNodeId` updates.
2. Left `Sidebar` shows the existing health/error pane and adds a **"Scaling"** section when the selected server has `autoscale` in its status.
3. Scaling section contents:
   - Headline: `Current 2 / Target 3 · Range 1–5`.
   - Dwell phrase: `Scaling up · median in-flight 7, target 5, sustained 18s` (present-tense, adapts to state).
   - Sparkline: 10-minute window overlaying current (solid violet) + target (dashed) + min/max bands.
   - Decision feed (collapsible, last 10): `14:32:05 · up 1→2 · median 7 > target 5 for 22s`.
4. On the canvas, the node badge changes from `×N` to `×current/target` when autoscale is present. A subtle ring color reflects `lastDecision`: no ring for `noop`, amber pulse for `up`, blue pulse for `down`.

### Workflow Impact

- **Zero friction for existing users**: "Static replicas" defaults preserve today's behavior byte-identically. YAML serialization already omits default values.
- **Autoscaled servers become legible**: operators stop needing to shell into the CLI to see current state.
- **Mutual exclusivity is UI-enforced** — toggling clears the opposite field group, so malformed configs never leave the browser.
- **Round-tripping expert mode**: `parseYAMLToForm` in `yaml-builder.ts` must recognize an `autoscale:` block and set the toggle to "Autoscale" on load.

### UX Recommendations

Adopted from market research:

- **Relabel** `target_in_flight` → **"Target concurrent requests per replica"** (Cloud Run phrasing) while keeping the YAML key unchanged.
- **Relabel** `scale_up_after`/`scale_down_after` → **"Scale up after"** / **"Scale down after"** with a help sentence: "Scale up after sustained load for __" and natural-unit strings (`30s`, `2m`).
- **Frame** `idle_to_zero` as a **"Scale to zero when idle"** checkbox with a tooltip on cold-start implications.
- **Smart defaults** on first render: min=1, max=5, target=10, scale_up=30s, scale_down=5m, warm_pool=0, idle_to_zero=false. Matches Cloud Run's "valid on first view" philosophy.
- **Live summary line** à la Cloud Run's "Auto (Min, Max)" — reassures users the form is correct before review.
- **Dwell phrase over countdown** in the status view. Users mistrust countdown timers that reset.
- **Keep the node minimal**. Resist the urge to put medianInFlight, min, max on the node chip — drawer/sidebar material.

### Anti-patterns to avoid

- Two tabs/screens for static vs autoscale (ECS confuses users).
- Bare seconds inputs with no units.
- Silent mutual exclusivity (fail at apply — forces users to re-open the wizard).
- Literal countdown timers ("scaling in 18s") — no major platform ships them.
- A bespoke "stabilization window progress bar" widget — Grafana/Datadog/Cast AI all skip it in favor of the current-vs-target overlay.
- Hiding the decision log behind a separate logs surface (GKE does this — operators dislike it).

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|---|---|---|
| Problem significance | Significant | New backend capability is invisible in the UI today; contradicts UI's mission. |
| User impact | Broad + Deep | Every web UI operator using container/local/ssh transports is affected. |
| Strategic alignment | Core mission | gridctl's UI exists precisely to make orchestration legible without CLI. |
| Market positioning | Leap ahead | No MCP gateway UI ships reactive-autoscale config + observability today. |

### Cost Breakdown

| Dimension | Rating | Notes |
|---|---|---|
| Integration complexity | Minimal | Pure additive — no refactoring. Patterns proven by PR #480. |
| Effort estimate | Medium | Slice A: small (~3 files). Slice B: medium (~5–6 files + sparkline + decision feed). |
| Risk level | Low | No destructive changes. Bad inputs → existing validation rail. Degrades cleanly if data missing. |
| Maintenance burden | Low | Bounded ring buffer, ephemeral decision feed, hand-maintained types consistent with rest of codebase. |

## Recommendation

**Build — bundled feature, shipped in two slices for incremental delivery:**

- **Slice A (Wizard config, MVP)**: segmented Scaling control + autoscale form + type definition + YAML round-trip + tests. Unblocks config authoring. ~3–5 days of focused work.
- **Slice B (Status observability)**: Sidebar Scaling section + `AutoscalePanel` component (sparkline + decision feed) + canvas badge + ring buffer in store + tests. Unblocks live observation. ~3–5 days of focused work.

Both slices carry independent user value; the feature stays coherent after Slice A alone, and Slice B is pure additive enhancement. Recommended build order: **A first, then B** — authoring has to precede observing.

No scope reductions recommended. Both slices are already minimal: market research confirms the patterns chosen are the simplest table-stakes versions, not ambitious ones. The only deferrable polish is the billable-vs-idle warm-pool visualization from Cloud Run; leave it for a future iteration if warm pool usage in the wild warrants it.

## References

**Config authoring**:
- [Cloud Run instance autoscaling](https://cloud.google.com/run/docs/about-instance-autoscaling)
- [Cloud Run manual scaling](https://cloud.google.com/run/docs/configuring/services/manual-scaling)
- [AWS App Runner autoscaling](https://docs.aws.amazon.com/apprunner/latest/dg/manage-autoscaling.html)
- [Render scaling docs](https://render.com/docs/scaling)
- [Azure Container Apps scale rules](https://learn.microsoft.com/en-us/azure/container-apps/scale-app)
- [DigitalOcean App Platform scaling](https://docs.digitalocean.com/products/app-platform/how-to/scale-app/)
- [Rancher HPA UI](https://ranchermanager.docs.rancher.com/how-to-guides/new-user-guides/kubernetes-resources-setup/horizontal-pod-autoscaler/manage-hpas-with-ui)
- [OpenShift HPA docs](https://docs.openshift.com/container-platform/4.18/nodes/pods/nodes-pods-autoscaling.html)
- [Knative scale bounds](https://knative.dev/docs/serving/autoscaling/scale-bounds/)
- [Anyscale scalable remote MCP](https://docs.anyscale.com/mcp/scalable-remote-mcp-deployment)
- [ToolHive scaling](https://docs.stacklok.com/toolhive/guides-vmcp/scaling-and-performance)

**Observability**:
- [Grafana HPA dashboard 22251](https://grafana.com/grafana/dashboards/22251-kubernetes-autoscaling-horizontal-pod-autoscaler/)
- [Grafana HPA dashboard 22128](https://grafana.com/grafana/dashboards/22128-horizontal-pod-autoscaler-hpa/)
- [Aptakube HPA detail](https://aptakube.com/blog/hpa-horizontalpodautoscaler)
- [AWS EC2 Auto Scaling activity history](https://docs.aws.amazon.com/autoscaling/ec2/userguide/as-verify-scaling-activity.html)
- [React Flow NodeStatusIndicator](https://reactflow.dev/ui/components/node-status-indicator)
- [LangGraph Studio](https://blog.langchain.com/langgraph-studio-the-first-agent-ide/)
- [AWS Step Functions execution details](https://docs.aws.amazon.com/step-functions/latest/dg/concepts-view-execution-details.html)

**Internal references**:
- PR #512: https://github.com/gridctl/gridctl/pull/512
- PR #480 (static replicas, precedent): canvas + wizard playbook
- PR #511 (registry primitives): keyboard-nav patterns to consider if adding a decision-feed list
