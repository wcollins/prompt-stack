# Feature Evaluation: Podman Graduation to Stable

**Date**: 2026-04-09
**Project**: gridctl
**Recommendation**: Build
**Value**: High
**Effort**: Medium

## Summary

Graduate Podman container runtime support from experimental to stable by adding multi-container integration tests, netavark/aardvark-dns detection, and removing all experimental markers. The architecture is already correct — the graduation work is focused validation and cleanup, not a rewrite. This unblocks the entire RHEL/Fedora/enterprise vertical where Docker is unavailable.

## The Idea

gridctl currently runs Podman under an "experimental" flag due to an unresolved rootless networking problem and missing integration test coverage. The README's "Known Limitations" cites slirp4netns/pasta inter-container communication as the blocker. Market research reveals the framing is imprecise: inter-container communication uses **netavark** bridge networks + aardvark-dns, not slirp4netns/pasta — and gridctl already creates named netavark bridge networks via `EnsureNetwork`. The actual gaps are test coverage and proactive detection of required platform components. Closing those gaps allows removing the experimental label and unblocking enterprise adoption in regulated environments that prohibit the Docker daemon.

## Project Context

### Current State

gridctl is a mature MCP gateway tool that aggregates tools from multiple MCP servers into a single endpoint. Container orchestration is a core feature — `image`-based MCP servers run in Docker or Podman containers managed by gridctl. Docker is stable; Podman is experimental.

The runtime abstraction is clean: `WorkloadRuntime` interface in `pkg/runtime/interface.go`, Docker implementation in `pkg/runtime/docker/`, runtime detection in `pkg/runtime/detect.go`. Both Docker and Podman use the same Docker SDK client (`github.com/docker/docker`) via Podman's Docker-compatible API socket — no separate Podman code path exists; the compat layer handles it.

Already working in Podman:
- Runtime auto-detection (Docker → Podman rootful → Podman rootless by socket priority)
- SELinux `:Z` volume label auto-detection and application (`ApplyVolumeLabels`)
- Host alias resolution (`host.containers.internal` for Podman 4.7+, `host.docker.internal` for older)
- Rootless mode detection (`IsRootless()` via socket path)
- Named bridge network creation (`EnsureNetwork` creates a netavark-backed named network)
- Container DNS aliases (containers registered with their `cfg.Name` as a DNS alias on the network)
- CI has a dedicated `podman-integration` job that installs Podman and runs the integration suite

### Integration Surface

| File | Role |
|------|------|
| `pkg/runtime/detect.go` | `IsExperimental()`, `DisplayName()`, `IsRootless()` — graduation marker removal here |
| `pkg/runtime/docker/container.go:87` | `ExtraHosts: host-gateway` — needs rootless validation |
| `cmd/gridctl/root.go:25` | `--runtime` flag help text — remove "(experimental for podman)" |
| `cmd/gridctl/info.go` | Displays `DisplayName()` — auto-updated when detect.go changes |
| `pkg/controller/controller.go` | Rootless warning display — keep but verify accuracy |
| `tests/integration/podman_test.go` | Integration tests — needs multi-container networking test |
| `.github/workflows/gatekeeper.yaml` | `podman-integration` CI job — may need test scope expansion |
| `README.md:96,137,442` | "experimental" references — update stability table, remove callout |
| `docs/troubleshooting.md:382-450` | Podman-specific issues section — update networking explanation |

### Reusable Components

- `TestContainerCleanup_CreatedNeverStarted` in `podman_test.go` — pattern for multi-container tests
- `EnsureNetwork` in `pkg/runtime/docker/network.go` — already creates the correct named bridge network
- `runtime.NetworkOptions` — driver/stack/labels already support what's needed
- Detection pattern in `detect.go` (e.g., `detectSELinux()`) — model for `detectNetavark()`

## Market Analysis

### Competitive Landscape

- **podman-compose**: Uses `podman network create` (netavark) for DNS-based service discovery in rootless mode. Works correctly on Podman 4.0+ with netavark + aardvark-dns. Shows the pattern is viable.
- **Testcontainers-Go**: Detects Podman socket, adjusts defaults (network name), surfaces known incompatibilities explicitly (Ryuk/privileged container). The pattern is: detect → adjust → warn; don't silently fail.
- **Dagger**: Requires rootful for anything beyond trivial use. Not a model for gridctl.
- **VS Code Dev Containers**: Does NOT officially support Podman (listed as "may work"). First-mover opportunity.

### Market Positioning

Table-stakes for RHEL enterprise adoption. RHEL 8 and RHEL 9 ship Podman as the exclusive container runtime — Docker is not packaged. Every RHEL shop hitting gridctl sees "podman (experimental)" immediately. In regulated/government environments where Docker's daemon model is prohibited, this is a hard stop. Stable Podman support is not a differentiator among general container tooling, but it IS a differentiator in the MCP/AI tooling space where no comparable tool has stable Podman support.

### Ecosystem Support

- Podman 4.0+: netavark + aardvark-dns, rootless named bridge networks, inter-container DNS
- Podman 4.7+: `host.containers.internal` (already handled in gridctl)
- Podman 5.0+: pasta as default egress transport (replaces slirp4netns)
- Podman 5.3+: `--map-guest-addr` in pasta, fixing container-to-host via `host.containers.internal`
- Docker SDK: works against Podman compat API — no library change needed

### Demand Signals

- User opened this feature request citing RHEL/Fedora enterprise environments as a hard adoption blocker
- MCP ecosystem PR #2205 (modelcontextprotocol/servers) adds SELinux/Podman bind mount compat — demand exists at the ecosystem level
- RHEL = Podman only, no Docker. Every RHEL gridctl user is blocked by the experimental label.

## User Experience

### Interaction Model

Post-graduation, a RHEL user's experience:
1. `sudo dnf install podman` (already installed by default on RHEL 9)
2. `systemctl --user enable --now podman.socket`
3. `gridctl apply stack.yaml` — Podman auto-detected, no experimental warning
4. `gridctl info` shows `Runtime: podman` (not "podman (experimental)")

Rootless users with multi-container stacks get a clear warning if netavark/aardvark-dns are missing, with actionable install instructions. If running Podman < 4.0, a version warning points to the upgrade path.

### Workflow Impact

**Before graduation**: Users see "experimental" in help text, `gridctl info`, and README — creating hesitation and support overhead. RHEL users with rootless Podman encounter silent networking failures with no actionable guidance.

**After graduation**: Podman is a peer to Docker in all UX surfaces. Rootless users get proactive detection: if netavark/aardvark-dns are absent, gridctl warns before attempting to start a multi-container stack rather than failing silently mid-apply.

### UX Changes Required

All "experimental" strings to update:
- `detect.go:336` — `DisplayName()`: `"podman (experimental)"` → `"podman"`
- `detect.go:347-350` — `IsExperimental()`: return `false` for Podman (or remove if unused)
- `root.go:25` — `--runtime` help: remove "(experimental for podman)"
- `README.md:96` — "supported as an experimental alternative" → "also fully supported"
- `README.md:137` — remove the NOTE callout block about experimental status
- `README.md:442` — stability table: `Experimental` → `Stable`, "May change without notice" → "Backward compatible in 0.x"
- `docs/troubleshooting.md:384-409` — correct the "slirp4netns or pasta" framing (they're egress, not inter-container); document netavark as the inter-container mechanism
- Known Limitations section: remove Podman rootless networking entry (or replace with Podman < 4.0 caveat)

### UX Recommendations

1. Keep the rootless warning in `controller.go` and `info.go` — it's a technical limitation notice, not a stability concern, and it's useful for users who haven't installed netavark.
2. Add a `detectNetavark()` check alongside `IsRootless()` — if rootless + multi-container + no netavark, warn at `apply` time with a specific install command rather than failing at container start.
3. Add a minimum version gate: if Podman < 4.0, warn prominently (pre-netavark environments).

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Critical | RHEL = Podman only; no Docker option. Experimental label blocks enterprise adoption entirely. |
| User impact | Narrow + Deep | Specific vertical (RHEL/regulated enterprise), but within it the impact is absolute. |
| Strategic alignment | Core mission | Container runtime support is foundational. Supporting the dominant Linux enterprise runtime at stable status is not optional for enterprise reach. |
| Market positioning | Differentiate | No MCP tooling has stable Podman support. VS Code Dev Containers doesn't officially support it. First-mover in AI tooling. |

### Cost Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Minimal | Architecture is already correct. Docker SDK + Podman compat API works. Named bridge networks already created. No core abstractions change. |
| Effort estimate | Medium | Multi-container integration test (the hardest part), netavark detection, docs update, marker removal. Approximately 1–2 weeks focused. |
| Risk level | Low | Existing code already works for most scenarios. Changes are additive (tests, detection) or cosmetic (marker removal). No breaking changes to stable APIs. |
| Maintenance burden | Minimal | CI `podman-integration` job already exists. Podman tracks Docker compat API. No new architectural seam. |

## Recommendation

**Build.** The architecture is already correct — gridctl creates named netavark bridge networks and registers DNS aliases, which IS the correct approach for rootless inter-container communication. The experimental label is conservative technical debt, not a reflection of broken functionality. The graduation work is focused:

1. Write multi-container integration test(s) that prove two containers can resolve each other by name in rootless Podman — this is the single most valuable deliverable
2. Add netavark/aardvark-dns presence detection with actionable warnings
3. Verify `host-gateway` / `host.containers.internal` behavior in rootless mode under Podman 5.x
4. Set a minimum version gate for Podman 4.0 (netavark floor)
5. Remove all "experimental" markers across detect.go, root.go, README, troubleshooting.md
6. Correct the Known Limitations entry (it currently describes the wrong mechanism)

No new dependencies. No architectural changes. The hardest part is the multi-container test, which is also the proof that everything works.

## References

- Podman basic networking tutorial: https://github.com/containers/podman/blob/main/docs/tutorials/basic_networking.md
- Podman rootless shortcomings: https://github.com/containers/podman/blob/main/rootless.md
- pasta/passt project: https://passt.top/passt/about/
- netavark: https://github.com/containers/netavark
- aardvark-dns: https://github.com/containers/aardvark-dns
- Podman 5.0 release (pasta as default): https://github.com/containers/podman/releases/tag/v5.0.0
- Podman 5.3 pasta `--map-guest-addr` fix: https://github.com/containers/podman/pull/23791
- Testcontainers-Go Podman docs: https://golang.testcontainers.org/system_requirements/using_podman/
- MCP servers Podman/SELinux PR: https://github.com/modelcontextprotocol/servers/pull/2205
- Podman networking docs (eriksjolund): https://github.com/eriksjolund/podman-networking-docs
