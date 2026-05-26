# Feature Evaluation: Curl Install Script + Cross-Platform Audit

**Date**: 2026-04-27
**Project**: gridctl
**Recommendation**: **Build**
**Value**: Medium-High (broad + shallow user impact, core strategic alignment)
**Effort**: Small-Medium (2-3 days — installer + upgrade subcommand + uninstall flag)

## Summary

Add a complete standalone install lifecycle:

1. A one-line `curl | bash` installer (modeled on opencode.ai, k3s, and goreleaser/run) that auto-detects OS/arch, downloads the matching GoReleaser archive from GitHub Releases, verifies its SHA256 checksum against the published `checksums.txt`, and installs to `~/.local/bin/gridctl` with no sudo
2. A `gridctl upgrade` Cobra subcommand that fetches the latest release, verifies its checksum, and replaces the running binary in place (with brew-install detection that defers to `brew upgrade`)
3. An `install.sh --uninstall` flag that removes the binary and optionally the config directory

Host the script at `raw.githubusercontent.com/gridctl/gridctl/main/install.sh` for now; migrate to `install.gridctl.dev` later if traffic justifies it. Update the README to lead with the curl one-liner and demote brew to a "Package managers" subsection.

The change is purely additive, opt-in, and reversible — existing brew users are unaffected. GoReleaser already produces the right artifacts and checksum file, so no release-pipeline changes are required.

## The Idea

Today gridctl users install via `brew install gridctl/tap/gridctl` (macOS, Linux-with-Homebrew) or build from source. This excludes the bulk of Linux users who don't run Homebrew, makes the README's "demo-friendly, fast, ephemeral" pitch ring hollow when step zero is "install Homebrew first," and means there is no shareable single-line install URL for tutorials, blog posts, or conference slides.

A curl installer solves three problems at once:
1. **Linux-without-brew users** get a frictionless path.
2. **WSL2 users** get a Linux-native experience (the binary is identical to native Linux).
3. **Marketing surface area** — a single short URL replaces "install Homebrew, then tap, then install."

Windows-native is explicitly out of scope (WSL2 only). PowerShell installer can be a Phase 3 follow-up if/when native Windows binaries are added.

## Project Context

### Current State

- **Tool shape**: Go CLI with embedded React web UI (single binary via `go:embed`), MCP gateway/orchestrator
- **Version**: v0.1.0-beta.6 (active beta, biweekly releases, fork workflow)
- **Build pipeline**: GoReleaser 2.x triggered on `v*` tags, runs in GitHub Actions on `ubuntu-latest`
- **Release artifacts** (verified on v0.1.0-beta.6):
  - `gridctl_<version>_darwin_amd64.tar.gz`
  - `gridctl_<version>_darwin_arm64.tar.gz`
  - `gridctl_<version>_linux_amd64.tar.gz`
  - `gridctl_<version>_linux_arm64.tar.gz`
  - `checksums.txt` (SHA256, GoReleaser default)
- **Homebrew tap**: auto-published to `gridctl/homebrew-tap` post-release; cask runs `xattr -dr com.apple.quarantine` on macOS

### Integration Surface

- `scripts/install.sh` — **new file** (canonical install script with `--uninstall` flag)
- `cmd/gridctl/upgrade.go` — **new file** (Cobra subcommand `gridctl upgrade`)
- `cmd/gridctl/root.go` — register the new `upgrade` subcommand on the root command
- `README.md` lines 71-92 — install section reorder, plus an "Updating" / "Uninstalling" subsection
- `.github/workflows/install-smoke.yaml` — **new file** (CI smoke test for install + upgrade + uninstall)
- `.goreleaser.yaml` lines 87-98 — release footer should reference the curl install command alongside brew (one-line addition)

### Reusable Components

- GoReleaser already produces `checksums.txt` (no work needed)
- Archive naming `<project>_<version>_<os>_<arch>.tar.gz` is GoReleaser-default and matches what the install script will compute via `uname` mapping
- `cmd/gridctl/version.go` already exposes `version` via ldflags — `gridctl --version` after install will confirm success

## Market Analysis

### Competitive Landscape

Every comparable Go CLI ships a curl installer:

| Tool | Install URL | Pattern |
|---|---|---|
| **mise** | `mise.run` | POSIX `set -eu`, embedded SHA256, `~/.local/bin/mise` |
| **uv** | `astral.sh/uv/install.sh` | POSIX `set -u`, multi-algorithm checksum, `$XDG_BIN_HOME` |
| **bun** | `bun.sh/install` | bash `set -euo pipefail`, Rosetta + AVX2 detection, `~/.bun/bin` |
| **opencode** | `opencode.ai/install` | bash `set -euo pipefail`, GitHub API tag scrape, `~/.opencode/bin` |
| **k3s** | `get.k3s.io` | `set -e`, SHA256 verify, `trap cleanup INT EXIT` |
| **goreleaser/run** | `goreleaser.com/static/run` | SHA256 + cosign keyless signature verify |
| **deno** | `deno.land/install.sh` | `set -e`, Rust-target-triple detection |
| **rustup** | `sh.rustup.rs` | POSIX `set -u`, TLS pinning, `ensure`/`ignore` wrappers |

### Market Positioning

**Catch-up, not leap-ahead.** A curl installer is table-stakes for serious Go CLIs in 2026. Not having one signals "early stage." gridctl is at v0.1.0-beta.6 with a polished README and OpenSSF Best Practices badge — the install story should match that maturity.

### Ecosystem Support

- **GoReleaser** already produces the consumed artifacts and checksums
- **shellcheck** lints the install script in CI
- **GitHub Actions** can smoke-test the script on `ubuntu-latest` and `macos-latest`
- No third-party dependencies needed; the script uses POSIX tools (`curl`, `tar`, `sha256sum`/`shasum`, `mkdir`, `mv`, `chmod`)

### Demand Signals

User-driven request from project owner. No GitHub issues currently track this, but the absence is structural — the comparable cohort universally ships this pattern, and the user explicitly cites opencode.ai's installer as the model. Demand is anticipatory rather than reactive.

## User Experience

### Interaction Model

**First-time install:**
```bash
curl -fsSL https://raw.githubusercontent.com/gridctl/gridctl/main/install.sh | bash
```

What the user sees:
```
gridctl installer
  Detecting platform: darwin/arm64
  Latest release:    v0.1.0-beta.6
  Downloading:       gridctl_0.1.0-beta.6_darwin_arm64.tar.gz
  Verifying:         SHA256 ✓
  Installing to:     /Users/william/.local/bin/gridctl

Installed gridctl v0.1.0-beta.6
Run `gridctl --help` to get started.
Docs: https://github.com/gridctl/gridctl
```

If `~/.local/bin` is not on `$PATH`, the script appends a guidance block:
```
Note: ~/.local/bin is not on your PATH. Add this line to your shell rc:
  export PATH="$HOME/.local/bin:$PATH"
```

### Workflow Impact

- **New users**: replaces a 3-step brew-tap dance with a single command
- **Existing brew users**: unaffected; if they accidentally run the curl script, it detects the brew install and bails with guidance ("gridctl is already installed via Homebrew at <path>. Use `brew upgrade gridctl/tap/gridctl` or remove the brew install first with `--force`.")
- **CI/Docker users**: get an unattended install (no sudo, no prompts)
- **Tutorial / blog authors**: get a single short URL to embed

### UX Recommendations

1. **Lead with curl, demote brew.** README install section reordered so the curl one-liner is the prominent block.
2. **No sudo, no prompts.** Default install dir is `~/.local/bin`. Override via `GRIDCTL_INSTALL_DIR` env var.
3. **Verify SHA256 against the published `checksums.txt`.** Free trust signal.
4. **Detect existing brew install.** Bail with guidance instead of clobbering.
5. **Detect missing PATH.** Print copy-pasteable export line; do not edit shell rc files automatically (rustup philosophy — less invasive).
6. **`NO_COLOR` env var support.** ANSI colors in TTYs, plain text in CI.
7. **Idempotent re-runs.** Re-running the script with the same version installed is a no-op with a "already installed" message.
8. **Neutral trust framing.** Match uv's tone: "The install script may be inspected before use: `curl -fsSL <url> | less`." No defensive disclaimers.
9. **WSL2 callout in README.** One sentence: "Windows: install via WSL2, then run the Linux command above." No script changes — WSL2 is Linux to the binary.
10. **CI smoke test.** GitHub Actions matrix on `ubuntu-latest` + `macos-latest` runs `bash install.sh && gridctl --version`. Catches regressions before users see them.

## Feasibility

### Value Breakdown
| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Significant | Brew-only excludes Linux-without-brew + WSL2 audiences; build-from-source has Go+Node prereqs |
| User impact | Broad + Shallow | Helps every prospective user once, at the highest-leverage moment (first impression) |
| Strategic alignment | Core | Reinforces gridctl's "fast, ephemeral, demo-friendly" positioning ("Containerlab for AI Agents") |
| Market positioning | Catch up | Table-stakes for comparable Go CLIs; absent it signals "early stage" |

### Cost Breakdown
| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Minimal-Moderate | Install script is purely additive; `gridctl upgrade` adds one Cobra subcommand and reuses the binary's existing `version` package and HTTP/checksum logic |
| Effort estimate | Small-Medium | 2-3 days: ~250-line bash script + ~150-line Go subcommand + uninstall flag + README + CI smoke test |
| Risk level | Low | Opt-in, reversible; SHA256 verification mitigates the curl-pipe-bash supply-chain concern; `upgrade` writes to the same path the binary already runs from (atomic rename) |
| Maintenance burden | Minimal | Reads release artifacts via GitHub API; new releases need no script or subcommand changes. One ongoing concern: the upgrade in-place rename behavior on running binaries (validated and documented in the prompt) |

## Recommendation

**Build — full install lifecycle in a single PR.** Scope guardrails:

### Ships in this PR
- `scripts/install.sh` (POSIX-compatible, ~250 lines, shellcheck-clean)
  - Installs latest release, verifies SHA256, supports `GRIDCTL_VERSION=` and `GRIDCTL_INSTALL_DIR=` env overrides
  - `--uninstall` flag removes the binary; `--purge` additionally removes `~/.gridctl` config dir
- `cmd/gridctl/upgrade.go` — `gridctl upgrade` Cobra subcommand
  - Detects brew install and defers to `brew upgrade`
  - Otherwise downloads new binary, verifies SHA256, atomically replaces self
  - Flags: `--check` (just check), `--version <ver>`, `--force`, `--yes` (non-interactive)
- README install-section rewrite (curl-first, brew second, source third) + Updating/Uninstalling subsection
- `.github/workflows/install-smoke.yaml` smoke test on Ubuntu + macOS runners — installs, runs `gridctl upgrade --check`, runs `install.sh --uninstall`
- One-line addition to `.goreleaser.yaml` release footer to advertise the curl command

### Deferred (until traffic / signal justifies)
- `install.gridctl.dev` custom domain via Cloudflare Worker / Pages redirect
- PowerShell `install.ps1` (only if native Windows binaries are ever added)
- Cosign signature verification (requires GoReleaser signing setup first)

### Why not "Build with caveats"

The risk profile is genuinely Low. The classical `curl | bash` security objection is mitigated by:
1. HTTPS + GitHub's TLS chain
2. SHA256 verification of the downloaded archive against `checksums.txt`
3. Tag-pinned URL for production-stable docs (`/v0.1.0-beta.6/install.sh`)
4. The script being open and inspectable by design — copy-paste the URL into `less`

These are the same mitigations the entire comparable cohort uses. No further caveats are warranted.

## References

- [opencode install script (canonical)](https://opencode.ai/install)
- [opencode source repo](https://github.com/sst/opencode)
- [k3s install.sh (gold-standard trap+sha256 pattern)](https://github.com/k3s-io/k3s/blob/master/install.sh)
- [goreleaser install runner (sha256+cosign in ~60 lines)](https://goreleaser.com/static/run)
- [uv install script (most thorough PATH resolution)](https://releases.astral.sh/installers/uv/latest/uv-installer.sh)
- [mise install script (clean POSIX example)](https://mise.run)
- [bun install script (bash + Rosetta detection)](https://bun.sh/install)
- [rustup install script (TLS pinning, ensure wrappers)](https://sh.rustup.rs)
- [GoReleaser archives + checksums docs](https://goreleaser.com/customization/checksum/)
- [GitHub raw content rate limit changes (May 2025)](https://github.blog/changelog/2025-05-08-updated-rate-limits-for-unauthenticated-requests/)
- [Sandstorm: Is curl|bash insecure? (mitigations writeup)](https://sandstorm.io/news/2015-09-24-is-curl-bash-insecure-pgp-verified-install)
