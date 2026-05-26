# Feature Implementation: Variable Usage Tracing

## Context

**gridctl** is a Go + React tool: an MCP gateway + skill library that declares MCP servers
in a single declarative stack YAML, resolves `${var:KEY}` references from an encrypted
variable vault during `apply`/`plan`, and renders the running topology in a web UI.

- **Backend**: Go. `pkg/config` (YAML parsing, variable expansion, plan diffing),
  `pkg/vault` (encrypted variable store), `pkg/controller` (daemon orchestration),
  `internal/api` (REST server, Go 1.22 `ServeMux` method+path routes), `pkg/mcp` (gateway).
- **Frontend**: React + TypeScript + Vite + Zustand. Variables live in a first-class
  "Variables" workspace; topology is a React Flow-style canvas.
- **Build/test**: `make build` + `./gridctl` (do **not** use a brew-installed binary);
  `go test -race ./...`; `golangci-lint run`; `cd web && npm run build` / `npm run test`
  (Vitest). `gridctl serve` daemonizes — use `--foreground` for scripts that kill it.
- **Conventions**: signed commits, conventional-commit messages, no Claude attribution
  anywhere in version control. gridctl uses a **fork-and-pull** workflow.

## Evaluation Context

Key findings from the feature-scout evaluation that shape this prompt:

- **This replaces a shipped placeholder.** PR #692 added a topology→vault bridge whose
  variable filter is an *approximate substring match* of the server name against variable
  keys, with a UI banner that literally says "approximate." This feature provides the exact,
  backend-derived data that retires that heuristic. (See
  `VaultWorkspace.tsx:152-160` and `ServerFilterBanner`.)
- **Market is white space.** No mainstream tool offers a standing "Used by N" badge +
  navigable consumer list from static config. Doppler only does a delete-time warning.
  HashiCorp built exactly this for Terraform (`terraform-ls` #651: CodeLens "N references" +
  "Go to References") — copy that interaction model. Frame copy as "Find Usages for your
  stack."
- **Strongest framing is pre-change safety.** Surface "used by N servers" in the delete
  confirmation; that's the highest-value moment (rotation/deletion fear is the documented
  pain, OWASP MCP #1 risk).
- **Two anti-patterns to design against**: stale indexes (re-derive on stack load; don't
  maintain a long-lived cache) and false positives (parse the real `${var:KEY}` grammar,
  never substring-match).
- **Scope decisions locked**: Core scope (no orphan-detection report, no topology highlight
  in this build) and **one-hop** reference resolution (direct refs only; UI states this).
- Full evaluation:
  `<prompts-dir>/gridctl/variable-usage-tracing/feature-evaluation.md`

## Feature Description

Index where each `${var:KEY}` variable is referenced across the **active stack's** MCP
servers and resources, and surface it in the Variables UI:

1. A "Used by N servers" badge on each variable card (rendered only when N > 0).
2. A drill-down listing the specific consumers (`name · ENV_KEY`/field), each a quick-nav
   link to the consumer node.
3. A "used by N servers" warning in the delete confirmation dialog.
4. Exact backend data replacing the approximate `ServerFilterBanner` substring filter.

The goal: show the blast radius of changing/rotating/deleting a variable before the user
commits to it.

## Requirements

### Functional Requirements

1. During stack load/expansion, build a reference index mapping each referenced variable key
   to the list of consumers that reference it. A **consumer** is `{kind: "mcp-server" |
   "resource", name, field}` where `field` identifies the reference site (e.g.
   `env.GITHUB_TOKEN`, `image`, `command[2]`, `openapi.base_url`).
2. The index must be derived from the **same reference detection** used by expansion
   (`expandRegex` in `pkg/config/expand.go`), covering all `${var:KEY}` / `${vault:KEY}`
   forms — never a separate substring scan. Bare `$VAR` / `${VAR}` env-style refs are **not**
   variable-store references and must not be indexed as such (only `var:`/`vault:`-prefixed
   refs are store references).
3. Resolution is **one-hop**: index direct references only. Do not follow a variable
   referenced inside another variable's value.
4. Expose the index via a **dedicated** read-only endpoint `GET /api/var/usage` returning a
   map of `key → [consumers]` (see API shape below). Do **not** add consumer data to the
   `variableEntry` wire type or to `vault.Variable` — the vault layer stays pure and is
   usable without a loaded stack.
5. If no stack is currently loaded/applied, the endpoint returns an empty map (200), and the
   UI shows no badges (not an error).
6. UI: render a "Used by N servers" badge on each variable card when N > 0; clicking it
   reveals the consumer list with quick-nav links.
7. UI: the delete `ConfirmDialog` shows a "used by N servers" warning when N > 0.
8. UI: replace the approximate `filteredByServer` substring logic with exact consumer data;
   update `ServerFilterBanner` copy to drop "approximate."
9. Quick-nav: clicking a consumer selects the corresponding topology node
   (`useStackStore.selectNode`) and resolves the vault→topology view transition deliberately.

### Non-Functional Requirements

- **Correctness over completeness**: an under-count is worse than no count (it gives false
  safety). Cover every field `expandStackVars` expands; add a test asserting parity between
  expanded fields and indexed fields.
- **No secret values** in the index or the `/api/var/usage` response — keys and consumer
  metadata only. Safe to return when the vault is locked (it indexes the stack, not values).
- **Don't block** the variable list render on usage data; fetch and merge lazily.
- **Staleness honesty**: the index reflects the last stack load/plan. Re-derive on stack
  load rather than caching long-lived. If the UI can detect a stale index, label the count
  as "as of last plan" rather than implying live accuracy.
- Accessibility: badge is a `<button>` with `aria-label`, keyboard-focusable, `Escape`
  collapses the drill-down.

### Out of Scope

- Orphan/unused-variable detection report or "show unused only" filter (follow-up).
- Topology canvas highlighting of consumer nodes (follow-up; respects neutral-edges
  convention).
- Transitive / nested-variable resolution.
- Cross-stack analysis (gridctl loads one stack at a time).
- Any change to variable values, the encryption envelope, or the vault store schema.

## Architecture Guidance

### Recommended Approach

**Backend — build the index inside the existing expansion walk.**

`expandStackVars` (`pkg/config/loader.go:146`) already iterates every expandable field of
every server and resource. Thread a reference collector through it:

- Add a variant of `ExpandString` (or a sibling that wraps it) that also reports which
  `var:`/`vault:`-prefixed keys it matched — reuse `expandRegex` so detection cannot drift
  from resolution.
- At each call site in `expandStackVars`, the consumer identity (kind, name, field) is
  already in scope — record `key → consumer` as expansion happens.
- Store the resulting index on the `Stack` (e.g. a `References` field or a method) or return
  it alongside the existing `(unresolved, emptyVars)` results. Keep it derived data, not part
  of the persisted YAML.
- Confirm where the API server can reach the active stack/index: `*Server` already holds
  `vaultStore` and serves live status from the controller, so the controller/stack is
  reachable. Wire the index through the same path that exposes server status. Verify the
  exact field/accessor before coding — do not assume.

**Backend — endpoint.** Add `GET /api/var/usage` in `internal/api`, registered inside
`registerVarRoutes` (`internal/api/api.go:248`) so it inherits the canonical/deprecated
prefix handling. Follow the existing handler pattern (`writeJSON`/`writeJSONError`, receiver
method on `*Server`).

**Frontend — additive UI.**

- Add a `fetchVariableUsage(): Promise<Record<string, Consumer[]>>` to `web/src/lib/api.ts`
  and a `Consumer` type. Do **not** change the `Variable` interface; merge usage in the hook
  or component.
- Fetch usage in `useVaultManager` (or alongside `refresh`) and expose a
  `usage: Record<string, Consumer[]>` map.
- `SecretItem`: add the badge after `<VariableTypeBadge />` in the header row; add the
  consumer list to the expanded body (or an inline expand triggered by the badge).
- `VaultWorkspace`: replace `filteredByServer` substring logic with exact-match against
  usage; pass usage count into the delete `ConfirmDialog` message; update `ServerFilterBanner`
  copy.

### Key Files to Understand

| File | Why |
|------|-----|
| `pkg/config/loader.go` (`expandStackVars`, ~line 146) | The walk where the index is built; lists every expandable field. |
| `pkg/config/expand.go` (`ExpandString`, `expandRegex`) | Reference detection grammar to reuse; note `var`/`vault` prefix handling. |
| `pkg/config/types.go` | `Stack`, `MCPServer`, `Resource` structs — where to attach the index. |
| `internal/api/vault.go` (`variableEntry` ~line 130, handler pattern) | Wire-shape seam (keep pure) + handler conventions. |
| `internal/api/api.go` (`registerVarRoutes` ~line 248) | Where to register `GET /api/var/usage`. |
| `web/src/components/vault/SecretItem.tsx` | Variable card; badge + drill-down placement. |
| `web/src/components/workspaces/VaultWorkspace.tsx` (`filteredByServer` ~152, `ServerFilterBanner` ~893) | Heuristic to replace; delete dialog wiring. |
| `web/src/components/layout/Sidebar.tsx` (`handleViewSecrets` ~102) | The topology→vault bridge that now resolves against exact data. |
| `web/src/lib/api.ts` (`Variable` ~541, `fetchVariables`) | API client + types. |
| `web/src/stores/useStackStore.ts` (`selectNode`) | Quick-nav target for consumer links. |

### Integration Points

- `expandStackVars` → returns/attaches the index (backend core).
- Controller/stack → `*Server` → `GET /api/var/usage` (verify the existing accessor path).
- `useVaultManager` → merges usage into what `VaultWorkspace` renders.
- `SecretItem` props → add optional `consumers?: Consumer[]` (or `usageCount` + list).

### Reusable Components

- `expandRegex` / `ExpandString` (reference detection — reuse, don't reinvent).
- `useStackStore.selectNode` (jump-to-consumer).
- `SetPill` styling for the badge; `ConfirmDialog` (rich message, no component change).
- `?filter=server:<name>` URL param + `ServerFilterBanner` (repurpose).

## UX Specification

- **Discovery**: badge `[N servers ↗]` after the type badge in the `SecretItem` header,
  styled like `SetPill` (`text-[10px] font-mono px-1.5 py-0.5 rounded`,
  `bg-surface-elevated text-text-muted`, hover lift). Rendered only when N > 0
  (absence-as-signal at 0).
- **Activation**: badge is a `<button>` with `onClick` calling `e.stopPropagation()` so it
  doesn't toggle row expand. Reveals the consumer list inline (expand-in-place for ≤3; "see
  all" for more).
- **Interaction**: each consumer row shows `name · ENV_KEY` with an `ArrowRight`/`ExternalLink`
  icon. Clicking calls `selectNode(<nodeId>)`; if currently in `/vault`, either show a toast
  ("Selected `name` — switch to Topology to inspect") or navigate to topology — pick one and
  be consistent. (Toast is the lower-surprise default.)
- **Feedback**: delete `ConfirmDialog` gains, when N > 0, a warning block (reuse
  `bg-status-error/10 border-status-error/20` styling): "This variable is used by N server(s).
  Deleting it may break those servers."
- **Reverse direction**: `ServerFilterBanner` copy changes from "approximate (matches keys
  containing the server name)" to an exact-match phrasing (e.g. "N variables used by
  `<server>`").
- **Error states**: no stack loaded → no badges, no error. Usage fetch failure → badges
  simply absent (don't block or error the variable list).

## Implementation Notes

### Conventions to Follow

- Go: receiver methods on `*Server`; `writeJSON`/`writeJSONError`; table-driven tests
  matching `expand_test.go` / `vault_test.go` style. Run `golangci-lint run` (gosec is on).
- TS: match the existing hook/store patterns; Vitest tests like `__tests__/VaultPanel.test.tsx`.
- Conventional commits, signed, no Claude attribution. Fork-and-pull workflow.
- Build/verify with `make build && ./gridctl ...` and `cd web && npm run build`.

### Potential Pitfalls

- **Under-counting** is the cardinal sin (false safety). Add a test that fails if a field is
  expanded but not indexed — keep `expandStackVars` and the indexer structurally in lockstep.
- **Substring temptation**: do not reuse the placeholder's key-substring logic. Match the
  parsed `${var:KEY}` grammar only.
- **Layering**: resist adding `usedBy` to `variableEntry`/`vault.Variable`. The vault is
  usable with no stack loaded; the index belongs to the stack/controller layer.
- **Set-injected secrets**: `injectSetSecrets` (`loader.go:106`) adds secret keys to server
  env *after* expansion, without `${var:...}` syntax. Decide explicitly whether
  set-injected consumers count as "usage." Recommended: index explicit `${var:KEY}`
  references for v1 and note set-injection as a known gap (or a follow-up), rather than
  silently conflating the two.
- **View transition**: jumping vault→topology must not feel jarring; prefer toast over
  forced navigation unless product says otherwise.

### Suggested Build Order

1. **Backend index**: collector through `expandStackVars` + `ExpandString` variant; unit
   tests asserting expand/index parity and one-hop behavior. (No API yet.)
2. **Wire index to API**: confirm the controller→`*Server` accessor; add `GET /api/var/usage`
   + handler test (including "no stack loaded" and "vault locked" cases).
3. **Frontend data**: `Consumer` type, `fetchVariableUsage`, merge into `useVaultManager`.
4. **Badge + drill-down** in `SecretItem`; quick-nav via `selectNode`.
5. **Delete-dialog warning** + **retire the substring heuristic** + `ServerFilterBanner`
   copy in `VaultWorkspace`.
6. Frontend tests; full `make build`, `go test -race ./...`, `npm run build`/`test`.

## Acceptance Criteria

1. `GET /api/var/usage` returns `key → [{kind, name, field}]` for the active stack, derived
   from the same reference detection as expansion; empty map when no stack is loaded.
2. The endpoint exposes no secret values and is safe when the vault is locked.
3. A variable referenced by 2 servers shows a "Used by 2 servers" badge; an unreferenced
   variable shows no badge.
4. Clicking the badge reveals consumers as `name · ENV_KEY`; clicking a consumer selects its
   topology node.
5. Deleting a referenced variable shows a "used by N servers" warning in the confirmation.
6. The `ServerFilterBanner` no longer claims "approximate"; the server filter now matches
   exact consumers (not key substrings).
7. A test fails if any field expanded by `expandStackVars` is not covered by the indexer.
8. The `vault.Variable` struct and `variableEntry` wire type are unchanged.
9. `go test -race ./...`, `golangci-lint run`, and `cd web && npm run build && npm run test`
   all pass.

## References

- Full evaluation: `<prompts-dir>/gridctl/variable-usage-tracing/feature-evaluation.md`
- terraform-ls "Find References" design (CodeLens + Go to References):
  https://github.com/hashicorp/vscode-terraform/issues/651 ·
  https://github.com/hashicorp/terraform-ls/blob/main/docs/USAGE.md
- LSP references / CodeLens "N references" pattern:
  https://microsoft.github.io/language-server-protocol/
- Doppler delete-time reference warning (closest competitor):
  https://docs.doppler.com/docs/config-inheritance
- OWASP MCP Top 10 — MCP01:2025 (the demand driver):
  https://owasp.org/www-project-mcp-top-10/2025/MCP01-2025-Token-Mismanagement-and-Secret-Exposure
- Blast Radius (Terraform reference-graph visualizer, for drill-down inspiration):
  https://github.com/28mm/blast-radius
