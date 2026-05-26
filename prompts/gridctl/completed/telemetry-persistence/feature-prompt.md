# Feature Implementation: Opt-In Telemetry Persistence

## Context

**gridctl** is an MCP (Model Context Protocol) gateway and control plane in active beta (v0.1.0-beta.7). It runs as a long-running Go daemon that orchestrates MCP servers defined in stack YAML files. The frontend is a React 19 + TypeScript + Vite + Zustand SPA embedded in the Go binary via `//go:embed` and rendered as a butterfly graph (gateway in the center, MCP servers as nodes around it). Communication is REST + SSE.

**Tech stack**:
- Backend: Go (Go 1.21+), `slog` for logging, `gopkg.in/yaml.v3` for config, `gopkg.in/natefinch/lumberjack.v2` for log rotation, full OpenTelemetry-Go SDK integration with custom in-memory ring buffers.
- Frontend: React 19, TypeScript, Vite, Zustand 5 with `subscribeWithSelector` middleware, Tailwind CSS, lucide-react icons, "Obsidian Observatory" dark theme. Existing components: collapsible Section, ConfirmDialog (with `variant="danger"`), Toast, Button, Power/PowerOff toggle pattern.
- Storage: flat files only — no SQLite, BoltDB, or other embedded DB. Convention: `~/.gridctl/{state,vault,pins,stacks,logs}/`.

**Repository**: `/Users/william/code/grid/gridctl` (single Git repo, trunk-based workflow, signed commits).

## Evaluation Context

This prompt was produced by a feature-scout evaluation that recommended **Build**. Key findings that shape the requirements below:

- **Two demand segments verified**: indie devs debugging MCP failures (closing Anthropic's [Claude Code #29035](https://github.com/anthropics/claude-code/issues/29035) gap) and enterprise audit/compliance (matching IBM ContextForge's [#535](https://github.com/IBM/mcp-context-forge/issues/535), [#2294](https://github.com/IBM/mcp-context-forge/issues/2294) backlog and LiteLLM's "guaranteed logging" bar).
- **Storage convergence on NDJSON**: Docker, kubelet, PM2, journald, and the **stable OpenTelemetry OTLP File Exporter spec** all use NDJSON, one file per resource per signal, with size+count rotation. Embedding SQLite would break gridctl's flat-file precedent for one feature; NDJSON keeps options open (DuckDB, ClickHouse, OTel collector replay) without lock-in.
- **Safe stack-YAML rewrite is already shipped**: PR #547 (`fix: make stack append safe (lock+TOCTOU+atomic)`) added the primitives in `internal/api/stack_edit.go` (atomic temp+fsync+rename, per-path `sync.Mutex`, SHA-256 TOCTOU re-read hash, `errStackModified` sentinel) and `internal/api/stack_append.go` (comment-preserving `yaml.Node` patcher), with regression tests covering comment/order preservation, on-disk conflict detection, atomic-on-failure, and concurrent caller serialization. **All new telemetry endpoints reuse these primitives — do not re-invent.**
- **UX guardrails are not polish, they're the feature**: tri-state inherit/on/off, storage path shown near toggle, wipe modal that enumerates what will be deleted, verb separation between transient "Clear view" and destructive "Wipe persisted data". Anti-patterns to avoid are documented in [evaluation §UX](./feature-evaluation.md#user-experience).
- **Default off in beta**. Don't flip until v0.2 stable.

Full evaluation: [`./feature-evaluation.md`](./feature-evaluation.md).

## Feature Description

Add opt-in disk persistence for the three telemetry signal types gridctl already captures: **logs, metrics, and traces**. Persistence is configurable in two layers — a stack-global default and per-MCP-server overrides — with matching UI toggles in the dashboard header (global) and the server detail sidebar (per-server). Toggling in the UI rewrites the stack YAML on disk. A wipe action is available globally (header popover) and per-resource (sidebar). Default off.

**Storage layout** (NDJSON, OpenTelemetry-conformant where applicable):

```
~/.gridctl/telemetry/<stack>/<server>/
  logs.jsonl      # NDJSON of pkg/logging.BufferedEntry
  metrics.jsonl   # NDJSON of metrics.Snapshot diffs (append on flush)
  traces.jsonl    # OTLP-JSON conformant (per OTel file-exporter spec)
```

Rotation via lumberjack (already a dep): MaxSize 100MB, MaxBackups 5, MaxAge 7d, Compress true. Each is overridable in the YAML.

## Requirements

### Functional Requirements

1. **Schema additions** to `pkg/config/types.go`:
   - Top-level `Stack.Telemetry *TelemetryConfig` block defining global persistence defaults and retention policy.
   - Per-server `MCPServer.Telemetry *MCPServerTelemetry` block with `*bool` fields for each signal so `nil` = inherit, `&true` = explicit on, `&false` = explicit off.
   - Schema example:
     ```yaml
     telemetry:
       persist: { logs: true, metrics: false, traces: true }
       retention: { max_size_mb: 100, max_backups: 5, max_age_days: 7 }
     mcp-servers:
       - name: github
         telemetry:
           persist: { traces: false }   # explicit override
     ```
   - `SetDefaults()` fills `MaxSizeMB=100`, `MaxBackups=5`, `MaxAgeDays=7` when retention block is unset.
   - Validation in `pkg/config/validate.go`: retention values must be positive; `max_size_mb >= 1`; warn if `max_size_mb * max_backups` exceeds 5GB per server.

2. **Resolver helpers** on `MCPServer` so callers don't reimplement inheritance:
   - `(s *MCPServer) PersistLogs(stack *Stack) bool`
   - `(s *MCPServer) PersistMetrics(stack *Stack) bool`
   - `(s *MCPServer) PersistTraces(stack *Stack) bool`
   Each returns `false` if both stack-global and per-server are nil/false.

3. **Storage layer** in a new package `pkg/telemetry/`:
   - `state.TelemetryDir() string` returns `~/.gridctl/telemetry/`.
   - `state.TelemetryServerPath(stackName, serverName, signal string) string` returns the path for a specific signal file.
   - `pkg/telemetry/logs.go` — slog handler that writes to a per-server lumberjack file when enabled. Wired alongside the existing `BufferHandler` via `MultiHandler` for that server's component.
   - `pkg/telemetry/metrics.go` — periodic flusher (default every 60s; configurable) that calls `accumulator.Snapshot()` and appends a diff line to `metrics.jsonl`. On daemon shutdown, flush once more.
   - `pkg/telemetry/traces.go` — custom `sdktrace.SpanExporter` writing OTLP-JSON lines using `go.opentelemetry.io/proto/otlp/trace/v1` + `protojson`. Registered alongside the in-memory `tracing.Buffer` and the optional OTLP exporter via OTel's `BatchSpanProcessor` chain.
   - `pkg/telemetry/inventory.go` — given a stack name and optional server name, walk the telemetry dir and return `{server, signal, path, sizeBytes, oldestTime, newestTime, fileCount}` records. Used by the wipe modal and the inventory API.
   - `pkg/telemetry/wipe.go` — `Wipe(stackName, serverName, signal string) error` deletes matching files (empty server/signal = wildcard). Holds `state.WithLock` while operating.

4. **Seeding from disk on startup** when persistence is on for a server+signal:
   - `LogBuffer.SeedFromFile(path string, n int)` — read up to last `n` NDJSON entries and prepend to the ring buffer.
   - `tracing.Buffer.SeedFromFile(path string, n int)` — same shape for traces.
   - Metrics: replay the latest snapshot only (don't replay history into the live ring; the snapshot is enough to display "where we left off" before live data resumes).
   - All three are called from `pkg/controller/gateway_builder.go` after the buffer is constructed but before the gateway starts serving.

5. **Reuse the existing safe-rewrite primitives** for every YAML mutation. Do not introduce a new `RewriteStackYAML` helper — the building blocks already exist:
   - `internal/api/stack_edit.go:stackFileLock(path)` — per-path `sync.Mutex` for serializing read-verify-write cycles.
   - `internal/api/stack_edit.go:atomicWrite(path, data)` — temp file in same dir + `fsync` + `Chmod` to preserve original mode + `os.Rename` + parent-dir `fsync`.
   - The TOCTOU pattern in `setServerTools` (read → SHA-256 hash → patch via `yaml.Node` → re-read → compare hash; `errStackModified` if changed).
   - `internal/api/stack_append.go:patchAppendResource` and `internal/api/stack_edit.go:patchServerTools` for `yaml.Node`-based comment-preserving mutation.
   
   Telemetry-specific patchers go in a new file `internal/api/stack_telemetry.go`:
   - `patchStackTelemetry(source []byte, persist *PersistDelta, retention *RetentionDelta) ([]byte, error)` — sets/updates/removes the top-level `telemetry` mapping.
   - `patchServerTelemetry(source []byte, serverName string, persist *PersistDelta) ([]byte, error)` — sets/updates/removes the per-server `telemetry` mapping. Removing the block entirely (clearing all overrides) deletes the key+value pair from the server mapping, matching the "tools whitelist" idiom of `replaceOrInsertTools`.
   - Both follow the same `findMappingValue`/`findOrCreateSequence` helper conventions used by neighbors.
   
   Mutating handlers wrap the patchers exactly like `setServerTools`: lock → read → hash → patch → re-read → compare → `atomicWrite`. Translate `errStackModified` to HTTP 409 in the handler.

6. **API endpoints**:
   - `PATCH /api/stack/telemetry` — body `{persist: {logs?, metrics?, traces?}, retention?: {...}}`. Updates the stack-global block. Calls `patchStackTelemetry` via the read-verify-write cycle.
   - `PATCH /api/mcp-servers/{name}/telemetry` — body `{persist: {logs?, metrics?, traces?}}`. `null` field value clears that signal's per-server override; absent field = no change; empty `persist: null` clears all overrides (removes the per-server `telemetry` key entirely).
   - `GET /api/telemetry/inventory` — returns the inventory shape from §3 across all servers in the stack. Drives the wipe modal.
   - `DELETE /api/telemetry?server={name}&signal={logs|metrics|traces}` — wipe; both query params optional (no params = global wipe). Holds `state.WithLock` for filesystem operations (no YAML mutation).
   - All four return JSON with success/error and a refreshed inventory snapshot.

7. **Frontend — Header global control** (`web/src/components/layout/Header.tsx`):
   - Add a "Persistence" pill between the stack-name pill and the server-count pill.
     - Gray when no signal is enabled globally.
     - Colored (use the existing emerald/amber semantic palette) when at least one signal is on.
     - Label: `Persistence: Off` or `Persistence: Logs+Traces` (truncate to 3 abbrevs).
   - Click → popover with three Power/PowerOff toggle buttons (use the existing pattern from `RegistrySidebar.tsx:547`) and a destructive "Wipe all persisted data" button.
   - Toggle action: `PATCH /api/stack/telemetry` → toast on success/failure.
   - Wipe action: open `ConfirmDialog` with `variant="danger"` showing the inventory enumeration ("Delete 142 MB across 3 servers...").

8. **Frontend — Per-server control** (`web/src/components/layout/Sidebar.tsx`):
   - Add a "Telemetry" collapsible Section between Actions and Tools.
   - Section header includes a small monospace label showing the storage path: `~/.gridctl/telemetry/<stack>/<server>/`.
   - Three rows: Logs, Metrics, Traces. Each is a tri-state control:
     - Inherit (gray, label "From: global (on)" or "From: global (off)"). Default state.
     - Explicit on (filled, emerald).
     - Explicit off (outlined, amber, struck-through label).
   - Click cycles inherit → on → off → inherit. Each transition fires `PATCH /api/mcp-servers/{name}/telemetry`.
   - "Reset to global" button appears when any of the three rows has an explicit override; it clears all overrides for that server.
   - "Wipe data" destructive button at the bottom of the section. Click → ConfirmDialog enumerating size + date range for that server only.

9. **Frontend — Graph indicator** (`web/src/components/graph/CustomNode.tsx`):
   - Small dot in the corner of each MCP server node (12px, positioned bottom-right).
   - Gray when no signal is persistently enabled for the server (computed = inherited or explicit, both off).
   - Filled when persistence is on AND the inventory shows files exist for that server.
   - Outlined when persistence is on but no files exist yet (silent-failure detection).
   - Tooltip on hover: "Logs: persistent · Metrics: off · Traces: persistent · 142 MB on disk."

10. **Tab seeding UX** (`web/src/components/log/LogsTab.tsx`, `metrics/MetricsTab.tsx`, `traces/TracesTab.tsx`):
    - On first mount with persistence enabled for the relevant signal, the tab shows historical data immediately (it's already in the buffer from server-side seeding). No "load historical" button. No banner. No progress indicator beyond the existing tab loading state.
    - One small change: when a tab knows its data was seeded from disk, show a subtle inline marker on the oldest entry: `── persisted from 2026-04-30 ──`. This separates pre-restart from post-restart visually.

11. **CLI parity** in `cmd/gridctl/`:
    - `gridctl telemetry status [<stack>]` — prints inventory.
    - `gridctl telemetry wipe [<stack>] [--server <name>] [--signal logs|metrics|traces]` — calls the same backend as the UI. Prompts for confirmation by default; `-y` skips.
    - `gridctl telemetry tail <stack> <server> --signal logs|metrics|traces` — `tail -f`-style follow on the relevant `.jsonl`.

### Non-Functional Requirements

- **Performance**: per-server log writes use an async lumberjack-backed handler (slog already buffers). Trace SpanExporter writes are batched via OTel's `BatchSpanProcessor` (already in the SDK). No blocking on disk IO from the request path.
- **Disk safety**: lumberjack defaults give ~600MB worst case per server (100MB × 5 backups + active file). Rotation is automatic. Validation warns if user configures > 5GB cap per server.
- **Atomicity**: YAML rewrites use temp file + `os.Rename`. Telemetry file writes use append-only semantics; no partial-write recovery needed because each line is self-contained NDJSON.
- **Concurrency**: `state.WithLock` (flock) wraps every YAML rewrite. Metrics flusher uses a single goroutine per stack.
- **Backward compatibility**: all new YAML fields are optional. Existing stacks without a `telemetry` block behave exactly as today (all signals ephemeral). yaml.v3 ignores unknown keys, so old daemons reading new files do not crash.
- **Security**: persisted files use mode 0600 (consistent with vault/state). Telemetry directory created with 0700. Logs may contain sensitive data — the existing redaction in `pkg/logging` already handles this; verify it applies to file-bound entries too.
- **Test coverage**: 
  - Unit tests for resolver helpers (inheritance logic), YAML round-trip with comments, atomic rewrite under simulated concurrent edit.
  - Integration test that spawns a stack, enables persistence per-server, restarts, and verifies seeded data appears in the API.
  - Frontend Vitest tests for the tri-state toggle, inventory rendering, wipe modal enumeration.

### Out of Scope

The following are deliberately deferred — do not implement as part of this feature:

- **SQLite/BoltDB or any embedded database.** NDJSON only.
- **Compaction, deduplication, or columnar formats** (Parquet, etc.).
- **Query DSL or search UI** over persisted telemetry. Users can `tail`/`jq`/`grep` the files; replay into a real backend is via `gridctl telemetry tail` piped to `vector` or `otelcol`.
- **Signed/tamper-evident exports, FedRAMP/SOC2 reports, JIT access auditing, audit log viewer with filters** — these are the IBM ContextForge "compliance track" features. Defer to v0.2+ once the foundation is in.
- **Dynamic retention DSL** (different retention per signal per server). One retention block per stack is enough at MVP.
- **Push to remote sinks** (S3, GCS) — out of scope. Users who need this run an OTel collector sidecar.
- **Persistence default-on**. Stays opt-in throughout the beta.
- **Web UI for the inventory beyond the wipe modal** (e.g., a dedicated "Persisted Data" tab). The header pill, sidebar section, and modal are sufficient.
- **Replay from disk into the OTLP exporter for forensic re-export.** Possible follow-up; not MVP.

## Architecture Guidance

### Recommended Approach

Build on existing patterns rather than introducing new abstractions:

- **Logs**: extend the existing `logging.BufferHandler` fan-out by adding a per-server slog handler that writes to a lumberjack-backed file. The existing `BufferHandler` already routes by `component` attr — register a per-server file handler when `PersistLogs(stack, server)` returns true.
- **Metrics**: the `metrics.Accumulator` already snapshots cleanly. Add a goroutine that calls `Snapshot()` every 60s, computes a diff against the previous snapshot, and appends one NDJSON line per server with non-zero deltas. On daemon shutdown, flush once.
- **Traces**: write a new `sdktrace.SpanExporter` that mirrors `tracing.Buffer` but writes OTLP-JSON to disk. Register it via `BatchSpanProcessor` alongside the in-memory buffer. The OTel SDK already supports multiple exporters in a chain.

The persistence layer never touches the request path. All writes are async (slog buffer, OTel batch processor, metrics goroutine). A failed write logs an error to stderr and continues — telemetry persistence must never fail an MCP call.

### Key Files to Understand

Read these in order before editing anything:

1. **`pkg/config/types.go`** — schema for Stack, MCPServer, GatewayConfig, LoggingConfig, TracingConfig. You'll add new types here; mimic the patterns used by `Autoscale` (nested optional struct) and `LoggingConfig` (file rotation with retention).
2. **`pkg/config/validate.go`** — validation patterns; add retention validation here.
3. **`pkg/state/state.go`** — directory conventions (`BaseDir()`, `LogDir()`, etc.) and `WithLock`. Add `TelemetryDir()` and `TelemetryServerPath()` helpers here.
4. **`pkg/logging/buffer.go`** — `LogBuffer` ring + `BufferHandler` slog fan-out. The pattern you'll mirror for per-server file handlers.
5. **`pkg/logging/file.go`** — `NewFileHandler` (lumberjack-backed) + `MultiHandler`. Reuse directly.
6. **`pkg/tracing/buffer.go`** — `Buffer` is an OTel `SpanExporter`; the new file exporter follows the same interface.
7. **`pkg/tracing/provider.go`** — TracerProvider wiring; you'll add the file exporter to the BatchSpanProcessor chain when persistence is enabled.
8. **`pkg/metrics/accumulator.go`** — `Snapshot()` shape; the metrics flusher serializes this.
9. **`pkg/controller/gateway_builder.go`** — where logging/tracing/metrics are wired into the runtime. New seeding-from-disk calls go here.
10. **`internal/api/stack_edit.go`** — the safe-rewrite primitives (`stackFileLock`, `atomicWrite`, `setServerTools`, TOCTOU re-read pattern, `errStackModified`). The model your new telemetry handlers must follow line-for-line.
11. **`internal/api/stack_append.go`** — `patchAppendResource`, `findOrCreateSequence` — the `yaml.Node` mutation idioms for nested structures.
12. **`internal/api/stack.go`** — handler-level wiring (`handleStackAppend`). Mirror this for the new telemetry handlers.
13. **`internal/api/api.go`** — handler registration; add the four new endpoints to the route table.
14. **`web/src/components/layout/Header.tsx`** — top bar; new persistence pill goes here.
15. **`web/src/components/layout/Sidebar.tsx`** — server detail panel; new Telemetry section.
16. **`web/src/components/registry/RegistrySidebar.tsx:547`** — Power/PowerOff toggle pattern reference.
17. **`web/src/components/ui/ConfirmDialog.tsx`** — reuse for wipe.
18. **`web/src/lib/api.ts`** — add `updateStackTelemetry`, `updateServerTelemetry`, `getTelemetryInventory`, `wipeTelemetry`.
19. **`docs/config-schema.md`** — append the new schema section.
20. **`examples/getting-started/mcp-basic.yaml`** — add a commented example showing the optional telemetry block (commented-out by default to keep ephemeral behavior).

### Integration Points

- **Schema → runtime**: `pkg/controller/gateway_builder.go` reads the resolved telemetry config per server and wires the appropriate handlers/exporters at gateway construction time. Hot reload (existing pattern in the same file) must rebuild handlers when toggles change without dropping in-flight requests.
- **API → YAML**: every `PATCH` reuses the per-path mutex + TOCTOU + `atomicWrite` pattern from `setServerTools`/`handleStackAppend`. The hot-reload watcher (already exists for stack file changes) re-runs the gateway builder, which reconciles the persistence layer.
- **Storage → UI**: `GET /api/telemetry/inventory` is the source for both the header pill state and the sidebar Section's per-server status. Poll it on the same interval as the existing status poll (3s).

### Reusable Components

Catalogued in evaluation §Reusable Components. Most relevant:
- `logging.BufferHandler`, `logging.NewFileHandler`, `logging.NewMultiHandler` — for log persistence.
- `tracing.Buffer.ExportSpans` — model for the new file SpanExporter.
- `metrics.Accumulator.Snapshot` — data shape for metrics flushes.
- `state.WithLock` — for the safe YAML rewrite.
- `web/src/components/ui/ConfirmDialog.tsx` (`variant="danger"`) — for wipe confirmation.
- Power/PowerOff toggle from `web/src/components/registry/RegistrySidebar.tsx` — for the per-server tri-state.

## UX Specification

### Discovery
- Header pill (gray "Persistence: Off") appears on every dashboard view by default.
- Sidebar's "Telemetry" section is visible whenever an MCP server is selected.
- No tour, no setting page, no "what's new" banner.

### Activation
- **Global**: header pill → popover → click any of three Power toggles → instant `PATCH` → toast.
- **Per-server**: sidebar → Telemetry section → click any of three tri-state controls (cycles inherit → on → off → inherit) → instant `PATCH` → toast.
- A "Reset to global" link appears whenever a server has explicit overrides; clicking removes the per-server `telemetry` block from YAML.

### Interaction
- Tri-state visual: inherit = gray with "From: global (on/off)" caption; on = filled emerald; off = outlined amber + strikethrough.
- Storage path shown in monospace beneath section header, e.g., `~/.gridctl/telemetry/my-stack/github/`.
- Graph node dot indicator: gray (off), filled (on with data), outlined (on, no data yet).

### Feedback
- Toast on every successful toggle: "Logs persistence enabled for `github`" or "Telemetry overrides cleared for `github`".
- Toast on every error with actionable copy: "Failed to update stack file — concurrent edit detected. Reload and retry." (when `RewriteStackYAML` returns `ErrConcurrentEdit`).
- Inventory poll updates the dot indicators within 3 seconds of any change.

### Error states
- Persistence enabled but storage path not writable → daemon logs a structured error and emits a toast on next UI poll: "Cannot write telemetry to `<path>`: permission denied. Disable persistence or fix permissions."
- File grew past max size + max backups while user wasn't looking → no UI surface needed; lumberjack handles silently.
- Wipe mid-write → flock prevents this; if it somehow happens, retry once.

## Implementation Notes

### Conventions to Follow

- Commit format: `<type>: <subject>` (e.g., `feat: add opt-in telemetry persistence`). Imperative mood, ≤50 chars, no period.
- Sign commits with `-S`. No Co-authored-by trailers. No mention of Claude in commits/PRs/branches.
- File mode 0600 for telemetry files; 0700 for the directory. Match vault/state conventions.
- `slog` for all logging in new packages — pass through the existing `BufferHandler` so logs about persistence operations themselves are visible in the UI.
- Errors: wrap with `fmt.Errorf("%w", err)` and lift actionable next steps into the message body. Match the patterns in `pkg/logging/file.go:30-34` (the existing "Tip:" suffix idiom).
- Frontend: use existing `useStackStore` for stack data; create `useTelemetryStore` (Zustand with `subscribeWithSelector`) for inventory + per-server state.
- Follow `web/AGENTS.md` for design system: glass panels, status colors (emerald/amber/red), Lucide icons.

### Potential Pitfalls

1. **YAML comment loss is silent.** Always patch via `*yaml.Node` and serialize with `yaml.NewEncoder(buf).SetIndent(2).Encode(&root)` — never `yaml.Marshal(stack)` — when rewriting the on-disk stack file. The `setServerTools`/`patchAppendResource` helpers already establish this contract; new telemetry patchers must follow it. Regression test: write a stack with comments, toggle a telemetry setting via API, diff the file. Comments and key order must survive. (See `TestHandleStackAppend_PreservesCommentsAndOrder` for the precedent.)
2. **Per-server override `nil` vs `false`.** The `*bool` semantics matter: `nil` means "no override, inherit", `&false` means "explicitly off, don't inherit". A common mistake is to default `*bool` fields to `&false` in `SetDefaults` — don't.
3. **OTLP-JSON spec strictness.** The file-exporter spec requires one `TracesData`/`MetricsData`/`LogsData` envelope per line, not raw spans. Use `protojson.Marshal` on the envelope, not on individual spans.
4. **Hot-reload race.** When a user toggles persistence, the gateway is mid-flight. The new handler must be installed before any subsequent log/span/metric is emitted, but the old in-memory buffer must continue serving until it is. Use the existing fsnotify-driven reload path; don't invent a new lifecycle.
5. **Lumberjack and active file deletion.** When wiping, you may delete the active `.jsonl` while lumberjack still has it open. On Linux this is fine (POSIX unlinks-on-close). On macOS dev environments this also works because lumberjack reopens on next write. Don't try to "stop and restart" the writer.
6. **Frontend tri-state hit target.** Cycling through three states by repeated click is fine for a toggle, but make sure each state has an obvious next-action affordance — don't leave users guessing what clicking does.
7. **Metrics diff edge cases.** First snapshot has nothing to diff against — write the full snapshot. Counter resets (replica restart): write the new snapshot fully, not as a negative diff. Document the reset semantics in the file header (a single `// reset` comment line is fine).
8. **File mode on first creation.** lumberjack creates files with the umask applied. Pass mode 0600 explicitly via lumberjack's `LocalTime: true` config (lumberjack v2 honors mode through file handle inheritance, but verify in tests).

### Suggested Build Order

1. **Phase 1 — Schema + resolvers** (~2 days). Add the `Telemetry`/`MCPServerTelemetry` types in `pkg/config/types.go`, `SetDefaults` updates, validation in `pkg/config/validate.go`, resolver helpers (`PersistLogs/Metrics/Traces`). Unit tests for inheritance.
2. **Phase 2 — Persistence backends** (~5-7 days). New `pkg/telemetry/{logs,metrics,traces}.go` writers. Wire into `pkg/controller/gateway_builder.go`. Seeding-from-disk paths on `LogBuffer` and `tracing.Buffer`. Integration test: enable persistence, restart, verify seeded data appears in tabs.
3. **Phase 3 — API endpoints** (~2-3 days). Four endpoints. New `internal/api/stack_telemetry.go` with `patchStackTelemetry` and `patchServerTelemetry` following the `stack_edit.go`/`stack_append.go` patterns line-for-line (lock → read → hash → patch → re-read → compare → atomicWrite). Inventory walker in `pkg/telemetry/inventory.go`. Wipe with `state.WithLock`.
4. **Phase 4 — Frontend** (~5-7 days). Header pill + popover. Sidebar Telemetry section + tri-state. Graph node dot. Wipe modal with enumeration. Inventory polling.
5. **Phase 5 — CLI parity** (~1-2 days). `gridctl telemetry status|wipe|tail`.
6. **Phase 6 — Docs + examples** (~1 day). `docs/config-schema.md`, example YAML, CHANGELOG entry.

Total: 3-5 weeks for one engineer, including review and iteration.

## Acceptance Criteria

1. A new stack with no `telemetry` block has identical behavior to today (all signals ephemeral, no files written, no UI changes visible until pill is clicked).
2. A stack with `telemetry.persist.logs: true` produces `~/.gridctl/telemetry/<stack>/<server>/logs.jsonl` for every MCP server, rotating per lumberjack defaults.
3. Per-server `telemetry.persist.logs: false` overrides global `true` and produces no file for that server.
4. Per-server `telemetry: nil` inherits global; this is the default for any server without an explicit block.
5. Toggling any control in the UI rewrites the stack YAML on disk such that:
   a. All comments and key order are preserved (verified by diff; mirrors `TestHandleStackAppend_PreservesCommentsAndOrder`).
   b. The write is atomic (no partial-write window observable by another reader; mirrors `TestHandleStackAppend_AtomicOnWriteFailure`).
   c. Concurrent external edits are detected and the API returns HTTP 409 with the existing `errStackModified` sentinel; the UI surfaces a clear toast instructing the user to reload (mirrors `TestHandleStackAppend_ConflictWhenDiskChanged`).
   d. Concurrent in-process callers are serialized via the existing per-path mutex (mirrors `TestHandleStackAppend_SerializesConcurrentCallers`).
6. The wipe modal displays the size and date range of data to be deleted before confirmation.
7. `gridctl telemetry tail <stack> <server> --signal logs` streams new lines as they're written.
8. `tail`-piping a `traces.jsonl` into the OTel collector's `otlpjsonfilereceiver` ingests cleanly (proves OTLP-JSON conformance).
9. Restarting the daemon with persistence on for a server seeds the Logs/Metrics/Traces tabs with pre-restart data on first load, with the visual "persisted from <date>" marker on the boundary.
10. The graph dot indicator visually distinguishes off (gray), on-with-data (filled), and on-without-data (outlined), and updates within 3s of a state change.
11. Default off in beta — confirmed by reading the parsed config: a stack file with no telemetry block resolves to all-ephemeral.
12. CHANGELOG updated with feature entry; `docs/config-schema.md` documents all new fields with type, default, description.
13. All existing integration and unit tests still pass. New tests: schema validation, resolver inheritance, atomic rewrite under contention, OTLP-JSON conformance round-trip via collector receiver, frontend tri-state cycling.

## References

- [Full evaluation document](./feature-evaluation.md)
- [OpenTelemetry OTLP File Exporter spec (stable)](https://opentelemetry.io/docs/specs/otel/protocol/file-exporter/)
- [OTLP-JSON File Receiver (collector-contrib, alpha)](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/receiver/otlpjsonfilereceiver/README.md)
- [opentelemetry-go SDK — stdouttrace](https://pkg.go.dev/go.opentelemetry.io/otel/exporters/stdout/stdouttrace)
- [google.golang.org/protobuf/encoding/protojson](https://pkg.go.dev/google.golang.org/protobuf/encoding/protojson) — for OTLP-JSON serialization
- [natefinch/lumberjack](https://github.com/natefinch/lumberjack)
- [yaml.v3 Node-based round-trip example](https://pkg.go.dev/gopkg.in/yaml.v3#Node)
- [Claude Code #29035 — context for the indie-dev demand segment](https://github.com/anthropics/claude-code/issues/29035)
- [IBM mcp-context-forge audit logging epics](https://github.com/IBM/mcp-context-forge/issues/2294)
- [LiteLLM dynamic logging — guaranteed-logging mode](https://docs.litellm.ai/docs/proxy/dynamic_logging)
- [GitHub Actions retention — UX reference for default+override](https://docs.github.com/en/organizations/managing-organization-settings/configuring-the-retention-period-for-github-actions-artifacts-and-logs-in-your-organization)
- [PM2 log management — `pm2 flush` reference](https://pm2.keymetrics.io/docs/usage/log-management/)
