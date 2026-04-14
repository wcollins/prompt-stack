# Feature Implementation: Pre-Tracing Readiness

## Context

gridctl is a Go-based MCP (Model Context Protocol) gateway — described as "Containerlab for AI agents." It runs as a daemon, aggregates multiple MCP servers behind a single authenticated endpoint, manages agent stacks via `stack.yaml`, and serves a web UI. The project uses Go 1.23+, `zerolog` for structured logging, a custom in-memory ring buffer for log storage, Docker for container lifecycle, and has a React/TypeScript web UI.

**Tech stack**: Go (pkg/, internal/, cmd/), React + TypeScript (web/), Docker daemon integration, YAML config, REST API

**Relevant architecture**:
- `pkg/logging/` — ring buffer, redaction, structured logger wrappers
- `pkg/mcp/` — MCP server management, SSE session management, northbound transport
- `pkg/a2a/` — A2A protocol handler and client adapter
- `pkg/format/` — tool result output formatting
- `pkg/metrics/` — token usage observer pattern
- `internal/api/` — REST API server
- `go.mod` — already includes `go.opentelemetry.io/otel v1.39.0`, `otel/trace`, `otlptrace/otlptracehttp`, `otelhttp`

## Evaluation Context

Three key findings from the feature evaluation shaped this prompt:

1. **OTel deps are already in go.mod** — the distributed tracing feature can wire them immediately. No new dependency negotiation needed.

2. **MCP deprecated HTTP+SSE in spec `2025-03-26`** — gridctl's northbound transport needs migration to Streamable HTTP (`2025-06-18`) before tracing spans SSE session lifetimes, or the spans will track a deprecated transport.

3. **Result size limits are a prerequisite** — without truncating large tool results before they enter the log/trace pipeline, a single 10MB JSON blob can make traces unusable.

Full evaluation: `prompts/gridctl/pre-tracing-readiness/feature-evaluation.md`

---

## Feature Description

Two pieces of groundwork before the distributed tracing feature:

**Part A — Result Size Limits** (do first, ~1 day): Add configurable truncation of large tool results at the format/logging layer. Prevents log/trace explosion from tools that return large payloads (markdown dumps, full JSON APIs, search results).

**Part B — Streamable HTTP Migration** (do second, ~1-2 weeks): Migrate gridctl's northbound MCP transport from the deprecated HTTP+SSE spec (`2024-11-05`) to Streamable HTTP (`2025-06-18`). This includes `Mcp-Session-Id` header management, `Last-Event-ID` resumability, DELETE-based session termination, and a backward-compatibility negotiation path for legacy clients.

Log file persistence (lumberjack rotation) is also included as a small, independent addition.

---

## Requirements

### Part A: Result Size Limits

**Functional Requirements**:
1. Add a `maxToolResultBytes` configuration option (default: 65536 bytes / 64KB) to the gateway config section of `stack.yaml`
2. When a tool result exceeds `maxToolResultBytes`, truncate it and append a suffix: `[truncated: <original_size> bytes, showing first 64KB]`
3. Apply truncation before the result enters the log buffer AND before it is emitted as an OTel span attribute (apply at the format/output layer)
4. Expose the config option as `gateway.maxToolResultBytes` in the stack.yaml schema
5. Log a warning at `WARN` level when truncation occurs, including the tool name, server name, and original byte count

**Non-Functional Requirements**:
- Truncation must be UTF-8 safe (do not split multi-byte rune sequences)
- Truncation must not break JSON validity if the original result was JSON — truncate by appending `... [truncated]` after the last complete field if possible, or truncate the string representation
- Zero allocation overhead when result is under the limit

**Out of Scope**: Streaming/chunked tool results, per-server truncation limits (use global gateway default for now)

### Part B: Streamable HTTP Migration

**Functional Requirements**:
1. Implement the MCP Streamable HTTP transport per spec `2025-06-18`:
   - Single `/mcp` endpoint responding to both POST (client→server) and GET (server→client SSE stream)
   - Server assigns `Mcp-Session-Id` (cryptographically secure, globally unique) in `InitializeResult` response headers
   - All subsequent client requests must include `Mcp-Session-Id`; server returns 405 with error for missing/expired session IDs
   - Client terminates session via HTTP DELETE to `/mcp` with `Mcp-Session-Id` header; server returns 200 and tears down session
   - Server assigns per-event SSE `id` fields; client reconnects with `Last-Event-ID` to replay missed events
2. Implement backward-compatibility negotiation: if client sends GET to legacy `/sse` endpoint, return a negotiation response directing them to POST `/mcp` first
3. Validate `Origin` header on all `/mcp` requests to prevent DNS rebinding attacks (allowlist: localhost, configured host)
4. Session eviction: maintain existing 1,000-session LRU cap, but use the new session ID format
5. Cancellation: disconnection is NOT treated as cancellation; client must send `CancelledNotification` explicitly
6. Expose session count and active session IDs in `GET /api/sessions` for observability

**Non-Functional Requirements**:
- Maintain existing agent-name capture from `X-Agent-Name` header and query parameter
- Existing keepalive heartbeat (30-second interval) must be preserved
- All tests in `pkg/mcp/` must pass; add new tests for session resume and DELETE termination
- The migration must not break Claude Desktop compatibility (Claude Desktop supports both old SSE and Streamable HTTP)

**Out of Scope**: gRPC transport, WebSocket transport, multi-tenant session isolation

### Part C: Log File Persistence (independent, small)

**Functional Requirements**:
1. Add `--log-file <path>` CLI flag to `gridctl deploy` and daemon mode
2. When set, write structured JSON logs to the specified file using `lumberjack v2` for rotation
3. Default rotation config: 100MB max size, 7 days max age, 3 compressed backups
4. Allow rotation config override via stack.yaml: `logging.file`, `logging.maxSizeMB`, `logging.maxAgeDays`, `logging.maxBackups`
5. Log to both the existing ring buffer (for web UI) AND the file simultaneously

**Out of Scope**: Remote log export (OTLP) — that belongs in the distributed tracing feature

---

## Architecture Guidance

### Recommended Approach

**Part A (size limits)**: Add truncation in `pkg/format/` as a reusable `TruncateResult(result string, maxBytes int) string` function. Call it from the gateway's tool result processing path. Read `pkg/format/` to understand existing output format conversion — plug truncation in alongside it.

**Part B (Streamable HTTP)**: Do not attempt to patch `pkg/mcp/sse.go` incrementally. The old dual-endpoint model (GET `/sse` + POST `/sse/messages`) is structurally incompatible with the new single-endpoint model. The right approach is:
1. Create `pkg/mcp/streamable.go` implementing the new transport
2. Keep `pkg/mcp/sse.go` alive for legacy client negotiation (redirect responses only)
3. Register both handlers in `internal/api/api.go`, with the new `/mcp` handler as primary

**Reference implementation**: `github.com/mark3labs/mcp-go` implements Streamable HTTP with backward compat to `2024-11-05`. Read its `server/streamable_http.go` for the negotiation handshake pattern.

**Part C (log file)**: Use `lumberjack v2` as `io.Writer`. Create a `pkg/logging/file.go` that builds a `zerolog.MultiLevelWriter` combining the existing buffer handler and the lumberjack writer.

### Key Files to Understand

1. **`pkg/logging/buffer.go`** — ring buffer implementation; understand capacity and concurrency model before adding file output
2. **`pkg/logging/redact.go`** — RedactingHandler; this is where result content flows through; size limit truncation should happen BEFORE or AT this layer
3. **`pkg/logging/structured.go`** — logger wrappers with `WithComponent()`, `WithTraceID()`; understand handler chain before adding file handler
4. **`pkg/mcp/session.go`** — `SessionManager` lifecycle; the Streamable HTTP migration will refactor this significantly
5. **`pkg/mcp/sse.go`** — current SSE implementation; read to understand keepalive, agent identity capture, and message flow — preserve these behaviors in the new transport
6. **`internal/api/api.go`** — where HTTP handlers are registered; new `/mcp` endpoint goes here
7. **`pkg/format/`** — existing output format conversion; truncation plugs in here
8. **`pkg/config/types.go`** — gateway config struct; add `MaxToolResultBytes` field here
9. **`pkg/config/validate.go`** — validation; add range check for `MaxToolResultBytes`
10. **`go.mod`** — confirm lumberjack is not already present; add `gopkg.in/natefinch/lumberjack.v2`

### Integration Points

**For size limits**:
```go
// pkg/format/truncate.go (new file)
func TruncateResult(result string, maxBytes int) (truncated string, wasTruncated bool)

// Called from: tool result processing in gateway/MCP server response path
// Also called from: OTel span attribute setter (in the tracing feature)
```

**For Streamable HTTP**:
```go
// pkg/mcp/streamable.go (new file)
type StreamableHTTPServer struct {
    sessions *SessionManager
    // ...
}

// Endpoints registered in internal/api/api.go:
// POST /mcp  → client→server messages
// GET  /mcp  → server→client SSE stream (with Last-Event-ID support)
// DELETE /mcp → session termination
```

**For log file**:
```go
// pkg/logging/file.go (new file)
func NewFileHandler(path string, opts FileOpts) (zerolog.LevelWriter, error)
// Uses lumberjack.Logger as io.Writer backend
```

### Reusable Components

- `pkg/logging/buffer.go` `LogBuffer` — keep as-is; add file writer alongside it
- `pkg/mcp/session.go` `SessionManager` — reuse session ID generation and LRU eviction; refactor lifecycle methods
- `pkg/metrics/observer.go` — observer pattern is the right model for hooking tool call result processing

---

## UX Specification

### Result Size Limits

- **Discovery**: `stack.yaml` schema reference, `gridctl validate` output when limit is near
- **Activation**: `gateway.maxToolResultBytes: 65536` in stack.yaml (opt-in; defaults to 64KB)
- **Feedback**: `WARN` log entry when truncation occurs: `tool result truncated: tool=list_containers server=docker original=1.2MB limit=64KB`
- **Error states**: No errors — truncation is silent at the tool result level, warning at the log level

### Streamable HTTP

- **Discovery**: Transparent — existing users see no change if their client supports both protocols
- **Activation**: No user action required; the server negotiates automatically
- **Feedback**: Session ID visible in web UI session list; `GET /api/sessions` for API consumers
- **Error states**: 405 on missing `Mcp-Session-Id` with a human-readable error body explaining that a session must be initialized first

### Log File Persistence

- **Discovery**: `gridctl deploy --help` shows `--log-file` flag
- **Activation**: `gridctl deploy --log-file /var/log/gridctl/gridctl.log`
- **Feedback**: Startup log entry: `log file opened: path=/var/log/gridctl/gridctl.log rotation=100MB`
- **Error states**: If the log file cannot be opened (permissions, missing directory), fail fast with an actionable error message including the path and suggested fix

---

## Implementation Notes

### Conventions to Follow

- **Commit types**: `feat`, `fix`, `refactor`, `chore` — sign all commits with `-S`
- **Error handling**: fail fast with clear messages; wrap errors with `fmt.Errorf("context: %w", err)`
- **Config**: add new fields to `pkg/config/types.go` with JSON and YAML tags; validate in `pkg/config/validate.go`
- **Testing**: table-driven tests in `*_test.go` files alongside the implementation; use `testify/assert` and `testify/require`
- **No global state**: pass dependencies via constructor injection, not `init()` or package-level vars

### Potential Pitfalls

**Part A**:
- UTF-8 safety: use `utf8.ValidString()` and trim at rune boundaries, not byte boundaries
- JSON truncation: if the result is JSON and you truncate mid-structure, the trace attribute will be invalid JSON. Consider truncating to the full string representation and appending `[truncated]` rather than trying to preserve JSON validity

**Part B**:
- The `Last-Event-ID` resume mechanism requires the server to store recent events per session, not just stream them. Plan for a per-session bounded ring buffer of recent SSE events (last 100 events, or last 5 minutes, whichever is smaller).
- DNS rebinding protection: parse `Origin` header carefully. Reject if host is not `localhost`, `127.0.0.1`, `::1`, or the configured gateway host. Do not reject missing `Origin` (non-browser clients won't send it).
- Claude Desktop compatibility test: verify Claude Desktop can connect and perform a full tool call round-trip before merging.

**Part C**:
- `lumberjack.Logger` implements `io.Writer` but not `zerolog.LevelWriter`. Wrap it or use zerolog's `LevelWriterAdapter`.
- Log rotation is not triggered by gridctl — lumberjack handles it internally based on file size. No cron or signal handling needed.

### Suggested Build Order

```
1. Part A: Result size limits
   a. Add TruncateResult() to pkg/format/
   b. Add MaxToolResultBytes to pkg/config/types.go + validate.go
   c. Wire truncation into tool result processing path
   d. Write tests with 50+ character and 1MB inputs

2. Part C: Log file persistence (independent, do while Part B is in review)
   a. Add gopkg.in/natefinch/lumberjack.v2 to go.mod
   b. Create pkg/logging/file.go with NewFileHandler()
   c. Add --log-file flag to cmd/deploy.go
   d. Wire into logger initialization in server startup

3. Part B: Streamable HTTP migration
   a. Read mark3labs/mcp-go streamable_http.go for reference
   b. Create pkg/mcp/streamable.go with StreamableHTTPServer
   c. Implement POST /mcp (client→server messages)
   d. Implement GET /mcp (server→client SSE with Last-Event-ID)
   e. Implement DELETE /mcp (session termination)
   f. Add Origin header validation middleware
   g. Register new handlers in internal/api/api.go alongside legacy /sse
   h. Write tests for session resume, DELETE teardown, Origin validation
   i. Manual test with Claude Desktop
```

---

## Acceptance Criteria

1. **Result size limits**: A tool result of 1MB is truncated to 64KB with a `[truncated: 1048576 bytes, showing first 65536 bytes]` suffix before entering the log buffer
2. **Result size limits**: Truncation warning appears in structured logs with `tool`, `server`, `original_bytes`, and `limit_bytes` fields
3. **Result size limits**: Results under the limit pass through with zero modification and zero allocation overhead
4. **Result size limits**: Truncation is UTF-8 safe — no rune splitting
5. **Streamable HTTP**: Claude Desktop successfully connects, lists tools, and executes a tool call using the new `/mcp` endpoint
6. **Streamable HTTP**: A client that disconnects mid-stream can reconnect with `Last-Event-ID` and receive missed events
7. **Streamable HTTP**: DELETE `/mcp` with a valid `Mcp-Session-Id` returns 200 and removes the session; subsequent requests with that ID return 404
8. **Streamable HTTP**: Requests from a foreign `Origin` are rejected with 403
9. **Streamable HTTP**: Legacy clients sending GET to `/sse` receive a negotiation response directing them to POST `/mcp` first
10. **Log file**: `gridctl deploy --log-file /tmp/gridctl.log` creates and writes to the file; process restart appends to the existing file
11. **Log file**: When the log file exceeds 100MB, lumberjack rotates it automatically without process restart
12. **Log file**: If the log file path is unwritable, `gridctl deploy` fails with a human-readable error before starting the daemon

---

## References

- [MCP Transports Specification (2025-06-18)](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports)
- [Why MCP Deprecated SSE — fka.dev](https://blog.fka.dev/blog/2025-06-06-why-mcp-deprecated-sse-and-go-with-streamable-http/)
- [mark3labs/mcp-go — Streamable HTTP reference implementation](https://github.com/mark3labs/mcp-go)
- [lumberjack v2 — natefinch/lumberjack](https://github.com/natefinch/lumberjack)
- [OTel GenAI Semantic Conventions (gen_ai.tool.*)](https://opentelemetry.io/docs/specs/semconv/gen-ai/)
- [A2A v1.0.0 — a2aproject/A2A](https://github.com/a2aproject/A2A)
- Full evaluation: `prompts/gridctl/pre-tracing-readiness/feature-evaluation.md`
