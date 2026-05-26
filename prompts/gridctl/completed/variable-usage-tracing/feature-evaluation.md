# Feature Evaluation: Variable Usage Tracing

**Date**: 2026-05-23
**Project**: gridctl
**Recommendation**: Build with caveats
**Value**: High
**Effort**: Medium

## Summary

Usage Tracing indexes where every `${var:KEY}` reference is consumed across the active
stack's MCP servers and resources, then surfaces it as a "Used by N servers" badge on each
variable card with a navigable drill-down to the consumers. It directly retires an
**approximate placeholder the team already shipped** (PR #692's substring-match server
filter, explicitly labeled "approximate" in the UI) and replaces it with exact,
backend-derived data. The pattern is canonical (IDE "Find All References" / CodeLens), the
problem is a named industry pain ("blast radius" / rotation fear), and the capability is
**white space** in both the secrets-management and MCP ecosystems. Build it, scoped to the
active stack with one-hop reference resolution.

## The Idea

Surface the "blast radius" of a variable before you edit or rotate it. The backend already
walks every string field of every server/resource during `apply`/`plan` to expand
`${var:KEY}` references; this feature records *which consumer referenced which variable*
during that same walk, producing a `variable → [consumers]` index. The UI then shows:

- A "Used by N servers" badge on each variable card (nothing rendered at 0 — absence is a
  signal).
- A drill-down listing the specific consumers (server/resource name + the env key/field
  that references the variable), each a quick-nav link to the consumer.
- A "used by N servers" warning in the delete confirmation — the highest-value moment.

**Who benefits:** every gridctl user who manages variables, especially those rotating
secrets or pruning config, who today face a `ConfirmDialog` that says only "This action
cannot be undone" with zero consumer awareness.

## Project Context

### Current State

gridctl is an MCP gateway + skill library (beta, → v1.0) that declares MCP servers in a
single stack YAML, resolves `${var:KEY}` references from an encrypted vault during
`apply`/`plan`, and renders the running topology in a React web UI. Variables were just
promoted to a first-class workspace (#691), topology server nodes were bridged to the vault
workspace (#692), and value masking landed (#694). This feature is the natural next step on
a road the team is already walking.

### Integration Surface

- **`pkg/config/loader.go:146` — `expandStackVars`**: the single function that walks every
  expandable string field of every MCP server and resource. The consumer identity (server
  name, env key, field) is in scope at each call site. **This is where the index is built —
  net-new data, zero new parsing.**
- **`pkg/config/expand.go:81` — `ExpandString`**: detects `${var:KEY}` / `${vault:KEY}` /
  `$VAR` forms via `expandRegex`. The resolver path must be reused so the index can't drift
  from actual resolution.
- **`internal/api/vault.go:130` — `variableEntry`**: the wire shape for `/api/var` (separate
  from raw `vault.Variable`). Confirms the clean seam: expose usage via a *dedicated
  endpoint*, not by coupling the vault to the loaded stack.
- **`internal/api/api.go:248-269` — `registerVarRoutes`**: where a new
  `GET /api/var/usage` route is registered.
- **`web/src/components/vault/SecretItem.tsx`**: the expandable variable card; badge goes
  after `VariableTypeBadge` in the header.
- **`web/src/components/workspaces/VaultWorkspace.tsx:152-160` + `ServerFilterBanner`**: the
  approximate substring filter this feature replaces.
- **`web/src/components/layout/Sidebar.tsx:102` — `handleViewSecrets`**: the topology→vault
  deep-link (`/vault?filter=server:<name>`) that should now resolve against exact data.
- **`web/src/lib/api.ts:541` — `Variable` interface** + `fetchVariables`.

### Reusable Components

- The `expandStackVars` walk (build the index inside it — no second traversal).
- `useStackStore.selectNode` for jump-to-consumer navigation (the Sidebar already does this).
- The `SetPill` styling (`text-[10px] font-mono px-1.5 py-0.5 rounded`) for the badge.
- The existing `ConfirmDialog` (already accepts rich `message` content — no component change).
- The `?filter=server:<name>` URL param and `ServerFilterBanner` (repurposed, copy updated).

## Market Analysis

### Competitive Landscape

- **Doppler** (closest analog): a *delete-time* warning + a link to a referenced secret's
  source. No standing count, weak navigation, scoped to secret→secret refs.
- **Infisical**: supports `${SECRET_NAME}` references but exposes **no** usage view at all.
- **HashiCorp Vault / AWS Secrets Manager / Akeyless / 1Password**: "where used" is answered
  only by *runtime access logs* (who touched it) — requires infra running, misses
  never-deployed config. Not the same as static dependency mapping.
- **GitGuardian / Vault Radar**: map *leaked copies* across repos ("blast radius" of
  revocation), not internal config dependencies.
- **Kubernetes / Helm**: nothing native; users `grep`. Helm has no "this value is consumed
  by N templates" view at all.

### Market Positioning

**Differentiator / leap-ahead.** No mainstream tool offers a standing, navigable
static-consumer view computed from declarative config. **HashiCorp built exactly this for
Terraform** in `terraform-ls`/`vscode-terraform` (#651): a CodeLens "N references" badge +
a "Go to References" drill-in — strong validation of the design, applied to a different
domain. The capability is entirely **unclaimed in the MCP ecosystem**.

### Ecosystem Support

- **Canonical UX pattern**: LSP `textDocument/references` + CodeLens "N references" — users
  already hold this mental model from their editors. Frame the feature as "Find Usages for
  your stack."
- **Prior art for the index**: Terraform's dependency graph (interpolations = edges); LSIF
  (precompute the index once, answer lookups cheaply). No graph library needed — a flat
  `map[key][]consumer` suffices.
- **Reference visualizer**: `28mm/blast-radius` (Terraform d3.js) validates the
  index-and-visualize pattern.

### Demand Signals

**Strong.** "Blast radius" is established change-management vocabulary. Rotation fear is a
named, documented obstacle: Doppler ("secret rotation feels like defusing a bomb"),
GitGuardian State of Secrets Sprawl 2025 (70% of leaked secrets still active after 2 years,
attributed partly to not knowing "which workloads depend on them"), and **OWASP MCP Top 10
ranks Token Mismanagement & Secret Exposure the #1 risk**, explicitly recommending teams
"determine where credentials flow." The MCP community is converging on `${var:KEY}`-style
interpolation (modelcontextprotocol/servers #1232) — the same model gridctl already has.

## User Experience

### Interaction Model

- **Discovery**: badge after the type badge in the `SecretItem` header, styled like
  `SetPill`. Rendered only when N > 0.
- **Activation**: click the badge (a real `<button>` with `e.stopPropagation()`) → expand a
  consumer list in-place for ≤3 consumers, with a "see all" affordance for more.
- **Drill-down**: each consumer shows `name · ENV_KEY` and is a quick-nav link that calls
  `selectNode` (and handles the vault→topology view switch deliberately — toast or navigate).
- **Reverse direction**: the topology "Secrets" button keeps deep-linking via
  `?filter=server:<name>`, but `VaultWorkspace` now filters on exact consumer data and the
  `ServerFilterBanner` drops the "approximate" disclaimer.

### Workflow Impact

Reduces friction and fear: the delete `ConfirmDialog` gains a "used by N servers" warning
(the strongest framing per research), turning a blind destructive action into an informed
one. Adds no friction to the common path — the badge is passive until clicked.

### UX Recommendations

- Absence-as-signal for 0 consumers (consistent with gridctl hiding the type badge for
  `string`).
- Don't block the variable list render on usage data — fetch/merge lazily.
- Accessibility: badge as button with `aria-label="Show N servers using this variable"`,
  keyboard focus into the consumer list, Escape to collapse.
- Respect the neutral-edges convention: no topology highlight in Core scope (deferred).

## Feasibility

### Value Breakdown
| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Significant | Rotation fear / blast radius is named, documented; OWASP MCP #1 risk. |
| User impact | Broad + Moderate depth | Every variable user benefits; depth scales with stack size; retires a heuristic all users hit. |
| Strategic alignment | Core-adjacent | Direct continuation of #689–#694; fills a documented TODO (#692 placeholder). |
| Market positioning | Leap ahead | White space; unclaimed in MCP ecosystem; Terraform validates the design. |

### Cost Breakdown
| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Moderate | Instrument an existing loop + one endpoint + additive UI. No new parsing. |
| Effort estimate | Medium | Index + endpoint + tests; badge/drill-down/delete-warning + tests. A few small PRs. |
| Risk level | Low–Medium | Rides an existing cheap loop; no secret values exposed. Risks: under-counting (missed ref forms) and staleness (index = "as of last plan"). |
| Maintenance burden | Minimal–Moderate | Derived data, no migration. Coupling: new expandable fields must be covered by the index. |

## Recommendation

**Build with caveats.** High value, strong strategic fit, genuine differentiator, low-to-
medium cost. The "caveats" are scoping/design decisions baked into the prompt, not blockers:

1. **Scope to the active stack** and label consumers "servers/resources," not "stacks" —
   gridctl loads one stack at a time.
2. **Reuse the resolver path** and parse the real `${var:KEY}` grammar (never substring) —
   this is precisely the placeholder's documented weakness.
3. **One-hop resolution** (per decision): index direct references only; the UI states the
   count reflects direct references. (Transitive nested-var resolution deferred.)
4. **Keep the index out of the vault layer**: expose via a dedicated `GET /api/var/usage`
   endpoint owned by the stack/controller layer; the frontend merges it with the variable
   list. The vault store and `variableEntry` stay pure.
5. **Treat the index as "as of last apply/plan"** and surface that honestly; re-derive on
   stack load rather than maintaining a long-lived cache (avoids the #1 documented
   anti-pattern: stale indexes).

**Scope locked to Core** (badge + drill-down + retire heuristic + delete warning,
read-only). Orphan/unused detection and topology highlighting are deferred as follow-ups.

## References

- Doppler config inheritance / secret references: https://docs.doppler.com/docs/config-inheritance
- Doppler zero-downtime rotation ("defusing a bomb"): https://www.doppler.com/blog/10-step-secrets-rotation-guide
- Infisical secret references: https://infisical.com/docs/documentation/platform/secret-reference
- HashiCorp Vault usage-visibility request: https://github.com/hashicorp/vault/issues/10714
- OWASP MCP Top 10 — MCP01:2025 Token Mismanagement & Secret Exposure: https://owasp.org/www-project-mcp-top-10/2025/MCP01-2025-Token-Mismanagement-and-Secret-Exposure
- Astrix State of MCP Server Security 2025: https://astrix.security/learn/blog/state-of-mcp-server-security-2025/
- GitGuardian State of Secrets Sprawl 2025: https://blog.gitguardian.com/the-state-of-secrets-sprawl-2025/
- MCP centralized secrets / interpolation syntax (modelcontextprotocol/servers #1232): https://github.com/modelcontextprotocol/servers/issues/1232
- HashiCorp vscode-terraform "Go to references" (#651): https://github.com/hashicorp/vscode-terraform/issues/651
- terraform-ls Find References (USAGE.md): https://github.com/hashicorp/terraform-ls/blob/main/docs/USAGE.md
- LSP CodeLens "N references" pattern: https://microsoft.github.io/language-server-protocol/specifications/lsif/0.6.0/specification/
- Terraform dependency graph: https://developer.hashicorp.com/terraform/internals/graph
- Blast Radius (Terraform d3.js visualizer): https://github.com/28mm/blast-radius
- JetBrains Find Usages: https://www.jetbrains.com/help/idea/find-highlight-usages.html
