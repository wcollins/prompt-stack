# Feature Evaluation: OTLP Trace Export

**Date**: 2026-04-05
**Project**: gridctl
**Recommendation**: Build
**Value**: High
**Effort**: Small

## Summary

OTLP HTTP export for distributed traces is already fully implemented in gridctl's tracing package — the ring buffer fan-out, config schema, and exporter wiring are all present and correct. Four small gaps prevent it from being production-ready: TLS is hardcoded off, the provider is never shut down gracefully, there are no tests for the OTLP path, and the feature is completely undiscoverable (no example, no docs). Fixing all four is ~half a day of work with near-zero risk.

## The Idea

Add an optional `gateway.tracing.otlp_endpoint` field to `stack.yaml` so traces can fan out to Jaeger, Grafana Tempo, or Honeycomb alongside the in-memory ring buffer. This converts the Traces tab from a novelty (ephemeral, local-only) into a tool engineers can use for real production debugging against a durable observability backend.

**Actual finding**: The config schema uses two fields (`export: otlp` + `endpoint: <url>`) rather than a single `otlp_endpoint` field. The implementation is functionally equivalent and more extensible. No schema change needed.

## Project Context

### Current State

gridctl is a local MCP (Model Context Protocol) gateway that proxies AI tool calls, manages Docker-based MCP servers, and provides a web UI for observability (logs, traces, metrics). The tracing subsystem uses the OpenTelemetry Go SDK with W3C trace context propagation across both HTTP and JSON-RPC transports.

The OTLP export feature exists today at `pkg/tracing/provider.go:61-76`. When `export: otlp` and `endpoint` are set in `stack.yaml`, the provider attaches a `BatchSpanProcessor` backed by `otlptracehttp` alongside the always-on `SimpleSpanProcessor` backed by the in-memory ring buffer. If the OTLP endpoint is unreachable at startup, a warning is logged and the gateway continues with ring buffer only.

### Integration Surface

| File | Role |
|------|------|
| `pkg/tracing/provider.go` | OTLP exporter wiring — needs `WithInsecure()` removed, `WithEndpointURL()` used instead |
| `pkg/tracing/provider_test.go` | Needs 7 new test cases for the OTLP init path |
| `pkg/controller/gateway_builder.go` | `buildAPIServer()` — needs to retain and return `tracingProvider` for Shutdown |
| `pkg/controller/instance.go` | `GatewayInstance` — needs `TracingProvider *tracing.Provider` field |
| `examples/tracing/otlp-jaeger.yaml` | New file — working example with Jaeger |
| `docs/config-schema.md` | Tracing section needs documenting |

### Reusable Components

- `pkg/tracing/config.go` — `Config` struct with `Export` and `Endpoint` fields (correct as-is)
- `pkg/config/types.go` — `TracingConfig` in `GatewayConfig.Tracing` (correct as-is)
- `pkg/controller/gateway_builder.go` — `buildTracingConfig()` helper (correct as-is)

## Market Analysis

### Competitive Landscape

Every production gateway tool exports OTLP natively:
- **Envoy Proxy**: OTLP trace export via `envoy.tracers.opentelemetry` filter, TLS-aware by endpoint scheme
- **Kong Gateway**: OpenTelemetry plugin exports to any OTLP backend; endpoint URL controls TLS
- **Traefik**: Built-in OTLP trace export; `insecure: true/false` flag per-backend

### Market Positioning

OTLP/HTTP with `WithEndpointURL()` (scheme-driven TLS) is the current standard pattern in the Go OTel SDK. Using `WithEndpoint()` + `WithInsecure()` is the older pattern that requires explicit flag management. The single-URL approach is table-stakes behavior.

### Ecosystem Support

- `go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp v1.42.0` — already in go.mod as a direct dependency
- `WithEndpointURL(url string)` — available since v1.21; reads scheme, no need for `WithInsecure()`
- OTLP HTTP port 4318 — universal across Jaeger, Tempo, and OTel Collector
- Honeycomb, Grafana Cloud, Datadog all accept OTLP HTTP over HTTPS on port 443

### Demand Signals

Users deploying gridctl in production environments will have existing Jaeger or Grafana Tempo installations. The Traces tab without export is a debugging dead-end for production incidents.

## User Experience

### Interaction Model

**Discovery**: Currently zero — neither the web UI, docs, nor any example YAML shows the tracing config. The feature is invisible.

**Activation**: Add to `stack.yaml`:
```yaml
gateway:
  tracing:
    export: otlp
    endpoint: http://localhost:4318   # Jaeger/Tempo/Collector
    # endpoint: https://api.honeycomb.io/v1/traces  # Honeycomb (needs header auth — see docs)
```

**Feedback**: On startup, the log line `OTLP trace exporter configured endpoint=http://localhost:4318` confirms the exporter is active. If the endpoint is unreachable, a `WARN` is logged and the gateway continues with in-memory ring buffer only.

### Workflow Impact

Zero impact on existing users — all changes are additive. The ring buffer always runs. OTLP is purely opt-in.

### UX Recommendations

- The example YAML should include a `docker run` one-liner for Jaeger so engineers can try it in under two minutes
- Log the active exporter type at startup (already done: `"export"` field in the init log)
- Consider a future `/api/tracing/status` endpoint that exposes exporter health, but that's out of scope for this fix

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Critical | Ephemeral traces are useless for production incidents |
| User impact | Narrow+Deep | Platform engineers get a complete observability pipeline |
| Strategic alignment | Core mission | Traces tab was built to be useful, not decorative |
| Market positioning | Catch up | All comparable tools already do this correctly |

### Cost Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Minimal | ≤3 files touched per gap; no architectural change |
| Effort estimate | Small | ~150 lines total across 4 gaps |
| Risk level | Low | Ring buffer path unchanged; OTLP degrades gracefully |
| Maintenance burden | Minimal | OTel SDK owns the exporter; we own only the wiring |

## Recommendation

**Build.** The core is already correct and battle-tested. These four gaps are mechanical fixes, not design problems:

1. **TLS (1 line)**: Replace `WithEndpoint(url) + WithInsecure()` with `WithEndpointURL(url)`. HTTP endpoints get plain HTTP, HTTPS endpoints get TLS — no config flag needed.
2. **Shutdown (~20 lines)**: Store `TracingProvider` on `GatewayInstance`; call `Shutdown()` after HTTP drain in `waitForShutdown`. Ensures batched spans flush before exit.
3. **Tests (~100 lines)**: 7 new cases in `provider_test.go` covering http/https endpoints, missing endpoint fallback, Shutdown after init, sampling, DefaultConfig values, and no-panic on unreachable collector.
4. **Discoverability (~50 lines)**: `examples/tracing/otlp-jaeger.yaml` with a Jaeger `docker run` comment, plus a Tracing section in `docs/config-schema.md`.

No schema changes. No breaking changes. Ring buffer behavior is untouched.

## References

- https://pkg.go.dev/go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp@v1.42.0
- https://www.jaegertracing.io/docs/1.76/getting-started/
- https://grafana.com/docs/tempo/latest/configuration/
- https://docs.honeycomb.io/send-data/opentelemetry/
- https://opentelemetry.io/docs/collector/configuration/
