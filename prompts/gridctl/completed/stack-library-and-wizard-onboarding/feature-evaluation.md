# Feature Evaluation: Stack Library and Wizard-First Onboarding

**Date**: 2026-04-14
**Project**: gridctl
**Recommendation**: Build
**Value**: High
**Effort**: Large

## Summary

gridctl has a bootstrap paradox: the web UI is only accessible after starting with a stack.yaml, but the wizard inside the UI is the best way to create one. This feature resolves that contradiction by adding stackless startup, a `~/.gridctl/stacks/` library, and runtime stack loading — making the wizard the primary onboarding path instead of a secondary tool for users who already have a stack. Research confirms this is architecturally feasible, the existing reload handler is the right extension point, and wizard-first onboarding is meaningfully differentiating in this tooling category.

## The Idea

Three coordinated changes:

1. **Stackless startup**: `gridctl serve` (or `gridctl apply` with no args) starts the API and web UI without requiring a stack file. An empty canvas with a clear CTA launches the wizard.
2. **Stack library**: `~/.gridctl/stacks/` stores named stack definitions. New endpoints list and save stacks. The wizard saves to the library on completion.
3. **Runtime stack loading**: After saving, the wizard calls a new endpoint that cold-initializes the gateway with the new stack — no restart required. The existing file watcher takes over for subsequent edits.

## Project Context

### Current State

gridctl requires `cobra.ExactArgs(1)` on the apply command — a stack file path is mandatory. The entire startup pipeline (`Controller.Deploy()` → `config.LoadStack()` → `GatewayBuilder.Build()`) is tightly coupled to having a valid stack file. The API server already handles nil states gracefully for many endpoints (wizard drafts, vault, validate), but stack-dependent endpoints return 503 when `s.stackFile == ""`. The web UI already handles "no servers" and "connecting" states correctly — no frontend empty-state work is needed for stackless mode beyond surfacing the wizard.

### Integration Surface

- `cmd/gridctl/apply.go` — remove `cobra.ExactArgs(1)`, make stack arg optional
- `pkg/controller/controller.go` — split boot-gateway from load-stack phases
- `pkg/controller/gateway_builder.go` — make `*config.Stack` parameter optional (nil = empty stack)
- `pkg/reload/reload.go` — extend `Reload()` to handle nil `currentCfg` (initial load path)
- `pkg/state/state.go` — add `StacksDir` constant
- `internal/api/api.go` — add `POST /api/stack/initialize`, `GET /api/stacks`, `POST /api/stacks`
- `web/src/components/wizard/steps/ReviewStep.tsx` — replace Deploy with Save & Load for stack type
- `web/src/components/wizard/CreationWizard.tsx` — gate MCP Server/Resource cards on stack state

### Reusable Components

- `pkg/reload/reload.go` — `Reload()` already does diff-apply; nil diff = treat all as added (initial load)
- `pkg/reload/watcher.go` — file watcher starts post-initialization, no changes needed
- `internal/api/wizard.go` — wizard draft API already fully stackless
- `web/src/stores/useStackStore.ts` — `connectionStatus === 'connected'` is the right stack-loaded signal
- `~/.gridctl/cache/wizard-drafts/` — already persists in-progress wizard work

## Market Analysis

### Competitive Landscape

- **HashiCorp Vault `--dev` mode**: the canonical zero-config startup. Boots fully operational without a config file; the "no persistent state" mode lets users explore immediately. The relevant insight: the daemon is useful before first configuration.
- **Railway dashboard**: the strongest wizard-first onboarding analogue. Empty canvas → "+ New" → template picker → populated canvas. This is exactly the loop gridctl wants.
- **Lens (Kubernetes IDE)**: catalog model — stacks appear as named items in a persistent library sidebar. "Add Cluster" CTA card on empty state. Stack library UX should follow this pattern.
- **Docker Desktop**: starts without any compose file; the daemon is always running. GUI surfaces whatever is running. The mental model is daemon-first, config-optional.
- **Tilt / Garden**: both require a config file to do anything; no stackless mode. This is where gridctl can differentiate.
- **WunderGraph Cosmo router**: most sophisticated runtime config loading — old and new graph instances coexist during transition, in-flight requests are preserved. gridctl's simpler case (cold init from nil) is easier.

### Market Positioning

Wizard-first onboarding with zero-config startup is **differentiating** in local developer infrastructure tooling. Most tools in this space (Tilt, Garden, Skaffold) require a config file to start. The tools that don't (Docker Desktop, Vault dev mode) are among the most accessible in their categories. For a UI-first tool targeting developers who may not be familiar with MCP server infrastructure, removing the bootstrap friction is a strategic advantage.

### Ecosystem Support

No new dependencies required. The existing `fsnotify` watcher and `pkg/reload` handler cover runtime loading. `~/.gridctl/stacks/` follows the same pattern as `~/.gridctl/state/`, `~/.gridctl/vault/`, etc. — no new conventions.

### Demand Signals

Direct user friction: the current flow requires creating a stack.yaml before using the UI, but the UI contains the best tool for creating a stack.yaml. This is the kind of paradox that surfaces immediately in user testing and support channels.

## User Experience

### Interaction Model

**New user (no stack):**
1. Runs `gridctl serve` — no args required
2. Browser opens to canvas — empty state with prominent "Create your first stack" CTA
3. Wizard opens — creates stack, reaches Review step
4. Clicks "Save & Load" — stack saved to `~/.gridctl/stacks/<name>.yaml`, gateway cold-initializes, canvas populates
5. Now adds MCP servers via wizard — deploys to active stack, live reload fires

**Returning user (stack exists):**
- `gridctl apply stack.yaml` still works exactly as today
- `gridctl serve` with stacks in `~/.gridctl/stacks/` could surface a stack picker on startup (future enhancement)

### Workflow Impact

- Eliminates the manual bootstrap step entirely for new users
- Existing `gridctl apply stack.yaml` workflow is fully preserved — zero regression risk
- MCP Server/Resource wizard cards are gated (dimmed) when no stack is loaded, teaching the mental model without blocking anything

### UX Recommendations

1. **Active stack name** should be an ambient indicator in the header or status bar — prevents "which stack am I editing?" confusion as the library grows (Stripe test/live mode banner is the right precedent)
2. **"Save & Load" button** in the Stack wizard review step replaces the broken Deploy button — primary action, same position (ml-auto)
3. **Card gating**: MCP Server and Resource cards dim to `opacity-40` with `cursor-not-allowed` and a native `title` tooltip when `connectionStatus !== 'connected'`
4. **Do not add a target-stack dropdown** to MCP Server/Resource wizard — the wizard is a live tool tied to the canvas; appending to a non-active stack breaks the feedback loop

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Critical | Bootstrap paradox blocks the intended onboarding flow |
| User impact | Broad+Deep | Every new user; the first 5 minutes of experience |
| Strategic alignment | Core mission | UI-first tool requires UI-first onboarding |
| Market positioning | Leap ahead | Differentiating vs. Tilt/Garden/Skaffold; on par with best-in-class (Vault, Railway) |

### Cost Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Significant | Startup pipeline refactor is the critical path |
| Effort estimate | Large | 4 phases; ~1.5–2 weeks |
| Risk level | Medium | Critical path code, but backward compat preserved; reload handler is already the right extension point |
| Maintenance burden | Moderate | New API surface (3 endpoints) + directory convention |

## Recommendation

Build. The bootstrap paradox is a day-one friction point that contradicts the tool's UI-first identity. The architecture is clearly feasible — the reload handler already handles diff-apply logic, and nil-diff (initial load from nothing) is a natural extension. The startup pipeline refactor is the riskiest piece but is clearly bounded and backward-compatible. Ship in 4 phases: (1) stackless startup backend, (2) stack library backend, (3) wizard save & load frontend, (4) wizard gating and polish.

## References

- HashiCorp Vault dev mode: https://developer.hashicorp.com/vault/docs/concepts/dev-server
- Railway canvas onboarding: https://docs.railway.com/getting-started
- WunderGraph Cosmo router config hot-reload: https://cosmo-docs.wundergraph.com/router/configuration
- Lens cluster catalog pattern: https://docs.k8slens.dev/getting-started/
- Docker contexts model: https://docs.docker.com/engine/context/working-with-contexts/
