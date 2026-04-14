# Feature Evaluation: Vault Secret Visibility for MCP Servers/Agents

**Date**: 2026-03-17
**Project**: gridctl
**Recommendation**: Build
**Value**: High
**Effort**: Small

## Summary

Add a "Secrets" section to the sidebar detail panel that shows which vault variable sets and secret key names an MCP server or agent is consuming. This surfaces secret dependencies directly in the node detail view, giving users operational visibility without exposing secret values. The infrastructure already exists — the feature connects existing data sources to a new UI section.

## The Idea

When viewing an MCP server or agent in the sidebar, users currently have no visibility into which vault secrets that node depends on. This feature adds a collapsible "Secrets" section that displays:
1. Which variable sets the node's secrets belong to
2. The secret key names (never values) grouped by set
3. Whether secrets are auto-injected via `secrets.sets` or explicitly referenced via `${vault:KEY}`

Users managing MCP stacks with credentials benefit from understanding secret dependencies for debugging, auditing, and operational awareness.

## Project Context

### Current State

gridctl manages MCP server stacks with a Go backend and React/TypeScript frontend. The vault system supports:
- Named secrets with `Key`, `Value`, and optional `Set` assignment
- Variable sets that group related secrets
- Stack-level `secrets.sets` for automatic injection of all secrets from named sets
- Per-node `${vault:KEY}` references in environment variable maps
- Encrypted vault with lock/unlock via passphrase

The sidebar detail panel shows node metadata across collapsible sections (Status, Token Usage, Actions, Tools, Skills, Access) but has no secrets section.

### Integration Surface

| File | Role |
|------|------|
| `internal/api/stack.go` | `handleStackSecretsMap` — extend to include set metadata |
| `web/src/lib/api.ts` | `fetchSecretsMap()` — update return type |
| `web/src/components/layout/Sidebar.tsx` | Add Secrets section |
| `web/src/stores/useVaultStore.ts` | Existing vault state (secrets, sets) |
| `web/src/components/spec/SecretHeatmapOverlay.tsx` | Shared-secret color coordination |
| `pkg/vault/types.go` | Secret/Set data models |
| `pkg/config/types.go` | Stack config with `Secrets.Sets` and `MCPServer.Env`/`Agent.Env` |

### Reusable Components

- `Section` component in Sidebar — collapsible sections with icon and count
- `AccessItem` pattern — card with colored header bar and item rows (visual template for set cards)
- `Badge` component — status display
- `KeyRound` icon and tertiary color palette — already associated with vault throughout the app
- `fetchSecretsMap()` API function — needs minor extension
- `useVaultStore` — already manages secrets and sets state

## Market Analysis

### Competitive Landscape

| Tool | Shows secrets per service? | Reverse lookup? | Variable groups? |
|------|---------------------------|-----------------|------------------|
| HashiCorp Vault | Via policies (indirect) | Audit logs only | Entity groups |
| Docker/Portainer | Flat list per container | No | No |
| K8s Dashboard | Pod detail view | No | No |
| Lens | Pod detail + Resource Map | Graph extension | No |
| GitHub Actions | Implicit in YAML | Org → repo selector | Environment scoping |
| Doppler | Project = service model | Global search | Projects + configs |
| Infisical | Dashboard per project | Integration status | Environments |

### Market Positioning

**Leap ahead.** No MCP tooling shows secret-to-service relationships. Even in traditional infrastructure tools, only Doppler's global search approaches this. Lens's Resource Map extension does it via graph visualization, but it's an optional add-on.

### Ecosystem Support

No dedicated React components for secret/credential visualization exist. The ecosystem composes general-purpose components (badges, chips, key-value lists). Reference implementations: Infisical (MIT) and Phase Console (MIT) for dashboard patterns.

### Demand Signals

- 88% of MCP servers require credentials; 53% use insecure static secrets
- OWASP MCP Top 10 lists token mismanagement as the #1 risk
- 29M secrets found on public GitHub in 2026; AI-service leaks surging 81%
- MCP gateway solutions with integrated secrets management are emerging as a category

## User Experience

### Interaction Model

- **Discovery**: Users click an MCP server or agent node to open the sidebar. The "Secrets" section appears between Actions and Tools with a count badge showing the number of referenced keys.
- **Activation**: Click to expand the collapsed section.
- **Interaction**: Secret keys are grouped by variable set in cards (matching the AccessItem pattern). Click a set name to open the vault panel filtered to that set. Hover a key name for a tooltip showing which other nodes share it.
- **Feedback**: Shared secrets show color-coded dots matching the heatmap overlay palette. Auto-injected sets show a distinguishing pill.
- **Error states**: Vault locked → flat key list with lock indicator; no vault refs → section not rendered.

### Workflow Impact

Reduces friction. Currently, understanding a node's secret dependencies requires reading YAML config. This surfaces it in the detail view users already use.

### UX Recommendations

- Place section between Actions and Tools (configuration metadata, applies to both servers and agents)
- Use tertiary/purple color for set headers (vault association)
- Cards per variable set with KeyRound icons for individual keys (mirrors AccessItem)
- Collapsed by default — count in header provides at-a-glance info
- Unassigned keys get a muted fallback card
- Vault locked: show keys from config parsing with lock indicator, note set grouping unavailable

## Feasibility

### Value Breakdown
| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Significant | No visibility into secret dependencies without reading YAML |
| User impact | Broad + Deep | Every user with vault secrets benefits; meaningfully improves debugging |
| Strategic alignment | Core mission | Infrastructure observability for MCP stacks |
| Market positioning | Leap ahead | No MCP tool does this; rare even in traditional infra tools |

### Cost Breakdown
| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Minimal | Extend existing API, add one new sidebar section |
| Effort estimate | Small | ~1 backend change, ~1 frontend component reusing existing patterns |
| Risk level | Low | Read-only, no data mutation, no architectural changes, never exposes values |
| Maintenance burden | Minimal | Renders from existing data sources, no new state management |

## Recommendation

**Build.** High value, low cost, low risk. The infrastructure is already in place — the secrets-map API maps keys to nodes, the vault store tracks set membership, the Sidebar has reusable section and card patterns. The only new work is extending the API response to include set metadata and adding a Secrets section to the Sidebar. This is a clean, well-scoped feature with a clear implementation path that would be genuinely differentiating in the MCP ecosystem.

## References

- [HashiCorp Vault UI Tutorial](https://developer.hashicorp.com/vault/tutorials/get-started/learn-ui)
- [HCP Vault Secrets Audit Logs](https://developer.hashicorp.com/hcp/docs/vault-secrets/audit-logs)
- [Docker Compose Secrets](https://docs.docker.com/compose/how-tos/use-secrets/)
- [Lens Resource Map](https://laurinevala.medium.com/visualizing-kubernetes-resources-ee9d8c16d264)
- [Doppler Workplace Structure](https://docs.doppler.com/docs/workplace-structure)
- [Infisical Secrets Management](https://infisical.com/docs/documentation/platform/secrets-mgmt/overview)
- [Phase Console GitHub](https://github.com/phasehq/console)
- [OWASP MCP01:2025 - Token Mismanagement](https://owasp.org/www-project-mcp-top-10/2025/MCP01-2025-Token-Mismanagement-and-Secret-Exposure)
- [State of MCP Server Security 2025](https://astrix.security/learn/blog/state-of-mcp-server-security-2025/)
- [State of Secrets Sprawl 2026](https://blog.gitguardian.com/the-state-of-secrets-sprawl-2026/)
- [Badges vs Chips vs Tags vs Pills](https://smart-interface-design-patterns.com/articles/badges-chips-tags-pills/)
