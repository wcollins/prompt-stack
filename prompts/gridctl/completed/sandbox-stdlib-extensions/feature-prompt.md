# Feature Implementation: Code Mode Sandbox Stdlib Extensions

## Context

gridctl is a Go-based MCP (Model Context Protocol) gateway and orchestration runtime. Its "code mode" feature exposes a sandboxed JavaScript scripting environment (using the `goja` VM) that allows AI agents and developers to write orchestration code that fans out across multiple MCP tool calls. The sandbox is defined in `pkg/mcp/codemode_sandbox.go`.

**Tech stack**: Go 1.22+, goja (`github.com/dop251/goja`) for JS execution, esbuild for ES2015 transpilation, `net/http` for HTTP clients, `crypto/rand` for cryptography, `log/slog` for structured logging.

**Current sandbox surface**: Only `console.{log,warn,error}` and `mcp.callTool(serverName, toolName, args)` are exposed. The execution model is a synchronous `vm.RunString()` with a 30-second timeout enforced via `ctx.Done() → vm.Interrupt()`.

## Evaluation Context

- **Market insight**: All V8-based runtimes (Cloudflare Workers, Deno Deploy) expose all three APIs natively. goja-based peers (n8n, Temporal, k6) deliberately omit fetch and setTimeout, routing HTTP/async through typed Go abstractions instead. gridctl can differentiate within the goja ecosystem by adopting the k6 event loop pattern for timers and a first-party SSRF-safe fetch binding.
- **Critical constraint**: goja has no built-in event loop. `setTimeout` is meaningless without `goja_nodejs/eventloop`. This requires changing from `vm.RunString()` to `loop.Run()` — a real but well-established migration (k6 uses this exact pattern).
- **Security decision**: Drop "routes through gateway auth context" for fetch. The gateway's auth is for validating *inbound* callers, not for injecting credentials into arbitrary outbound requests. Fetch should be a clean `net/http` client binding with SSRF mitigations.
- **Risk mitigation baked in**: `setInterval/clearInterval` are explicitly out of scope due to goroutine leak risk. `sleep(ms)` is added as a convenience wrapper.
- Full evaluation: `prompts/gridctl/sandbox-stdlib-extensions/feature-evaluation.md`

## Feature Description

Extend the goja sandbox with three stdlib APIs, implemented in three phases of increasing complexity:

**Phase 1 — `crypto.randomUUID()`**: Inject a `crypto` global with `randomUUID()` backed by Go's `crypto/rand`. No execution model changes. ~5 lines of Go.

**Phase 2 — `setTimeout/clearTimeout` + `sleep(ms)`**: Adopt `goja_nodejs/eventloop` to give the sandbox a real event loop. Replace `vm.RunString()` with `loop.Run()`. Add `sleep(ms)` as a top-level convenience function (returns a Promise that resolves after the delay). Explicitly omit `setInterval/clearInterval`.

**Phase 3 — `fetch(url, options)`**: Implement a sandboxed `fetch()` binding backed by a `net/http.Client` with SSRF mitigations enforced at the dial level: HTTPS-only by default, RFC 1918 + loopback IP blocklist, 1MB response size cap, per-request timeout (10s default), structured audit logging. Returns a Response-like object with `.json()`, `.text()`, and `.ok`/`.status` fields.

## Requirements

### Functional Requirements

**Phase 1: crypto.randomUUID()**

1. A `crypto` global object must be available in the sandbox with a `randomUUID()` method.
2. `crypto.randomUUID()` must return a valid RFC 4122 version 4 UUID string (e.g., `"550e8400-e29b-41d4-a716-446655440000"`).
3. Each call must return a cryptographically random UUID; sequential calls must return different values.
4. The `crypto` object must not expose any other Web Crypto API methods in Phase 1.

**Phase 2: setTimeout/clearTimeout + sleep()**

5. `setTimeout(fn, delayMs)` must schedule `fn` to be called after approximately `delayMs` milliseconds and return a numeric timer ID.
6. `clearTimeout(id)` must cancel a pending timer. Calling with an invalid or already-fired ID must be a no-op.
7. A `sleep(ms)` top-level function must be available that returns a Promise resolving after `ms` milliseconds. Idiomatic usage: `await sleep(1000)`.
8. `async/await` syntax must work correctly (microtask queue must drain between event loop ticks).
9. `setInterval` and `clearInterval` must NOT be exposed (out of scope, goroutine leak risk).
10. The existing 30-second sandbox timeout must continue to interrupt execution if timers cause the code to run beyond the deadline.
11. Timer goroutines must not leak after the sandbox exits (cancelled timers, context cancellation on timeout).

**Phase 3: fetch()**

12. A `fetch(url, options)` global function must be available. `url` is a string. `options` is an optional object supporting: `method` (default `"GET"`), `headers` (object), `body` (string).
13. `fetch()` must return a Promise that resolves to a Response object with: `.ok` (bool), `.status` (int), `.headers` (object), `.text()` (Promise<string>), `.json()` (Promise<any>).
14. HTTPS-only by default: URLs with `http://` scheme must be rejected with a descriptive error unless an explicit operator-level config option enables plain HTTP.
15. Private network addresses must be blocked: loopback (`127.x`, `::1`), RFC 1918 (`10.x`, `172.16–31.x`, `192.168.x`), link-local (`169.254.x`, `fe80::/10`), and multicast must all be rejected. This check must be performed at the TCP dial level (not DNS level) to prevent DNS rebinding attacks.
16. Response body must be capped at 1MB by default (configurable). Responses exceeding the cap must return an error.
17. Per-request timeout must default to 10 seconds, independent of the overall sandbox timeout.
18. All outbound fetch calls must be logged with structured slog fields: `url`, `method`, `status`, `duration`, and a sandbox execution identifier.
19. Redirects must re-validate the redirect target against the blocklist before following.
20. Credentials (Authorization headers, cookies) from the gateway's inbound request context must NOT be automatically injected into fetch calls.

### Non-Functional Requirements

- No new external dependencies for Phase 1 (only `crypto/rand` from stdlib).
- Phase 2 adds exactly one dependency: `github.com/dop251/goja_nodejs` (maintained by goja's author).
- Phase 3 uses only Go stdlib (`net/http`, `net`, `io`, `context`).
- All new code must have unit tests covering: happy path, error path, and security boundary (for fetch: SSRF attempt, oversized response, timeout).
- The event loop adoption (Phase 2) must not regress existing tests in `codemode_test.go`.

### Out of Scope

- `setInterval` / `clearInterval` — defer indefinitely due to goroutine leak risk
- Promises wrapping `mcp.callTool()` (making callTool async) — future work after event loop is proven stable
- Per-URL auth credential injection — each fetch call is unauthenticated by default; callers must explicitly set `Authorization` headers if needed
- WebSocket, SSE, or streaming fetch responses
- `crypto.subtle` or any Web Crypto API beyond `randomUUID()`
- Request body types other than string (Blob, FormData, etc.)

## Architecture Guidance

### Recommended Approach

**Phase 1** follows the existing pattern exactly: create a new `goja.Object`, set `randomUUID` as a native function, and `vm.Set("crypto", cryptoObj)` after the `mcp` object setup in `Sandbox.Execute()`.

**Phase 2** replaces the `vm.RunString()` call with an event loop. The `goja_nodejs/eventloop` package provides `eventloop.New(vm)` and `loop.Run(fn func(*goja.Runtime))`. Inside `fn`, call `vm.RunString(transpiled)`. The loop drains all pending timers and promises before `loop.Run()` returns. The existing context watcher goroutine continues to work: `vm.Interrupt()` from the watcher goroutine causes `loop.Run()` to return with an `*goja.InterruptedError`.

Inject setTimeout/clearTimeout into the loop using `loop.SetTimeout()` / `loop.ClearTimeout()` from `goja_nodejs/eventloop`. For the `sleep()` global, inject a native function that calls `loop.SetTimeout()` and wraps it in a goja Promise (use `vm.NewPromise()` from goja).

**Phase 3** implements a `sandboxedFetch` struct with its own `*http.Client`. The client must use a custom `net.Dialer` that validates the resolved IP against the blocklist *after* DNS resolution but *before* completing the TCP dial. This prevents DNS rebinding attacks (where the IP returned by DNS lookup differs from the IP used for connection):

```go
dialer := &net.Dialer{}
transport := &http.Transport{
    DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
        host, port, _ := net.SplitHostPort(addr)
        ips, err := net.DefaultResolver.LookupHost(ctx, host)
        // validate each ip against blocklist before dialing
        return dialer.DialContext(ctx, network, net.JoinHostPort(ips[0], port))
    },
}
```

The fetch native function must be registered into the event loop via `loop.RunOnLoop()` pattern to safely call back into the goja runtime after the Go HTTP request completes.

### Key Files to Understand

| File | Why |
|------|-----|
| `pkg/mcp/codemode_sandbox.go` | Core implementation — all changes happen here |
| `pkg/mcp/codemode_test.go` | Test patterns — mockToolCaller, TestSandbox_Timeout pattern |
| `pkg/mcp/codemode_transpile.go` | ES2015 constraint — async/await requires transpilation to work |
| `pkg/mcp/types.go` | DefaultRequestTimeout (30s), ToolCaller interface |
| `pkg/mcp/openapi_client.go` | Reference for response size cap (`io.LimitReader`) and content-type validation |
| `pkg/mcp/handler.go` | Shows context flow from HTTP handler into sandbox |
| `go.mod` | Add `goja_nodejs` in Phase 2 |

### Integration Points

- **`Sandbox.Execute()`** (`codemode_sandbox.go:40`): Primary change site. Phase 1: add crypto object after line 144. Phase 2: replace `vm.RunString()` at line 147 with `loop.Run()`. Phase 3: inject fetch binding with access to `loop` for `RunOnLoop()` callbacks.
- **`Sandbox` struct** (`codemode_sandbox.go:20`): Add a `fetchConfig *FetchConfig` field for Phase 3 URL controls. Add `NewSandboxWithFetch(timeout, fetchConfig)` constructor or extend the existing one.
- **`codemode_test.go`**: Add `TestSandbox_CryptoRandomUUID`, `TestSandbox_Sleep`, `TestSandbox_SetTimeout`, `TestSandbox_Fetch`, `TestSandbox_FetchSSRFBlocked`, `TestSandbox_FetchOversizedResponse`.

### Reusable Components

- `vm.NewGoError(err)` → panic — use for all error propagation in native functions (existing pattern)
- `vm.ToValue(v)` — marshal Go values to JS (existing pattern)
- `io.LimitReader(resp.Body, maxBytes)` — copy from openapi_client.go for response size cap
- Timeout watcher goroutine pattern (lines 58–61 in sandbox.go) — reuse unchanged for Phase 2

## UX Specification

### Discovery

The new globals are documented in the `ExecuteTool` MCP tool description (`pkg/mcp/codemode_tools.go`). Update the description to list all available globals. AI agents using code mode will see this in the tool schema.

### Activation

```js
// Phase 1 — crypto
const id = crypto.randomUUID();

// Phase 2 — sleep (primary use case)
await sleep(2000);  // 2-second pause

// Phase 2 — setTimeout (advanced)
const tid = setTimeout(() => console.log("fired"), 500);
clearTimeout(tid);

// Phase 3 — fetch
const resp = await fetch("https://api.example.com/v1/status");
if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
const data = await resp.json();
```

### Interaction

Polling loop with sleep:
```js
const jobId = crypto.randomUUID();
mcp.callTool("jobs", "create", { id: jobId, task: "process" });

for (let attempt = 0; attempt < 10; attempt++) {
  await sleep(2000);
  const status = mcp.callTool("jobs", "get_status", { id: jobId });
  if (status.complete) return status.result;
}
throw new Error("job did not complete within timeout");
```

### Feedback

- `crypto.randomUUID()` — returns string synchronously, no feedback needed
- `sleep(ms)` — silent delay; users see the sandbox takes longer
- `fetch()` errors must be descriptive: `"fetch blocked: private network addresses are not allowed (resolved 192.168.1.1)"`, `"fetch timeout: request to https://api.example.com exceeded 10s"`, `"fetch error: response body exceeded 1MB limit"`

### Error States

| Error | Message |
|-------|---------|
| SSRF blocked | `fetch blocked: private network addresses are not allowed` |
| Non-HTTPS | `fetch blocked: only HTTPS URLs are allowed` |
| Response too large | `fetch error: response body exceeded 1MB limit` |
| Per-request timeout | `fetch timeout: request exceeded 10s` |
| Network error | `fetch error: <underlying Go error>` |
| setTimeout callback throws | Propagated as JS exception, interrupts sandbox |

## Implementation Notes

### Conventions to Follow

- Native function signature: `func(call goja.FunctionCall) goja.Value` — always
- Error propagation: `panic(vm.NewGoError(err))` — matches existing mcp.callTool pattern
- Value marshaling: `vm.ToValue(v)` for Go → JS, `call.Arguments[n].Export()` for JS → Go
- Logging: use `slog.Default()` with structured fields — check codemode.go for field naming conventions
- Test mocking: use `mockToolCaller` pattern from codemode_test.go; fetch tests use `httptest.NewServer`
- Commit type: `feat` (new functionality)

### Potential Pitfalls

1. **goja single-goroutine constraint**: Never call into `vm.*` methods from a goroutine other than the one running the event loop. For fetch, use `loop.RunOnLoop()` to schedule the callback after the HTTP response arrives.

2. **DNS rebinding in fetch**: Do NOT validate the IP at DNS lookup time. Validate at dial time (after `net.LookupHost`). The `DialContext` override in the custom transport is the correct place.

3. **Sleep + existing timeout**: If `sleep(29000)` is called in a 30-second sandbox, the watcher goroutine fires `vm.Interrupt()` just before the sleep resolves. The event loop returns with `*goja.InterruptedError` — existing error handling in `Execute()` catches this correctly.

4. **Promise resolution requires microtask draining**: `loop.Run()` from `goja_nodejs/eventloop` drains microtasks between each macro-task tick. Do not use a raw goroutine + channel approach; it won't drain microtasks correctly.

5. **goja_nodejs/eventloop goroutine leak**: If a timer goroutine is blocked trying to send to the loop's job channel after the loop has stopped, it will hang. Mitigation: the event loop's `Stop()` method closes the job channel — ensure the timeout watcher calls `loop.Stop()` or that all timer goroutines select on both the job channel and a done channel.

6. **Fetch redirect chain**: Go's default `http.Client` follows up to 10 redirects. For the sandboxed client, set a custom `CheckRedirect` function that re-validates each redirect target's IP against the blocklist.

7. **`vm.RunString()` vs `loop.Run()`**: Phase 2 changes the execution entry point. The transpiled code string must be passed inside the `loop.Run(fn)` callback: `loop.Run(func(vm *goja.Runtime) { vm.RunString(transpiled) })`. Return value capture requires a variable in the closure.

### Suggested Build Order

1. **Start with Phase 1** (`crypto.randomUUID()`): Simplest change, validates the native function injection pattern, produces a passing test suite.
2. **Write the event loop integration (Phase 2)**: Run existing tests first to establish baseline. Migrate `vm.RunString()` to `loop.Run()`, run existing tests again — they should all pass unchanged. Then add setTimeout/sleep.
3. **Phase 3 (fetch)**: Write the `sandboxedFetch` struct and its IP blocklist logic first. Test with `httptest.NewServer` pointing at 127.0.0.1 to verify SSRF blocking. Then wire into the event loop via `RunOnLoop()`.
4. **Update `ExecuteTool` description** last, after all three phases are implemented, to document the full available surface.

## Acceptance Criteria

1. `crypto.randomUUID()` returns a valid RFC 4122 v4 UUID string in the format `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx`.
2. Two sequential calls to `crypto.randomUUID()` return different values.
3. `await sleep(100)` resolves after approximately 100ms (within ±50ms tolerance in tests).
4. `setTimeout(fn, 0)` schedules `fn` to run after the current synchronous code completes (not during).
5. `clearTimeout(id)` prevents the scheduled function from running.
6. `setInterval` is not defined in the sandbox (accessing it returns `undefined` or throws ReferenceError).
7. `await fetch("https://httpbin.org/get")` (or equivalent test server) returns a response object with `.ok === true` and `.json()` returning valid parsed JSON.
8. `await fetch("http://127.0.0.1:1234")` throws an error containing "private network addresses are not allowed".
9. `await fetch("http://192.168.0.1")` throws an error containing "private network addresses are not allowed".
10. `await fetch("http://example.com")` throws an error containing "only HTTPS URLs are allowed" (when HTTPS-only mode is active).
11. A fetch response body exceeding 1MB causes an error containing "exceeded 1MB limit".
12. All outbound fetch calls are logged with at minimum: `url`, `method`, `status`, `duration` fields.
13. All existing tests in `codemode_test.go` pass without modification after the event loop migration.
14. The sandbox timeout (30s default) continues to interrupt execution when timers cause the code to run past the deadline.
15. No goroutine leaks: running `go test -race ./pkg/mcp/...` passes cleanly.

## References

- [goja GitHub](https://github.com/dop251/goja)
- [goja_nodejs eventloop source](https://github.com/dop251/goja_nodejs/blob/master/eventloop/eventloop.go)
- [goja_nodejs eventloop pkg.go.dev](https://pkg.go.dev/github.com/dop251/goja_nodejs/eventloop)
- [goja_nodejs interval leak issue #81](https://github.com/dop251/goja_nodejs/issues/81)
- [k6 eventloop pkg](https://pkg.go.dev/go.k6.io/k6/js/eventloop) — production reference for goja+eventloop
- [k6 event loop PR #2228](https://github.com/grafana/k6/pull/2228)
- [MDN crypto.randomUUID](https://developer.mozilla.org/en-US/docs/Web/API/Crypto/randomUUID)
- [OWASP SSRF Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html)
- [CVE-2024-29415 — IP denylist bypass](https://www.herodevs.com/vulnerability-directory/cve-2024-29415)
- [Go net.Dialer DialContext](https://pkg.go.dev/net#Dialer.DialContext) — use for post-DNS IP validation
- [Go io.LimitReader](https://pkg.go.dev/io#LimitReader) — response body size cap
- [Go net/http CheckRedirect](https://pkg.go.dev/net/http#Client) — redirect chain re-validation
