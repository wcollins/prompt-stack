# Feature Implementation: Wizard Tool Picker — Phase 2 (Ephemeral Probe Endpoint)

## Context

**Project**: gridctl — an MCP (Model Context Protocol) gateway and orchestrator. Go CLI + gateway, React/TypeScript web UI.

**Prerequisite**: **Phase 1 must be merged before starting this phase.** Phase 1 shipped the `ToolsPicker` component wired to already-loaded topology tools (`useStackStore.tools`) with a manual-entry fallback. This phase adds the probe endpoint that makes the picker work for **greenfield servers** — servers not yet loaded in the topology.

Phase 1 reference: `prompts/gridctl/wizard-tool-picker-phase-1/feature-prompt.md`

**Tech stack**:
- **Backend**: Go ≥1.22. Internal API at `internal/api/*`, config types at `pkg/config/types.go`, gateway at `pkg/mcp/gateway.go`, MCP client implementations at `pkg/mcp/client_*.go`.
- **Frontend**: React 19 + TypeScript in `/web`. `ToolsPicker` already exists as of Phase 1.

**What exists after Phase 1**:
- `ToolsPicker.tsx` renders in the wizard's MCP server form Advanced section.
- Picker populates from `useStackStore.tools` for servers already in the topology.
- Manual-entry fallback is reachable within one click.
- Backend filtering primitive (`MCPServer.Tools []string` + `filterTools()`) is unchanged and still authoritative.

**What's missing** (and this phase delivers): for a server not yet loaded in the topology (new stack from scratch, or a new MCP server being added that's never run before), there is no way to see the available tool list. The user either has to know tool names by heart (manual entry), or ship `tools: []` (all exposed) and curate later.

## Evaluation Context

Key findings from the feature evaluation that shaped this prompt:

- **Probe is unavoidable for greenfield servers**: public MCP registries (official, Smithery, Glama, mcp.so) do **not** publish tool manifests. They are package catalogs. Tools are only discoverable by running the server and calling `tools/list`.
- **Ecosystem pattern is standard**: both `mcptools` CLI and MCP Inspector enumerate tools via ephemeral spawn + `initialize` + `tools/list`. This is the accepted approach.
- **Container lifecycle is the riskiest code in the project.** Every probe path (success, timeout, initialize error, panic) must deterministically tear down the spawned container/process. A leaked-container bug will be a real support burden.
- **Secret handling matters**: users will paste env vars (API keys, tokens) into the probe config. Error responses must scrub secrets.
- **Transport coverage is uneven**: probe is most valuable for container + stdio + local-process transports (~60% of server types). SSH probe needs credentials the user may not have entered. OpenAPI already has Operations Filter. External URL servers are a special case (they're usually already running).
- Full evaluation (includes competitive landscape and demand signals): `prompts/gridctl/wizard-tool-picker/feature-evaluation.md`

## Feature Description

Add a `POST /api/servers/probe` endpoint that accepts an `MCPServer` config JSON body, ephemerally spawns the server, performs the MCP `initialize` + `tools/list` handshake, tears down, and returns the tool list. Cache successful probes in memory keyed by a canonicalized config hash.

Wire the existing Phase 1 `ToolsPicker`'s empty state to include a "Discover tools" button that invokes the probe. On success, the picker populates with the discovered tools. On failure, show an inline error with a `Retry` action while keeping the manual-entry fallback visible. Never block Next/Deploy on probe failure.

## Requirements

### Functional Requirements

1. New handler `POST /api/servers/probe` in `internal/api/probe.go` (new file):
   1. Request body: an `MCPServer` config JSON (subset of the full stack schema).
   2. Response (success, 200): `{ "tools": [{ "name": string, "description": string, "inputSchema": object }], "probedAt": RFC3339 timestamp, "cached": boolean }`.
   3. Response (probe failure, 422): `{ "error": { "code": string, "message": string, "hint"?: string } }`. Structured error — never 500 on a probe failure caused by the server config or a timeout.
   4. Response (validation failure, 400): invalid config body (e.g., missing `image` for container transport).
   5. Response (internal failure, 500): reserved for unexpected panics or infrastructure failure — not for normal probe-failure modes.
2. Probe lifecycle:
   1. Reuse the MCP client construction paths from `pkg/mcp/gateway.go:766-825` — study how each transport's client is instantiated per `MCPServer` config.
   2. Use `context.WithTimeout(ctx, 10*time.Second)` — overridable via the config's `ReadyTimeout` field following existing semantics.
   3. Call the client's `Initialize()` then `ListTools()` (or equivalent method on the base client interface).
   4. Tear down the client deterministically: `defer` cleanup; if a container was spawned, ensure it is **stopped and removed** before returning. Every code path — success, timeout, initialize error, list error, panic recovery — must run cleanup.
3. Supported transports in Phase 2:
   - **container** (HTTP/SSE-based) — primary target.
   - **stdio** (container-based with stdio transport) — primary target.
   - **local process** (non-container spawn) — primary target.
   - **external URL** — probe by connecting; no spawn required. Low-risk addition.
   - **SSH**, **OpenAPI** — **out of scope for Phase 2.** Return a structured 422 `code: "unsupported_transport"` with a hint pointing to manual entry / Operations Filter.
4. In-memory cache:
   1. `sync.Map` keyed by `sha256(canonical(serverConfig))` storing `{ tools, probedAt }` tuples.
   2. TTL: 5 minutes. Expired entries evicted lazily on access.
   3. Canonicalization: sort map keys (env, build_args), include fields relevant to the server's identity (image, command, port, transport, env, build_args, source, URL, replicas), **exclude** volatile/identity-only fields (name, network).
   4. Cache hits short-circuit the spawn and return `"cached": true`.
5. Concurrency safety:
   1. Cap concurrent in-flight probes per client session at 3 (use a semaphore). Excess requests return 429 with `Retry-After`.
   2. Global cap on concurrent probes across the process: 10. Excess return 503 with `Retry-After`.
6. Secret scrubbing:
   1. Before returning any error response, traverse `message` and `hint` strings and replace values that match any key in the probed config's `env` map with `***`.
   2. Do not log raw env values. Follow existing logging conventions in `internal/api/*`.
7. Frontend integration:
   1. Add `probeServer(config: MCPServerConfig): Promise<ProbeResponse>` to `web/src/lib/api.ts` (or the equivalent API client file).
   2. In `ToolsPicker.tsx`'s empty state, render a "Discover tools" button (primary CTA) alongside the existing "Enter tool names manually" link. Show the button only for supported transports.
   3. On click: spinner (`Loader2`) appears, `aria-busy="true"` on the picker container. On success, populate the checklist. On failure, show an inline error using the existing `FieldError` component *plus* a `showToast('error', msg)`, with a `Retry` button. Manual-entry fallback remains visible.
   4. Show a "Last discovered: {relative time} ago" caption next to the "Discover tools" button when cached data exists.
   5. **Never** disable the wizard's Next or Deploy buttons based on probe state.
8. Optional debounced auto-probe: if the user opens the Advanced section and the current config has a `name` and enough fields to probe (e.g., container + image), trigger a probe silently 500ms after the section expands. If the user edits the config, cancel any in-flight probe. Phase 2 may omit auto-probe if it complicates the UX — explicit "Discover tools" is the primary path.
9. Update `docs/config-schema.md` with a brief note that tool selection can now be performed via the wizard (both from the live topology and via probe for greenfield servers).

### Non-Functional Requirements

- **Performance**: cached probes must respond in <50ms. Live probes must complete or timeout within the configured window (default 10s).
- **Reliability**: zero container leaks under any probe outcome. Leak test is mandatory (see test requirements below).
- **Accessibility**: probe spinner uses `aria-busy="true"`. Error state is reachable via keyboard; Retry button has `aria-label`.
- **Security**:
  - Probe handler must enforce the concurrency caps described above.
  - Secret scrubbing as described — no env-var values leaked in errors or logs.
  - Validation rejects malformed configs before spawning.
  - Probe must not persist state; the spawned container must not join a user's existing topology network.
- **Backward compatibility**: no changes to the stack YAML schema. Phase 1 behavior unchanged when probe is not invoked.

### Out of Scope

- SSH probe (credential-handling UX is a separate feature).
- OpenAPI probe (already covered by Operations Filter).
- Probing running stacks via the topology view (already covered by `/api/tools`).
- Persistent cache (on-disk, Redis, etc.) — in-memory only.
- Cross-session cache sharing.
- CLI-level `gridctl probe` command — potentially valuable but out of scope here.
- Post-deploy re-curation flow — separate UX track.
- Identity-bound allowlists, policy-as-code, audit logging.

## Architecture Guidance

### Recommended Approach

- Create `internal/api/probe.go` as a single handler file. Stylistic reference: `internal/api/wizard.go` or whichever nearby handler matches the project's current style.
- Extract a `probeServer(ctx, cfg) ([]Tool, error)` function that's testable in isolation (inject the client factory). The HTTP handler is a thin shell around it (parse → validate → call probeServer → serialize).
- **Reuse existing client construction**. Do not reinvent transport-specific spawn logic. The gateway already knows how to construct each client per transport in `pkg/mcp/gateway.go:766-825`. Extract or mirror that construction path for the probe. If extracting into a shared function is risky (tight coupling to gateway state), mirror it and add a test that asserts both paths stay aligned.
- For the cache, a small package `internal/probe/cache.go` with a `Cache` struct wrapping `sync.Map` + TTL keeps the handler focused. Canonicalization lives there too.
- Frontend: add a dedicated `useProbeServer` hook to encapsulate the loading/error state and expose a simple `{ probe, loading, error, data, lastProbedAt }` API to `ToolsPicker`. This keeps the picker component clean.

### Key Files to Understand

Read these first:

| File | Why |
|---|---|
| `web/src/components/wizard/steps/ToolsPicker.tsx` | The Phase 1 component you're extending. Understand its internal state machine (checklist / empty / manual-entry). |
| `pkg/mcp/gateway.go:766-825` | How each transport's client is instantiated per `MCPServer`. The probe handler mirrors this. |
| `pkg/mcp/client_base.go` | Base client interface — what `Initialize()` and `ListTools()` (or equivalents) look like. |
| `pkg/mcp/client_container.go` (and siblings `client_stdio.go`, `client_process.go`, `client_http.go`) | Transport-specific client implementations. Understand their lifecycle hooks — `Close()`, `Stop()`, container teardown. |
| `pkg/config/types.go:130-160` | `MCPServer` struct — the canonical shape for the probe config body and cache hash. |
| `internal/api/api.go` | Router registration — where `/api/servers/probe` is wired. |
| `internal/api/wizard.go` | Existing handler style reference. |
| `web/src/lib/api.ts` (or equivalent) | Frontend API client — where `probeServer()` is added. |

### Integration Points

| Where | What |
|---|---|
| `internal/api/api.go` | Register `POST /api/servers/probe`. |
| `internal/api/probe.go` | New file — the handler. |
| `internal/probe/cache.go` | New file — in-memory cache + canonicalization. |
| `web/src/lib/api.ts` | Add `probeServer(config)` client function. |
| `web/src/hooks/useProbeServer.ts` | New hook — loading/error state wrapper. |
| `web/src/components/wizard/steps/ToolsPicker.tsx` | Add "Discover tools" button to the empty state; wire to the hook. |
| `docs/config-schema.md` | Brief note under the `tools` field documentation. |

### Reusable Components

- MCP client construction from `pkg/mcp/gateway.go` — mirror, don't reinvent.
- Existing error-response conventions in `internal/api/*` handlers.
- `Loader2` from `lucide-react` — probe spinner.
- `FieldError` from `MCPServerForm.tsx` — inline error rendering.
- `showToast('error', msg)` — toast notifications.

## UX Specification

**Discovery**: Empty state of `ToolsPicker` (server not in topology) now shows a primary "Discover tools" button next to the "Enter tool names manually" link.

**Activation**:
1. User fills the MCP server form fields required for the transport (image for containers, command for local process, URL for external, etc.).
2. User expands Advanced section; `ToolsPicker` empty state is visible.
3. User clicks "Discover tools".

**Interaction flow**:
1. Click → spinner replaces button text; `aria-busy="true"` on picker.
2. Backend probes ephemerally (2–5s typical for container, <500ms for external URL cache hit).
3. Success → checklist populates with discovered tools; "Last discovered: just now" caption appears.
4. Failure → inline error with `code`, `message`, `hint`; `Retry` button; `Enter tool names manually` link.
5. User can re-probe at any time (Retry button or re-click Discover).

**Feedback**:
- Probe in progress: spinner + optional stage text ("Starting server..." / "Listing tools...").
- Cached hit: instant populate + `"Last discovered: 2m ago"` caption.
- Probe failure: red alert box with hint — e.g., `"Server failed to initialize. Hint: missing env var 'GITHUB_TOKEN'"`.

**Error states** (map to response `code`):
- `probe_timeout` → "Probe timed out after 10s. The server may need more time to start or may require environment variables. [Retry] [Enter manually]"
- `initialize_failed` → "Server failed to initialize. {hint if safe}. [Retry] [Enter manually]"
- `tools_list_failed` → "Server failed to list tools. [Retry] [Enter manually]"
- `unsupported_transport` → "Probe not supported for {transport}. [Enter manually]"
- `invalid_config` → "Config is incomplete. {hint}" (no Retry — the form needs fixing)
- `rate_limited` → "Too many probes in progress. Try again in a few seconds. [Retry]"

**Never**: disable the wizard's Next/Deploy buttons based on probe state. The picker is optional; the form is not blocked.

## Implementation Notes

### Conventions to Follow

- **Go**: mirror existing handler idioms — context handling, structured logging, error typing. Signed commits, no Claude mentions.
- **Frontend**: typed API client, hook-based state, Tailwind, no new deps.
- **Testing**: backend uses Go's `testing` — check `internal/api/*_test.go` for style. Frontend uses Vitest + Testing Library.
- **PR discipline**: one PR. Keep handler + cache + frontend wiring together so it can be reviewed as a complete capability.

### Potential Pitfalls

- **Container cleanup is non-negotiable.** Use `defer` and make sure it runs even on panic. Add a leak test that deliberately makes `Initialize()` fail and asserts the container is gone.
- **Don't share the probe client with the running gateway's network.** Spawn on an isolated network or none.
- **Don't cache probe failures.** Only cache successful tool lists. A transient network failure shouldn't poison the cache.
- **Canonicalization must be stable across reorderings.** Marshal with sorted keys or use a deterministic encoding library.
- **Concurrency caps must be enforced at both levels.** Session cap alone doesn't protect against a misbehaving test or a script.
- **Don't surface raw initialize errors unfiltered.** They may include env var values or paths. Scrub first.
- **cmdk's default filter is substring.** If `ToolsPicker` uses a custom `filter` prop (should, per Phase 1), Phase 2 doesn't change that.
- **Don't regress Phase 1.** The checklist and manual-entry modes must continue to work when probe is disabled or fails. Write a test that disables probe (e.g., via an env flag) and confirms Phase 1 behavior is unchanged.

### Suggested Build Order

1. Read all key files above. Run a local probe manually with `mcptools` or MCP Inspector against a local container to understand the handshake timing and failure modes.
2. Write the handler test first with a stubbed client factory. Cover: happy path, timeout, initialize failure, list failure, cache hit, unsupported transport, invalid config.
3. Extract/mirror the gateway's client construction into a form the probe can call. Write a leak test (spawn, fail, assert cleanup).
4. Implement the in-memory cache with canonicalization. Unit test it directly.
5. Implement the HTTP handler. Wire the route in `internal/api/api.go`.
6. Add `probeServer()` to the frontend API client and write a small unit test for the request shape.
7. Create `useProbeServer` hook. Test loading/error/data transitions.
8. Wire the "Discover tools" button into `ToolsPicker`'s empty state. Write a component test for the probe-button interaction.
9. Manual QA matrix: (a) probe a container-type server, (b) probe a stdio-type server, (c) probe a local-process server, (d) probe an external URL server, (e) verify probe failure paths for each (bad image, missing env, timeout), (f) verify cache hit is instant on re-open, (g) verify rate-limit responses under load, (h) verify Phase 1 behavior is unchanged when probe endpoint is unreachable.
10. Update `docs/config-schema.md` briefly.
11. Open PR.

## Acceptance Criteria

1. `POST /api/servers/probe` returns the enumerated tool list for a valid container-type, stdio-type, local-process-type, and external-URL-type MCP server config.
2. Probe timeout is enforced at 10s (configurable via `ReadyTimeout`); timed-out probes return 422 with `code: "probe_timeout"` and a clear `message` and `hint`.
3. Probed containers/processes are always torn down, including on timeout, initialize error, list error, and panic paths. Verified by a leak test.
4. Successful probes are cached in-memory keyed by canonicalized config hash for 5 minutes. Cache hits short-circuit the spawn and respond with `"cached": true`.
5. Canonicalization is stable across map-key reorderings (verified by a round-trip test).
6. SSH and OpenAPI transports return 422 with `code: "unsupported_transport"` and a helpful hint — no spawn attempted.
7. Probe failures never return 500 for server-config-related errors. 500 is reserved for infrastructure/unexpected panics.
8. Concurrency caps (3 per session, 10 global) enforced with 429/503 responses and `Retry-After` headers.
9. Error responses scrub env-var values from `message` and `hint`; logs do not contain raw env values.
10. Frontend `ToolsPicker` empty state shows a "Discover tools" button for supported transports. Clicking invokes the probe, shows a spinner with `aria-busy`, and populates the checklist on success.
11. Probe failures show an inline error with the error `code`, `message`, `hint`, plus a `Retry` button and keep the manual-entry fallback visible. Wizard Next/Deploy buttons are never disabled by probe state.
12. Cached results show a "Last discovered: {relative time} ago" caption.
13. Phase 1 behavior is unchanged when the probe endpoint is unavailable — verified by a frontend test that stubs the endpoint to fail.
14. Handler tests cover: happy path for each supported transport, timeout, initialize failure, list failure, cache hit, unsupported transport, invalid config, secret scrubbing, concurrency caps.
15. Frontend tests cover: probe-button interaction (loading/success/error), retry flow, unchanged manual-entry fallback.
16. `docs/config-schema.md` notes that greenfield tool discovery is supported via the wizard.
17. No new dependencies added to either `web/package.json` or `go.mod`.

## References

- Full evaluation: `prompts/gridctl/wizard-tool-picker/feature-evaluation.md`
- Phase 1 prompt: `prompts/gridctl/wizard-tool-picker-phase-1/feature-prompt.md`
- [MCP spec — tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)
- [MCP Inspector — CLI probe pattern](https://github.com/modelcontextprotocol/inspector)
- [f/mcptools — CLI tool discovery](https://github.com/f/mcptools)
- [OWASP LLM Top 10 2025 — LLM06 Excessive Agency](https://owasp.org/www-project-top-10-for-large-language-model-applications/)
- Existing gridctl example: `examples/access-control/tool-filtering.yaml`
