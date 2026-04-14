# Feature Implementation: OTLP Trace Export — Production Readiness

## Context

gridctl is a local MCP (Model Context Protocol) gateway written in Go. It proxies AI tool calls, manages Docker-based MCP servers, and exposes a web UI for observability (logs, traces, metrics, schemas). The tracing subsystem uses the OpenTelemetry Go SDK with W3C trace context propagation across HTTP and JSON-RPC transports.

The core OTLP export feature is **already implemented** in `pkg/tracing/provider.go`. When `gateway.tracing.export: otlp` and `gateway.tracing.endpoint: <url>` are set in `stack.yaml`, the provider attaches a `BatchSpanProcessor` backed by `otlptracehttp` alongside the always-on in-memory ring buffer. This prompt fixes four mechanical gaps that prevent it from being production-ready.

Tech stack: Go 1.23+, OpenTelemetry Go SDK v1.42.0, React/TypeScript web UI.

## Evaluation Context

- The feature is completely invisible — no example YAML, no docs. Engineers cannot discover it without reading source code.
- `WithInsecure()` is hardcoded, so HTTPS backends (Honeycomb, Grafana Cloud, any production cloud backend) fail silently. `WithEndpointURL()` reads the scheme from the URL and eliminates the need for this flag.
- The `tracingProvider` created in `buildAPIServer` is a local variable — `Shutdown()` is never called on gateway exit, so spans buffered by the `BatchSpanProcessor` may not flush.
- Zero test coverage for the OTLP initialization and fallback paths.
- Full evaluation: `prompts/gridctl/otlp-trace-export/feature-evaluation.md`

## Feature Description

Fix four production-readiness gaps in the existing OTLP trace export, in priority order:

1. **Discoverability** — Add `examples/tracing/otlp-jaeger.yaml` and a `gateway.tracing` section to `docs/config-schema.md`
2. **TLS** — Replace `WithEndpoint(url) + WithInsecure()` with `WithEndpointURL(url)` so HTTP and HTTPS backends both work from the URL scheme alone
3. **Tests** — Add 4 targeted test cases to `provider_test.go` covering the OTLP initialization and fallback paths
4. **Shutdown** — Store the tracing provider on `GatewayBuilder`; call `Shutdown()` during gateway drain to flush batched spans

## Requirements

### Functional Requirements

**Discoverability**

1. `examples/tracing/otlp-jaeger.yaml` must be a valid `stack.yaml` with `gateway.tracing.export: otlp`, `gateway.tracing.endpoint: http://localhost:4318`, and a comment block showing the Jaeger `docker run` one-liner and a note that Honeycomb/Grafana Cloud use `https://` endpoints
2. `docs/config-schema.md` must include a `gateway.tracing` section documenting all fields: `enabled`, `sampling`, `retention`, `export`, `endpoint`, `max_traces`

**TLS fix**

3. `WithEndpointURL(endpoint)` must be the sole option passed to `otlptracehttp.New()` for endpoint configuration — no `WithEndpoint()`, no `WithInsecure()`
4. The `WithTimeout(5*time.Second)` option must be preserved

**Tests**

5. `provider_test.go` must include these 4 new test cases (existing 4 tests unchanged):
   - `TestProviderInit_otlpHTTP` — init with `export: otlp`, `endpoint: http://localhost:4318`; assert `p.provider != nil`, no error returned
   - `TestProviderInit_otlpMissingEndpoint` — init with `export: otlp`, `endpoint: ""`; assert no error, `p.provider != nil` (ring buffer path active, OTLP branch skipped)
   - `TestProviderShutdown_afterOTLPInit` — init with OTLP config then `Shutdown()`; assert no error
   - `TestProviderInit_unreachableCollector` — init with `export: otlp`, `endpoint: http://localhost:19999`; assert no panic, no error returned (graceful warn-and-continue behavior)

**Shutdown**

6. `GatewayBuilder` must have a `tracingProvider *tracing.Provider` field (unexported)
7. In `buildAPIServer()`, after `tracingProvider.Init()`, assign `b.tracingProvider = tracingProvider`
8. In `waitForShutdown()`, after `inst.HTTPServer.Shutdown(shutdownCtx)`, call:
   ```go
   if b.tracingProvider != nil {
       if err := b.tracingProvider.Shutdown(shutdownCtx); err != nil {
           logger.Error("tracing shutdown error", "error", err)
       }
   }
   ```

### Non-Functional Requirements

- No changes to `pkg/tracing/config.go` or `pkg/config/types.go` — the config schema is correct as-is
- No changes to `buildTracingConfig()` — it's correct as-is
- No changes to `buildAPIServer()`'s return signature — store the provider on the builder, not as a return value
- No changes to `GatewayInstance` — `TracingProvider` does not belong there; the builder owns the lifecycle
- No changes to the ring buffer or web UI

### Out of Scope

- Header-based auth for Honeycomb (`x-honeycomb-team`) — document as a note in the example, not in code
- An HTTPS test case — `otlptracehttp.New()` dials lazily, so a unit test with an unreachable HTTPS URL passes trivially and proves nothing about TLS behavior. Integration test territory.
- Retry logic or exporter health monitoring
- OTLP gRPC export
- Any changes to the web UI Traces tab

## Architecture Guidance

### Recommended Build Order

Work gap by gap — each is independent:

1. **Discoverability first** — zero risk, highest user-facing value; `examples/tracing/otlp-jaeger.yaml` + `docs/config-schema.md`
2. **TLS fix** — one-line change in `provider.go`; run existing tests to confirm nothing regressed
3. **Tests** — 4 new cases in `provider_test.go`; run `go test ./pkg/tracing/...`
4. **Shutdown** — add `tracingProvider` field to `GatewayBuilder`, wire in `waitForShutdown`

### Key Files to Understand

| File | Why it matters |
|------|---------------|
| `pkg/tracing/provider.go` | OTLP exporter wiring — TLS fix lives at lines 62–65 |
| `pkg/tracing/provider_test.go` | Existing 4 test cases — add 4 more following the same patterns |
| `pkg/controller/gateway_builder.go` | `GatewayBuilder` struct (line 47), `buildAPIServer()` (line 324), `waitForShutdown()` (line 517) |
| `pkg/tracing/config.go` | Config struct — read-only reference |
| `pkg/config/types.go` | `TracingConfig` in `GatewayConfig` — read-only reference |

### Integration Points

**TLS fix — `pkg/tracing/provider.go:62-65`**

Current:
```go
exp, err := otlptracehttp.New(ctx,
    otlptracehttp.WithEndpoint(p.cfg.Endpoint),
    otlptracehttp.WithInsecure(),
    otlptracehttp.WithTimeout(5*time.Second),
)
```

Replace with:
```go
exp, err := otlptracehttp.New(ctx,
    otlptracehttp.WithEndpointURL(p.cfg.Endpoint),
    otlptracehttp.WithTimeout(5*time.Second),
)
```

**Shutdown — `pkg/controller/gateway_builder.go`**

Add field to `GatewayBuilder` (line 47 area):
```go
tracingProvider *tracing.Provider // retained for Shutdown
```

In `buildAPIServer()`, after the existing `tracingProvider.Init()` call (line 374):
```go
b.tracingProvider = tracingProvider
```

In `waitForShutdown()`, after `inst.HTTPServer.Shutdown(shutdownCtx)` (line 539):
```go
if b.tracingProvider != nil {
    if err := b.tracingProvider.Shutdown(shutdownCtx); err != nil {
        logger.Error("tracing shutdown error", "error", err)
    }
}
```

### Reusable Components

- `tracing.Provider.Shutdown(ctx)` — already implemented at `provider.go:109`; nil-safe on the inner `p.provider` field, so no double-nil-check needed

## UX Specification

`examples/tracing/otlp-jaeger.yaml` — copy-paste–ready, runnable in under two minutes:

```yaml
# examples/tracing/otlp-jaeger.yaml
#
# Distributed tracing with Jaeger
#
# Start Jaeger (OTLP HTTP on :4318, UI on :16686):
#   docker run --rm -p 4318:4318 -p 16686:16686 jaegertracing/jaeger:latest
#
# Then run: gridctl up -f examples/tracing/otlp-jaeger.yaml
# Open Jaeger UI: http://localhost:16686
#
# For HTTPS backends (Honeycomb, Grafana Cloud), set endpoint to an https:// URL.
# Note: most cloud backends require auth headers — use an OTel Collector as a proxy
# to inject them rather than embedding credentials in stack.yaml.

version: "1"
name: otlp-jaeger-example

gateway:
  tracing:
    export: otlp
    endpoint: http://localhost:4318

network:
  name: otlp-jaeger-net
  driver: bridge

mcp-servers: []
```

`docs/config-schema.md` — add under the Gateway section:

```markdown
### `gateway.tracing`

Configures distributed tracing for the gateway. When omitted, tracing is enabled
with defaults (in-memory ring buffer, no OTLP export).

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enabled` | bool | `true` | Enable/disable tracing |
| `sampling` | float | `1.0` | Head-based sampling rate [0.0–1.0] |
| `retention` | string | `"24h"` | How long to keep traces in the ring buffer (Go duration) |
| `export` | string | `""` | Exporter type: `"otlp"` or `""` (none) |
| `endpoint` | string | `""` | OTLP HTTP endpoint URL. `http://` uses plain HTTP; `https://` uses TLS. |
| `max_traces` | int | `1000` | Ring buffer capacity |

**Example — local Jaeger:**
```yaml
gateway:
  tracing:
    export: otlp
    endpoint: http://localhost:4318
```

**Example — Honeycomb or Grafana Cloud (HTTPS):**
```yaml
gateway:
  tracing:
    export: otlp
    endpoint: https://api.honeycomb.io/v1/traces
```
> Cloud backends typically require auth headers (e.g. `x-honeycomb-team`).
> Use an OTel Collector as a proxy to inject headers without embedding credentials in stack.yaml.
```

## Implementation Notes

### Conventions to Follow

- Commit types: `docs:` for Gap 1, `fix:` for Gaps 2–4
- Error handling: log warnings, don't fail — the existing `Warn + continue` pattern in `provider.go:68-69` is the right model
- Test file stays in `package tracing` (not `tracing_test`) — internal access to `p.provider` is needed for assertions
- No new imports needed anywhere — `otlptracehttp` is already imported in `provider.go`; `tracing` is already imported in `gateway_builder.go`

### Potential Pitfalls

- `WithEndpointURL` dials lazily — passing an unreachable URL does not cause `otlptracehttp.New()` to fail. The existing `if err != nil { warn + continue }` guard handles genuine construction errors (malformed URL, etc.).
- `b.tracingProvider.Shutdown()` is nil-safe on its inner field (`if p.provider == nil { return nil }` at line 110), but the outer `b.tracingProvider != nil` guard is still required since the field itself may be nil if OTLP was not configured.
- The 15-second `shutdownCtx` in `waitForShutdown` is shared with HTTP shutdown. The tracing exporter timeout is 5 seconds, so it fits comfortably within the budget regardless of how long HTTP drain takes.
- Do not add `TracingProvider` to `GatewayInstance` — the builder owns the provider lifecycle, not the instance. The instance is a value bag for running components; lifecycle management belongs on the builder.

## Acceptance Criteria

1. `go test ./pkg/tracing/...` passes with all 8 test cases (4 existing + 4 new)
2. `go build ./...` produces no errors
3. `pkg/tracing/provider.go` contains no reference to `WithInsecure` or `WithEndpoint(` (the non-URL variant)
4. `pkg/tracing/provider.go` contains `WithEndpointURL`
5. `GatewayBuilder` has an unexported `tracingProvider *tracing.Provider` field
6. `waitForShutdown` calls `b.tracingProvider.Shutdown` after HTTP shutdown
7. `buildAPIServer()`'s return signature is unchanged — still `(*api.Server, error)`
8. `examples/tracing/otlp-jaeger.yaml` exists and is valid YAML with `gateway.tracing.export: otlp`
9. `docs/config-schema.md` documents all 6 fields of `gateway.tracing`
10. No changes to `pkg/tracing/config.go`, `pkg/config/types.go`, or `buildTracingConfig()`
11. Existing `TestProviderInit_defaultConfig` and `TestProviderBuffer_populated` still pass

## References

- https://pkg.go.dev/go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp@v1.42.0
- https://www.jaegertracing.io/docs/1.76/getting-started/ — Jaeger OTLP HTTP setup
- https://grafana.com/docs/tempo/latest/configuration/ — Tempo OTLP HTTP config
- https://docs.honeycomb.io/send-data/opentelemetry/ — Honeycomb OTLP endpoint + auth headers
