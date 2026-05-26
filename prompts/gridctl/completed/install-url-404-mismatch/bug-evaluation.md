# Bug Investigation: Install URL 404 Mismatch

**Date**: 2026-05-08
**Project**: gridctl
**Recommendation**: Fix immediately
**Severity**: High
**Fix Complexity**: Trivial

## Summary

The README's headline install command (`curl -fsSL https://raw.githubusercontent.com/gridctl/gridctl/main/install.sh | sh`) returns HTTP 404 because the script lives at `scripts/install.sh`, not at the repo root. The mismatch has existed since the script was first introduced in PR #531 (2026-04-27) and blocks every new user who follows the documented quick-install path. Fix: move `scripts/install.sh` to the repo root and update the CI workflow + AGENTS.md to match.

## The Bug

A Debian user ran the documented install command from the README:

```
curl -fsSL https://raw.githubusercontent.com/gridctl/gridctl/main/install.sh | sh
```

and received `curl: (22) The requested URL returned error: 404`.

**Expected**: The URL serves the install script, which detects platform/arch, fetches the latest release, verifies its checksum, and installs `gridctl` to `~/.local/bin`.

**Actual**: GitHub returns 404 because no file exists at `/main/install.sh`. The script is one directory down at `/main/scripts/install.sh`.

## Root Cause

### Defect Location

There is no single defective line — the bug is a path/URL mismatch across documentation and the script's own self-references.

**File the user expects**: `install.sh` at repo root (does not exist).

**File that actually exists**: `scripts/install.sh`.

**Documentation pointing at the wrong URL**:
- `README.md:76` — quick install
- `README.md:85` — inspect-before-running command
- `README.md:143` — uninstall
- `README.md:146` — uninstall + purge
- `scripts/install.sh:8` — usage comment header
- `scripts/install.sh:23` — `RAW_INSTALL_URL` variable, printed at line 302 as the upgrade-hint message
- `AGENTS.md:320` — architecture table

### Code Path

User -> reads README quick-install -> runs curl one-liner -> GitHub returns 404 -> `curl -f` exits non-zero -> piped `sh` receives empty stdin -> nothing executes. The script never runs. There is no failure mode in the script itself; the failure is at the URL-resolution step.

### Why It Happens

PR #531 (commit `f445d5b`, 2026-04-27, "feat: add curl install script with upgrade and uninstall") introduced the script at `scripts/install.sh` while simultaneously authoring documentation that assumes it lives at the repo root. Both halves were committed together, so neither half was wrong against the other in isolation — they were just inconsistent. CI (`install-smoke.yaml`) runs `bash scripts/install.sh` directly from a checkout, so it never exercised the curl-one-liner that the docs promote, and the bug was not caught.

### Similar Instances

None. The mismatch is specific to this one script. `cmd/gridctl/upgrade.go` does not download the install script (it fetches GoReleaser archives directly) and is not affected.

## Impact

### Severity Classification

**High** — onboarding-blocker UX defect. Not data loss, not security, not a crash, but a 100%-failure-rate command on the project's primary install path during pre-release adoption.

### User Reach

Every new user who follows the README quick-install. The command is featured at the top of the install section with `assets/install.gif` next to it, and the same broken URL is repeated in the uninstall instructions further down the README. There is no path through the documented quick-install flow that succeeds.

### Workflow Impact

Critical-path blocker for new-user onboarding. Workarounds exist (Homebrew, manual download from releases, clone + `bash scripts/install.sh`) but each requires the user to find the workaround docs *after* the headline command fails — significant friction during first-impression.

### Workarounds

- `brew install gridctl/tap/gridctl` — works, documented further down the README
- Manual binary download from `https://github.com/gridctl/gridctl/releases/latest`
- `git clone` then `bash scripts/install.sh` — works, undocumented as a workaround

All workarounds require the user to abandon the documented quick path and seek out alternatives.

### Urgency Signals

- Active user encounter (Debian / admin@titan, 2026-05-08)
- Project is in pre-release (v0.1.0-beta.x); first-impression cost is high
- The broken URL has been live in the README for ~11 days (since 2026-04-27)
- The same install command appears in marketing-adjacent surfaces (README headline, install GIF caption); any external promotion that copied the URL is also broken

## Reproduction

### Minimum Reproduction Steps

1. From any machine with `curl` installed (any OS, any arch).
2. Run:
   ```
   curl -fsSL https://raw.githubusercontent.com/gridctl/gridctl/main/install.sh | sh
   ```
3. Observe `curl: (22) The requested URL returned error: 404`.

Or, equivalently:

```
curl -sI https://raw.githubusercontent.com/gridctl/gridctl/main/install.sh
# HTTP/2 404
```

### Affected Environments

All. The bug is on GitHub's raw-content host, not the user's machine. Every platform, every shell, every network path that can reach raw.githubusercontent.com sees the same 404.

### Non-Affected Environments

- `bash scripts/install.sh` from a local clone — works.
- `https://raw.githubusercontent.com/gridctl/gridctl/main/scripts/install.sh` (with the correct path) — returns HTTP 200.
- Homebrew install path — works.
- `gridctl upgrade` (in-place upgrade for users who already have a binary) — works; does not consume the install script.

### Failure Mode

`curl -f` exits non-zero on the 404 and prints the error. Because the command is piped to `sh`, no script content reaches the shell; nothing is executed. The system is left in its prior state (no partial install, no corruption). Recoverable: the user just gets an error and never installs.

## Fix Assessment

### Fix Surface

- Move `scripts/install.sh` -> `install.sh` (preserve git history with `git mv`).
- Update `.github/workflows/install-smoke.yaml` — 7 path references (`scripts/install.sh` -> `install.sh`).
- Update `AGENTS.md:320,330,336-337,355,367-368` — table row and references that name `scripts/install.sh`.
- Add a regression test step to `install-smoke.yaml` that performs `curl -fsSL --head` against `https://raw.githubusercontent.com/${REPO}/${BRANCH}/install.sh` and asserts HTTP 200, so future doc/path drift is caught.

No changes needed to:
- `README.md` (already references `/main/install.sh`)
- `scripts/install.sh` body, including `RAW_INSTALL_URL` (already references `/main/install.sh`)
- `cmd/gridctl/upgrade.go` (does not consume the script)

### Risk Factors

- Low. The script is only invoked in two places: the curl-one-liner (which the move *fixes*) and `install-smoke.yaml` (whose 7 path references are mechanically updated alongside the move).
- Brief documentation/CI race window is non-issue: the move and the workflow update land in the same commit.
- External tooling that imports the path (none known) would break, but a `git log -- scripts/install.sh` shows only the original add commit; no third-party integrations are documented against the `scripts/` path.
- The repo root gains one more file. Acceptable tradeoff for an industry-convention install URL (k3s, helm, rustup, oh-my-zsh, etc. all live at `/install.sh`).

### Regression Test Outline

In `install-smoke.yaml`, add a job (or a step in the existing job) that runs:

```yaml
- name: Documented install URL is reachable
  run: |
    url="https://raw.githubusercontent.com/${{ github.repository }}/${{ github.ref_name }}/install.sh"
    code="$(curl -fsSL -o /dev/null -w '%{http_code}' "$url")"
    test "$code" = "200" || { echo "install.sh URL returned $code"; exit 1; }
```

This step should run on PRs that touch `install.sh` or the workflow itself, and on pushes to `main`. It guards specifically against the doc/path drift class of bug.

## Recommendation

**Fix immediately.** Move `scripts/install.sh` to `install.sh` at the repo root and update the CI workflow + AGENTS.md to match. Add a curl-HEAD regression test to `install-smoke.yaml` to prevent recurrence.

This is the cheaper of the two fix shapes and aligns with industry convention. The README, the script's self-references, and the `RAW_INSTALL_URL` variable already assume root placement; moving the file is the minimal change that makes reality match the documentation. The alternative (rewriting four README URLs + two install.sh self-references + AGENTS.md to use the `scripts/` path) is more lines changed and produces a non-conventional install URL.

There is no "external link preservation" concern with either approach: the documented URL has been broken since day one, so no working external references to it exist.

## References

- Source commit introducing the mismatch: `f445d5b` (PR #531, "feat: add curl install script with upgrade and uninstall")
- Convention examples: `https://get.k3s.io`, `https://sh.rustup.rs`, `https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3` (helm is the rare counter-example using `scripts/`).
- Affected README anchor: `README.md` "Quick install (macOS, Linux, WSL2)" section
- CI workflow: `.github/workflows/install-smoke.yaml`
