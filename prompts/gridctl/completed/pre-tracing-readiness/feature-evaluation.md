# Feature Evaluation: Pre-Tracing Readiness

**Date**: 2026-03-20
**Project**: gridctl
**Recommendation**: Build with caveats
**Value**: High
**Effort**: Medium (varies significantly per idea)

## Summary

The user proposed four categories of preparatory work before implementing distributed tracing: logging fundamentals, operational foundation, protocol readiness, and A2A stabilization. Research reveals the user's mental model is partially correct but misidentifies the actual critical path. The single most important finding is that MCP deprecated HTTP+SSE in March 2025 — gridctl's northbound transport is building on a deprecated spec. Log persistence is sound advice but not a tracing prerequisite. Drift detection is already fully implemented. The right sequence is: result size limits → Streamable HTTP migration → distributed tracing + OTLP logs together.

## The Idea

Four proposed prerequisites to distributed tracing:
1. **Log Persistence** — replace/supplement the in-memory ring buffer with lumberjack disk rotation; improve redaction coverage for large tool results; add remote log export (OTLP/Loki)
2. **Operational Foundation** — implement headless agents, stabilize drift detection
3. **Protocol Readiness** — harden SSE northbound session management before tracing spans those sessions
4. **A2A Stabilization** — stabilize agent-to-agent before tracing across agents

User's proposed sequence: log persistence → drift detection → distributed tracing.

## Project Context

### Current State

**Logging infrastructure (`pkg/logging/`):**
- `LogBuffer`: circular in-memory ring buffer, 1,000 entries max, no disk persistence
- `RedactingHandler`: comprehensive pattern and exact-value redaction (auth headers, bearer tokens, passwords, secrets, keys, credentials) with recursive scanning across strings, arrays, maps
- `BufferedEntry`: includes a `TraceID` field — already positioned for OTel correlation
- Critical gap: no size limits on large tool results; redaction is character-by-character with no truncation or sampling

**SSE/MCP session management:**
- `SessionManager`: cryptographically secure 16-byte session IDs, LRU eviction at 1,000 session cap, LastSeen-based cleanup
- `SSESession`: 30-second keepalive heartbeats, agent identity capture from headers/query params
- Gap: using the old HTTP+SSE transport (two endpoints: `/sse` for stream, `/sse/messages` for POST)
- **MCP deprecated HTTP+SSE in spec version `2025-03-26`.** Current spec (`2025-06-18`) uses Streamable HTTP with single `/mcp` endpoint, `Mcp-Session-Id` headers, `Last-Event-ID` resumability, and DNS rebinding protections.

**Drift detection (`pkg/config/plan.go`, `internal/api/stack.go`):**
- Fully implemented end-to-end. `ComputePlan()` diffs MCP servers, agents, resources, A2A agents, gateway config, networks.
- API: `GET /api/stack/health` returns `SpecHealth` with `DriftStatus` (in-sync / drifted / unknown)
- Limitation: poll-on-demand, not a continuous background watcher. README says "runs in the background" — this is aspirational, not current.
- **Verdict: NOT experimental. Fully working.**

**Headless agents:**
- Config layer complete: `Agent.Runtime`, `Agent.Prompt` fields, `IsHeadless()` helper, validation
- Runtime execution: zero implementation. Orchestrator handles only container-based agents.
- **Verdict: NOT implemented. Config exists, execution does not.**

**A2A implementation:**
- Handler (`pkg/a2a/handler.go`): 392 lines, 16 test cases, covers all routes, task lifecycle (submitted → working → completed/failed/cancelled/rejected), method routing
- Adapter (`pkg/adapter/a2a_client.go`): functional A2A→MCP bridge, async polling with timeout
- **A2A v1.0.0 released March 12, 2026** (22.7k GitHub stars, 2.3k forks, production stable)
- Verdict: Handler is production-ready. The "experimental" label is outdated relative to where the protocol now is.

**OpenTelemetry dependencies:**
- `go.opentelemetry.io/otel v1.39.0`, `otel/trace`, `otlp/otlptrace/otlptracehttp`, `otelhttp` already in `go.mod`
- Zero active use — no spans, tracers, or exporters initialized anywhere
- OTel log SDK (`go.opentelemetry.io/otel/sdk/log`) reached stable in early 2025

### Integration Surface

| Area | Files |
|---|---|
| Log rotation + size limits | `pkg/logging/buffer.go`, `pkg/logging/redact.go`, `pkg/format/` |
| Streamable HTTP migration | `pkg/mcp/session.go`, `pkg/mcp/sse.go`, `internal/api/api.go` |
| OTel initialization | New: `pkg/telemetry/provider.go` |
| OTLP log bridge | `pkg/logging/structured.go` (add OTel log handler) |
| A2A tracing | `pkg/a2a/handler.go`, `pkg/adapter/a2a_client.go` |

### Reusable Components

- `BufferedEntry.TraceID` — already structured for OTel correlation; wire it to actual OTel context
- `pkg/metrics/observer.go` — observer pattern is the right hook point for OTel span creation on tool calls
- `pkg/format/` — output format conversion is the right layer to add size limits and truncation
- OTel dependencies already in `go.mod` — can wire immediately without new dependency negotiation

## Market Analysis

### Competitive Landscape

**Log rotation in Go (2025-2026):**
- `gopkg.in/natefinch/lumberjack.v2` (v2.2.1, Feb 2023) is maintenance-mode but still the dominant rotating `io.Writer` for Go daemons. v3 is stranded in alpha.
- Standard pattern: zerolog or slog as the logging frontend, lumberjack v2 as the rotating `io.Writer` backend.
- Alternative for daemon mode: systemd/journald via stderr capture eliminates the need for log rotation entirely.

**OTLP logs vs Loki:**
- OTel log SDK reached stable in early 2025. For a tool already exporting OTel traces, OTLP log export to the same collector is the lowest-friction path and provides automatic trace-log correlation via `trace_id`/`span_id`.
- Loki is the right answer for log querying/visualization in a Grafana stack, but is a heavier dependency for a local developer tool. OTel Collector can fan-out to Loki later without changing instrumented code.

**MCP transport deprecation:**
- MCP spec `2025-03-26` deprecated HTTP+SSE. Spec `2025-06-18` (current) mandates Streamable HTTP.
- Failure modes of old HTTP+SSE: dual-endpoint coordination races, no `Last-Event-ID` resume, proxy/load balancer buffering issues, no backpressure.
- Go library: `github.com/mark3labs/mcp-go` implements Streamable HTTP (`2025-06-18`) with backward compatibility to `2024-11-05`. Active maintenance.

**A2A protocol:**
- v1.0.0 released March 12, 2026. Production stable. W3C trace context propagation (`traceparent`/`tracestate`) is the SDK-level standard for distributed tracing across A2A calls.
- Custom attributes: `a2a.task_id`, `a2a.context_id`, `a2a.streaming`.

**OTel GenAI semantic conventions:**
- All `gen_ai.*` attributes are `Development` stability (not stable). `gen_ai.tool.*` namespace is correct for MCP tool call tracing.
- No finalized MCP-specific OTel convention. `gen_ai.tool.name`, `gen_ai.tool.call.id`, `gen_ai.operation.name` are de facto standard.
- Pin semconv version; plan for migration when stabilized.

### Market Positioning

- Log rotation: table-stakes for any Go daemon
- OTLP log export: differentiator for a developer tool in 2026 — most CLI tools don't do this
- Streamable HTTP: **required for MCP spec compliance** — this is not optional
- A2A tracing: differentiator; cross-agent trace propagation is genuinely novel

### Demand Signals

- MCP spec deprecation of SSE is a clear demand signal from the protocol authors
- A2A v1.0.0 reaching stable with 22.7k stars signals ecosystem traction
- OTel GenAI SIG activity (AI agent observability blog post, 2025) signals growing demand for AI tool tracing

## User Experience

### Interaction Model

**Log persistence (`--log-file` flag or stack.yaml config):**
- Discovery: `gridctl --help`, documented in README
- Activation: `gridctl deploy --log-file /var/log/gridctl.log` or `logging.file` in stack.yaml
- Zero workflow disruption for existing users

**Result size limits (internal, no user-facing surface):**
- Transparent truncation with `[truncated: N bytes]` suffix in log/trace entries
- Config: `gateway.maxToolResultBytes` in stack.yaml (with a sensible default of 64KB)
- Prevents silent log/trace explosion

**Streamable HTTP migration:**
- Transparent to users — same endpoint, new protocol negotiation
- Risk: clients on old SSE transport need negotiation handshake. The MCP spec defines the backward-compatibility path: attempt POST `InitializeRequest`, fall back to GET on 4xx.
- Requires testing matrix with Claude Desktop, other MCP clients

**OTLP log + trace export (config-driven):**
- Discovery: new `[observability]` section in stack.yaml
- Activation: `otel.endpoint: http://localhost:4318` enables both traces and logs
- UX pattern: Temporal's approach — structured logs to file/stdout by default, OTel opt-in

**Headless agents (if built):**
- Requires `runtime: claude-code` and `prompt: |` fields in stack.yaml agent config
- Major new UX surface; documentation-heavy

### Workflow Impact

| Change | Friction | Benefit |
|---|---|---|
| Size limits | None (transparent) | Prevents trace/log explosion |
| Streamable HTTP | Low (behind the scenes) | Spec compliance, better client compat |
| Log file persistence | Low (opt-in flag) | Crash recovery, audit trails |
| OTLP export | Low (opt-in config) | Trace-log correlation, Jaeger integration |
| Headless agents | High (new paradigm) | Major vision feature |
| Drift continuous watcher | None (background) | Real-time drift push vs. poll |

### UX Recommendations

1. Group observability config under a single `[observability]` stack.yaml section: `log.file`, `log.maxResultBytes`, `otel.endpoint`, `otel.serviceName`
2. Provide a `gridctl trace` subcommand for trace management (enable, disable, export, status)
3. OTLP export should be a single config toggle that enables traces + logs together — don't make users configure them separately

## Feasibility

### Value Breakdown by Idea

| Idea | Problem Significance | User Impact | Strategic Alignment | Market Positioning |
|---|---|---|---|---|
| Log persistence (disk) | Minor | Narrow+Shallow | Adjacent | Catch up |
| Result size limits | Significant | Broad+Shallow | Core mission | Table-stakes |
| OTLP log export | Significant | Narrow+Deep | Core mission | Differentiator |
| Headless agents | Significant | Narrow+Deep | Core mission | Leap ahead |
| Drift: continuous watcher | Minor | Broad+Shallow | Adjacent | Catch up |
| **Streamable HTTP migration** | **Critical** | **Broad+Deep** | **Core mission** | **Catch up (required)** |
| A2A tracing | Significant | Narrow+Deep | Core mission | Differentiator |

### Cost Breakdown by Idea

| Idea | Integration Complexity | Effort | Risk | Maintenance Burden |
|---|---|---|---|---|
| Log persistence (disk) | Minimal | Small | Low | Minimal |
| Result size limits | Minimal | Small | Low | Minimal |
| OTLP log export | Minimal | Small | Low | Moderate |
| Headless agents | Architectural | Large | High | High |
| Drift: continuous watcher | Moderate | Medium | Low | Moderate |
| **Streamable HTTP migration** | **Significant** | **Medium** | **Medium** | **Moderate** |
| A2A tracing | Moderate | Medium | Low | Moderate |

## Recommendation

**Build with caveats** — but the sequence and framing needs adjustment.

### What the User Got Right

- Log persistence is a good idea. Adding `lumberjack v2` as an `io.Writer` backend is small, low-risk, and table-stakes for a daemon. Do it.
- Redaction maturity matters. The current gap around large tool results is a real risk — if unchecked, a single tool returning a 10MB JSON blob will explode both logs and traces.
- SSE robustness is a legitimate concern. The user diagnosed a real symptom (SSE instability) but underestimated the cure required (full Streamable HTTP migration).

### What the User Got Wrong

**Drift detection is already done.** It works end-to-end via `GET /api/stack/health`. It is poll-based rather than push-based, but it is not "experimental" in any meaningful sense. Building drift detection is not on the critical path.

**Log persistence is NOT a tracing prerequisite.** The ring buffer is fine for the tracing use case (in-memory, fast, with TraceID correlation). Disk persistence matters for crash recovery and audit trails — different use cases.

**The SSE concern is more urgent than framed.** The issue is not "harden SSE" — it is "MCP deprecated SSE entirely." The correct action is migration to Streamable HTTP, not incremental hardening of a deprecated transport.

**OTLP log export belongs inside the tracing feature.** Since OTel deps are already in `go.mod` and the OTel log SDK is stable, there is no reason to build log export separately. It is a 100-line addition once the OTel provider is initialized.

**A2A is stable at v1.0.0.** A2A tracing is not a prerequisite — it is a capability to add within the tracing feature.

### Revised Critical Path

```
1. Result size limits          [1 day, prerequisite for trace health]
   └── Add maxToolResultBytes truncation to pkg/format/ and pkg/logging/

2. Streamable HTTP migration   [1-2 weeks, spec compliance]
   └── Migrate pkg/mcp/sse.go to Streamable HTTP per spec 2025-06-18
   └── Add Mcp-Session-Id, Last-Event-ID, DELETE session termination
   └── Add backward-compatibility negotiation for legacy clients
   └── Use mark3labs/mcp-go as reference implementation

3. Distributed tracing + OTLP logs   [the actual feature]
   └── Wire OTel provider (deps already in go.mod)
   └── Create spans for MCP tool calls using gen_ai.tool.* attributes
   └── Propagate W3C trace context on A2A HTTP calls
   └── Bridge existing TraceID log field to OTel context
   └── OTLP log export as part of the same feature

4. Log file persistence         [independent, low priority]
   └── --log-file flag with lumberjack v2 rotation

5. Headless agents             [major standalone feature, later]

6. Drift: continuous watcher   [nice-to-have, later]
```

### On Alternatives

**Alternative to lumberjack**: For daemon mode (systemd), write to stderr and let journald handle rotation — no dependency needed. For standalone, lumberjack v2 is the right call despite maintenance-mode status. Do not wait for v3.

**Alternative to Loki**: Skip it for now. OTLP log export to the same collector as traces gives you log-trace correlation without a separate Grafana stack. Add Loki as a collector destination later if users ask.

**Alternative to building drift push**: Add a WebSocket endpoint to `GET /api/stack/events` that streams `DriftEvent` payloads. This is additive and does not require rebuilding the existing poll API.

## References

- [MCP Transports Specification (2025-06-18)](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports)
- [Why MCP Deprecated SSE and Went with Streamable HTTP](https://blog.fka.dev/blog/2025-06-06-why-mcp-deprecated-sse-and-go-with-streamable-http/)
- [mark3labs/mcp-go — Go MCP SDK with Streamable HTTP](https://github.com/mark3labs/mcp-go)
- [A2A v1.0.0 Release — a2aproject/A2A](https://github.com/a2aproject/A2A)
- [A2A Observability and Telemetry](https://deepwiki.com/google/a2a-python/8.3-observability-and-telemetry)
- [OTel Semantic Conventions for Generative AI](https://opentelemetry.io/docs/specs/semconv/gen-ai/)
- [OTel GenAI Client Spans](https://opentelemetry.io/docs/specs/semconv/gen-ai/gen-ai-spans/)
- [AI Agent Observability — OTel Blog 2025](https://opentelemetry.io/blog/2025/ai-agent-observability/)
- [lumberjack v2 — natefinch/lumberjack](https://github.com/natefinch/lumberjack)
- [OpenTelemetry vs Loki — SigNoz](https://signoz.io/comparisons/opentelemetry-vs-loki/)
- [Grafana Loki OTLP ingestion](https://grafana.com/docs/loki/latest/send-data/otel/)
