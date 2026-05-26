# Feature Implementation: Context Auto-Injector

## Context

**gridctl** is an MCP (Model Context Protocol) gateway/orchestrator written in Go (module `github.com/gridctl/gridctl`, go 1.26), with a React/TypeScript web console (`web/`, Vite SPA, embedded into the binary via `cmd/gridctl/embed.go`). It defines a "stack" of MCP servers in a YAML file, spins them up, and exposes them through a single namespaced MCP gateway. It runs as a daemonizing `serve` process and ships a built-in skill library served as MCP prompts. Current version: **v0.1.0-beta.10**. The project is governed by a CONSTITUTION.md (notably Article VIII semver, Article IX stack.yaml backward-compatibility, Article XII secure defaults) and enforces per-package test coverage gates (`scripts/check-coverage.sh`: pkg/mcp ≥75%, pkg/config ≥70%, pkg/controller ≥50%) — new code must clear them or CI fails.

This feature gives MCP agents **persistent, cross-client context** that the gateway auto-injects into prompts, so context survives switching between clients (Claude Code ↔ Claude Desktop) and survives rebuilding throwaway stacks.

## Evaluation Context

This prompt is the **scoped** outcome of a feature evaluation (full doc: `prompts/gridctl/context-auto-injector/feature-evaluation.md`). The original plan (`proto/context.md`, "Decoupled Context Sessions") was deliberately scoped down because:

- **The pattern is table-stakes, not innovative.** "Agent self-edits a markdown memory file + KV, injected into context" is exactly what Anthropic's own tools do (CLAUDE.md, the Claude memory tool, Claude Code auto-memory). gridctl's only defensible wedge is **zero-config convenience + governance**, not retrieval capability — so the build leans into those, not into a custom memory engine.
- **The variable half is redundant.** gridctl already has a mature variable store (`pkg/vault`: typed, encrypted, grouped into "Sets", REST+CLI+UI). The original `state.json` is a strictly weaker copy. **Reuse the variable store's Sets for structured session variables; do not build a new key-value engine.**
- **The value is concentrated in one piece: the gateway-side auto-injection glue.** The `{{name}}` substitution it needs already exists in `HandlePromptsGet`. Most of the original plan was plumbing or duplication.
- **The project just removed its agent-runtime surface to narrow scope.** This feature must read as *gateway infrastructure* (shared context across the fan-out), not "gridctl is becoming an agent." Keep it minimal and on-mission.
- **Risk mitigations baked in below:** size-bounded injection (context-bloat), provenance + treat-LLM-writes-as-untrusted + sanitize-before-inject (memory-poisoning is a documented attack), TTL + validation-against-current-reality (staleness), inner-only locking + lazy-load (the gateway has no stack awareness and runs injection on a hot, locked path).
- **Do NOT integrate mem0 or any vector DB** — mem0 has no Go SDK and needs a 3-container stack; antithetical to a single-binary CLI.

## Feature Description

Add a **Context Auto-Injector**: a named "context session" is a flat markdown findings log on disk that the gateway automatically injects (size-bounded) into the MCP prompt path for the bound stack, alongside values from a reused variable-store Set. An agent can append findings via one built-in tool. The result: prior discoveries are curated, persistent, and surfaced to any connected client with zero manual effort, with a governance layer (provenance, TTL, audit, validation) that the commodity memory MCP servers lack.

**What it does:** stores a per-session `findings.md`; binds a session to a stack via `session_binding:`; on `prompts/get`, the gateway injects the bound session's bounded findings + Set values into the prompt; a built-in `save_finding` tool lets the agent write; a UI panel shows/prunes what's stored and previews exactly what's being injected.

**Problem it solves:** cross-client / cross-rebuild context loss — the "I researched for 2 hours in Claude Code and lost it all in Claude Desktop" pain.

**Who benefits:** every gridctl user driving MCP tools from more than one client, or rebuilding ephemeral stacks.

## Requirements

### Functional Requirements

1. **Session store** — a new package (named to avoid collisions; **do not** use `pkg/context`, which shadows stdlib, or "Session" alone, which collides with `pkg/mcp/session.go`; prefer e.g. `pkg/agentmem` with a "context session" domain term). It manages sessions under `~/.gridctl/sessions/` via `pkg/state` helpers (add `SessionsDir()`/`SessionPath(name)`). Each session = a flat `<name>.md` findings file plus lightweight metadata (created_at, last_active, optional `set:` naming a variable-store Set). Model the store on `pkg/pins/store.go` (in-memory `sync.RWMutex` + `state.WithLock` flock, version field, corrupt-file tolerance, `NewWithPath` test constructor). Keep this store's lock strictly **inner** relative to the gateway's `g.mu`.
2. **Stack binding** — add an optional `session_binding: <name>` (or nested block) field to the `Stack` struct in `pkg/config/types.go`. Backward-compatible (Article IX): absence = no injection. Update `SetDefaults()` if needed.
3. **Bounded auto-injection** — extend the gateway prompt path (`HandlePromptsGet`, and/or `buildInstructions()` for the `initialize` Instructions) so that, when a session is bound, it resolves and injects the session's findings markdown + the bound Set's values. **Enforce a hard size cap** (mirror Claude Code's 200-line / 25 KB MEMORY.md cap; make it configurable). Content beyond the cap is excluded (and marked, not silently dropped). Injection must:
   - resolve `{{session.findings}}` and `{{session.<var>}}` placeholders, reusing the existing substitution loop semantics (client-passed args take precedence over injected values);
   - **lazy-load / cache** session data — no disk read on every request;
   - handle the stackless / no-bound-session / empty-server case gracefully (no silent failures).
4. **Gateway session resolution** — the `Gateway` struct currently holds **no stack awareness** (`NewGateway()` takes nothing). Introduce a `SessionResolver` interface (or equivalent) injected into the gateway that, given the active stack, returns the bound session's injectable content. Wire it where the gateway is built (`pkg/controller/gateway_builder.go`) and refresh it on reload (`pkg/reload`).
5. **Built-in `save_finding` tool** — a gateway-native tool (modeled on the code-mode meta-tool injection in `pkg/mcp/codemode_tools.go` / `codemode.go`: synthetic `Tool` in `HandleToolsList`, dispatched in `HandleToolsCall` before downstream routing) that appends a finding to the active session's `findings.md`. Tag each appended entry with **provenance = LLM** and a timestamp. **Sanitize/escape** the text so it cannot inject gateway-level instructions or break the prompt structure. (`recall`/read-back tool is optional for v1; the auto-injection already surfaces findings.)
6. **Governance**:
   - **Provenance** — every finding records who wrote it (user vs LLM).
   - **TTL / expiry** — each entry has an age; support an auto-prune window (default ~28 days, per Copilot precedent) and a soft "archive" state.
   - **Validation-against-current-reality** — when injecting, flag/suppress findings that reference MCP servers/tools no longer present in the running stack.
   - **Audit trail** — log every write / edit / expire / inject with timestamp + actor (this doubles as poisoning detection).
7. **REST API** — a minimal set on `internal/api/api.go` (clone `internal/api/vault.go` patterns: nil-store guards, `writeJSON`/`writeJSONError`, validation, partial-update PUT, 201/204): list sessions, read a session (findings + resolved Set values + metadata), edit/prune findings, and bind/unbind a session to the running stack. **Do not** build the full original five-endpoint suite; build only what the UI panel needs.
8. **Web UI (minimal — panel only, no workspace tab)**:
   - **Header binding badge** in `web/src/components/layout/Header.tsx` (`◆ session: <name>` beside the stack-name pill; absent when unbound; amber when items are expiring). Clicking it opens the panel.
   - **Session panel** cloned from `web/src/components/vault/VaultPanel.tsx` (right-docked, resizable, searchable), toggled via a `showSession`/`toggleSession` state mirroring `showVault`/`toggleVault` in `web/src/stores/useUIStore.ts`. Rows show the finding text + a **provenance badge** (user ✎ / LLM ⚙) + age/expiry chip + an "injected / over-cap / expired" status chip. Per-entry delete + bulk delete + filter-by-provenance/age. A live **size/line-cap meter** ("142 / 200 lines · 18 / 25 KB").
   - **Injection preview** — a toggle that renders the exact bounded payload the gateway will inject, reusing the read-only annotated `web/src/components/spec/SpecTab.tsx` viewer idiom (there is **no** existing MCP-prompts UI to extend).
   - **Binding affordance** in the wizard — a "Session" accordion section in `web/src/components/wizard/steps/StackForm.tsx` cloned from the "Secrets" section, with a `SessionSelector` cloned from `web/src/components/wizard/VaultSetSelector.tsx`, writing `session_binding:` into the generated YAML.
   - **Explicitly do NOT** add a `WORKSPACE_CONFIG` entry / ⌘5 tab in `web/src/types/workspace.ts`, and do NOT build a session-gallery page.

### Non-Functional Requirements

- **Performance**: injection adds no per-request disk I/O (lazy-load + cache, invalidated on write/reload). Injection latency negligible vs. existing in-memory substitution.
- **Concurrency**: daemon + API + gateway all write `~/.gridctl/`; use the same `sync.RWMutex` (in-memory) + `state.WithLock` (flock) discipline as `pkg/pins`/`pkg/vault`. Session-store lock strictly inner relative to `g.mu` to avoid lock-ordering deadlocks.
- **Security**: sanitize/escape all LLM-written content before storing/injecting; treat LLM-authored findings as untrusted; never let injected content escape into gateway-level instruction context.
- **Backward compatibility**: stacks without `session_binding:` behave exactly as today. Article IX compliant.
- **Coverage**: meet the enforced gates (pkg/mcp ≥75%, pkg/config ≥70%, pkg/controller ≥50%). Table-driven tests using `t.TempDir()` + `httptest`, no mocking framework (follow `internal/api/vault_test.go`).
- **Token budget**: the size cap is the core safety property — the feature is self-defeating if it blows the context budget it claims to protect.

### Out of Scope

- A `state.json` / bespoke key-value store (reuse the variable store's Sets).
- A `pkg/context` subsystem of the original scale, the `set_session_var` tool, semantic/vector/graph recall, and any external memory service (mem0 etc.).
- A ⌘5 Context workspace and a session-gallery management page.
- Encoding memory as a new MCP protocol primitive (conflicts with MCP's stateless direction; inject via existing `prompts` + `tools`).

## Architecture Guidance

### Recommended Approach

Compose existing primitives; add the one net-new seam (gateway session resolution + bounded injection). Treat the build as three layers: (1) a small flat-file session store reusing `pkg/state` + the `pkg/pins` store shape; (2) the variable-store Set as the structured-variable backend (zero new storage); (3) the injection glue in the gateway behind a `SessionResolver` interface so the gateway stays decoupled from `config`.

### Key Files to Understand

| File | Why |
|------|-----|
| `proto/context.md` | The original maximal plan — read for intent, but build the scoped version here. (Gitignored local doc.) |
| `pkg/mcp/gateway.go` (~119 struct, ~1146 `buildInstructions`, ~1222 `HandleToolsList`, ~1252 `HandleToolsCall`/`IsMetaTool`, ~1592 `HandlePromptsGet`) | The injection points + the existing `{{}}` substitution loop + the built-in-tool dispatch seam. |
| `pkg/vault/store.go` + `types.go` | The variable store + Sets to reuse for session variables; also a storage/atomic-write reference. |
| `pkg/pins/store.go` | Best template for the session store (RWMutex + flock, version, corruption tolerance, `NewWithPath`). |
| `pkg/state/state.go` | `~/.gridctl/` dir convention + `WithLock`; add `SessionsDir()`/`SessionPath()`. |
| `pkg/config/types.go` | `Stack` struct + `SetDefaults` — where `session_binding:` goes. |
| `pkg/controller/gateway_builder.go` (~463) | Where stores are constructed and injected into the gateway/API; wire the `SessionResolver` here. |
| `pkg/reload/reload.go` | Holds `currentCfg`; the hook for "active session" + runtime rebind. |
| `pkg/mcp/codemode_tools.go` + `codemode.go` | Gateway-native synthetic-tool pattern for `save_finding`. |
| `internal/api/vault.go` + `vault_test.go` + `api.go` | REST handler + test idiom + route/store-setter wiring to clone. |

### Key Web Files to Understand

| File | Why |
|------|-----|
| `web/src/components/vault/VaultPanel.tsx` | Clone target for the right-docked session panel. |
| `web/src/stores/useUIStore.ts` (~144) | `showVault`/`toggleVault` pattern → add `showSession`/`toggleSession`. |
| `web/src/components/workspaces/ToolsWorkspace.tsx` | Audit Mode = the provenance/TTL/prune transparency template (`AUDIT_STYLES`, lookback `<select>`, confirm-gated remediation banner). |
| `web/src/components/layout/Header.tsx` (~141) | Where the binding badge pill goes (beside the stack-name pill). |
| `web/src/components/spec/SpecTab.tsx` | Read-only annotated viewer to reuse for the injection preview. |
| `web/src/components/wizard/VaultSetSelector.tsx` + `wizard/steps/StackForm.tsx` (Secrets section) | Clone for the `session_binding` selector + accordion. |
| `web/src/lib/api.ts` | Typed fetch-wrapper conventions for the new endpoints. |

### Integration Points

- Gateway gains a `SessionResolver` field + setter; built where the registry/vault stores are wired (`gateway_builder.go`) and refreshed on reload.
- `HandlePromptsGet` (and `buildInstructions`) call the resolver, apply the size cap, run the existing substitution loop with injected values (client args win), and validate findings against currently-registered servers/tools (already available under `g.mu.RLock()` via `serverMeta`/router).
- API `Server` gains a `SetSessionStore(...)` setter following the existing pattern.

### Reusable Components

Variable-store Sets (session vars), `HandlePromptsGet` substitution loop (injection), `pkg/pins` store shape (persistence), `VaultPanel` + `showVault` (panel), Audit Mode idioms (governance UI), `VaultSetSelector` (binding selector), `SpecTab` viewer (injection preview), `showToast`/`ConfirmDialog` (feedback/destructive confirms).

## UX Specification

- **Discovery**: wizard "Session" accordion; Header binding badge on running stacks; `session_binding:` visible in the read-only Spec tab.
- **Activation**: select/create a session name in the wizard `SessionSelector` → writes `session_binding:` → deploy through the existing wizard→apply flow. (Optional: a runtime `bind` endpoint + CLI for already-running stacks.)
- **Interaction**: badge opens the right-docked panel → read findings (read-only markdown, Spec styling), see per-entry provenance/age/status, prune individual entries or bulk-expire (Audit-style banner), toggle injection preview.
- **Feedback**: success/error toasts on append/prune; live size/line-cap meter; badge turns amber when items are expiring; "Writing memory" events surfaced in the request trace/logs.
- **Error states**: reuse inline `AlertCircle` + `status-error/10` banners for load/append failures; a `status-pending` "cap exceeded — oldest findings truncated on inject" warning; `ConfirmDialog` (danger) before any prune/clear, stating the exact consequence.

## Implementation Notes

### Conventions to Follow

- Go: existing package layout, slog logging, atomic writes, `state.WithLock` for cross-process safety, table-driven tests with `t.TempDir()`, no new mocking deps.
- API: Go 1.22 method-prefixed routes (`mux.HandleFunc("POST /api/...", ...)`), `writeJSON`/`writeJSONError`, nil-store `ServiceUnavailable` guards, store-setter injection.
- Web: append to single-source registries (e.g. `useUIStore` toggles) rather than scattering state; lazy-loaded routes; existing token/utility classes; clone the nearest recent component rather than inventing.
- Commits/PRs: per the repo's git workflow (fork workflow for gridctl; signed commits; no Claude mentions). Conventional Commit subjects ≤50 chars.
- Update `CHANGELOG.md` (`[Unreleased]`), `AGENTS.md`, `docs/config-schema.md` (new `session_binding:` field), and add a `proto/` smoke-test domain if appropriate.

### Potential Pitfalls

- **Naming collisions** — not `pkg/context` (stdlib), not bare "Session" (`pkg/mcp/session.go` is MCP-protocol sessions). Pick distinct names.
- **Lock ordering** — session-store lock must be inner to `g.mu`; never acquire `g.mu` while holding the session lock.
- **Hot-path I/O** — cache session content; invalidate on write/reload; don't `os.ReadFile` per `prompts/get`.
- **Empty/stackless case** — `buildInstructions()` returns `""` with no servers; ensure findings injection isn't silently dropped or doesn't crash when nothing is bound.
- **Silent injection** — the Cursor failure mode; the injection preview + panel are mandatory, not optional polish.
- **Untrusted writes** — sanitize/escape LLM findings; cap growth; the audit trail is the poisoning-detection mechanism.
- **Coverage gates** — budget real tests for any pkg/mcp and pkg/config additions.

### Suggested Build Order

1. **Session store + `pkg/state` helpers** (`SessionsDir`/`SessionPath`), with tests. Pure storage; no gateway changes.
2. **`session_binding:` on `Stack`** + loader/defaults + config tests. Backward-compat verified.
3. **`SessionResolver` + bounded injection** in `HandlePromptsGet`/`buildInstructions`, wired via `gateway_builder.go` + reload. **This is the core value — get it working end-to-end first** (a user can manually write the `.md`, bind it, and see it injected). Validation-against-current-reality here.
4. **`save_finding` built-in tool** (provenance=LLM, sanitize, append). 
5. **REST endpoints** (list/read/edit-prune/bind) cloning `vault.go`.
6. **Web UI**: `useUIStore` toggle → Header badge → `VaultPanel`-clone session panel → injection preview → wizard binding accordion.
7. **Governance polish**: TTL/auto-prune/archive, audit trail, size-cap meter, provenance filtering, bulk actions.

A valid **v0 milestone** is steps 1–3 alone (manual findings file + binding + bounded injection) — it proves the headline value before any tool/UI/governance investment.

## Acceptance Criteria

1. A stack with `session_binding: <name>` causes the gateway, on `prompts/get`, to inject the named session's findings markdown + bound Set values into the prompt body, respecting the size cap and letting client-passed args override injected values.
2. A stack with no `session_binding:` behaves identically to current `main` (no injection, no regressions; existing prompt tests pass).
3. Injected content is hard-capped (default ~200 lines / 25 KB); content over the cap is excluded and surfaced as "not injected" (verified by test).
4. The built-in `save_finding` tool appears in `tools/list`, appends a sanitized, provenance-tagged, timestamped entry to the active session, and the new content is reflected on the next injection (cache invalidated).
5. Findings referencing MCP servers/tools not present in the running stack are flagged/suppressed at injection time.
6. No session data is read from disk on the hot `prompts/get` path more than once per change (lazy-load + cache verified).
7. REST endpoints list sessions, return a session's findings + resolved Set values + metadata, prune/edit findings, and bind/unbind — each with nil-store guards and correct status codes.
8. The web console shows a Header binding badge when bound, opens a session panel listing findings with provenance + age + injection-status chips and a size/line-cap meter, supports per-entry + bulk delete and provenance/age filtering, and renders an accurate injection preview. No ⌘5 workspace or gallery is added.
9. The wizard offers a "Session" accordion that writes `session_binding:` into the generated YAML.
10. Concurrent writes from daemon + API + gateway are safe (RWMutex + flock); no data races under `go test -race`; no lock-ordering deadlock with `g.mu`.
11. Coverage gates pass (pkg/mcp ≥75%, pkg/config ≥70%, pkg/controller ≥50%); `golangci-lint`, `go test -race`, `go build`, and `npm run build` all succeed.
12. `CHANGELOG.md`, `AGENTS.md`, and `docs/config-schema.md` document the new field and feature.

## References

- Full evaluation: `prompts/gridctl/context-auto-injector/feature-evaluation.md`
- Original maximal plan (gitignored, in-repo): `proto/context.md`
- Claude Code memory (200-line/25KB cap precedent): https://code.claude.com/docs/en/memory
- Anthropic memory tool / context management: https://docs.claude.com/en/docs/agents-and-tools/tool-use/memory-tool · https://www.anthropic.com/news/context-management
- GitHub Copilot memory (28-day TTL, validation, provenance, bulk delete): https://docs.github.com/en/copilot/how-tos/use-copilot-agents/copilot-memory
- Letta ADE memory blocks (live token indicators): https://docs.letta.com/guides/ade/core-memory/
- Cursor silent-memory anti-pattern (what to avoid): https://forum.cursor.com/t/unable-to-view-or-manage-memories-and-no-notifications/124572
- Memory-injection attack (security/transparency case): https://www.theregister.com/2025/10/27/atlas_vulnerability_memory_injection
- Official MCP memory server (file-backed reference): https://github.com/modelcontextprotocol/servers/tree/main/src/memory
- MCP has no memory primitive / stateless direction: https://github.com/modelcontextprotocol/modelcontextprotocol/discussions/1226
