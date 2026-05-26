# Feature Implementation: MCP Autoscale UI (Wizard + Status Observability)

## Context

**Project**: gridctl — a Go-based orchestrator for MCP (Model Context Protocol) servers that run as LLM-accessible tool gateways. Repo at `/Users/william/code/gridctl`, branch `main`, GitHub remote `gridctl/gridctl`.

**Tech stack**:
- Backend: Go (MCP gateway, replica set, autoscaler controller). Relevant packages: `pkg/mcp`, `pkg/config`, `internal/api`.
- Frontend: React 19 + TypeScript + Vite + Tailwind (v4) + Zustand in `web/`. Hand-rolled component library (no shadcn/MUI). Manual `fetch`-based API client in `web/src/lib/api.ts`. Hand-maintained TypeScript types in `web/src/types/index.ts` (NO code generation from Go).
- Testing: Vitest + React Testing Library. Test files live in `web/src/__tests__/`.
- Graph visualization: `@xyflow/react` v12 for the canvas; nodes are registered in `web/src/components/graph/nodeTypes.ts`.

**State model**:
- `useStackStore` (Zustand) holds `MCPServerStatus[]`, React Flow nodes, and `selectedNodeId`. Populated by `usePolling` every 3 seconds via `fetchStatus()` hitting `/api/status`.
- `useWizardStore` drives the creation wizard with sessionStorage persistence.

**Design tokens** (Tailwind, dark-mode only, "Obsidian Observatory" palette):
- Primary: amber `#f59e0b`.
- Secondary: teal `#0d9488`.
- Tertiary/server: violet `#8b5cf6`.
- Status: running=green, error=rose, pending=yellow, stopped=gray.
- Typography: Outfit (sans), IBM Plex Mono (mono).

## Evaluation Context

Key findings from the feature evaluation (full document: `prompts/gridctl/mcp-autoscale-ui/feature-evaluation.md`):

- **Market insight**: Cloud Run's segmented "Auto vs Manual" scaling toggle is the winning mutual-exclusivity pattern — adopted over DigitalOcean's progressive-disclosure button and ECS's split-screen approach (both confuse users).
- **Vocabulary choices**: Relabel `target_in_flight` → "Target concurrent requests per replica" (Cloud Run's phrasing) in the UI while keeping the YAML key unchanged. Phrase dwell times as sentences, not bare seconds.
- **UX decision (status view)**: Unanimous graph-UI convention (Step Functions, LangGraph, n8n, Temporal) keeps nodes glanceable and puts numbers in a side panel. gridctl already has a left `Sidebar` that renders per-server state — extend it rather than introducing a new right drawer.
- **Sparkline format**: Grafana HPA mixins (dashboards 22128/22251/22595) converge on current + target overlaid with min/max bands. Adopt this exact visual vocabulary; it's what operators expect.
- **Explainability pattern**: Structured event log with reason codes (ECS/GKE style) with a "below target for 2m12s" dwell phrase. No literal countdown timers — they lose user trust when they reset.
- **Defaults are table-stakes**: pre-fill min=1, max=5, target=10, scale_up=30s, scale_down=5m so the form is valid on first view.
- **Risk mitigation**: Backend validation already surfaces at YAML paths like `mcp-servers[i].autoscale.min` — the existing `ReviewStep` error renderer consumes these without modification. Do not duplicate validation on the client; use it only for immediate feedback (clamping).
- **Competitive signal**: No MCP ecosystem tool ships this today. ToolHive is YAML/CRD-only. Shipping both slices makes gridctl first in the category.

## Feature Description

**What to build**: Add a UI in the gridctl web frontend that (A) lets users configure the reactive autoscaling capability added by PR #512 via the wizard, and (B) renders live autoscale state when an operator selects a server on the canvas.

**Problem solved**: PR #512 shipped a major backend capability (reactive autoscaling with bounded replica sets) that is currently invisible in the web UI. Users cannot author autoscale configs in the wizard, and the canvas silently shows `×1` for every autoscaled server regardless of the true replica count.

**Who benefits**: All web UI operators running MCP servers in container, local-process, or SSH transports. The feature is not applicable to `external` URL or `openapi` server types (backend rejects autoscale for those transports).

**Backend contract summary** (for reference; already shipped in PR #512):

- Config struct (`pkg/config/types.go:169-190`):
  - `min` (required, int ≥ 0; must be ≥ 1 unless `idle_to_zero` is true)
  - `max` (required, int ≥ 1, ≤ 32, ≥ min)
  - `target_in_flight` (required, int ≥ 1)
  - `scale_up_after` (optional string, default `30s`, min `10s`)
  - `scale_down_after` (optional string, default `5m`, min `1m`)
  - `warm_pool` (optional int ≥ 0, default 0; `min + warm_pool ≤ max`)
  - `idle_to_zero` (optional bool, default false)
  - Mutually exclusive with static `replicas` on the same server.
- Live status struct (`pkg/mcp/autoscaler.go:702-717`):
  - `min`, `max`, `current`, `target`, `targetInFlight`, `medianInFlight`
  - `lastScaleUpAt`, `lastScaleDownAt` (optional RFC3339 timestamps)
  - `lastDecision` ∈ `{"up", "down", "noop"}`
  - `warmPool`, `idleToZero` (omitted when unset)
- API (`internal/api/api.go:428-429`): `/api/mcp-servers` and `/api/status` already return `autoscale?: AutoscaleStatus` on each `MCPServerStatus`.

## Requirements

### Functional Requirements — Slice A (Wizard)

1. **Type additions** (`web/src/lib/yaml-builder.ts`):
   - Add `autoscale?: AutoscaleFormData` to `MCPServerFormData`.
   - `AutoscaleFormData` fields: `min`, `max`, `targetInFlight` (required numbers), `scaleUpAfter?: string`, `scaleDownAfter?: string`, `warmPool?: number`, `idleToZero?: boolean`.
2. **YAML serialization** in `buildMCPServer()`:
   - When `data.autoscale` is present, emit an `autoscale:` block at the same indent level as `replicas:`, with YAML keys matching the backend (`target_in_flight`, `scale_up_after`, `scale_down_after`, `warm_pool`, `idle_to_zero`).
   - Mirror Go `omitempty` semantics: omit `scale_up_after`/`scale_down_after` when unset, `warm_pool` when 0, `idle_to_zero` when false.
   - Never emit both `replicas:` and `autoscale:` in the same server entry — this is the backend's mutual-exclusivity rule.
3. **YAML parsing** in `parseYAMLToForm()`:
   - Recognize an `autoscale:` block and populate `autoscale` on the returned form data; leave `replicas` undefined in that case.
   - Keep the current best-effort line-based parser; no full YAML library addition.
4. **Visibility flag** in `MCPServerForm.tsx`:
   - Extend `FieldVisibility` with `autoscale: boolean`, set `true` for server types `container | source | local | ssh`, `false` for `external | openapi`. Matches existing `replicas` gating.
5. **Segmented "Scaling" control** at the top of the existing Advanced section, replacing the standalone Replicas input when `visibility.autoscale` is true. (Single choice: Static replicas | Autoscale.)
   - "Static replicas" selection shows the existing Replicas + Replica Policy fields.
   - "Autoscale" selection shows the autoscale form fields.
   - Toggling between modes clears the opposite field group (`data.replicas`/`data.replicaPolicy` or `data.autoscale`) to guarantee the output YAML has at most one of the two blocks.
   - Default selection: "Static replicas" for new servers; load-driven for existing YAML (autoscale present → "Autoscale", replicas > 1 → "Static replicas", neither → "Static replicas").
   - When `visibility.autoscale` is false (external/openapi types), show only the Static replicas input; the segmented control is hidden (not disabled) because autoscale is irrelevant, not just unavailable. Note that `visibility.replicas` is also `false` for those types today, so the whole scaling block collapses.
6. **Autoscale form fields** (rendered when "Autoscale" is selected):
   - **Min replicas** (number, clamp 0–32). Default 1.
   - **Max replicas** (number, clamp 1–32). Default 5.
   - **Target concurrent requests per replica** (number, clamp 1–10000). Default 10. Help text: "gridctl adds replicas when the average in-flight request count exceeds this."
   - **Scale up after** (text input accepting Go-duration strings like `30s`, `1m`). Default `30s`. Inline help: "Wait this long while above target before spawning a replica (min 10s)."
   - **Scale down after** (text input). Default `5m`. Inline help: "Wait this long while below target before reaping a replica (min 1m)."
   - **Warm pool** (number, clamp 0–32). Default 0. Help: "Extra idle replicas kept above the load-derived target."
   - **Scale to zero when idle** (checkbox). Default unchecked. Help: "Allow reaping every replica after sustained idle. First request after idle may be slower."
7. **Live summary line** below the autoscale fields: `Autoscale <min>–<max> replicas · <target> concurrent/replica` (Cloud Run-style confirmation).
8. **Client-side clamping, not duplicate validation**: inputs clamp to known-valid ranges in real time; semantic errors (e.g., `min + warm_pool > max`) flow through the backend via `ReviewStep` at apply time using the existing dotted-path rendering.
9. **Tests** (`web/src/__tests__/MCPServerForm.test.tsx`, extend):
   - Default state renders Static replicas selected.
   - Toggling to Autoscale shows all six field inputs + summary line.
   - Toggling back to Static clears `data.autoscale`.
   - For `external` and `openapi` server types, the segmented control is not rendered.
   - YAML builder emits the correct `autoscale:` block when selected.
   - `parseYAMLToForm` round-trips a YAML with `autoscale:` → form → YAML and the result is byte-identical.

### Functional Requirements — Slice B (Status Observability)

10. **Type additions** (`web/src/types/index.ts`):
    - Add `AutoscaleStatus` interface with fields mirroring `pkg/mcp/autoscaler.go:702-717` exactly (`min`, `max`, `current`, `target`, `targetInFlight`, `medianInFlight`, `lastScaleUpAt?`, `lastScaleDownAt?`, `lastDecision`, `warmPool?`, `idleToZero?`). Use `string` for timestamps (RFC3339) and `number` for all numeric fields (`medianInFlight` is `int64` on the Go side but TypeScript `number` is safe for the in-flight request counts this tracks).
    - Add `autoscale?: AutoscaleStatus` to `MCPServerStatus`.
    - Add `autoscale?: AutoscaleStatus` to `MCPServerNodeData` so it flows to the canvas.
11. **Node data flow** (`web/src/lib/graph/nodes.ts`):
    - `createMCPServerNodes()` should copy `server.autoscale` (if present) onto the node data.
12. **Canvas node badge** (`web/src/components/graph/CustomNode.tsx`):
    - When `data.autoscale` is present: render `×<current>/<target>` (e.g., `×2/3`) in place of the existing `×<N>` badge.
    - When `data.autoscale` is absent but `replicaCount > 1`: keep today's `×N`.
    - When neither: render nothing (today's behavior).
    - Add a subtle ring indicator driven by `autoscale.lastDecision`:
      - `"noop"`: no extra styling.
      - `"up"`: amber pulse ring (reuse existing `pulse-glow` or `status-pulse` animation; amber is already the primary color).
      - `"down"`: a matching ring in a muted teal/blue tone (use `secondary` color class for consistency).
    - The ring should not mask existing selection highlighting; layer it with a subtle inner ring, not a border replacement.
13. **Sidebar Scaling section** (`web/src/components/layout/Sidebar.tsx`):
    - Render a new "Scaling" section in the selected-server view when `MCPServerStatus.autoscale` is present.
    - Layout (top-down):
      1. Headline row: `Current <current> / Target <target>  ·  Range <min>–<max>` (single line, existing Sidebar typography).
      2. Dwell phrase (present-tense, computed from current state):
         - If `lastDecision === "up"`: `Scaling up · median in-flight <medianInFlight>, target <targetInFlight>` (no duration — backend does not expose the partial-window timer).
         - If `lastDecision === "down"`: `Scaling down · median in-flight <medianInFlight> below target <targetInFlight>`.
         - If `lastDecision === "noop"` and `current === target`: `Stable · median in-flight <medianInFlight>, target <targetInFlight>`.
         - If `idleToZero` and `current === 0`: `Idle · scaled to zero`.
      3. Sparkline component (see below).
      4. Decision feed (collapsible, default closed): last 10 entries. Each row: `<HH:MM:SS> · <up|down|noop chip> · <summary>` where summary is `current→target` for up/down and `stable` for noop. Source data: derive client-side from transitions in `current`/`target`/`lastDecision` observed across polling cycles. Timestamp the client-side observation (Date.now()) — the backend does not emit per-decision events to the UI today, so the feed is derived, not ground-truth.
14. **AutoscalePanel component** (`web/src/components/status/AutoscalePanel.tsx`, new):
    - Accepts `{ status: AutoscaleStatus, history: AutoscaleSample[] }` as props.
    - Renders the headline, dwell phrase, sparkline, and decision feed from requirement 13.
    - Sparkline is inline SVG (no chart library dependency):
      - Width fills container; fixed height ~40px.
      - X axis: sample index; Y axis: 0–max (auto-scaled with headroom).
      - Lines: `current` (solid violet, 1.5px), `target` (dashed violet at 50% opacity).
      - Bands: min and max as faint horizontal guide lines (violet at 15% opacity).
      - Tooltip: on hover, show the sampled `current`/`target`/`medianInFlight` at that index. Minimum viable: bare <title> elements on each point; enhance later if desired.
15. **Ring buffer in store** (`web/src/stores/useStackStore.ts`):
    - Add `autoscaleHistory: Record<string, AutoscaleSample[]>` keyed by server name.
    - `AutoscaleSample = { t: number; current: number; target: number; medianInFlight: number }`.
    - On every poll that returns `autoscale` for a server, append a sample; cap the array at **120 entries** (6 minutes at 3-second polling).
    - Reset on page reload is acceptable — this is live observability, not history.
16. **Decision feed derivation**:
    - In `useStackStore`, add `autoscaleDecisions: Record<string, AutoscaleDecision[]>` keyed by server name.
    - On each poll, if `autoscale.lastScaleUpAt` or `autoscale.lastScaleDownAt` has changed since the previous sample for that server, prepend a `{ t, kind: 'up'|'down', from, to, reason }` entry. Cap at **10 entries**. `reason` is a templated string from the pre-/post-transition `current`/`target`/`medianInFlight` values.
    - This is derived client-side because the backend does not stream events to the UI.
17. **Tests** (`web/src/__tests__/`):
    - `AutoscalePanel.test.tsx`: renders headline, dwell phrase, sparkline with correct path data given a mock history, and decision feed rendering.
    - `CustomNode.test.tsx` extension: asserts `×current/target` badge when `autoscale` present; asserts `×N` fallback; asserts no badge when neither.
    - `useStackStore.test.ts` (or new): asserts ring buffer cap (121st sample evicts the 1st) and decision-feed appending on `lastScaleUpAt` change.

### Non-Functional Requirements

- **Accessibility**: segmented control uses radio-group semantics (arrow-key nav within, Tab out). Duration inputs announce format errors via `aria-describedby` on `FieldError` (existing pattern). Decision feed does not use `aria-live` by default — would spam screen readers during a scale storm.
- **Performance**: sparkline re-renders only when history for the selected server changes; memoize the SVG path. Ring buffer push is O(1) plus a shift at cap.
- **No new external dependencies**. Sparkline is inline SVG. No chart library.
- **Tailwind-only styling**. No stylesheet additions.
- **Dark mode only** (current app state — no light-mode work).
- **Browser compatibility**: matches current frontend baseline (modern evergreen browsers).

### Out of Scope

- Histogram or heatmap of in-flight distribution (only the median is exposed).
- Cost estimation for autoscaled servers.
- Warm-pool billable-vs-idle stacked sparkline (Cloud Run pattern) — deferred until warm_pool usage signals warrant it.
- Editing autoscale config on deployed servers directly from the topology (there's no edit flow for servers today; this would be a new feature).
- Per-replica health drill-down in the Scaling section (belongs to a future "Replicas" detail view, not this feature).
- Any backend changes. Everything backend-side was delivered by PR #512.
- Code generation for TypeScript types from Go structs (codebase deliberately hand-maintains types).

## Architecture Guidance

### Recommended Approach

- **Mirror PR #480's playbook exactly** for Slice A. That PR added the static replicas UI using the same Section pattern, FieldVisibility flag, YAML-builder extension, and tests. Reading its diff is the shortest path to shipping a consistent Slice A.
- **Extend existing Sidebar** for Slice B — do not introduce a new right-side drawer. The Sidebar already renders per-server details when `selectedNodeId` is set; adding a Scaling section preserves the single-panel mental model operators have today.
- **Derive the decision feed client-side**. The backend exposes state snapshots (`lastDecision`, `lastScaleUpAt`, `lastScaleDownAt`) but does not stream per-decision events. Diffing consecutive poll snapshots for changes in these fields is the only viable UI-side approach. This is intentional — a later backend change could add a server-side event stream and this UI would migrate forward.
- **Keep types hand-maintained**. The codebase deliberately does not codegen from Go. Add `AutoscaleStatus` manually in `web/src/types/index.ts` following the exact convention already used for `ReplicaStatus`.

### Key Files to Understand

Read these first, in this order:

1. **`pkg/mcp/autoscaler.go`** (especially lines 702–717) — the exact `AutoscaleStatus` Go struct. Treat it as the source of truth for the TypeScript type.
2. **`pkg/config/types.go`** (lines 160–190) — the `AutoscaleConfig` YAML struct, including `omitempty` semantics that the YAML builder must mirror.
3. **`pkg/config/validate.go`** (lines 426–492) — the full backend validation ruleset. Read this so client-side clamping uses the same bounds and does not diverge.
4. **`internal/api/api.go`** (lines 408–463) — how the API emits `autoscale` on `MCPServerStatus`. Confirms the wire shape.
5. **`web/src/lib/yaml-builder.ts`** — `MCPServerFormData` interface (lines 9–80), `buildMCPServer()` serialization (lines 154–282), `parseYAMLToForm()` parser (lines 414–474). Pay attention to how `replicas` is handled today (lines 272–279) — autoscale follows the same shape.
6. **`web/src/components/wizard/steps/MCPServerForm.tsx`** — `SERVER_TYPES`, `FieldVisibility`, `getFieldVisibility`, the `Section` accordion primitive (line 188), `FieldError` (line 238), and the existing Replicas input (lines 1411–1450) which is the anchor for where the new segmented control goes.
7. **`web/src/types/index.ts`** — `ReplicaStatus` (lines 21–34) and `MCPServerStatus` (lines 37–60) conventions to match.
8. **`web/src/components/graph/CustomNode.tsx`** — existing `×N` badge at lines 113–123 is what changes to `×current/target`.
9. **`web/src/components/layout/Sidebar.tsx`** — existing health/error rendering pattern; adopt the same typography and pill styles for the Scaling section.
10. **`web/src/stores/useStackStore.ts`** — selection state and polling-driven data updates. Ring buffer additions live here.
11. **`web/src/hooks/usePolling.ts`** — confirms 3-second polling cadence so the ring buffer size makes sense.
12. **`web/src/__tests__/MCPServerForm.test.tsx`** and **`web/src/__tests__/CustomNode.test.tsx`** — test patterns to extend.

### Integration Points

- **YAML builder**: extend `buildMCPServer()` to emit `autoscale:` block; extend `parseYAMLToForm()` to recognize it. Keep key order consistent (min → max → target_in_flight → scale_up_after → scale_down_after → warm_pool → idle_to_zero) so YAML round-trips are byte-stable.
- **FieldVisibility**: add one boolean flag, set it in `getFieldVisibility()` for all six server types.
- **API client / polling**: no changes. `fetchStatus()` already returns `autoscale` in the response post-PR-#512.
- **Store**: two additions — `autoscaleHistory` ring buffer, `autoscaleDecisions` derived feed. Both populated in the same reducer that processes poll responses.
- **Canvas node types**: registered in `web/src/components/graph/nodeTypes.ts` — no changes; the node renderer reads new fields off `MCPServerNodeData`.

### Reusable Components

Use these rather than building new primitives:

- `Section` accordion from `MCPServerForm.tsx:188` for the autoscale group inside Advanced.
- `FieldError` from `MCPServerForm.tsx:238` for inline validation errors.
- `inputClass`, `labelClass`, `errorClass` constants from `MCPServerForm.tsx:234-236`.
- `Badge`, `StatusDot` from `web/src/components/ui/`.
- `cn()` helper from `web/src/lib/cn.ts` for conditional classnames.
- Existing Tailwind animation utilities: `animate-fade-in-up`, `animate-pulse-glow`, `animate-status-pulse` (defined in `tailwind.config.js`).

## UX Specification

### Discovery

- **Wizard**: Users see the segmented "Scaling" control whenever they expand the Advanced section on a supported server type. No separate entry point, no feature flag, no "try this new thing" banner.
- **Status**: Users see the Scaling section in the Sidebar whenever they click an autoscaled server on the canvas. The canvas badge change (`×current/target` + colored ring) is the peripheral cue that draws attention.

### Activation

- **Wizard**: Users click "Autoscale" in the segmented control; defaults are populated so the form is immediately valid.
- **Status**: Selection (click or keyboard nav to a server node) activates the Scaling section automatically when `autoscale` is present on the server.

### Interaction

- **Wizard**:
  1. Expand Advanced.
  2. (Optional) click "Autoscale" in segmented control.
  3. Adjust any of min / max / target / dwells / warm pool / scale-to-zero.
  4. Live summary line updates as fields change.
  5. Continue to Review; backend validation errors show inline in ReviewStep if anything was off.
- **Status**:
  1. Click a server node on the canvas.
  2. Sidebar shows health + the new Scaling section.
  3. Watch current/target update in real-time via 3-second polling.
  4. Expand decision feed to see recent scaling history.

### Feedback

- **Wizard**: instant input clamping; live summary line; form-level error surfacing in ReviewStep.
- **Status**: live updates every 3 seconds; dwell phrase changes reactively; sparkline scrolls in new data; decision feed appends entries on scale events.

### Error states

- **Wizard**: invalid duration strings (e.g., `"5"` with no unit) → inline `FieldError` with help text "Use Go duration syntax (e.g., `30s`, `1m`, `5m`)". Invalid numbers → clamped silently (no error). Semantic errors (min+warm_pool > max, min ≥ 1 without idle_to_zero) → surfaced at ReviewStep via backend validation.
- **Status**: API poll failure → existing error banner (no change); if `autoscale` is absent on a server response (e.g., after a reload removed it), the Scaling section is not rendered.

## Implementation Notes

### Conventions to Follow

- **Signed commits**: every commit uses `-S`. This is enforced by the user's global CLAUDE.md.
- **No Co-authored-by trailers**. No mention of Claude in commits, PRs, or branch names.
- **Fork-and-pull workflow**: gridctl uses `/branch-fork` → work → `/pr-fork`. See the project memory at `~/.claude/projects/-Users-william-code-gridctl/memory/feedback_fork_workflow.md`.
- **Build flow**: use `make build` + `./gridctl`, not the brew-installed binary. Per project memory `feedback_build_workflow.md`.
- **Commit types**: `feat:` for new slice work, `test:` for test-only commits, `refactor:` for cleanups. Subjects ≤ 50 chars, imperative mood, no trailing period. Break the work into small commits (PR #512 has 25+ commits; the team prefers fine-grained history).
- **Testing**: `make test` (Go) and `cd web && npm test` (frontend). Both must pass before opening the PR.
- **Lint**: `make lint` runs golangci-lint; frontend is typechecked via `tsc --noEmit` inside `npm run build`.
- **Pre-release checks** (from `/release-gridctl`): lint, `go test -race`, `go build`, `npm run build` — run equivalents locally.
- **Changelog**: PR #512 added a changelog entry; this PR should add one under the appropriate unreleased section noting the new UI surfaces.

### Potential Pitfalls

1. **YAML round-trip byte-identity**: the current YAML builder preserves byte-identity for default values via the `omitempty` mirror (see lines 272–279 of `yaml-builder.ts` for how `replicas: 1` is omitted). Follow this exactly for autoscale — emit only non-default fields. Test round-tripping explicitly.
2. **parseYAMLToForm is line-based, not a full YAML parser**: when adding autoscale parsing, the existing simple key-value regex won't handle nested blocks. You will need to extend with minimal nested parsing (detect the `autoscale:` line, then continue consuming indented child lines until an outer-level key). Keep it minimal; do not introduce a YAML library. Tests must cover round-trip byte identity.
3. **Mutual exclusivity enforcement**: the segmented control must clear the opposite field group. If the user toggles Static → Autoscale → Static, `data.autoscale` must be undefined at the end, not an empty object, so the YAML builder omits it cleanly.
4. **FieldVisibility for external/openapi**: these types already have `replicas: false`. When `visibility.autoscale` is also false, render neither control and neither form — the "Advanced" section just has one fewer block. Do not show a disabled/grayed-out segmented control on those types.
5. **lastDecision churn**: the backend's `lastDecision` field snapshots what the controller *just* decided, not what it's *about to* do. Do not use it to show a countdown. Use it to color the ring and drive the dwell-phrase wording.
6. **Decision feed is derived, not authoritative**: two polling samples can miss a scale event (e.g., up-then-down within 3 seconds). Document this in a code comment — accuracy trades against backend simplicity, and accepting 3s resolution is fine for operator awareness.
7. **Sparkline Y-axis scaling**: auto-scale to `max(max, max(current), max(target)) * 1.1` for headroom. Don't fix at 0–32; it'll look flat for small scale ranges.
8. **Ring buffer memory**: 120 samples × 4 numbers × 8 bytes = ~4KB per server. At 50 autoscaled servers that's 200KB — negligible but worth noting.
9. **Existing replicas input preservation**: the current Replicas input (lines 1411–1450 of `MCPServerForm.tsx`) should still render when "Static replicas" is selected. Do not delete it — move it under the segmented control's "Static replicas" branch.
10. **Canvas ring color vs selection highlighting**: existing selection uses `shadow-[0_0_15px_rgba(139,92,246,0.3)]` and `ring-1 ring-violet-500/30`. Put the autoscale decision ring on a different layer (e.g., `ring-2` inset, or a second `ring-offset-*`) so it doesn't fight with selection state.

### Suggested Build Order

**Slice A (Wizard) — ship first, independently mergeable**:

1. Add `AutoscaleStatus` and `AutoscaleFormData` types in `web/src/types/index.ts` and `web/src/lib/yaml-builder.ts`.
2. Extend `buildMCPServer()` to emit autoscale YAML.
3. Extend `parseYAMLToForm()` to recognize autoscale blocks.
4. Extend `FieldVisibility` in `MCPServerForm.tsx`.
5. Add the segmented "Scaling" control and autoscale form fields under Advanced.
6. Wire up mutual-exclusivity clearing on toggle.
7. Add the live summary line.
8. Extend `MCPServerForm.test.tsx` with toggle + YAML round-trip tests.
9. Manual test: open wizard, author an autoscaled server, apply, verify backend accepts it.

**Slice B (Status) — ship as a follow-up PR**:

10. Add `autoscale?: AutoscaleStatus` on `MCPServerStatus` and `MCPServerNodeData` types.
11. Pass `autoscale` through `createMCPServerNodes()` in `lib/graph/nodes.ts`.
12. Update `CustomNode.tsx` badge to `×current/target` with decision ring.
13. Add ring buffer `autoscaleHistory` and derived `autoscaleDecisions` in `useStackStore`.
14. Build `AutoscalePanel` component (headline, dwell phrase, sparkline, decision feed).
15. Integrate `AutoscalePanel` into `Sidebar.tsx` under a Scaling section.
16. Add tests (`AutoscalePanel.test.tsx`, extend `CustomNode.test.tsx`, store tests).
17. Manual test: deploy an autoscaled server (use `examples/autoscale/autoscale-basic.yaml`), drive some load, watch the UI reflect it.

## Acceptance Criteria

### Slice A (Wizard)

1. In the wizard Advanced section for a container/source/local/ssh server, a segmented "Scaling" control with "Static replicas" and "Autoscale" choices is rendered.
2. For `external` and `openapi` server types, neither the Scaling segmented control nor any replica/autoscale input is rendered.
3. Selecting "Autoscale" renders six inputs (Min, Max, Target concurrent per replica, Scale up after, Scale down after, Warm pool) plus the Scale-to-zero checkbox, all pre-filled with the defaults specified in requirement 6.
4. Below the fields, a live summary line renders in the form `Autoscale 1–5 replicas · 10 concurrent/replica` and updates as fields change.
5. Selecting "Static replicas" after "Autoscale" clears any staged `autoscale` form data; the YAML preview in ReviewStep contains no `autoscale:` block.
6. Selecting "Autoscale" after "Static replicas" clears any staged `replicas`/`replicaPolicy`; the YAML preview contains no `replicas:`/`replica_policy:` keys.
7. Authoring an autoscale config and applying it results in the backend accepting the spec (no validation errors for a well-formed submission).
8. Authoring an invalid config (e.g., min=3 max=2) surfaces the backend error in ReviewStep at the path `mcp-servers[i].autoscale.max` with the exact message the backend emits.
9. `parseYAMLToForm` correctly recognizes a YAML with `autoscale:` and sets the form in "Autoscale" mode on load; a YAML with only `replicas:` sets it in "Static replicas" mode.
10. Round-trip byte-identity: a YAML with `autoscale:` loaded via `parseYAMLToForm` then re-serialized via `buildYAML` produces identical output (modulo whitespace-only differences the builder already normalizes).
11. New tests in `MCPServerForm.test.tsx` cover requirements 1, 3, 5, 6, 9, 10. All tests pass under `npm test`.
12. `npm run build`, `make build`, `make lint`, `make test` all succeed on the branch.

### Slice B (Status)

13. `AutoscaleStatus` interface exists in `web/src/types/index.ts` with all fields from the Go struct, using the exact same camelCase keys the backend emits.
14. `MCPServerStatus` and `MCPServerNodeData` both expose an `autoscale?: AutoscaleStatus` field.
15. On the canvas, an autoscaled server node renders `×<current>/<target>` where a static server renders `×N` (or nothing for N=1).
16. When `autoscale.lastDecision === "up"`, the node shows an amber pulse ring. When `"down"`, a teal/blue ring. When `"noop"`, no extra ring.
17. Selecting an autoscaled server on the canvas causes the Sidebar to render a "Scaling" section with: headline (`Current X / Target Y · Range min–max`), dwell phrase, sparkline, and collapsible decision feed.
18. The dwell phrase matches the decision and state per requirement 13.
19. The sparkline renders `current` (solid violet line), `target` (dashed violet line), with min/max as faint horizontal bands, using inline SVG with no external chart library.
20. Polling populates the ring buffer; at steady state the buffer holds up to 120 samples per server, with older samples evicted.
21. A scale event (either `lastScaleUpAt` or `lastScaleDownAt` changes) prepends an entry to the decision feed; the feed is capped at 10 entries per server.
22. Tests in `AutoscalePanel.test.tsx` assert correct rendering given a mocked history; extended tests in `CustomNode.test.tsx` assert the badge variations; a store test asserts the ring-buffer cap and decision-feed append.
23. `npm test`, `npm run build`, `make build`, `make lint`, `make test` all succeed on the branch.

## References

### Backend source of truth (in repo)
- `pkg/mcp/autoscaler.go:702-717` — `AutoscaleStatus` Go struct
- `pkg/config/types.go:160-190` — `AutoscaleConfig` YAML struct
- `pkg/config/validate.go:426-492` — full validation ruleset
- `internal/api/api.go:408-463` — API response shape
- `examples/autoscale/autoscale-basic.yaml` — reference config for manual testing
- `docs/scaling.md#autoscaling` — backend-facing autoscaling doc

### Frontend anchors (in repo)
- `web/src/lib/yaml-builder.ts` — form ↔ YAML serialization
- `web/src/components/wizard/steps/MCPServerForm.tsx` — wizard host
- `web/src/types/index.ts` — canonical type definitions
- `web/src/components/graph/CustomNode.tsx` — canvas node rendering
- `web/src/components/layout/Sidebar.tsx` — per-server detail rendering
- `web/src/stores/useStackStore.ts` — Zustand state + polling integration

### Precedent PRs
- [PR #512](https://github.com/gridctl/gridctl/pull/512) — backend autoscaling (the reason we're here)
- PR #480 — static replicas in the wizard; direct playbook for Slice A
- PR #511 — unified registry primitives and keyboard nav; reference for decision-feed list interactions if desired

### External references
- [Cloud Run instance autoscaling](https://cloud.google.com/run/docs/about-instance-autoscaling) — segmented control + summary line pattern
- [Grafana HPA dashboard 22251](https://grafana.com/grafana/dashboards/22251-kubernetes-autoscaling-horizontal-pod-autoscaler/) — current+target sparkline convention
- [AWS EC2 Auto Scaling activity history](https://docs.aws.amazon.com/autoscaling/ec2/userguide/as-verify-scaling-activity.html) — decision feed format
- [React Flow NodeStatusIndicator](https://reactflow.dev/ui/components/node-status-indicator) — canvas ring pattern
- Full market research: `prompts/gridctl/mcp-autoscale-ui/feature-evaluation.md`
