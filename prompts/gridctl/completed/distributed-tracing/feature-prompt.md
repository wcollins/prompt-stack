# Feature Implementation: Distributed Tracing with W3C Traceparent

## Context

gridctl is an MCP (Model Context Protocol) gateway and orchestrator written in Go with a React web UI. It aggregates multiple downstream MCP servers (Docker stdio, HTTP, SSH, local process, OpenAPI) into a single endpoint for LLM clients. The request flow is: SSE/HTTP Handler → Gateway → Router → downstream MCP Client.

**Tech stack**:
- Backend: Go 1.24+, `net/http` stdlib, `slog` structured logging
- Frontend: React 18, TypeScript, React Flow, Zustand, Vite, Tailwind CSS
- OTel deps already in `go.mod` (indirect): `go.opentelemetry.io/otel` v1.39.0, `otlptrace/otlptracehttp`, `otelhttp`
- Testing: Go stdlib + `uber/mock`

## Evaluation Context

- **MCP spec alignment**: PR #414 formalized `params._meta.traceparent`, `_meta.tracestate`, and `_meta.baggage` as reserved keys for OTel trace context propagation. This is the official transport-agnostic mechanism — use it for all transports (HTTP and stdio).
- **OTel MCP semantic conventions** are published and stable: `mcp.method.name`, `mcp.session.id`, `mcp.protocol.version`, `network.transport`. Use these instead of generic RPC/HTTP semconv.
- **Competitive context**: IBM ContextForge has full OTel with W3C Trace Context. AgentGateway has per-tool-call traces. Not having tracing is a competitive gap.
- **Existing foundation leveraged**: `ToolCallObserver` pattern, `WithTraceID()` in logging, `context.Context` threaded throughout, canvas overlay hooks in web UI, bottom panel tab pattern.
- **Risk mitigation**: Always-on with in-memory storage by default. OTLP export is opt-in. Zero performance impact when no exporter configured.
- Full evaluation: `prompts/gridctl/distributed-tracing/feature-evaluation.md`

## Feature Description

Add end-to-end distributed tracing to gridctl's MCP gateway. Every tool call flowing through the gateway gets instrumented with OpenTelemetry spans. Trace context propagates via W3C `traceparent` headers (HTTP transports) and MCP `_meta.traceparent` (stdio transports). Traces are stored in an in-memory ring buffer and surfaced through the CLI (`gridctl traces`), web UI (Traces tab with waterfall view), and optionally exported to external collectors via OTLP.

**Problem**: Users cannot debug slow or failing tool calls across the gateway boundary. With multi-server stacks, there is no visibility into where time is spent or where errors originate.

**Who benefits**: Every gridctl user running multi-server MCP stacks — the common case.

## Requirements

### Functional Requirements

1. Generate a root span for every incoming MCP request (tools/call, tools/list, prompts/get, resources/read, ping) at the handler layer
2. Extract W3C `traceparent` from incoming HTTP headers when present; create new trace context when absent
3. Extract `_meta.traceparent` from incoming MCP JSON-RPC `params._meta` when present (for clients that propagate trace context in the MCP protocol layer)
4. Create child spans for: ACL check, routing decision, downstream client call, format conversion
5. Inject `traceparent` header into outgoing HTTP requests to downstream MCP servers
6. Inject `_meta.traceparent` into outgoing JSON-RPC params for stdio/process/SSH transports
7. Store completed traces in an in-memory ring buffer (default: 1000 traces or 24h retention)
8. Expose traces via `GET /api/traces` (list with filters) and `GET /api/traces/{traceId}` (detail) REST endpoints
9. Support optional OTLP export to external collectors (Jaeger, Tempo, etc.) configured via `stack.yaml`
10. Add `gateway.tracing` configuration block to `stack.yaml` with fields: `enabled` (default: true), `sampling` (default: 1.0), `retention` (default: "24h"), `export` ("otlp"), `endpoint`
11. Add `gridctl traces` CLI command with table view of recent traces
12. Add `gridctl traces <trace-id>` CLI command with ASCII waterfall visualization
13. Support CLI filters: `--server`, `--errors`, `--min-duration`, `--json`, `--follow`
14. Add "Traces" tab to the web UI bottom panel with a filterable trace list
15. Add waterfall visualization in the web UI when clicking a trace
16. Add canvas edge latency overlay toggle (matching existing token heat pattern)
17. Add pop-out window support at `/traces` route
18. Correlate traces with existing logs via the `trace_id` field already in `LogEntry`
19. Use OTel MCP semantic conventions for all span attributes: `mcp.method.name`, `mcp.session.id`, `mcp.protocol.version`, `network.transport`
20. Populate `WithTraceID()` in structured logging with actual OTel trace IDs

### Non-Functional Requirements

1. Zero performance impact when no OTLP exporter configured (in-memory buffer only)
2. Thread-safe trace buffer supporting concurrent reads and writes
3. Graceful shutdown: flush pending spans on gateway shutdown
4. Trace buffer memory bounded (ring buffer eviction, not unbounded growth)
5. No new external dependencies beyond what's already in `go.mod` (OTel deps are already indirect)
6. Web UI waterfall renders smoothly for traces with up to 50 spans

### Out of Scope

1. Trace-based alerting or anomaly detection
2. Persistent trace storage to disk
3. Distributed trace aggregation across multiple gridctl instances
4. Custom span processors or sampling strategies beyond head-based rate sampling
5. Prometheus metrics export (separate feature)
6. Modifying downstream MCP servers to emit their own spans (gridctl traces end at the gateway→server boundary unless the server independently implements OTel)

## Architecture Guidance

### Recommended Approach

Follow the existing observer pattern established by `metrics.Observer`. Create a new `pkg/tracing` package that:

1. Initializes the OTel SDK (tracer provider, propagator, optional OTLP exporter)
2. Provides middleware for the HTTP handler to extract/inject trace context
3. Implements span creation at key points in the request flow
4. Stores completed spans in a ring buffer for API/CLI access
5. Integrates with the existing `ToolCallObserver` or creates a parallel hook

For the `_meta` propagation, implement a custom `propagation.TextMapCarrier` that wraps the MCP params `_meta` map, enabling standard OTel `Extract()`/`Inject()` calls.

### Key Files to Understand

Read these before starting implementation:

| File | Why |
|------|-----|
| `pkg/mcp/handler.go` | HTTP request entry point. Understand how `r.Context()` flows to gateway methods. This is where trace extraction middleware hooks in. |
| `pkg/mcp/gateway.go` | Central orchestration. `HandleToolsCall()` and `HandleToolsCallForAgent()` are the primary span creation points. Understand the observer pattern at lines 126-132. |
| `pkg/mcp/client.go` | HTTP transport. `sendHTTP()` already sets custom headers — pattern for `traceparent` injection. |
| `pkg/mcp/client_base.go` | Transport abstraction. The `transporter` interface defines `call()` and `send()` — understand how context flows to different transport implementations. |
| `pkg/mcp/stdio.go` | Docker stdio transport. Request/response multiplexing via channels. Understand how JSON-RPC messages are constructed for `_meta` injection. |
| `pkg/mcp/types.go` | `ToolCallObserver` interface definition. Pattern for trace observer. |
| `pkg/metrics/observer.go` | Reference implementation of `ToolCallObserver`. Pattern to replicate. |
| `pkg/metrics/accumulator.go` | Thread-safe ring buffer with atomic operations. Pattern for trace buffer. |
| `pkg/logging/structured.go` | `WithTraceID()` at line 117. `LogEntry` schema with `TraceID` field. |
| `pkg/logging/buffer.go` | `BufferedEntry` with `TraceID` field. Ring buffer pattern for in-memory storage. |
| `pkg/config/types.go` | `GatewayConfig` struct — where `TracingConfig` goes. |
| `internal/api/api.go` | API route registration. Pattern for adding `/api/traces` endpoints. |
| `pkg/jsonrpc/types.go` | JSON-RPC `Request` struct. Params is `json.RawMessage` — need to handle `_meta` injection into this. |
| `web/src/components/layout/BottomPanel.tsx` | Bottom panel tab system. Pattern for adding Traces tab. |
| `web/src/hooks/useTokenHeat.ts` | Canvas overlay hook. Pattern for latency heat overlay. |
| `web/src/pages/DetachedMetricsPage.tsx` | Pop-out window pattern. Template for `DetachedTracesPage`. |
| `web/src/stores/useUIStore.ts` | UI state management. Extend for traces tab and detachment state. |

### Integration Points

**Backend**:

1. **New package `pkg/tracing/`**: OTel SDK init, tracer provider, span buffer, trace API types
2. **`pkg/mcp/handler.go`**: Wrap handler with OTel HTTP middleware or manually extract trace context from `r.Context()` / HTTP headers. Create root span for each MCP method.
3. **`pkg/mcp/gateway.go`**: Create child spans in `HandleToolsCall()` / `HandleToolsCallForAgent()`. Call `WithTraceID()` on the logger with the OTel trace ID. Notify trace observer after tool call completion.
4. **`pkg/mcp/client.go`**: In `sendHTTP()`, inject `traceparent` header from context using `otel.GetTextMapPropagator().Inject()`.
5. **`pkg/mcp/client_base.go`**: Before calling downstream transporter, inject `_meta.traceparent` into the JSON-RPC params for stdio/process transports.
6. **`pkg/jsonrpc/types.go`**: May need a helper to inject `_meta` into `Params` (which is `json.RawMessage`). Alternatively, handle this at the `client_base` level by wrapping params before serialization.
7. **`pkg/config/types.go`**: Add `TracingConfig` struct to `GatewayConfig`.
8. **`internal/api/api.go`**: Register `/api/traces` and `/api/traces/{traceId}` endpoints.
9. **`internal/api/traces.go`** (new): HTTP handlers for trace list and detail endpoints.
10. **`cmd/gridctl/traces.go`** (new): CLI command implementation.

**Frontend**:

1. **`web/src/stores/useTracesStore.ts`** (new): Zustand store for trace data, polling, filters
2. **`web/src/components/traces/TracesTab.tsx`** (new): Bottom panel tab with trace list table
3. **`web/src/components/traces/TraceWaterfall.tsx`** (new): Waterfall visualization component
4. **`web/src/components/traces/SpanDetail.tsx`** (new): Span attribute detail panel
5. **`web/src/components/layout/BottomPanel.tsx`**: Add "Traces" to TABS array
6. **`web/src/hooks/useLatencyHeat.ts`** (new): Canvas overlay hook for edge latency coloring
7. **`web/src/pages/DetachedTracesPage.tsx`** (new): Pop-out window for traces
8. **`web/src/stores/useUIStore.ts`**: Add `tracesDetached` state

### Reusable Components

- **`metrics.Observer`**: Clone pattern for `tracing.Observer` implementing `ToolCallObserver`
- **`logging.Buffer`**: Clone ring buffer pattern for trace storage
- **`metrics.Accumulator`**: Reference for thread-safe per-server aggregation
- **`otel/propagation.TraceContext`**: Standard W3C propagation — don't reinvent
- **Custom `TextMapCarrier`**: Wrap `map[string]any` (MCP `_meta`) to implement `propagation.TextMapCarrier` interface for `_meta.traceparent` extraction/injection
- **`useTokenHeat` hook**: Clone for `useLatencyHeat` canvas overlay
- **`DetachedMetricsPage`**: Clone for `DetachedTracesPage`

## UX Specification

### Discovery

Tracing is always on by default. Users discover it through:
- `gridctl status` showing a one-line activity summary
- Canvas edge animations during in-flight tool calls
- The "Traces" tab appearing in the bottom panel

### Activation

No activation needed for basic in-memory tracing. For OTLP export:
```yaml
gateway:
  tracing:
    sampling: 1.0
    retention: "24h"
    export: "otlp"
    endpoint: "http://localhost:4318"
```

### CLI Interaction

```bash
# List recent traces
$ gridctl traces
TRACE ID         DURATION   SPANS   STATUS   OPERATION
a1b2c3d4e5f6     234ms      5       ok       tools/call github__search_code
f7e8d9c0b1a2     1.2s       8       error    tools/call chrome__navigate_page

# Filter
$ gridctl traces --server github --min-duration 500ms --errors

# Drill down
$ gridctl traces a1b2c3d4e5f6
Trace a1b2c3d4e5f6 (234ms, 5 spans)
├─ gateway.receive            0ms─────┤ 2ms
├─ gateway.acl_check          2ms─┤ 3ms
├─ gateway.route              3ms─┤ 5ms
├─ mcp.client.call_tool       5ms───────────────────────┤ 228ms
│  └─ transport: http, server: github
└─ gateway.format_convert   228ms──┤ 234ms

# Live streaming
$ gridctl traces --follow
```

### Web UI Interaction

1. **Trace list** (bottom panel Traces tab): Filterable table with columns: time, trace ID, operation, server, duration, status. Filters: server dropdown, error toggle, duration range, text search.
2. **Waterfall** (click trace row): Inline waterfall with horizontal span bars. Color-coded by server. Error spans in red. Click span for detail panel.
3. **Span detail** (click span in waterfall): Side panel showing all OTel attributes, associated log entries (correlated via trace ID), timing breakdown.
4. **Canvas overlay**: Toggle for latency heat on edges. Animated edges during in-flight calls.
5. **Pop-out**: Button opens `/traces` in dedicated window.

### Feedback

- Spans show duration with millisecond precision
- Error spans highlighted in red with error message visible
- Slow spans (>p95 of recent traces) highlighted in amber
- "No traces yet" empty state when gateway has just started

### Error States

- OTLP export failure: log warning, continue with in-memory storage (graceful degradation)
- Trace buffer full: ring buffer evicts oldest traces (no error, expected behavior)
- Downstream server doesn't support `_meta.traceparent`: trace ends at gateway boundary (expected, not an error)

## Implementation Notes

### Conventions to Follow

- **Package structure**: New `pkg/tracing/` package following the pattern of `pkg/metrics/`
- **Error handling**: `fmt.Errorf("tracing: %w", err)` pattern consistent with codebase
- **Logging**: Use `slog` with `component: "tracing"` via `logging.WithComponent()`
- **Testing**: Use `uber/mock` for interface mocking. Test trace propagation end-to-end with mock HTTP servers.
- **Config**: YAML tags use `snake_case` (`yaml:"sampling"`)
- **API responses**: JSON with `camelCase` field names matching existing API patterns
- **Frontend**: Zustand stores with polling pattern matching `useStackStore`. Components in `web/src/components/traces/`. Tailwind CSS.
- **Sign all commits** with `-S` flag. No Co-authored-by trailers.

### Potential Pitfalls

1. **`_meta` injection into `json.RawMessage` params**: The JSON-RPC `Params` field is `json.RawMessage`. Injecting `_meta` requires unmarshaling to `map[string]any`, adding `_meta`, and re-marshaling. Handle the case where params is `null`, an empty object, or already has a `_meta` key.
2. **Stdio response correlation**: Stdio transports use request ID channels for response multiplexing. Trace context must be stored alongside the request ID and retrieved when the response arrives — don't try to thread it through the stdio pipe.
3. **OTel SDK shutdown**: The tracer provider must be shut down gracefully to flush pending spans. Hook into the existing gateway shutdown path.
4. **Span naming**: Use OTel MCP semantic conventions (`mcp.method.name`, not custom names). Reference: https://opentelemetry.io/docs/specs/semconv/gen-ai/mcp/
5. **Memory pressure**: Ring buffer should have a hard cap on both count and total memory. Traces with large tool call results could be expensive — consider truncating span attributes for large payloads.
6. **Thread safety**: The trace buffer will be written from multiple goroutines (one per SSE session). Use the same atomic/mutex patterns as `metrics.Accumulator`.

### Suggested Build Order

**Phase A — Backend Core (build first, delivers standalone value)**:
1. `pkg/tracing/provider.go` — OTel SDK initialization, tracer provider, shutdown
2. `pkg/tracing/config.go` — `TracingConfig` type and defaults
3. `pkg/config/types.go` — Add `Tracing *TracingConfig` to `GatewayConfig`
4. `pkg/tracing/carrier.go` — Custom `TextMapCarrier` for MCP `_meta` map
5. `pkg/tracing/buffer.go` — In-memory ring buffer for completed traces
6. `pkg/mcp/handler.go` — Extract trace context from HTTP headers, create root spans
7. `pkg/mcp/gateway.go` — Child spans for tool call flow, populate `WithTraceID()` on logger
8. `pkg/mcp/client.go` — Inject `traceparent` into outgoing HTTP requests
9. `pkg/mcp/client_base.go` — Inject `_meta.traceparent` into JSON-RPC params for stdio transports
10. `internal/api/traces.go` — `/api/traces` REST endpoints
11. `internal/api/api.go` — Register trace routes
12. Tests for all of the above

**Phase B — CLI (build second)**:
1. `cmd/gridctl/traces.go` — `gridctl traces` command with table and waterfall output
2. `cmd/gridctl/status.go` — Add activity summary line
3. Tests

**Phase C — Web UI (build third)**:
1. `web/src/stores/useTracesStore.ts` — Zustand store with polling
2. `web/src/components/traces/TracesTab.tsx` — Trace list table
3. `web/src/components/traces/TraceWaterfall.tsx` — Waterfall visualization
4. `web/src/components/traces/SpanDetail.tsx` — Span detail panel
5. `web/src/components/layout/BottomPanel.tsx` — Add Traces tab
6. `web/src/pages/DetachedTracesPage.tsx` — Pop-out window
7. `web/src/hooks/useLatencyHeat.ts` — Canvas edge latency overlay
8. `web/src/stores/useUIStore.ts` — Extend for traces state

## Acceptance Criteria

1. Every `tools/call` through the gateway produces an OTel trace with root + child spans
2. Traces appear in `gridctl traces` CLI output within 1 second of completion
3. `gridctl traces <id>` shows an ASCII waterfall with correct span hierarchy and timing
4. `GET /api/traces` returns a JSON list of recent traces with filtering support
5. `GET /api/traces/{traceId}` returns full trace detail with all spans and attributes
6. Outgoing HTTP requests to downstream MCP servers include the `traceparent` header
7. Outgoing JSON-RPC messages to stdio transports include `_meta.traceparent` in params
8. When an incoming request includes `traceparent` (HTTP header or `_meta`), the gateway creates a child span (not a new root)
9. Span attributes follow OTel MCP semantic conventions: `mcp.method.name`, `mcp.session.id`, `network.transport`
10. Structured logs include `trace_id` from the active OTel span context
11. In-memory trace buffer evicts old traces when capacity is reached (no memory leak)
12. When `gateway.tracing.export: "otlp"` is configured, traces export to the specified OTLP endpoint
13. When no exporter is configured, tracing still works with in-memory storage only
14. Web UI "Traces" tab shows a filterable list of recent traces
15. Clicking a trace in the web UI shows a waterfall visualization with color-coded spans
16. The `/traces` route works as a pop-out window
17. All new code has test coverage

## References

- [MCP Spec: _meta convention (PR #414)](https://github.com/modelcontextprotocol/modelcontextprotocol/pull/414)
- [OTel Semantic Conventions for MCP](https://opentelemetry.io/docs/specs/semconv/gen-ai/mcp/)
- [OTel Go SDK propagation package](https://pkg.go.dev/go.opentelemetry.io/otel/propagation)
- [OTel Go SDK trace package](https://pkg.go.dev/go.opentelemetry.io/otel/trace)
- [OTLP HTTP exporter](https://pkg.go.dev/go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp)
- [IBM ContextForge Observability](https://ibm.github.io/mcp-context-forge/manage/observability/)
- [W3C Trace Context specification](https://www.w3.org/TR/trace-context/)
- [KrakenD OTel Gateway (Go reference)](https://github.com/krakend/krakend-otel)
- [mcp-otel-go (Go MCP OTel middleware)](https://github.com/olgasafonova/mcp-otel-go)
