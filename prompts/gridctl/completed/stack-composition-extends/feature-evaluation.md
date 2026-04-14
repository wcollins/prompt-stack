# Feature Evaluation: Stack Composition via `extends`

**Date**: 2026-04-06
**Project**: gridctl
**Recommendation**: Build
**Value**: High
**Effort**: Small

## Summary

Add a top-level `extends: ./base-stack.yaml` field that deep-merges a parent stack's
server list into the child stack, with child servers taking precedence by name. This
eliminates copy-paste sprawl across multi-stack organizations (dev/prod/team stacks)
and positions gridctl as the first MCP tooling platform with organizational-scale
config composition. Implementation is a single, narrowly scoped change to `LoadStack`.

## The Idea

Every gridctl stack is currently a standalone island. Orgs running multiple stacks
(dev, prod, team-A) must copy-paste shared servers — auth, logging, observability MCP
servers — into every YAML file. A change to a shared server must be propagated manually
across all stacks, leading to drift and operational toil.

An optional top-level `extends: ./base-stack.yaml` field would allow child stacks to
inherit a parent's server list. The child's servers take precedence (matched by name);
parent-only servers are appended. All other top-level fields (Gateway, Network, Logging,
Secrets) use child-wins semantics: if the child defines them, the child's value is used;
otherwise the parent's value is inherited.

Analogy: Containerlab shared topologies, Docker Compose `extends`, GitLab CI `extends`.

## Project Context

### Current State

gridctl is a production-grade MCP orchestration platform. `LoadStack` in
`pkg/config/loader.go` is the single, clean ~93-line entry point. The pipeline is:
unmarshal YAML → expand vars → set defaults → resolve relative paths → validate.
The `Stack` struct in `pkg/config/types.go` has no existing composition mechanism.
`Validate()` in `pkg/config/validate.go` is comprehensive with field-path-aware errors.

**No `extends`, `include`, or `import` mechanism exists anywhere in the codebase.**

### Integration Surface

| File | Change |
|------|--------|
| `pkg/config/types.go` | Add `Extends string` field to `Stack` struct |
| `pkg/config/loader.go` | Add `mergeStacks()` function; call it in `LoadStack` after unmarshal, before defaults |
| `pkg/config/validate.go` | Add `extends` path validation and circular dependency detection |
| `pkg/config/loader_test.go` | Add test cases for extends behavior |

### Reusable Components

- `resolveRelativePaths()` pattern for path resolution relative to the child file
- `ValidationErrors` type for structured error reporting on extends-related errors
- `expandTildeAndResolvePath()` for path normalization
- The `LoadOption` functional pattern — no changes needed to the public API

## Market Analysis

### Competitive Landscape

- **Docker Compose**: `extends:` field at service level with per-type merge semantics (maps deep-merge, lists concatenate). Users expect this pattern.
- **Containerlab**: Intra-file defaults→kinds→groups→nodes cascade. No multi-file composition. This is a documented gap in Containerlab — gridctl can differentiate here.
- **Kustomize**: Base/overlay with strategic merge patches. Powerful but complex; CRD lists are notoriously broken.
- **GitLab CI**: `extends:` with deep map merge, list replace.
- **Helm**: Layered values files, deep merge maps, replace lists.

### Market Positioning

**Differentiator** in the MCP tooling space. No MCP server management tool (mcp-hub,
mcp-serverman, mcp-configuration-manager) implements file-level config composition.
The MCP spec discussion #2218 specifically avoided inheritance in the proposed universal
config standard to keep adoption low-friction — meaning there is deliberate white space
here for tooling to fill.

### Ecosystem Support

No third-party library needed. The feature is implemented purely in the config loader
using standard Go. The merge semantics are well-understood from Docker Compose precedent.

### Demand Signals

- Directly user-requested with a concrete description of the pain point
- "Every stack is a standalone island" is the exact phrase users reach for when describing multi-stack operational toil
- Containerlab's gap here is a known frustration in the network-as-code community

## User Experience

### Interaction Model

```yaml
# base.yaml
version: "1"
name: base
mcp-servers:
  - name: auth-server
    url: https://auth.internal/mcp
  - name: logging
    image: myorg/mcp-logging:latest
    port: 8080

# dev.yaml
version: "1"
name: dev
extends: ./base.yaml          # ← new field
mcp-servers:
  - name: logging              # overrides parent's logging server
    image: myorg/mcp-logging:dev
    port: 8080
  - name: github               # additional dev-only server
    image: ghcr.io/github/mcp-server-github:latest
    port: 9000
```

Resolved server list for `dev.yaml`: `auth-server` (from base) + `logging` (child override) + `github` (child only).

### Workflow Impact

- **Reduces friction**: users managing 3+ stacks eliminate dozens of duplicate lines
- **Zero disruption**: stacks without `extends` are unaffected
- **Familiar mental model**: identical to Docker Compose — most gridctl users already know this pattern

### UX Recommendations

1. The `plan` command output should mark inherited servers visually, e.g., `(inherited from base.yaml)`, so users understand the source of each server in the merged list.
2. Error messages should include the full chain (e.g., `extends: dev.yaml → base.yaml → MISSING`) for multi-level inheritance.
3. Circular dependency errors should show the cycle explicitly: `extends: a.yaml → b.yaml → a.yaml (cycle detected)`.
4. Keep `extends` at the top level only — per-server extends is out of scope and adds complexity without proportional value.

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Critical | Copy-paste sprawl causes real config drift at scale |
| User impact | Broad+Deep | Any org with >1 stack benefits immediately |
| Strategic alignment | Core mission | "Containerlab for AI infra" analogy requires this for org-scale adoption |
| Market positioning | Leap ahead | First MCP tooling platform with file-level composition |

### Cost Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Minimal | Single insertion point in `LoadStack`, one new field on `Stack` |
| Effort estimate | Small | ~100-150 lines of production Go + ~200 lines of tests |
| Risk level | Low | `extends` is optional — zero backward compat risk; only new code paths touched |
| Maintenance burden | Minimal | Merge semantics are stable once defined |

## Recommendation

**Build.** This is an unusually clean case: high value, minimal cost, zero backward
compat risk, proven UX pattern, and first-mover advantage in the MCP tooling space.
The implementation is a single function (`mergeStacks`) inserted into the `LoadStack`
pipeline before defaults are applied.

The one design decision requiring explicit commitment is the merge strategy for
non-server fields (Gateway, Network, Logging, Secrets). The recommended approach is
**child-wins for top-level blocks** (if child defines Gateway, use child's Gateway;
otherwise inherit parent's). This is the simplest, most predictable semantic and
avoids the list-merge footguns that plague Kustomize and Helm.

Allow multi-level inheritance (A extends B extends C) but cap depth at a reasonable
limit (e.g., 10) to prevent accidental runaway chains without adding meaningful
restriction for real use cases.

## References

- [Docker Compose extends](https://docs.docker.com/compose/how-tos/multiple-compose-files/extends/)
- [Docker Compose merge semantics](https://docs.docker.com/compose/how-tos/multiple-compose-files/merge/)
- [Containerlab topology definition](https://containerlab.dev/manual/topo-def-file/)
- [GitLab CI YAML extends](https://docs.gitlab.com/ci/yaml/#extends)
- [Kustomize strategic merge patches incomplete (Sep 2025)](https://www.fractolog.com/2025/09/kustomize-strategic-merge-patches-are-incomplete/)
- [MCP universal config standard proposal #2218](https://github.com/modelcontextprotocol/modelcontextprotocol/discussions/2218)
- [mcp-hub multi-config support](https://github.com/ravitemer/mcp-hub)
