# Feature Implementation: Real Tokenizer (cl100k default + API opt-in)

## Context

gridctl is an MCP (Model Context Protocol) gateway and orchestrator written in Go 1.25.8. It aggregates multiple MCP servers (Docker containers, local processes, SSH tunnels, OpenAPI specs) into a single endpoint, primarily for use with Claude Desktop and Claude Code. It is currently at v0.1.0-beta.4. The project is pure Go — `CGO_ENABLED=0` is enforced in `.goreleaser.yaml` for all release builds. No CGO dependencies exist anywhere in the codebase.

**Tech stack**: Go 1.25.8, Cobra CLI, net/http for the API layer, React/TypeScript frontend (web/), GitHub Actions CI with golangci-lint + go test -race + per-package coverage thresholds.

**Key architectural pattern**: The project uses an interface-first design. Swappable implementations (counter, observer, accumulator, format converters) are wired once at startup in `pkg/controller/gateway_builder.go` via setter methods on structs. Consumers never reference concrete types.

## Evaluation Context

- Market research confirmed that Claude 3+ uses an unpublished vocabulary — cl100k_base is an approximation, not an exact match. This must be documented in the counter package for future maintainers.
- The Anthropic API has a free `POST /v1/messages/count_tokens` endpoint that returns exact counts — but it is Anthropic-specific (wrong for non-Anthropic model routing), requires network access, and must never be the silent default.
- The opt-in mechanism is `gateway.tokenizer: api` in `stack.yaml`, not a CLI flag — this is a gateway-level concern that belongs alongside `output_format` and `code_mode`.
- Do NOT add `github.com/anthropics/anthropic-sdk-go` as a dependency. The count_tokens call is a simple JSON POST; implement it with stdlib `net/http` and `encoding/json`.
- Full evaluation: `prompt-stack/prompts/gridctl/real-tokenizer-cl100k-api/feature-evaluation.md`

## Feature Description

Replace the heuristic 4-bytes/token counter in `pkg/token/counter.go` with a real BPE tokenizer as the default, and add an opt-in API-backed counter for exact Anthropic token counts. This addresses two distinct problems:

**Problem 1 (default path)**: The heuristic overcounts ASCII/code by 40-60% and undercounts CJK/non-Latin text by 100-300% in the wrong direction. Replace `HeuristicCounter` with a `TiktokenCounter` backed by `github.com/tiktoken-go/tokenizer` (pure Go, cl100k_base encoding, no CGO). Users get better numbers with no config change.

**Problem 2 (opt-in path)**: Users who need exact counts for cost analysis can set `gateway.tokenizer: api` in `stack.yaml`. This wires an `APICounter` that calls `POST /v1/messages/count_tokens` on each measurement. Explicitly documented as Anthropic-specific and network-dependent.

## Requirements

### Functional Requirements

1. Add `github.com/tiktoken-go/tokenizer` to `go.mod` as a direct dependency.
2. Implement `TiktokenCounter` in `pkg/token/counter.go` using cl100k_base encoding. It must satisfy the `Counter` interface (`Count(text string) int`). Constructor: `NewTiktokenCounter() (*TiktokenCounter, error)`.
3. Implement `APICounter` in `pkg/token/api_counter.go` using stdlib `net/http`. It must satisfy the `Counter` interface. Constructor: `NewAPICounter(apiKey string) *APICounter`. It calls `POST https://api.anthropic.com/v1/messages/count_tokens` with a minimal request body (single user message containing the text). On any network error, HTTP error, or timeout, it falls back to `TiktokenCounter` and logs a warning (do not fail the tool call).
4. Add `Tokenizer string` field to `GatewayConfig` in `pkg/config/types.go`. Valid values: `"embedded"` (default) and `"api"`. Add `TokenizerAPIKey string` for optional explicit key override (fallback: `ANTHROPIC_API_KEY` env var).
5. Update `gateway_builder.go:buildAPIServer` to read `stack.Gateway.Tokenizer` and instantiate the appropriate counter. When `"api"` is configured: validate that an API key is available at startup and return a clear error if not (do not start silently with a broken counter).
6. Extend `GET /api/status` response in `internal/api/api.go` to include the active tokenizer name (`"embedded"` or `"api"`) in the gateway info block.
7. Add a tokenizer badge to `web/src/components/layout/StatusBar.tsx` immediately adjacent to the existing token counter. The badge text is `cl100k` (embedded) or `api`. Follow the identical markup and styling pattern as the CodeMode badge (lines 88-94).
8. Update `pkg/token/counter.go` to add a package-level comment documenting that Claude 3+ uses an unpublished vocabulary and cl100k_base is therefore an approximation for Claude models specifically. Future maintainers must understand why the embedded counter is not labeled "exact."
9. Add `tokenizer` documentation to `examples/gateways/gateway-basic.yaml` with inline comments explaining the embedded vs. api trade-off.
10. All new code must have tests. The `TiktokenCounter` tests must use known reference strings with verified cl100k_base token counts (not derived from the heuristic). The `APICounter` tests must mock the HTTP endpoint.

### Non-Functional Requirements

- No CGO. `tiktoken-go/tokenizer` must be pure Go. Verify with `go build -v` that no CGO files are compiled.
- The `APICounter` must set a 5-second timeout on the HTTP client. Tool call observation already runs in a goroutine; the network call must not block indefinitely.
- `TiktokenCounter` initialization (vocab table loading) happens once at startup. The counter instance is reused for all calls — do not reload the vocab on each `Count()` call.
- The `APICounter` fallback to `TiktokenCounter` on error must log via `slog` at warn level (not error) since the metric is non-critical.
- Per-package coverage thresholds must be maintained: `pkg/mcp` requires 75%. Adding tests for the new counter implementations should not decrease any package's threshold.

### Out of Scope

- Per-server tokenizer selection (all servers share one counter at the gateway level)
- Support for encodings other than cl100k_base in Phase 1 (o200k_base can be added later by extending the `Tokenizer` config values)
- Calling the Anthropic SDK (`github.com/anthropics/anthropic-sdk-go`) — use stdlib HTTP only
- Replacing the `HeuristicCounter` struct or removing it from the package (keep it; it may be useful for testing or future comparison)
- Any changes to the `Counter` interface itself or to `CountJSON`
- Metrics Tab UI changes beyond the StatusBar badge

## Architecture Guidance

### Recommended Approach

Follow the established pattern for adding a new `Counter` implementation:

1. New implementations go in `pkg/token/`. Keep `HeuristicCounter` in `counter.go`. Add `TiktokenCounter` to `counter.go` alongside it. Add `APICounter` to a new `api_counter.go` in the same package.
2. The `GatewayConfig` field follows the same pattern as `OutputFormat` and `CodeMode`: a `string` type with a string constant for the default, no pointer, applied in `gateway_builder.go`.
3. The startup validation for `"api"` mode (API key check) belongs in `buildAPIServer()` before the counter is constructed — return an error that propagates through `Build()` to the CLI.

### Key Files to Understand

| File | Why it matters |
|---|---|
| `pkg/token/counter.go` | Current interface + implementations; add `TiktokenCounter` here |
| `pkg/controller/gateway_builder.go:351-358` | Sole instantiation point; read `stack.Gateway.Tokenizer` here |
| `pkg/config/types.go:52-83` | `GatewayConfig` struct; add `Tokenizer` and `TokenizerAPIKey` fields here |
| `pkg/metrics/observer.go` | Shows how `Counter` is used — no changes needed |
| `pkg/mcp/gateway.go:SetTokenCounter` | Shows the setter pattern — no changes needed |
| `internal/api/api.go:236-272` | `/api/status` handler; extend response struct here |
| `web/src/components/layout/StatusBar.tsx:88-94` | CodeMode badge — copy this pattern for the tokenizer badge |
| `pkg/token/counter_test.go` | Test patterns to follow for new implementations |
| `.goreleaser.yaml` | Confirms `CGO_ENABLED=0` — must not break release builds |

### Integration Points

**`pkg/config/types.go`** — Add to `GatewayConfig`:
```go
Tokenizer       string // "embedded" (default) or "api"
TokenizerAPIKey string // optional; falls back to ANTHROPIC_API_KEY env
```

**`pkg/controller/gateway_builder.go:buildAPIServer`** — Replace the hardcoded counter construction:
```go
// Wire token usage metrics
counter, err := b.buildTokenCounter()
if err != nil {
    return nil, err
}
accumulator := metrics.NewAccumulator(10000)
// ... rest unchanged
```

Add a private `buildTokenCounter()` method on `GatewayBuilder` that reads `b.stack.Gateway.Tokenizer` and returns the appropriate `token.Counter`.

**`internal/api/api.go`** — Extend the anonymous status struct to include `Tokenizer string` in the `Gateway` info. The API server needs to know the active tokenizer name; pass it via a setter (e.g., `server.SetTokenizerName(name string)`) rather than reaching into the gateway.

**`web/src/types/index.ts`** — Extend the `GatewayInfo` or equivalent status type to include `tokenizer?: string`.

### Reusable Components

- `token.CountJSON` — unchanged; works with any `Counter`
- The StatusBar CodeMode badge markup — copy the exact JSX pattern
- `pkg/config/types.go:SetDefaults()` — add default for `Tokenizer` here: `"embedded"`

## UX Specification

**Discovery**: The `tokenizer` field appears documented in `examples/gateways/gateway-basic.yaml` with a comment block. Users discover it the same way they discover `output_format`.

**Activation (embedded, default)**: Zero config. On upgrade, users see the StatusBar badge change from nothing to `cl100k`. Token numbers improve silently.

**Activation (api opt-in)**: User adds `gateway.tokenizer: api` to their `stack.yaml`. If `ANTHROPIC_API_KEY` is not set and `tokenizer_api_key` is not specified, `gridctl up` exits with:
```
error: gateway.tokenizer is "api" but no API key is configured.
Set ANTHROPIC_API_KEY or add tokenizer_api_key to stack.yaml.
```

**StatusBar badge**: Appears immediately right of the token counter display. Text: `cl100k` (embedded) or `api` (API mode). Style matches the CodeMode badge — small, muted, uses the same badge component.

**Error states (api mode)**: When the `count_tokens` API call fails (network error, rate limit, auth error), the `APICounter` logs at warn level, increments an internal error counter, and returns the `TiktokenCounter` result for that call. The metrics continue to flow. The user is not alerted on every failure — the warn log is sufficient. No UI indicator for API counter degradation in Phase 1.

## Implementation Notes

### Conventions to Follow

- Conventional commits: `feat: replace heuristic token counter with cl100k tokenizer` for Phase 1, `feat: add opt-in api tokenizer mode` for Phase 2
- Error wrapping: `fmt.Errorf("token: %w", err)` — never raw errors from the token package
- `slog` for logging, not `log` or `fmt.Printf`
- Test files: `_test.go` suffix, same package (not `_test` package), table-driven with `t.Run`
- The `tiktoken-go/tokenizer` constructor returns an error; handle it at startup, not per-call

### Potential Pitfalls

1. **`tiktoken-go` vocab loading is lazy by default** — some implementations load the vocabulary on first `Encode` call, not at construction time. Force eager loading in the constructor by encoding a test string (e.g., `"hello"`) and discarding the result. This surfaces any vocab load failure at startup, not mid-request.
2. **`APICounter` request body shape** — the `count_tokens` endpoint expects a `messages` array with `role`/`content` fields and a `model` field. Use a minimal hardcoded model (`claude-3-5-haiku-20241022`) for the request since the endpoint is used purely for token counting, not inference. The response is `{"input_tokens": N}`.
3. **`APICounter` for tool arguments** — `CountJSON` marshals arguments to JSON before calling `Count`. The resulting JSON string is passed to `APICounter.Count` which wraps it in a user message. This is an approximation (the real context includes tool definitions, system prompt, etc.) but it is consistently better than the heuristic for structured JSON payloads.
4. **Coverage threshold** — `pkg/mcp` requires 75%. Adding new code in `pkg/token` doesn't affect `pkg/mcp` coverage directly, but verify with `go test -coverprofile=coverage.out ./...` and `scripts/check-coverage.sh` before submitting.
5. **Binary size** — `tiktoken-go` embeds the cl100k_base vocabulary (~2.5MB compressed). The release binary will grow by ~4MB. This is acceptable but worth noting in the PR description.

### Suggested Build Order

1. Add `github.com/tiktoken-go/tokenizer` to `go.mod` (`go get github.com/tiktoken-go/tokenizer`)
2. Implement and test `TiktokenCounter` in `pkg/token/counter.go`
3. Add `Tokenizer` / `TokenizerAPIKey` to `GatewayConfig` in `pkg/config/types.go` with default `"embedded"` in `SetDefaults()`
4. Update `gateway_builder.go:buildAPIServer` to use a `buildTokenCounter()` method; make `"embedded"` produce `TiktokenCounter`
5. Extend `/api/status` response and pass tokenizer name through to the API server
6. Add StatusBar badge in the frontend (`StatusBar.tsx`)
7. Run full test suite + coverage check
8. Implement `APICounter` in `pkg/token/api_counter.go` with mock tests
9. Wire `"api"` case in `buildTokenCounter()`; add startup validation
10. Update `examples/gateways/gateway-basic.yaml` with documented `tokenizer` field
11. Add package-level comment to `counter.go` about Claude 3+ vocabulary being unpublished

## Acceptance Criteria

1. `go build ./...` succeeds with no CGO compilation (`CGO_ENABLED=0 go build ./...`).
2. `go test -race ./pkg/token/...` passes with tests covering `TiktokenCounter.Count` against at least 5 known cl100k_base reference strings (not derived from the heuristic).
3. `go test -race ./pkg/token/...` passes with tests for `APICounter` using a mock HTTP server.
4. Running `gridctl up` with a default stack (no `gateway.tokenizer` field) uses `TiktokenCounter`. The StatusBar shows `cl100k` badge.
5. Running `gridctl up` with `gateway.tokenizer: api` and `ANTHROPIC_API_KEY` set uses `APICounter`.
6. Running `gridctl up` with `gateway.tokenizer: api` and no API key returns a clear startup error and exits non-zero.
7. When `APICounter` HTTP call fails (tested with mock returning 500), the counter falls back to `TiktokenCounter` without crashing, and a warn-level log entry is emitted.
8. `GET /api/status` response includes `"tokenizer": "embedded"` or `"tokenizer": "api"` in the gateway block.
9. `scripts/check-coverage.sh` passes — no package drops below its threshold.
10. `pkg/token/counter.go` contains a package-level comment documenting that Claude 3+ vocabulary is unpublished and cl100k_base is therefore approximate for Claude models.
11. `examples/gateways/gateway-basic.yaml` documents the `gateway.tokenizer` field with inline comments.

## References

- [tiktoken-go/tokenizer](https://github.com/tiktoken-go/tokenizer)
- [Anthropic count_tokens endpoint](https://platform.claude.com/docs/en/build-with-claude/token-counting)
- [Anthropic tokenizer deprecation notice (Claude 3+ vocabulary is unpublished)](https://github.com/anthropics/anthropic-tokenizer-typescript)
- [cl100k_base accuracy benchmarks](https://llm-calculator.com/blog/tokenization-performance-benchmark/)
- [CJK token ratio analysis](https://tonybaloney.github.io/posts/cjk-chinese-japanese-korean-llm-ai-best-practices.html)
