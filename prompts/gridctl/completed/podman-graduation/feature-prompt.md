# Feature Implementation: Podman Runtime Graduation to Stable

## Context

gridctl is a Go CLI tool that aggregates tools from multiple MCP (Model Context Protocol) servers into a single gateway endpoint. It manages container orchestration via Docker or Podman — users define a stack in YAML, run `gridctl apply stack.yaml`, and gridctl spins up containers and wires them into a unified MCP gateway.

**Tech stack**: Go 1.23+, Docker SDK (`github.com/docker/docker`), React frontend, GitHub Actions CI.

**Architecture**:
- `pkg/runtime/` — runtime abstraction layer
- `pkg/runtime/interface.go` — `WorkloadRuntime` interface (13 methods)
- `pkg/runtime/detect.go` — runtime detection, `RuntimeInfo` struct, feature helpers
- `pkg/runtime/docker/` — Docker implementation (used for both Docker and Podman via compat API)
- `pkg/runtime/docker/container.go` — container creation with networking config
- `pkg/runtime/docker/network.go` — named bridge network creation
- `tests/integration/podman_test.go` — Podman integration tests
- `.github/workflows/gatekeeper.yaml` — CI with `podman-integration` job

Podman uses the same Docker SDK client against Podman's Docker-compatible API socket. No separate Podman code path exists — the compat layer handles it.

## Evaluation Context

Full evaluation: `/Users/william/code/prompt-stack/prompts/gridctl/podman-graduation/feature-evaluation.md`

Key findings that shaped this prompt:

- **The framing in the README is wrong**: it says "slirp4netns or pasta" are required for inter-container communication. They are not — they are *egress* transports (container → host). Inter-container communication uses **netavark** bridge networks + aardvark-dns, and gridctl **already creates named netavark bridge networks** via `EnsureNetwork`. The architecture is correct.
- **The actual gaps**: no multi-container networking integration test, no proactive detection of netavark/aardvark-dns, incorrect documentation, and all "experimental" markers still in place.
- **Market signal**: RHEL 8/9 ships Podman as the only container runtime (Docker not packaged). Every RHEL gridctl user sees "podman (experimental)". This is the single largest barrier to enterprise adoption.
- **Comparable tools** (Testcontainers-Go, podman-compose) use the exact same approach — named netavark bridge networks — and it works in rootless mode on Podman 4.0+.
- **Podman 5.3+** fixed container-to-host connectivity in pasta mode via `--map-guest-addr`. The `host-gateway` / `host.containers.internal` path needs validation against current Podman versions.

## Feature Description

Graduate Podman container runtime support from "experimental" to "stable" in gridctl. This involves:

1. Adding multi-container integration test(s) that prove two containers can resolve each other by DNS name on a shared named network in rootless Podman
2. Adding detection for netavark and aardvark-dns presence, with actionable warnings when missing
3. Adding a minimum Podman version gate (4.0 for netavark floor)
4. Verifying `host-gateway` / `host.containers.internal` behavior under current Podman (5.x) in rootless mode
5. Removing all "experimental" markers from code, CLI, and documentation
6. Correcting the Known Limitations text and troubleshooting documentation

No new dependencies. No architectural changes. No changes to stable APIs.

## Requirements

### Functional Requirements

1. Two containers started on the same gridctl-managed named network in rootless Podman must be able to reach each other by DNS alias (the name registered in `EndpointsConfig.Aliases`).
2. When rootless Podman is detected and netavark is absent (or aardvark-dns binary is missing), gridctl must emit a clear warning at `apply` time before attempting to start a multi-container stack — not fail silently mid-execution.
3. When Podman < 4.0 is detected, gridctl must warn that multi-container stacks may not work and recommend upgrading.
4. Container-to-host communication via `host.containers.internal` (Podman 4.7+) or `host.docker.internal` (fallback) must work correctly in rootless mode. Verify and fix if needed.
5. `gridctl info` must display `Runtime: podman` (not "podman (experimental)") after graduation.
6. `gridctl apply --runtime podman --help` must not contain "(experimental for podman)" in the flag description.
7. All CI integration tests (both the `integration` and `podman-integration` jobs) must pass.

### Non-Functional Requirements

8. The multi-container networking integration test must run in the `podman-integration` CI job using rootless Podman on Ubuntu (the current CI setup).
9. No new Go module dependencies may be added.
10. Existing Docker integration tests must continue to pass unchanged.
11. The `IsExperimental()` method must return `false` for Podman (or be removed if no callers remain).

### Out of Scope

- Podman pod support (shared network namespace / `podman pod create`)
- macOS Podman machine support (VM-based; fundamentally different networking)
- Quadlet / systemd unit file generation
- Podman-native Go bindings (`github.com/containers/podman/v5/pkg/bindings`) — Docker SDK compat API is the right approach
- rootful-only restriction (rootless should remain supported)
- Any changes to stable Docker runtime behavior

## Architecture Guidance

### Recommended Approach

**Step 1: Write the multi-container networking integration test first.** This is the specification. If it passes in the CI `podman-integration` job, graduation is proven. If it fails, the failure will pinpoint exactly what needs fixing.

The test should:
- Create a named bridge network
- Start two containers (use `alpine:latest`) connected to that network with distinct names
- From container A, `wget` or `nslookup` container B by its registered DNS alias
- Assert success
- Clean up

**Step 2: Run the test in CI.** Push to a branch that triggers the `podman-integration` job and check if the networking test passes. If it does, the architecture is validated and graduation is primarily a cleanup exercise. If not, the failure output will identify whether the issue is DNS (aardvark-dns), IP routing (netavark), or the `host-gateway` egress path.

**Step 3: Add detection.** Based on what Step 2 reveals, add appropriate `detectNetavark()` and `detectAardvarkDNS()` helpers in `detect.go` following the pattern of `detectSELinux()`. Surface warnings via the controller when rootless + multi-container conditions are met.

**Step 4: Remove experimental markers.** Once tests pass, remove all "experimental" strings from code, CLI, and docs.

**Step 5: Fix documentation.** Correct the Known Limitations entry and troubleshooting section to accurately describe the netavark dependency (not slirp4netns/pasta).

### Key Files to Understand

| File | Why it matters |
|------|---------------|
| `pkg/runtime/detect.go` | All graduation marker changes live here: `DisplayName()`, `IsExperimental()`, `IsRootless()`, and new detection helpers |
| `pkg/runtime/docker/container.go:83-96` | `ExtraHosts: host-gateway` — verify this works in rootless Podman 5.x; the `EndpointsConfig.Aliases` at line 93 is how container-to-container DNS works |
| `pkg/runtime/docker/network.go` | `EnsureNetwork` already creates the right named bridge network; understand what options are passed |
| `tests/integration/podman_test.go` | All existing Podman integration tests; add the multi-container test here |
| `.github/workflows/gatekeeper.yaml:97-132` | `podman-integration` CI job setup; understand how rootless Podman is configured (socket path, GRIDCTL_RUNTIME env var) |
| `pkg/controller/controller.go` | Where rootless warning is currently emitted; extend for netavark detection |
| `cmd/gridctl/info.go` | Displays `DisplayName()` — will auto-fix when detect.go changes |
| `cmd/gridctl/root.go:25` | `--runtime` flag help text — remove experimental qualifier |
| `README.md:96,137,442` | "experimental" references — update stability table, remove callout box |
| `docs/troubleshooting.md:382-452` | Podman-specific issues section — correct the networking mechanism description |

### Integration Points

**`detect.go` — new helpers to add** (following `detectSELinux()` pattern):

```go
// detectNetavark checks if netavark is available for rootless bridge networking.
func detectNetavark() bool {
    _, err := exec.LookPath("netavark")
    return err == nil
}

// detectAardvarkDNS checks if aardvark-dns is available for inter-container DNS.
func detectAardvarkDNS() bool {
    _, err := exec.LookPath("aardvark-dns")
    return err == nil
}
```

Also add to `RuntimeInfo`:

```go
type RuntimeInfo struct {
    // ... existing fields ...
    HasNetavark    bool // Whether netavark is available (rootless inter-container networking)
    HasAardvarkDNS bool // Whether aardvark-dns is available (inter-container DNS resolution)
}
```

Populate in `buildRuntimeInfo()` when runtime is Podman and rootless.

**`detect.go` — version gate**:

```go
// IsSupportedPodmanVersion returns true if the Podman version supports netavark (4.0+).
func (info *RuntimeInfo) IsSupportedPodmanVersion() bool {
    if info.Type != RuntimePodman {
        return true // Not applicable
    }
    return compareSemver(info.Version, "4.0.0") >= 0
}
```

**`controller.go` — extend the rootless warning block** to check netavark/aardvark-dns and version:

```go
if info.IsRootless() {
    if !info.IsSupportedPodmanVersion() {
        printer.Warn("Podman %s detected — upgrade to 4.0+ for multi-container networking support", info.Version)
    }
    if !info.HasNetavark {
        printer.Warn("netavark not found — rootless multi-container networking requires netavark: sudo dnf install netavark")
    }
    if !info.HasAardvarkDNS {
        printer.Warn("aardvark-dns not found — inter-container DNS requires aardvark-dns: sudo dnf install aardvark-dns")
    }
}
```

**`detect.go` — graduation marker changes**:

```go
// DisplayName — remove "(experimental)"
func (info *RuntimeInfo) DisplayName() string {
    switch info.Type {
    case RuntimePodman:
        return "podman"
    default:
        return "docker"
    }
}

// IsExperimental — return false (or remove after checking all callers)
func (info *RuntimeInfo) IsExperimental() bool {
    return false
}
```

### Reusable Components

- `detectSELinux()` in `detect.go` — exact pattern to follow for `detectNetavark()` and `detectAardvarkDNS()`
- `compareSemver()` in `detect.go` — use for version gate
- `TestContainerCleanup_CreatedNeverStarted` in `podman_test.go` — pattern for the multi-container test (create network, start containers, verify, clean up)
- `EnsureNetwork` in `network.go` — already correct; use as-is in the test

## UX Specification

### Rootless Podman — before multi-container apply

If rootless Podman is detected and netavark/aardvark-dns are missing:

```
⚠  Rootless Podman detected — multi-container networking requires netavark and aardvark-dns.
   Install: sudo dnf install netavark aardvark-dns   (Fedora/RHEL)
            sudo apt install netavark              (Debian/Ubuntu)
   Continuing — single-container stacks will work; multi-container stacks may fail.
```

This is a warning, not a hard stop — single-container stacks work fine.

### `gridctl info` output (post-graduation)

```
Runtime:  podman
Version:  5.3.1
Socket:   /run/user/1000/podman/podman.sock
Mode:     rootless
Network:  netavark + aardvark-dns ✓
```

### `--runtime` flag help (post-graduation)

```
--runtime string   Container runtime to use (docker, podman). Auto-detected if not set.
```

## Implementation Notes

### Conventions to Follow

- All new functions in `detect.go` should follow the existing style: short, single-responsibility, return bool or primitive
- Integration tests use the `//go:build integration` build tag — do not omit it
- Test functions must be skippable when the runtime is unavailable (pattern: `t.Skipf("No container runtime available: %v", err)`)
- Error messages follow the existing pattern: terse description, then actionable next steps

### Potential Pitfalls

1. **`host-gateway` in rootless**: The string `"host-gateway"` in `ExtraHosts` is Docker-specific magic. Podman's compat API supports it in rootful mode but behavior in rootless changed between Podman versions. Test this explicitly. If it doesn't work in rootless, the fix is to resolve the gateway IP explicitly and inject it as a literal IP rather than the magic string.

2. **aardvark-dns binary location**: On some distros, aardvark-dns installs to `/usr/libexec/podman/aardvark-dns` or `/usr/lib/podman/aardvark-dns`, not in `$PATH`. Use `exec.LookPath` first; if not found, also check known libexec paths.

3. **CI rootless Podman version**: The `podman-integration` job installs whatever version `apt-get install podman` provides on Ubuntu. Check the Ubuntu package version — if it's < 4.7, `host.containers.internal` won't be in play and the host alias fallback code path will be exercised. This is fine but worth noting in the test.

4. **The default `podman` network**: Podman maintains a default `podman` network for Docker compatibility. This network does NOT support DNS resolution. gridctl creates its own named networks (`EnsureNetwork`), which is the correct approach. Do not rely on the default `podman` network in tests.

5. **`IsExperimental()` callers**: Before removing or changing this method, search all callers: `grep -r "IsExperimental" --include="*.go"`. Update every call site.

6. **README stability table ordering**: The stability table in README.md should list Podman as "Stable | Backward compatible in 0.x" consistent with Docker orchestration.

### Suggested Build Order

1. **Read and understand** the files listed in "Key Files to Understand" before writing any code
2. **Write the multi-container networking integration test** in `podman_test.go` — this drives everything
3. **Run it locally** against a rootless Podman installation (or review the CI `podman-integration` output) to confirm pass/fail
4. **If it passes**: proceed to marker removal and docs. **If it fails**: debug the specific failure, then fix before proceeding.
5. **Add netavark/aardvark-dns detection** in `detect.go` + `RuntimeInfo` struct
6. **Extend the controller warning block** for rootless + missing components
7. **Remove experimental markers** (detect.go → root.go → README → troubleshooting.md) — do all in the same PR
8. **Update `detect_test.go`** for `DisplayName()` assertion change
9. **Verify CI** — both `integration` and `podman-integration` jobs must be green

## Acceptance Criteria

1. A new integration test in `tests/integration/podman_test.go` starts two containers on a shared named network in rootless Podman and verifies container B is reachable by its DNS alias from container A.
2. The `podman-integration` CI job passes with the new test included.
3. `gridctl info` with rootless Podman displays `Runtime: podman` (no "experimental" suffix).
4. `gridctl apply --help` contains no "(experimental for podman)" text.
5. `README.md` stability table shows `Podman runtime | Stable | Backward compatible in 0.x`.
6. The "Known Limitations" section in README.md no longer lists "Podman rootless networking requires slirp4netns or pasta for inter-container communication" as an unresolved issue (either removed or replaced with accurate netavark dependency note).
7. `docs/troubleshooting.md` Podman section correctly describes the networking architecture: netavark for inter-container, pasta/slirp4netns for egress.
8. When rootless Podman is detected and netavark is absent, `gridctl apply` emits a warning with actionable install instructions before proceeding.
9. When Podman < 4.0 is detected, `gridctl apply` emits a version warning.
10. All existing unit and integration tests continue to pass.
11. `IsExperimental()` returns `false` for Podman (or is removed if no callers remain after the change).

## References

- Podman basic networking tutorial: https://github.com/containers/podman/blob/main/docs/tutorials/basic_networking.md
- Podman rootless limitations: https://github.com/containers/podman/blob/main/rootless.md
- netavark (Podman network stack): https://github.com/containers/netavark
- aardvark-dns (container DNS): https://github.com/containers/aardvark-dns
- pasta/passt project: https://passt.top/passt/about/
- Podman 5.0 release notes (pasta as default): https://github.com/containers/podman/releases/tag/v5.0.0
- Podman 5.3 pasta host.containers.internal fix: https://github.com/containers/podman/pull/23791
- Testcontainers-Go Podman pattern: https://golang.testcontainers.org/system_requirements/using_podman/
- eriksjolund Podman networking docs: https://github.com/eriksjolund/podman-networking-docs
- Full feature evaluation: /Users/william/code/prompt-stack/prompts/gridctl/podman-graduation/feature-evaluation.md
