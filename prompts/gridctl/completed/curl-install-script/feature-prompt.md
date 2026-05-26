# Feature Implementation: Curl Install Script for gridctl

## Context

**gridctl** is a Go-based MCP (Model Context Protocol) gateway and orchestrator. It aggregates tools from multiple MCP servers behind a single endpoint. Users define their MCP stack in YAML and apply it with `gridctl apply stack.yaml`. The binary embeds a React web UI (served at `localhost:8180`) via Go's `embed` directive — single self-contained binary.

**Tech stack & repo layout:**
- Go 1.26 (`go.mod`), Cobra CLI framework
- React frontend in `web/`, built and embedded into `cmd/gridctl/web/dist/` via `make build` with `-tags embed_web`
- Released via **GoReleaser** triggered on `v*` tag pushes (`.github/workflows/release.yaml`)
- **Fork workflow**: origin = `wcollins/gridctl`, upstream = `gridctl/gridctl` — work on feature branches off origin and PR upstream
- Existing scripts live in `scripts/` (currently `check-coverage.sh`, `govulncheck.sh`)

**Current install story (README.md lines 71-92):**
```bash
brew install gridctl/tap/gridctl
```
With a collapsed `<details>` block for build-from-source and a link to GitHub Releases. No install script exists today.

**Release artifact naming** (verified on v0.1.0-beta.6):
```
gridctl_<version>_darwin_amd64.tar.gz
gridctl_<version>_darwin_arm64.tar.gz
gridctl_<version>_linux_amd64.tar.gz
gridctl_<version>_linux_arm64.tar.gz
checksums.txt   # SHA256 sums, GoReleaser default name
```
Version strings in archive names are **without** the `v` prefix (e.g., `0.1.0-beta.6`, not `v0.1.0-beta.6`); release tags **are** prefixed with `v`. The script must handle both forms.

## Evaluation Context

The full evaluation is at `prompts/gridctl/curl-install-script/feature-evaluation.md`. Key findings that shaped this prompt:

- **Market consensus**: Every comparable Go CLI (mise, uv, bun, opencode, k3s, goreleaser/run, deno, rustup, fly) ships a curl installer. gridctl is "catching up," not innovating — copy proven patterns rather than inventing new ones.
- **Best-in-class reference**: `goreleaser/run` and `k3s` install.sh — concise, SHA256-verifying, trap-cleaning. opencode.ai's script (460 lines) is over-engineered for gridctl's needs (it does AVX2 baseline detection, musl variants, Rosetta — none apply here because Go binaries from GoReleaser don't have variants). Borrow opencode's *style* (banner, ANSI, idempotency) but copy k3s's *structure* (sha256-mandatory, simpler).
- **No-sudo install philosophy**: install to `~/.local/bin`, not `/usr/local/bin`. Matches mise/bun/opencode. Avoids sudo prompts that break unattended use cases (CI, demos, Docker images).
- **Trust signaling**: SHA256 verification against the published `checksums.txt` is the single most important security mitigation. Non-negotiable. Use neutral framing for the inspection-before-running option (uv pattern), not defensive disclaimers.
- **Brew coexistence**: Detect existing brew install and bail with guidance. Two binaries on PATH is a support nightmare.
- **WSL2 = Linux**: No special handling needed in the script. One-sentence README callout is enough.

## Feature Description

Add a complete standalone install lifecycle for gridctl on macOS (amd64, arm64) and Linux/WSL2 (amd64, arm64):

1. **Install** — A one-line `curl | bash` installer that downloads the matching GoReleaser archive from GitHub Releases, verifies its SHA256 checksum against the published `checksums.txt`, extracts the binary, places it on the user's PATH (default `~/.local/bin`), and prints next-steps guidance.

2. **Upgrade** — A `gridctl upgrade` Cobra subcommand that checks for a newer release, downloads + verifies it, and atomically replaces the running binary in place. Detects brew-managed installs and defers to `brew upgrade`.

3. **Uninstall** — An `install.sh --uninstall` flag that removes the binary, with an optional `--purge` flag that also removes the gridctl config directory (`~/.gridctl`).

The install command:
```bash
curl -fsSL https://raw.githubusercontent.com/gridctl/gridctl/main/install.sh | bash
```

The upgrade command (after install):
```bash
gridctl upgrade           # check + prompt + upgrade
gridctl upgrade --check   # just report whether an update is available
gridctl upgrade --yes     # non-interactive (CI-friendly)
```

The uninstall command:
```bash
curl -fsSL https://raw.githubusercontent.com/gridctl/gridctl/main/install.sh | bash -s -- --uninstall
# or, if the script is local:
bash scripts/install.sh --uninstall          # removes the binary
bash scripts/install.sh --uninstall --purge  # also removes ~/.gridctl config dir
```

Update the README to lead with the install command and demote brew to a "Package managers" subsection. Add Updating and Uninstalling subsections. Add a CI smoke test that exercises install → upgrade --check → uninstall on Ubuntu and macOS runners.

## Requirements

### Functional Requirements

1. **Single-file install script** at `scripts/install.sh`. POSIX-compatible (`#!/bin/sh`, `set -eu`). Must work under both `bash` and `dash` (shellcheck `-s sh` clean).
2. **OS detection** via `uname -s`:
   - `Darwin` → `darwin`
   - `Linux` → `linux`
   - Anything else → fail with: "gridctl supports macOS and Linux. Windows is supported via WSL2 — install WSL2, then run this command inside your Linux distribution."
3. **Architecture detection** via `uname -m`:
   - `x86_64`, `amd64` → `amd64`
   - `arm64`, `aarch64` → `arm64`
   - Anything else → fail with platform-not-supported message linking to releases page
4. **Version resolution**:
   - Default: resolve latest non-draft, non-prerelease release via GitHub redirect: `curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/gridctl/gridctl/releases/latest` and parse the tag from the URL. (No GH API token needed — sidesteps unauthenticated rate limits for a single redirect probe.)
   - **However** gridctl is currently in pre-release (v0.1.0-beta.6). Until a stable release exists, use the GitHub API path `https://api.github.com/repos/gridctl/gridctl/releases?per_page=1` (which returns pre-releases too) and parse `tag_name` with `sed`. Document this in a comment at the version-resolution function with a TODO to revert to the redirect-based approach once a stable release ships.
   - Override via env var `GRIDCTL_VERSION=v0.1.0-beta.6` (with or without `v` prefix). Strip leading `v` for archive name construction.
5. **Download URL construction**:
   ```
   https://github.com/gridctl/gridctl/releases/download/v<version>/gridctl_<version>_<os>_<arch>.tar.gz
   https://github.com/gridctl/gridctl/releases/download/v<version>/checksums.txt
   ```
   Where `<version>` is the version *without* the leading `v` in the archive name, but the URL path uses the tag (`v<version>`).
6. **HEAD-check before download**. Use `curl -fsSI` to verify the archive URL returns 200 before starting the download. On 404, fail with: "No release artifact found for <os>/<arch> at version <version>. See https://github.com/gridctl/gridctl/releases."
7. **SHA256 checksum verification**:
   - Download `checksums.txt` to the temp dir
   - Use `sha256sum -c --ignore-missing` (Linux) or `shasum -a 256 -c` (macOS — detect via `command -v sha256sum`)
   - Mismatch → fail loudly with expected vs actual, do not install
8. **Extract** with `tar -xzf` into the temp dir. Verify the binary `gridctl` exists in the extracted contents.
9. **Existing-install detection**:
   - If `command -v gridctl` resolves and the resolved path contains `Cellar` or `homebrew` (case-insensitive), the binary is brew-managed:
     - Print: "gridctl is already installed via Homebrew at <path>. Use `brew upgrade gridctl/tap/gridctl` to update, or remove it first with `brew uninstall gridctl/tap/gridctl` and rerun this script."
     - Exit 0 unless `--force` flag is passed
   - If `command -v gridctl` resolves to the install destination AND `gridctl --version` matches the version being installed: print "gridctl <version> is already installed at <path>" and exit 0 (idempotent re-run).
10. **Install destination**:
    - Default: `${GRIDCTL_INSTALL_DIR:-$HOME/.local/bin}`
    - Create directory with `mkdir -p` if missing
    - Move the binary with `mv` (atomic)
    - `chmod +x` the binary
    - On macOS, attempt to clear quarantine: `xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true` (matches what the brew cask post-install hook does)
11. **PATH guidance**: After install, check whether the install directory is on `$PATH` (parse `:$PATH:` for `:$dir:`). If not on PATH, print:
    ```
    Note: <dir> is not on your PATH.
    Add this line to your shell profile:
      export PATH="<dir>:$PATH"
    ```
12. **Cleanup**: `trap 'rm -rf "$tmpdir"' EXIT INT TERM` removes the temp directory on any exit path.
13. **Output formatting**:
    - ANSI colors when stdout is a TTY (`[ -t 1 ]`) AND `NO_COLOR` env var is unset
    - Plain text otherwise (CI, pipes)
    - Use a small ANSI palette: bold for the banner, dim/grey for labels, green for success ✓ marks, red for errors
14. **Final output** (success path):
    ```
    Installed gridctl v0.1.0-beta.6 → /Users/william/.local/bin/gridctl
    Run `gridctl --help` to get started.
    Docs: https://github.com/gridctl/gridctl
    ```

15. **`--uninstall` flag** on `install.sh`:
    - When `--uninstall` is passed, the script switches to uninstall mode and skips download/checksum/install logic
    - Resolve the binary path: prefer `command -v gridctl`; fall back to `${GRIDCTL_INSTALL_DIR:-$HOME/.local/bin}/gridctl`
    - **If brew-managed** (path contains `Cellar` or `homebrew`): print "gridctl is installed via Homebrew. Use `brew uninstall gridctl/tap/gridctl` to remove it." and exit 0
    - **If not found**: print "gridctl is not installed at <expected path>." and exit 0
    - **If found**: print the path, remove with `rm -f "$path"`, print "Removed gridctl binary at <path>"
    - **`--purge` flag** (additive to `--uninstall`): also remove `$HOME/.gridctl` config dir. Print "Removed config directory at $HOME/.gridctl" or "No config directory at $HOME/.gridctl to remove."
    - Final output: "gridctl has been uninstalled. To reinstall, run: curl -fsSL https://raw.githubusercontent.com/gridctl/gridctl/main/install.sh | bash"
    - Both flags are no-prompt, no-confirm — the script is non-interactive by design

### Functional Requirements — `gridctl upgrade` subcommand

16. **Cobra subcommand registration**: `gridctl upgrade` is a top-level subcommand registered in `cmd/gridctl/root.go` (or wherever subcommands are registered — discover by reading the existing root command setup).

17. **Brew-install detection**:
    - Determine the running binary's absolute path: use `os.Executable()` then `filepath.EvalSymlinks` to resolve.
    - If the path contains `Cellar` or `homebrew` (case-insensitive substring match): print "gridctl is installed via Homebrew at <path>. Run `brew upgrade gridctl/tap/gridctl` to update." and exit 0 (not an error).
    - If `--force` is passed, override and proceed with in-place upgrade anyway.

18. **Update check**:
    - Hit GitHub API to resolve the latest release (`https://api.github.com/repos/gridctl/gridctl/releases?per_page=1` for now — same path the install script uses; share rationale via comment about pre-release tracking).
    - Compare the discovered tag to the embedded `version` from `cmd/gridctl/version.go`. Strip leading `v` consistently before comparing.
    - **`--check` flag**: print the comparison result and exit (0 if up-to-date, 0 if update available — never fail just because an update exists; CI scripts may want to know without failing).
      ```
      Current version: v0.1.0-beta.6
      Latest version:  v0.1.0-beta.7
      An update is available. Run `gridctl upgrade` to update.
      ```
      or
      ```
      Current version: v0.1.0-beta.7
      Latest version:  v0.1.0-beta.7
      gridctl is up to date.
      ```

19. **Confirmation**:
    - When stdout is a TTY AND `--yes`/`-y` is not passed: print the version diff and ask `Upgrade to v0.1.0-beta.7? [y/N]` — read one line from stdin. Anything other than `y`/`Y`/`yes` aborts cleanly.
    - When stdout is not a TTY OR `--yes` is passed: proceed without prompting.

20. **Download + verify**:
    - Reuse the same archive naming convention as the install script: `gridctl_<version>_<os>_<arch>.tar.gz` and `checksums.txt`
    - Download to a temp dir created via `os.MkdirTemp("", "gridctl-upgrade-*")`. `defer os.RemoveAll(tmpDir)`
    - Verify SHA256: parse `checksums.txt`, find the line matching the archive name, compute SHA256 of the downloaded archive (use `crypto/sha256` from stdlib), compare hex strings. Mismatch → fail loudly, do not replace.
    - Extract the `gridctl` binary from the tarball using `archive/tar` + `compress/gzip` from stdlib (no shelling out to `tar`).

21. **Atomic in-place replacement**:
    - Write the new binary to a sibling temp file in the same directory as the running binary (e.g., `/Users/william/.local/bin/.gridctl-new-<pid>`). Same directory matters because `os.Rename` is only atomic within the same filesystem.
    - `chmod 0755` on the temp file
    - `os.Rename(tmpPath, runningBinaryPath)` — atomic on POSIX, replaces the running binary
    - **Important**: this is safe because the kernel keeps the running process's executable file open (via inode reference) even after the directory entry is replaced. The current invocation continues to run from the old inode; the next invocation runs the new binary.
    - On macOS, attempt `xattr -dr com.apple.quarantine` on the new binary path (best-effort, ignore errors).
    - Print: "Upgraded gridctl from v0.1.0-beta.6 to v0.1.0-beta.7"

22. **Flags summary**:
    - `--check` — only check, do not download/install
    - `--version <ver>` — install a specific version (with or without `v` prefix). Allows downgrades.
    - `--force` — bypass brew detection AND bypass the "already up-to-date" short-circuit
    - `--yes` / `-y` — non-interactive (skip the y/N prompt)

23. **Output formatting**: same conventions as install.sh — ANSI when TTY + `NO_COLOR` unset, plain otherwise. Use the existing logging conventions in the gridctl codebase if any are present (read other Cobra subcommand files in `cmd/gridctl/` to match the project's idiomatic style — e.g., see how `cmd/gridctl/version.go` prints).

- **No interactive prompts.** The script must run cleanly under `curl ... | bash` (no controlling TTY for stdin).
- **Idempotent.** Re-running the script with the same version installed is a no-op.
- **No shell rc edits.** Print the PATH export line; do not append to `.bashrc`/`.zshrc`/`.profile`. (rustup philosophy — less invasive, fewer cross-shell edge cases.)
- **No third-party dependencies** beyond POSIX standard tools: `curl`, `tar`, `mkdir`, `mv`, `chmod`, `command`, `uname`, plus `sha256sum` OR `shasum`.
- **shellcheck-clean** under `shellcheck -s sh scripts/install.sh`.
- **Total length ~150-250 lines** (excluding comments and ASCII banner). Reject scope creep — keep it focused.

### Out of Scope

- **PowerShell `install.ps1`** — defer until native Windows binaries are added (currently WSL2 only)
- **Custom domain `install.gridctl.dev`** — deferred until traffic warrants; raw.githubusercontent.com is the v1 host
- **Cosign signature verification** — deferred (GoReleaser doesn't currently sign releases; SHA256 over HTTPS is sufficient for now)
- **Telemetry / install analytics** — out of scope, do not add
- **AVX2 baseline / musl variant detection** — gridctl ships single static Go binaries per arch; no variants needed
- **Auto shell-rc PATH editing** — print the line, let the user paste
- **Self-update on launch** — `gridctl upgrade` is explicit and user-invoked; no background update checks on every command

## Architecture Guidance

### Recommended Approach

Structure the script as a sequence of small, well-named functions called from `main`. This both makes the script readable and defends against the partial-download attack (if the script is truncated mid-stream, the `main` call at the bottom won't execute and nothing runs):

```sh
#!/bin/sh
set -eu

# --- helpers, color, logging ---
# --- detect_platform ---
# --- resolve_version ---
# --- download_archive ---
# --- verify_checksum ---
# --- check_existing_install ---
# --- install_binary ---
# --- print_path_guidance ---
# --- main ---

main() {
    parse_args "$@"
    print_banner
    detect_platform        # sets OS, ARCH
    resolve_version        # sets VERSION (no v prefix)
    check_existing_install # may exit early
    download_archive       # sets ARCHIVE_PATH, CHECKSUMS_PATH
    verify_checksum
    install_binary         # extracts, moves, chmods
    print_success
    print_path_guidance    # if needed
}

main "$@"
```

### Key Files to Understand

1. **`/Users/william/code/gridctl/.goreleaser.yaml`** (lines 33-43) — Archive `name_template` is `{{ .ProjectName }}_{{ .Version }}_{{ .Os }}_{{ .Arch }}` and checksum file is `checksums.txt`. The script's filename construction must match exactly.
2. **`/Users/william/code/gridctl/.goreleaser.yaml`** (lines 87-98) — Release footer with current install instructions. Add a curl-line block alongside the brew block.
3. **`/Users/william/code/gridctl/README.md`** (lines 71-92) — Existing install section. Reorder: curl first, brew under "Package managers", source under "Build from source".
4. **`/Users/william/code/gridctl/cmd/gridctl/version.go`** (lines 10-15) — `version`/`commit`/`date` injected via ldflags. After install, `gridctl --version` should print these — useful for the "already installed" idempotency check.
5. **`/Users/william/code/gridctl/scripts/check-coverage.sh`**, **`/Users/william/code/gridctl/scripts/govulncheck.sh`** — Existing scripts as a style reference for shell conventions in this repo.
6. **`/Users/william/code/gridctl/.github/workflows/release.yaml`** — Release pipeline (no changes needed; just confirm checksums.txt is published, which it is).

### Integration Points

| File | Change |
|---|---|
| `scripts/install.sh` | **NEW** — install script with `--uninstall` and `--purge` flags |
| `cmd/gridctl/upgrade.go` | **NEW** — `gridctl upgrade` Cobra subcommand |
| `cmd/gridctl/<root>.go` | Register the new `upgrade` command on the root command. Find by reading `cmd/gridctl/main.go` and `cmd/gridctl/root.go` (or wherever `rootCmd.AddCommand(...)` is called for other subcommands like `apply`, `version`). |
| `README.md` (lines 71-92) | Reorder install section; lead with curl, demote brew, add WSL2 callout, add Updating + Uninstalling subsections |
| `.github/workflows/install-smoke.yaml` | **NEW** — CI smoke test exercising install → upgrade --check → uninstall on `ubuntu-latest` and `macos-latest` |
| `.goreleaser.yaml` (lines 87-98) | Add curl install block to release footer alongside the brew block |

### Reusable Components

None to integrate with — the script is standalone. It consumes GoReleaser's existing outputs (archives + `checksums.txt`).

## UX Specification

### Discovery
- Top of README's `## 🪛 Installation` section
- Linkable directly: blog posts, conference slides, demo materials use the raw URL or future custom domain

### Activation
- One command, no prerequisites beyond `curl` (universal) and POSIX shell

### Interaction
- Zero questions asked
- Output narrates what's happening: platform detection → version resolution → download → checksum verify → install → next-step

### Feedback
- Banner at start
- Per-step labels with values
- Green ✓ marks on key milestones (checksum, install)
- Final success line with binary path
- PATH-not-on-PATH guidance only when relevant

### Error states
Each error path prints (a) what was attempted, (b) what failed, (c) the next step. Examples:

| Failure | Message |
|---|---|
| Unsupported OS | `gridctl supports macOS and Linux. Windows is supported via WSL2 — install WSL2, then run this command inside your Linux distribution.` |
| Unsupported arch | `No release artifact for <os>/<arch>. See https://github.com/gridctl/gridctl/releases or build from source: https://github.com/gridctl/gridctl#build-from-source` |
| Network error fetching version | `Could not reach api.github.com to resolve the latest version. Check your network or pin a version with GRIDCTL_VERSION=v0.1.0-beta.6.` |
| Archive 404 | `Release artifact not found at <url>. The release may not have built for your platform. See https://github.com/gridctl/gridctl/releases.` |
| Checksum mismatch | `Checksum verification failed for <archive>.  Expected: <hex>  Actual:   <hex>This is unexpected — please open an issue at https://github.com/gridctl/gridctl/issues.` |
| Cannot write to install dir | `Cannot write to <dir> (permission denied). Set a writable destination:  GRIDCTL_INSTALL_DIR=$HOME/.local/bin curl -fsSL <url> | bash` |
| Brew install detected | `gridctl is already installed via Homebrew at <path>. Use 'brew upgrade gridctl/tap/gridctl' to update, or 'brew uninstall gridctl/tap/gridctl' first to switch.Pass --force to install anyway.` |

## Implementation Notes

### Conventions to Follow

- **Commit format**: `feat: add curl install script` — types per `.gitmessage` are `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`, `perf`. Sign commits with `-S`. No Co-authored-by trailers. No mention of Claude in commits, PRs, or branch names (per global CLAUDE.md).
- **Branch name**: `feature/install-script` (fork workflow — branch off origin)
- **Workflow**: This repo uses the fork workflow (origin = `wcollins/gridctl`, upstream = `gridctl/gridctl`). Use `/branch-fork` and `/pr-fork` skills, not the trunk variants.
- **PR title**: short (under 70 chars), e.g., "Add curl install script for macOS and Linux"
- **README emoji style**: existing section headers use emoji (🪛 Installation, 🐋 Container Runtime, ⚡️ Why Gridctl). Match the existing style — don't strip them.

### Potential Pitfalls

1. **Version string ambiguity**. GoReleaser tags are `v0.1.0-beta.6` but archive names use `0.1.0-beta.6` (no `v`). The script must consistently distinguish "tag" (with `v`) from "version" (without).
2. **`sha256sum` vs `shasum`**. macOS lacks `sha256sum` by default — use `command -v sha256sum >/dev/null && SHA_CMD="sha256sum -c --ignore-missing" || SHA_CMD="shasum -a 256 -c"`. Both accept the GoReleaser `checksums.txt` format.
3. **`set -e` and pipelines**. POSIX `set -e` does NOT propagate failures through pipes by default; if a check uses a pipe (e.g., `curl ... | grep ...`), wrap it explicitly or test the pipeline result. Avoid `pipefail` since it's bash-only and we're targeting `dash`.
4. **`uname -m` on Apple Silicon**. Returns `arm64` (good — matches GoReleaser's `arm64`). On Linux ARM it returns `aarch64` — must normalize.
5. **GitHub redirect parsing**. `curl -sLI -o /dev/null -w '%{url_effective}'` follows redirects and prints the final URL. Parse the tag with `sed -n 's|.*/tag/v\?\([^/]*\)$|\1|p'`. Test with both `v` and non-`v` tag forms.
6. **`tar` flag portability**. Use `tar -xzf` (POSIX), not `tar xfz` or GNU-only flags.
7. **`mktemp` portability**. macOS `mktemp -d` requires a template on some versions: `mktemp -d -t gridctl-install.XXXXXX` works on both Linux and macOS.
8. **Terminal color detection**. Test `[ -t 1 ]` AND check `NO_COLOR` env var (per https://no-color.org). Don't enable color unconditionally.
9. **The README install section is currently inside `<details>` blocks**. Maintain that pattern — don't flatten everything into top-level visibility, but DO promote the curl one-liner OUT of `<details>` (it's the new primary install path).
10. **Pinned-tag note in the prompt is recommend, not required for v1**. The README's primary command points to `main`. A pinned-tag form can be added later as part of a "Pinned version" `<details>` block.
11. **The release footer in `.goreleaser.yaml`** appears in every GitHub Release's body. Adding the curl line there is a small but high-leverage doc surface.

### Suggested Build Order

**Stage A — install script (covers requirements 1-14)**
1. **Read referenced files first** (`.goreleaser.yaml`, `README.md` install section, existing `scripts/*.sh` for style, `cmd/gridctl/version.go`, and the existing root command setup in `cmd/gridctl/`).
2. **Write `scripts/install.sh` skeleton** — top-of-file comment, `set -eu`, helpers, empty function stubs, `main`. Verify shellcheck is happy with the skeleton.
3. **Implement detect_platform** + add a `--debug` env var (`GRIDCTL_INSTALL_DEBUG=1`) that prints decisions. Test on macOS arm64 by running locally.
4. **Implement resolve_version** with both override path (env var) and discovery path (GitHub API for now, redirect parser stubbed for future). Test by setting `GRIDCTL_VERSION=v0.1.0-beta.6` and confirming URL construction.
5. **Implement download_archive + verify_checksum**. Run end-to-end on macOS pulling a real release artifact. Confirm SHA256 verification passes; deliberately corrupt the temp file and confirm it fails.
6. **Implement install_binary + path guidance**. Run with default `~/.local/bin`; verify `gridctl --version` runs after install.
7. **Implement check_existing_install + brew detection**. Test by `brew install gridctl/tap/gridctl` first, then run the script; confirm it bails with the right message.

**Stage B — uninstall flag (covers requirement 15)**
8. **Add `--uninstall` and `--purge` flags** to install.sh's argument parser. Implement the uninstall function (binary removal + brew detection + optional config-dir purge). Test the four cases: not-installed, standalone-installed, brew-installed, with-purge.

**Stage C — upgrade subcommand (covers requirements 16-23)**
9. **Read existing Cobra subcommands** in `cmd/gridctl/` to match conventions: how flags are registered, how output is formatted, how errors are surfaced, how `version.go` exposes the version string.
10. **Scaffold `cmd/gridctl/upgrade.go`** with the Cobra command struct, flag registration (`--check`, `--version`, `--force`, `--yes`/`-y`), and a `RunE` that calls placeholder functions.
11. **Register the command** on the root command — match the call site of other subcommand registrations (e.g., wherever `apply`, `version` are added).
12. **Implement the brew-detection branch** — `os.Executable()` + `filepath.EvalSymlinks` + substring check on `Cellar`/`homebrew`. Test by building on a brew-installed setup with `make build` and running the in-place upgrade against a brew-managed binary path (use a copy under `/tmp` to simulate). Per the user's `feedback_build_workflow.md` memory, ALWAYS test with `make build` + `./gridctl upgrade ...`, not the brew-installed binary.
13. **Implement the version check + `--check` flag** — GitHub API call, parse tag, compare to embedded version. No-op exit when up-to-date. Test by hand-editing version.go to an old version and confirming the diff is reported.
14. **Implement the confirmation prompt** — TTY detect with `isatty` (the project may already use a TTY-detection lib; check `go.mod`/imports first; if not, use `golang.org/x/term.IsTerminal(int(os.Stdin.Fd()))`). Stub out the prompt for `--yes` and non-TTY paths.
15. **Implement download + SHA256 verify in Go** — use `net/http`, `crypto/sha256`, `encoding/hex`, `archive/tar`, `compress/gzip` from stdlib. No shelling out. Match the install script's URL construction so the same artifact + checksums.txt format is consumed.
16. **Implement atomic in-place rename** — write `<dir>/.gridctl-new-<pid>`, chmod 0755, `os.Rename` to the running binary's path. Add a unit-style test or manual test where you run the upgrade against a temp directory containing a copy of `./gridctl` and observe the file change while a process holds the old inode open.
17. **End-to-end test the full upgrade flow locally**: install via `./scripts/install.sh` to `~/.local/bin/gridctl-test` (use `GRIDCTL_INSTALL_DIR` override), pin `GRIDCTL_VERSION` to a slightly older release (e.g., v0.1.0-beta.5 if available), then run `gridctl-test upgrade --yes` and confirm version bump.

**Stage D — docs + CI + polish**
18. **Add ANSI/NO_COLOR support** to install.sh and the upgrade subcommand. Match conventions.
19. **Update README.md** install section per the layout below — including new Updating and Uninstalling subsections.
20. **Add `.github/workflows/install-smoke.yaml`** — see suggested workflow below. The workflow exercises install → upgrade --check → uninstall.
21. **Add curl install block to `.goreleaser.yaml` footer** alongside brew.
22. **Run linters locally**: `shellcheck -s sh scripts/install.sh`, plus whatever Go linter the project uses (`golangci-lint run` is in the user's CLAUDE.md as a pre-release check). Fix any warnings.
23. **Local end-to-end smoke**: temporarily push the script to your fork's main branch (or use a feature branch + raw URL), run it from a clean dir, then clean up. Run `./gridctl upgrade --check` and `./gridctl upgrade --yes`. Run `./scripts/install.sh --uninstall --purge`.
24. **Open the PR.**

### Proposed README Install Section (replacement for lines 71-92)

```markdown
## 🪛 Installation

### Quick install (macOS, Linux, WSL2)

```bash
curl -fsSL https://raw.githubusercontent.com/gridctl/gridctl/main/install.sh | bash
```

Installs the latest release to `~/.local/bin/gridctl`. The script verifies the
release checksum and prints the install path and next steps.

The script can be inspected before running:

```bash
curl -fsSL https://raw.githubusercontent.com/gridctl/gridctl/main/install.sh | less
```

> **Windows**: install [WSL2](https://learn.microsoft.com/en-us/windows/wsl/install), then run the command above inside your Linux distribution.

![Install Gridctl](assets/install.gif)

### Package managers

<details>
<summary><strong>Homebrew</strong> (macOS, Linux)</summary>

```bash
brew install gridctl/tap/gridctl
```

Update with `brew upgrade gridctl/tap/gridctl`.

</details>

### Other options

<details>
<summary><strong>Pre-built binaries</strong></summary>

Download the tarball for your platform from the [releases page](https://github.com/gridctl/gridctl/releases),
verify against `checksums.txt`, extract, and place `gridctl` on your `PATH`.

</details>

<details>
<summary><strong>Build from source</strong></summary>

Requires Go 1.26+ and Node 20+.

```bash
git clone https://github.com/gridctl/gridctl
cd gridctl && make build
./gridctl --version
```

</details>

### Updating

```bash
gridctl upgrade            # check + prompt + upgrade (standalone install)
gridctl upgrade --check    # only check; do not install
gridctl upgrade --yes      # non-interactive (CI)
gridctl upgrade --version v0.1.0-beta.7   # install a specific version
```

If gridctl was installed via Homebrew, `gridctl upgrade` will detect that and recommend `brew upgrade gridctl/tap/gridctl` instead.

### Uninstalling

```bash
# Standalone install
bash <(curl -fsSL https://raw.githubusercontent.com/gridctl/gridctl/main/install.sh) --uninstall

# Also remove the config directory at ~/.gridctl
bash <(curl -fsSL https://raw.githubusercontent.com/gridctl/gridctl/main/install.sh) --uninstall --purge

# Homebrew install
brew uninstall gridctl/tap/gridctl
```
```

### Proposed `.github/workflows/install-smoke.yaml`

```yaml
name: Install Smoke Test

on:
  pull_request:
    paths:
      - "scripts/install.sh"
      - ".github/workflows/install-smoke.yaml"
  push:
    branches: [main]
    paths:
      - "scripts/install.sh"
  schedule:
    - cron: "0 8 * * 1"  # Monday 08:00 UTC — catches GitHub Releases drift

jobs:
  smoke:
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - name: Run installer (latest release)
        run: bash scripts/install.sh
      - name: Verify gridctl on PATH
        run: |
          export PATH="$HOME/.local/bin:$PATH"
          gridctl --version
      - name: Re-run is idempotent
        run: |
          export PATH="$HOME/.local/bin:$PATH"
          bash scripts/install.sh
          gridctl --version
      - name: Upgrade --check reports a comparable version
        run: |
          export PATH="$HOME/.local/bin:$PATH"
          gridctl upgrade --check
      - name: Uninstall removes the binary
        run: |
          export PATH="$HOME/.local/bin:$PATH"
          bash scripts/install.sh --uninstall
          if command -v gridctl >/dev/null 2>&1; then
            echo "gridctl still on PATH after uninstall" >&2
            exit 1
          fi
      - name: Uninstall --purge removes config dir
        run: |
          mkdir -p "$HOME/.gridctl"
          touch "$HOME/.gridctl/sentinel"
          bash scripts/install.sh
          export PATH="$HOME/.local/bin:$PATH"
          bash scripts/install.sh --uninstall --purge
          if [ -e "$HOME/.gridctl/sentinel" ]; then
            echo "config dir not purged" >&2
            exit 1
          fi

  shellcheck:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: shellcheck -s sh scripts/install.sh
```

### Proposed `.goreleaser.yaml` footer addition

Replace the current `footer:` block (lines 87-98) with:

```yaml
  footer: |
    ---
    ## Installation

    **Quick install (macOS / Linux / WSL2)**:
    ```bash
    curl -fsSL https://raw.githubusercontent.com/gridctl/gridctl/main/install.sh | bash
    ```

    **Homebrew**:
    ```bash
    brew install gridctl/tap/gridctl
    ```

    **Binary Download**: See assets below for your platform.

    **Full Changelog**: https://github.com/gridctl/gridctl/compare/{{ .PreviousTag }}...{{ .Tag }}
```

## Acceptance Criteria

### Install script
1. `scripts/install.sh` exists, is executable (`chmod +x`), shellcheck-clean under `shellcheck -s sh scripts/install.sh`.
2. Running `bash scripts/install.sh` on macOS (arm64 or amd64) downloads the latest gridctl release, verifies its SHA256, installs it to `~/.local/bin/gridctl`, and prints a success message including the version and binary path.
3. Running the same on Ubuntu (amd64 or arm64) — including in a GitHub Actions `ubuntu-latest` runner — produces the same result.
4. `GRIDCTL_VERSION=v0.1.0-beta.6 bash scripts/install.sh` installs the pinned version (with or without `v` prefix accepted).
5. `GRIDCTL_INSTALL_DIR=/tmp/gridctl-test bash scripts/install.sh` installs to the override directory.
6. Running the script a second time when the same version is already installed prints "gridctl <version> is already installed" and exits 0.
7. With `gridctl` already brew-installed (`brew install gridctl/tap/gridctl`), running the script bails with the brew-detected guidance message and exits 0 (no clobber). Passing `--force` overrides.
8. SHA256 mismatch (simulate by corrupting a downloaded archive in test) causes the script to fail loudly, print expected vs actual, and not install anything.
9. `NO_COLOR=1 bash scripts/install.sh` produces ANSI-free output. Output in a non-TTY context (piped to `tee` or running under CI) also produces ANSI-free output.
10. The script is ≤ 350 lines (excluding ASCII banner, comments, and blank lines) — installer + uninstall combined.

### Uninstall flag
11. `bash scripts/install.sh --uninstall` removes the binary at the resolved install path and reports what was removed.
12. `bash scripts/install.sh --uninstall --purge` additionally removes `$HOME/.gridctl` (or the equivalent state directory used by the project — confirm the path by reading `pkg/state/state.go`).
13. With a brew-managed install present, `--uninstall` does not remove the brew binary; it prints the recommended `brew uninstall` command and exits 0.
14. With no gridctl installed, `--uninstall` exits 0 with a "not installed" message rather than erroring.

### Upgrade subcommand
15. `cmd/gridctl/upgrade.go` registers a `gridctl upgrade` Cobra subcommand, visible in `gridctl --help` output.
16. `gridctl upgrade --check` prints the current and latest versions and an "up to date" / "update available" line; exits 0 in both cases.
17. `gridctl upgrade --yes` performs the full upgrade flow non-interactively: download, SHA256 verify, atomic in-place rename, success message with old → new version.
18. `gridctl upgrade --version v0.1.0-beta.5` installs the specified version (allowing downgrades).
19. When the running binary is brew-managed (resolved path contains `Cellar` or `homebrew`), `gridctl upgrade` prints the recommended `brew upgrade gridctl/tap/gridctl` command and exits 0 without modifying anything. `--force` overrides.
20. When stdin is a TTY and `--yes` is not passed, the command prompts `Upgrade to vX.Y.Z? [y/N]` and aborts cleanly on anything other than y/Y/yes.
21. SHA256 mismatch on the downloaded archive aborts the upgrade with a loud error; the existing binary is not modified.
22. Atomic in-place replacement: a running `gridctl` invocation continues to execute correctly while the file is replaced (verified by holding a long-running `gridctl` process and observing that subsequent invocations show the new version).
23. `NO_COLOR=1 gridctl upgrade --check` produces ANSI-free output.

### README + CI + release footer
24. README install section reordered: curl one-liner is the prominent first block; brew is nested in a "Package managers" `<details>` block; build-from-source remains in `<details>`. WSL2 callout sentence present.
25. README has Updating and Uninstalling subsections covering both standalone and brew install paths.
26. `.github/workflows/install-smoke.yaml` exists, runs on PR/push to install.sh, on push to main, and on weekly cron. The workflow exercises install → upgrade --check → uninstall (and `--purge`) on Ubuntu and macOS, plus shellcheck. All jobs pass.
27. `.goreleaser.yaml` release footer includes the curl install block alongside the brew block.

### Workflow
28. PR opened from `wcollins/gridctl:feature/install-script` against `gridctl/gridctl:main` with a concise PR description (1-2 sentences summary + a Test plan checklist). Commits signed (`-S`), no Co-authored-by trailers, no mention of Claude in commits/PR/branch.

## References

### Reference scripts (to read before writing)
- [k3s install.sh — sha256 + trap pattern](https://github.com/k3s-io/k3s/blob/master/install.sh)
- [goreleaser install runner — concise sha256+cosign](https://goreleaser.com/static/run)
- [opencode install (style reference, not structure)](https://opencode.ai/install)
- [mise install (POSIX `set -eu` example)](https://mise.run)
- [uv install — most thorough PATH detection](https://releases.astral.sh/installers/uv/latest/uv-installer.sh)
- [bun install — Rosetta detection if ever needed](https://bun.sh/install)

### Project files
- `/Users/william/code/gridctl/.goreleaser.yaml` — archive naming, checksum config, release footer
- `/Users/william/code/gridctl/.github/workflows/release.yaml` — confirms checksums.txt is published per release
- `/Users/william/code/gridctl/README.md` (lines 71-92) — current install section
- `/Users/william/code/gridctl/cmd/gridctl/version.go` — version injection via ldflags

### Standards / conventions
- [no-color.org](https://no-color.org) — `NO_COLOR` env var handling
- [shellcheck](https://www.shellcheck.net/) — `-s sh` for POSIX dialect
- [GoReleaser archive name template docs](https://goreleaser.com/customization/archive/)
- [GoReleaser checksum docs](https://goreleaser.com/customization/checksum/)
