# Feature Evaluation: Opt-In Telemetry Persistence

**Date**: 2026-05-04
**Project**: gridctl
**Recommendation**: **Build**
**Value**: High
**Effort**: Large (3-5 weeks)

## Summary

Add opt-in disk persistence for user-facing telemetry — logs, metrics, and traces — emitted by MCP servers in a stack. Default off. Toggleable globally in the stack YAML and per-MCP-server, with matching UI controls (a header pill for global, a "Telemetry" section in the server detail sidebar for per-server). UI toggles rewrite the stack YAML. Wipe action available globally and per-resource. Recommended storage: NDJSON files conformant with the OpenTelemetry file-exporter spec, rotated by lumberjack, no embedded database.

The capture layer is ~70% built (slog buffer, OTel SDK + ring buffer, metrics accumulator with per-server breakdown, lumberjack already a project dep). The safe stack-YAML rewrite primitives also already exist as of PR #547 (`internal/api/stack_edit.go:atomicWrite`, per-path mutex, TOCTOU SHA-256 check, `yaml.Node` round-trip with comment preservation, full test coverage). The new telemetry endpoints reuse those primitives directly. The remaining work is at the boundary: schema, persistence layer, UI toggles, wipe endpoints, retention policy.

## The Idea

**The feature**: persistent telemetry for stacks managed by gridctl, opt-in by design.

**Today**: gridctl emits logs (in-memory ring buffer, 1000 entries), metrics (token usage accumulator with 7-day per-minute ring buffer), and traces (OpenTelemetry SDK with 24-hour in-memory buffer). All three are lost on daemon restart. There is one escape valve: optional OTLP export to an external collector for traces. Logs have a top-level file output (`logging.file`), but it is gateway-wide, not per-server.

**Proposed**: a `telemetry` block in the stack YAML, expressible at two levels:

```yaml
# Stack-global default
telemetry:
  persist:
    logs: true
    metrics: false
    traces: true
  retention:
    max_size_mb: 100
    max_backups: 5
    max_age_days: 7

mcp-servers:
  - name: github
    # Per-server override; nil values inherit from global
    telemetry:
      persist:
        traces: false   # explicitly off, even though global says on
```

Persisted data lives at `~/.gridctl/telemetry/<stack>/<server>/{logs,metrics,traces}.jsonl`, rotated by lumberjack. UI exposes the same controls — a global pill in the dashboard header and a per-server section in the sidebar that opens when a user clicks an MCP server box. UI toggles rewrite the stack YAML. A wipe action is available globally (top bar) and per-resource (sidebar).

**Problem solved**: today, when an MCP server fails or behaves oddly, the user has no record of what it did. Restart the daemon and the trail is gone. This affects two user segments: indie developers debugging Claude Code / Cursor / VS Code MCP integrations, and enterprise teams who need audit trails for SOC2/GDPR/HIPAA. Both segments are documented (citations in Market Analysis below).

**Who benefits**: every gridctl user who runs MCP servers. Capture is universal; persistence is the user-controllable knob.

## Project Context

### Current State

gridctl is an MCP gateway control plane in active beta (v0.1.0-beta.7). A long-running daemon parses a stack YAML file and orchestrates MCP servers (Docker containers, local processes, SSH-tunneled remote processes, OpenAPI-shimmed APIs, external HTTP/SSE URLs). A React + TypeScript + Vite + Zustand frontend talks to the Go backend over REST and SSE. The frontend embeds in the binary via `//go:embed` and renders a butterfly graph of the gateway and its servers.

Persistence today is flat-file with no embedded database:
- `~/.gridctl/state/{stack}.json` — daemon PID/port/start time
- `~/.gridctl/vault/` — encrypted secrets (XChaCha20-Poly1305)
- `~/.gridctl/pins/{stack}.json` — TOFU schema pins per stack
- `~/.gridctl/stacks/` — saved stack YAML library
- `~/.gridctl/logs/{stack}.log` — optional gateway log file via lumberjack rotation

There is no SQLite, BoltDB, or other embedded engine. The recommended persistence layer for this feature must respect that precedent.

### Integration Surface

**Stack schema** (`pkg/config/types.go`): the `Stack` struct already has `Logging` and `gateway.Tracing` blocks, but no top-level `telemetry`. The `MCPServer` struct has no per-server telemetry fields. New nested types must be added at both levels. yaml.v3 ignores unknown keys, so adding fields is structurally safe and backward-compatible with existing stacks.

**Capture layer**:
- `pkg/logging/buffer.go` — in-memory `LogBuffer` (1000 entries, ring), `BufferHandler` (slog handler that fans out to buffer + inner). Per-server slicing is done at query time via the `component` attribute.
- `pkg/logging/file.go` — lumberjack-backed slog handler with `MultiHandler` for fan-out. Already wired for gateway-wide log file.
- `pkg/tracing/buffer.go` — `Buffer` is an OTel `SpanExporter` with a 1000-trace ring and 24h retention. Already filters by `server.name` attribute, so per-server scoping is supported in-memory at the query layer.
- `pkg/tracing/provider.go` — wires the OTel TracerProvider with the in-memory buffer and an optional OTLP exporter.
- `pkg/metrics/accumulator.go` — atomic counters + per-server ring buffers (1-minute buckets, 10000-slot ring ≈ 7 days). `Snapshot()` returns a JSON-serializable shape.

**Frontend**:
- `web/src/components/layout/Header.tsx` — top bar with status pills (connection, stack name, server count). New global "Persistence" pill goes here.
- `web/src/components/layout/Sidebar.tsx` — opens when user clicks an MCP server node. Already has collapsible Status/Token Usage/Scaling/Actions/Tools sections. New "Telemetry" section slots between Actions and Tools.
- `web/src/components/ui/ConfirmDialog.tsx` — already supports `variant="danger"`. Direct reuse for wipe.
- `web/src/components/log/LogsTab.tsx`, `metrics/MetricsTab.tsx`, `traces/TracesTab.tsx` — currently live-only. Will need silent seeding from persisted files on daemon startup when persistence is on.

**State and locking**: stack-YAML rewrites are already serialized by per-path `sync.Mutex` (`internal/api/stack_edit.go:stackFileLock`) with TOCTOU detection via SHA-256 hash and atomic `os.Rename` writes. `pkg/state/state.go` exposes `WithLock(name, timeout, fn)` (flock-based) for daemon-lifecycle operations. New telemetry mutating endpoints reuse the existing per-path mutex + atomic-write pattern; wipe operations use `state.WithLock`.

### Reusable Components

| Component | Path | Reuse for |
|---|---|---|
| `LogBuffer` ring buffer | `pkg/logging/buffer.go` | template for any in-memory ring; already complete |
| `BufferHandler` slog fan-out | `pkg/logging/buffer.go` | adding a per-server file handler in parallel to the in-memory one |
| `NewFileHandler` + lumberjack | `pkg/logging/file.go` | per-server log file with rotation |
| `MultiHandler` slog fan-out | `pkg/logging/file.go` | combine in-memory + per-server file outputs |
| `tracing.Buffer` OTel SpanExporter | `pkg/tracing/buffer.go` | model for the new file SpanExporter |
| `metrics.Accumulator.Snapshot()` | `pkg/metrics/accumulator.go` | data shape for periodic NDJSON flushes |
| `atomicWrite` + `stackFileLock` + TOCTOU hash | `internal/api/stack_edit.go` | safe stack-YAML mutation for new telemetry endpoints (already battle-tested by `setServerTools` and `handleStackAppend`) |
| `patchAppendResource` `yaml.Node` patcher | `internal/api/stack_append.go` | reference for comment-preserving mutation of nested YAML structures |
| `state.WithLock` | `pkg/state/state.go` | flock for filesystem wipe operations |
| `ConfirmDialog` | `web/src/components/ui/ConfirmDialog.tsx` | wipe-data confirmation modal |
| Power/PowerOff toggle pattern | `web/src/components/registry/RegistrySidebar.tsx:547` | per-server toggle UI without building a new switch component |
| Toast system | `web/src/components/ui/Toast.tsx` | success/error feedback on toggle and wipe |

## Market Analysis

### Competitive Landscape

The MCP gateway space is bifurcated:

- **Heavyweight (IBM mcp-context-forge)** — default-on SQLAlchemy state DB (SQLite default, Postgres optional). Telemetry ships out via OTLP, not persisted locally. Has a dense backlog of compliance/audit feature requests open.
- **Lightweight (sparfenyuk/mcp-proxy, mcpo)** — pass-through, persist nothing.
- **Closest neighbor: lasso-security/mcp-gateway** — opt-in `xetrack` plugin writes per-server SQLite + filesystem logs via env vars (`XETRACK_LOGS_PATH`, `XETRACK_DB_PATH`). `server_name` is a column on every event. This is the precedent that most closely matches gridctl's proposed feature shape.
- **Closest non-MCP analog: LiteLLM proxy** — Postgres-based audit logs, retention config, "guaranteed logging" mode for compliance buyers. Treats persistent audit logs as table-stakes.

Container/process orchestrators set the user expectation:
- **Docker json-file driver**: NDJSON, one file per container, `max-size`/`max-file` rotation. Default-on.
- **Kubernetes**: `/var/log/pods/...`, per-container, `containerLogMaxSize: 10Mi`, `containerLogMaxFiles: 5`.
- **PM2**: `~/.pm2/logs`, per-process, `pm2 flush [app]` is the explicit wipe primitive.
- **systemd-journald**: `Storage={volatile,persistent,auto,none}`, `SystemMaxUse`, `MaxRetentionSec`. Per-unit retention config.

The convergent pattern: **NDJSON, one file per resource per signal, size+count rotation, explicit wipe verb, no confirmation prompt for view-only clears**.

### Market Positioning

- **Catch-up to table-stakes** for serious deployment. Anything below LiteLLM's audit-log bar will look immature next to the alternatives.
- **Differentiator** on the YAML-first per-server toggle ↔ UI sync. No MCP gateway in the survey exposes this as cleanly as the proposed shape. GitHub Actions' org-default + per-workflow override is the closest reference, and that's a CI tool — no MCP gateway has imported the pattern.

### Ecosystem Support

- **OTel file-exporter spec** is **stable**: JSONL/NDJSON encoding of OTLP-JSON. The opentelemetry-go SDK does not ship a file exporter — but writing OTLP-JSON lines from a custom `SpanExporter` is ~50 LOC using `go.opentelemetry.io/proto/otlp` + `protojson`. The collector-contrib `otlpjsonfilereceiver` (alpha) can replay these files into a real backend, so persisted gridctl data is ecosystem-portable from day one.
- **lumberjack** (`gopkg.in/natefinch/lumberjack.v2`) is already a project dep — the rotation primitive is sitting there.
- **No SQLite needed.** Adopting one would break gridctl's flat-file precedent for one feature.

### Demand Signals

Real, recurring, concentrated in two segments:

**Indie developer debugging**:
- [Claude Code #29035](https://github.com/anthropics/claude-code/issues/29035) — "Add per-MCP-server log files" — closed "not planned", leaving the gap to fill. Direct quote: *"stderr from STDIO-based servers is not captured anywhere persistent."*
- [Cursor MCP Logging Issue thread](https://forum.cursor.com/t/mcp-logging-issue/57577) — *"the logging does not come through"*, *"hard to debug anything without it"*.
- [MCP spec discussion #269](https://github.com/modelcontextprotocol/modelcontextprotocol/discussions/269) — proposes OTel tracing because *"errors might lack sufficient context about where within the server's internal logic the failure occurred"*.
- An ecosystem of MCP-Analyzer-style "MCP-as-debugger" tools has emerged to fill the gap.

**Enterprise audit/compliance**:
- IBM ContextForge issues [#535](https://github.com/IBM/mcp-context-forge/issues/535) (audit logging, SOC2/GDPR/HIPAA), [#2294](https://github.com/IBM/mcp-context-forge/issues/2294) (audit log viewer + signed exports), [#1223](https://github.com/IBM/mcp-context-forge/issues/1223) (forensic resource access trail).
- Rafter blog: *"MCP Audit Logging: Optional, Inconsistent, and a Compliance Liability."*

What's notably absent: no grass-roots Reddit demand for "replay" or "post-mortem" — users don't reach for those words. They say *"where did my logs go"*, *"I can't tell what happened"*, *"audit trail"*, *"compliance"*. UX copy should match those terms.

## User Experience

### Interaction Model

**Discovery**: feature lands silently in two places.
1. A new persistence pill appears in the dashboard header, between the stack-name pill and the server-count pill. Default state: gray, label "Persistence: Off."
2. Clicking any MCP server node opens the existing sidebar; a new "Telemetry" section is visible between Actions and Tools.

No onboarding tour, no settings page, no "what's new" banner. This is consistent with how every other gridctl feature has shipped.

**Activation**:
- **Global**: click the header pill → popover opens with three switches (Logs / Metrics / Traces) and a "Wipe all persisted data" destructive button. Toggling a switch fires `PATCH /api/stack/telemetry`, which rewrites the stack YAML and shows a success toast. The pill turns colored when any signal is on.
- **Per-server**: open the sidebar for the server. The Telemetry section shows three rows, each with a tri-state control: inherit (gray, label "From: global"), explicit on (filled), explicit off (outlined, struck through). A "Reset to global" button appears whenever the server has any explicit override. Storage path is shown beneath the section header: `~/.gridctl/telemetry/<stack>/<server>/`.

**Wipe**:
- Per-server: a "Wipe data" button at the bottom of the Telemetry section. Click → `ConfirmDialog` with `variant="danger"`. Modal enumerates what will be deleted, with size and date range — e.g., *"Delete 142 MB of logs from `github`, 2026-04-20 to 2026-05-04?"*
- Global: from the header popover. Same modal pattern, lists every server with persisted data and total size.

**Visible state on the graph**: each MCP server node gets a small dot indicator. Gray = persistence off (or fully inherited and global is off). Filled = persistence on with data on disk. Outlined = persistence on but no data captured yet. This distinguishes the most common confusion vector — "off + empty" vs "on + waiting for events."

**Replay on startup**: when a user has persistence enabled and restarts the daemon, the Logs/Metrics/Traces tabs silently seed their in-memory buffers from disk before live data starts arriving. No "load historical" button, no progress indicator beyond the existing tab loading state.

### Workflow Impact

**Adds friction**: zero, for users who don't enable persistence — the feature is invisible by default.

**Reduces friction**: substantial, for users who currently lose context on daemon restart or want to investigate failures from hours/days ago. Replaces the workaround of running an external OTel collector or re-running a flow to reproduce.

**No regressions** in existing workflows. The capture layer doesn't change; only an optional output is added.

### UX Recommendations (must-haves)

1. **Storage path next to the toggle.** Anti-pattern to avoid: Docker's `daemon.json` opacity. Users must know where the data lives.
2. **Tri-state inherit/on/off at the per-server layer** with a "Reset to global" button. Anti-pattern to avoid: JetBrains soft-wrap bug, where overrides cannot be cleared back to inherit.
3. **Wipe modal enumerates what's being deleted** (size + date range, per server). Anti-pattern: PM2's silent `flush`.
4. **Verb separation**: existing log-pane "Clear view" (transient) and the new "Wipe persisted data" (destructive) must never appear adjacent. Anti-pattern: Docker's clear-vs-delete proximity confusion ([for-win/#13292](https://github.com/docker/for-win/issues/13292)).
5. **Empty-state distinction** via the graph dot indicator. Anti-pattern: ambiguous identical UI for "persistence off + empty" vs "persistence on + no events yet."
6. **No confirmation for view-only clears** (existing behavior); confirmation **required** for wipe. Industry norm.

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|---|---|---|
| Problem significance | **Significant** | Two real demand segments verified with specific issues, forums, blog posts. Anthropic closed Claude Code #29035 as "not planned" — gap is gridctl's to fill. |
| User impact | **Broad+Deep** | Every gridctl user runs MCP servers; debugging-after-the-fact is universal; cost analysis matters for paid tools; compliance is the enterprise wedge. |
| Strategic alignment | **Core mission** | Observability is intrinsic to a control plane. YAML-first opt-in is gridctl's ethos. |
| Market positioning | **Catch up + differentiator** | Catch-up to LiteLLM/Lasso bar; differentiator on per-server YAML toggle ↔ UI sync. |

### Cost Breakdown

| Dimension | Rating | Notes |
|---|---|---|
| Integration complexity | **Moderate** | Capture layer ~70% built. Safe YAML rewrite primitives already exist (PR #547). Work is at the boundary: schema additions, persistence layer (NDJSON writer + custom SpanExporter), UI toggles, wipe endpoints, retention. |
| Effort estimate | **Large** | 3-5 weeks for one engineer including review and iteration. |
| Risk level | **Low–Medium** | The previously-flagged YAML-rewrite risk is closed (PR #547 added atomic temp+fsync+rename, per-path mutex, TOCTOU SHA-256 check, comment-preserving `yaml.Node` round-trip, with regression tests). Remaining risks: disk growth on wide enablement (mitigated by lumberjack defaults — ~600MB worst case per server), backward compat (mitigated by default-off + yaml.v3 ignoring unknown keys). |
| Maintenance burden | **Moderate** | Custom NDJSON SpanExporter, per-server log fan-out, metrics flusher. Conventional, no exotic deps. Compliance epics (signed exports, retention DSL, audit search) deferable to v0.2+. |

## Recommendation

**Build.**

Strategic alignment is high, problem significance is significant, and the foundation is in place. The market evidence — both the loud indie-dev complaints and the dense enterprise epic backlog at IBM ContextForge — confirms this is real demand, not a hypothetical itch. The earlier flag about an unsafe YAML rewrite path is now resolved: PR #547 (`fix: make stack append safe (lock+TOCTOU+atomic)`) added the atomic-write, per-path mutex, TOCTOU hash check, and `yaml.Node` round-trip primitives in `internal/api/stack_edit.go` and `internal/api/stack_append.go`, with regression tests. The new telemetry endpoints reuse those primitives directly.

Implementation principles:

1. **Reuse the existing safe-rewrite primitives.** Every telemetry mutation goes through the `stackFileLock(path)` mutex and `atomicWrite` (temp + fsync + rename + parent dir fsync). Mutate in-place via `yaml.Node` patches following the `patchAppendResource`/`patchServerTools` model so comments and key order survive. Detect external edits via SHA-256 hash of the original vs. a re-read just before write — return `errStackModified` (HTTP 409) on conflict.

2. **Default off in beta.** Stay opt-in. Industry-aligned (Jaeger ephemeral default, Lasso opt-in plugin, lumberjack-rotation conservative caps). Flip default at v0.2 stable if telemetry signals warrant — never before.

3. **Scope to NDJSON, no embedded DB.** OTel file-exporter spec is stable; writing OTLP-JSON is ~50 LOC. Aligns with gridctl's flat-file precedent. The compliance epics that require structured query (audit search, signed exports, FedRAMP reports) are deferred to v0.2+ — but the NDJSON foundation supports them.

4. **Document storage layout in user-facing copy.** Users must know data lives at `~/.gridctl/telemetry/<stack>/<server>/`. Show the path beneath the toggle. Document `gridctl telemetry wipe [<server>]` CLI alongside the UI button.

5. **Use the schema's `*bool` semantics for per-server overrides.** `nil` = inherit global; `&true` = explicit on; `&false` = explicit off. This is what enables the tri-state inherit/on/off UX without a sentinel string.

6. **Bake the UX guardrails in from day one.** Storage path next to toggle, tri-state with reset, wipe modal that enumerates, verb separation, dot indicator. These aren't polish — they're the difference between "useful feature" and "footgun."

## References

- [Claude Code issue #29035 — Add per-MCP-server log files](https://github.com/anthropics/claude-code/issues/29035)
- [Cursor MCP Logging Issue forum thread](https://forum.cursor.com/t/mcp-logging-issue/57577)
- [MCP spec discussion #269 — distributed tracing](https://github.com/modelcontextprotocol/modelcontextprotocol/discussions/269)
- [IBM mcp-context-forge #535 — audit logging](https://github.com/IBM/mcp-context-forge/issues/535)
- [IBM mcp-context-forge #2294 — audit viewer + compliance reports](https://github.com/IBM/mcp-context-forge/issues/2294)
- [IBM mcp-context-forge #1223 — resource access audit trail](https://github.com/IBM/mcp-context-forge/issues/1223)
- [Rafter — MCP Audit Logging is a Compliance Liability](https://rafter.so/blog/mcp-audit-logging-problems)
- [lasso-security/mcp-gateway xetrack plugin](https://github.com/lasso-security/mcp-gateway)
- [LiteLLM dynamic logging / guaranteed logging](https://docs.litellm.ai/docs/proxy/dynamic_logging)
- [LiteLLM db_info — spend logs and audit](https://docs.litellm.ai/docs/proxy/db_info)
- [OpenTelemetry OTLP File Exporter spec](https://opentelemetry.io/docs/specs/otel/protocol/file-exporter/)
- [OTLP-JSON File Receiver (collector-contrib)](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/receiver/otlpjsonfilereceiver/README.md)
- [opentelemetry-go stdouttrace — WithWriter pattern](https://pkg.go.dev/go.opentelemetry.io/otel/exporters/stdout/stdouttrace)
- [natefinch/lumberjack — log rotation](https://github.com/natefinch/lumberjack)
- [Docker json-file logging driver](https://docs.docker.com/engine/logging/drivers/json-file/)
- [Kubernetes container log rotation](https://kubernetes.io/docs/concepts/cluster-administration/logging/)
- [PM2 log management — pm2 flush](https://pm2.keymetrics.io/docs/usage/log-management/)
- [systemd-journald.conf](https://www.freedesktop.org/software/systemd/man/journald.conf.html)
- [GitHub Actions org-level retention](https://docs.github.com/en/organizations/managing-organization-settings/configuring-the-retention-period-for-github-actions-artifacts-and-logs-in-your-organization)
- [Docker for-win #13292 — clear-vs-delete proximity](https://github.com/docker/for-win/issues/13292)
- [SigNoz retention period](https://signoz.io/docs/userguide/retention-period/)
- [Grafana Tempo block retention](https://github.com/grafana/tempo/discussions/1487)
- [Jaeger Badger ephemeral default](https://www.jaegertracing.io/docs/1.62/deployment/)
