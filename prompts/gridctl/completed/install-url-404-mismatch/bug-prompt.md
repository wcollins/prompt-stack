# Bug Fix: Install URL 404 Mismatch

## Context

`gridctl` is a Go CLI plus web UI distributed as GoReleaser binaries from GitHub Releases. It is in pre-release (v0.1.0-beta.x). The repo at `github.com/gridctl/gridctl` exposes a one-line curl installer (POSIX `sh`) modeled after k3s/rustup-style installers; the script lives at `scripts/install.sh` in source but the README directs users to `https://raw.githubusercontent.com/gridctl/gridctl/main/install.sh`. CI smoke-tests the install in `.github/workflows/install-smoke.yaml`, executing the script directly from a checkout. `cmd/gridctl/upgrade.go` provides an in-place upgrade for users who already have a binary; it fetches GoReleaser archives directly and does NOT consume `install.sh`.

## Investigation Context

- **Root cause confirmed**: Documented install URL `…/main/install.sh` returns HTTP 404 because the file is at `scripts/install.sh`, not the repo root. Verified with `curl -sI` against both paths (root: 404, `scripts/install.sh`: 200).
- **Origin**: PR #531 (commit `f445d5b`, 2026-04-27) introduced the script at `scripts/install.sh` while simultaneously writing docs that assume root placement. CI tests `bash scripts/install.sh` (file path), never the curl-one-liner (URL path), so the bug was not caught.
- **Reproduction confirmed**: Deterministic on every platform — the failure is on GitHub's CDN, not the user's machine.
- **Fix shape decided**: Move the file to repo root (Option A). README, the script's own header comment, and `RAW_INSTALL_URL` already assume root placement; this is the minimal change that aligns reality with documentation. The alternative (rewriting 4 README URLs + 2 install.sh self-doc lines + RAW_INSTALL_URL + AGENTS.md to use `scripts/`) is more churn and yields a non-conventional URL. No external links to preserve — the documented URL has never worked.
- **Regression test required**: Add a `curl -fsSL --head` check on the documented URL in `install-smoke.yaml` to prevent future doc/path drift.
- **Full investigation**: `prompts/gridctl/install-url-404-mismatch/bug-evaluation.md`

## Bug Description

The README's headline install command:

```
curl -fsSL https://raw.githubusercontent.com/gridctl/gridctl/main/install.sh | sh
```

returns `curl: (22) The requested URL returned error: 404`. Every new user following the documented quick-install path is blocked. The script exists and works correctly when invoked directly from a checkout (`bash scripts/install.sh`); only the documented download URL is broken. Same broken URL is used in 4 places in `README.md`, in the script's own header comment, in `RAW_INSTALL_URL` (which is printed as an upgrade-hint at install.sh:302), and in the `AGENTS.md` architecture table.

## Root Cause

`scripts/install.sh` was added by PR #531 (commit `f445d5b`). Documentation, the script's self-references, and the `RAW_INSTALL_URL` variable all assume the script is served from `https://raw.githubusercontent.com/gridctl/gridctl/main/install.sh` (repo root), but the file is one directory down at `scripts/install.sh`. CI invokes the script via the `scripts/install.sh` path directly (so the install logic itself is exercised) but never tests the documented curl URL, so the mismatch was not caught.

## Fix Requirements

### Required Changes

1. Move the install script from `scripts/install.sh` to `install.sh` at the repo root, preserving git history (use `git mv`).
2. Update `.github/workflows/install-smoke.yaml` — replace all 7 references to `scripts/install.sh` with `install.sh`. The current references are at the path-trigger filters (lines ~6 and ~11) and inside the run steps (lines ~50, ~62, ~87, ~99, ~101, ~113). Verify by re-grepping after the move; nothing should remain.
3. Update `AGENTS.md` — replace `scripts/install.sh` with `install.sh` in:
   - Line ~320: architecture table row "Curl one-liner"
   - Line ~330: prose mentioning "Both `scripts/install.sh` and `cmd/gridctl/upgrade.go`"
   - Lines ~336-337: contract table cells
   - Line ~355: "release artifact identity" reference
   - Lines ~367-368: PR/push trigger description
   Re-grep `AGENTS.md` after edits; the only remaining reference to `scripts/install.sh` should be zero.
4. Add a regression-test step to `install-smoke.yaml` that asserts the documented URL serves HTTP 200. Suggested placement: a separate job named `documented-url` so it runs in parallel with the existing install/uninstall tests. It must run on the existing `pull_request` and `push` triggers (path filters are fine — the job only matters when install.sh or the workflow change). Body:
   ```yaml
   documented-url:
     runs-on: ubuntu-latest
     steps:
       - name: Documented install URL is reachable
         env:
           # On PRs from forks, github.head_ref is the source branch; on push
           # to main, github.ref_name is "main". Either way we want the branch
           # this workflow run actually represents.
           BRANCH: ${{ github.head_ref || github.ref_name }}
         run: |
           url="https://raw.githubusercontent.com/${{ github.repository }}/${BRANCH}/install.sh"
           echo "checking $url"
           code="$(curl -fsSL -o /dev/null -w '%{http_code}' "$url")"
           if [ "$code" != "200" ]; then
             echo "install.sh URL returned HTTP $code (expected 200)"
             exit 1
           fi
   ```
   Note: on PRs from a fork, `raw.githubusercontent.com` may serve the user's fork branch; that's still a valid liveness check. On a `push` to `main` after merge, this asserts that the production URL is healthy.

### Constraints

- Do NOT change `README.md`. It already references `…/main/install.sh` correctly. Verify with `rg -n "raw.githubusercontent.com.*install\.sh" README.md` — every match should remain unchanged after the fix.
- Do NOT change the body of the install script. `RAW_INSTALL_URL` (`scripts/install.sh:23`) and the script's header usage comment (`scripts/install.sh:8`) already point at `…/main/install.sh` — those become correct automatically once the file moves to the root. The only thing that changes for the script is its location, not its contents.
- Do NOT touch `cmd/gridctl/upgrade.go`. It is unrelated to install.sh.
- Do NOT add a copy/symlink at `scripts/install.sh` "for backwards compatibility." Nothing depends on the old path; a copy creates drift risk.
- Use `git mv`, not delete + create, so blame and history survive the move.
- Keep the move and the CI/AGENTS updates in a single commit — the working tree must never be in an "install.sh moved but install-smoke.yaml still says scripts/install.sh" state on `main`.

### Out of Scope

- Reorganizing other scripts in `scripts/`.
- Refactoring or improving `install.sh` beyond moving it.
- Improving or rewriting the README install section.
- Adding new install methods (apt, deb, snap, etc.).
- Changing `gridctl upgrade` behavior.
- Adding install metrics or telemetry.

## Implementation Guidance

### Key Files to Read

- `scripts/install.sh` — to confirm `RAW_INSTALL_URL` and the header comment do not need editing (they already reference `…/main/install.sh`).
- `.github/workflows/install-smoke.yaml` — to enumerate every `scripts/install.sh` reference before editing.
- `AGENTS.md` — same enumeration; the file has multiple references in different table rows and prose.
- `README.md` (sections "Quick install" ~line 70-90 and "Uninstalling" ~line 135-150) — read-only verification; should not be modified.

### Files to Modify

- `scripts/install.sh` -> `install.sh` (move, no content change). Use `git mv scripts/install.sh install.sh`.
- `.github/workflows/install-smoke.yaml` — 7 path references updated; new `documented-url` job added.
- `AGENTS.md` — every occurrence of `scripts/install.sh` becomes `install.sh`. Re-grep after edit.

### Reusable Components

- The existing job structure in `install-smoke.yaml` is the model for the new `documented-url` job — copy the `runs-on`, env-var, and triggers pattern.
- Use `${{ github.repository }}` and `${{ github.head_ref || github.ref_name }}` for the URL, not hardcoded `gridctl/gridctl/main`, so the test works on PR branches and forks.

### Conventions to Follow

- Branch naming: `fix/install-url-404` (the project uses `fix/` prefix for bug fixes per the global CLAUDE.md).
- Commit format: `fix: <subject>` imperative, ≤50 chars, no period. Example: `fix: serve install.sh from repo root`.
- Sign all commits with `-S`. No Co-authored-by trailers. No mention of Claude in commit messages, PR titles, or branch names.
- This repo uses the **fork workflow** (per project memory): origin is `wcollins/gridctl`, upstream is `gridctl/gridctl`. Use `/branch-fork` and `/pr-fork` skills, not their trunk equivalents.
- One commit for the move + CI/AGENTS update. Add the `documented-url` job in the same commit (it's part of the same fix).

## Regression Test

### Test Outline

The regression test is an end-to-end check that the documented URL is reachable. It belongs in `install-smoke.yaml` as a new `documented-url` job (see "Required Changes" #4 for the exact YAML).

Inputs: the canonical URL pattern `https://raw.githubusercontent.com/{repo}/{branch}/install.sh`.
Expected output: HTTP 200.
What it catches:
- File deleted or renamed without doc update.
- Branch deleted (extremely unlikely on `main`).
- Documented URL drifting from actual file location (the exact bug being fixed).

### Existing Test Patterns

The existing jobs in `install-smoke.yaml` use:
- `runs-on: ubuntu-latest` (or matrix for cross-platform install testing)
- Path filters in `on:` for `pull_request` and `push`
- Plain `run:` shell steps with `set -eu` semantics implicit
- `shellcheck -s sh` for the script itself (line ~113)

Follow the same shape for the new job — a single shell step is sufficient; no setup actions required.

## Potential Pitfalls

- **CI catches its own breakage by accident**: After the move, the existing job that runs `bash scripts/install.sh` will fail (path no longer exists) until you update its references. Update both halves in the same diff so CI passes on the fix branch.
- **Path-filter triggers**: `install-smoke.yaml`'s `on:` path filter currently watches `scripts/install.sh`. After the move, watch `install.sh` instead. Forgetting this means CI silently stops running on install-script changes.
- **`shellcheck -s sh` invocation**: The shellcheck step at line ~113 runs `shellcheck -s sh scripts/install.sh`. Update the path. Re-run shellcheck locally on the moved file before pushing — `shellcheck -s sh install.sh` should pass with no diagnostics.
- **README "uninstall" command**: Currently uses `…/main/install.sh | sh -s -- --uninstall`. After the fix this works, so it does not need editing. But verify by running it in a sandbox (e.g., a Docker container) before claiming the fix is complete.
- **Merging timing**: Until the PR merges to `main`, the documented URL stays broken. The new `documented-url` job will only verify the production URL once the change is on `main`. On the PR branch, the job verifies the PR branch's URL — which proves the fix works but doesn't prove production is fixed until after merge. Manually verify post-merge with `curl -sI https://raw.githubusercontent.com/gridctl/gridctl/main/install.sh` (expect HTTP 200).
- **Repo root noise**: The repo root gains `install.sh` next to `Makefile`, `go.mod`, `README.md`, etc. This is conventional (k3s, rustup, helm-installer, oh-my-zsh) and is the explicit tradeoff being made. Do not nest the file again to "tidy up."

## Acceptance Criteria

1. `git mv scripts/install.sh install.sh` lands in a single commit; `git log --follow install.sh` shows the move (history preserved).
2. `rg -n "scripts/install\.sh" .` returns zero matches anywhere in the repo (excluding test fixtures and committed lockfiles, which should not contain it).
3. After the PR merges to `main`, `curl -sI https://raw.githubusercontent.com/gridctl/gridctl/main/install.sh` returns `HTTP/2 200`.
4. After the PR merges to `main`, `curl -fsSL https://raw.githubusercontent.com/gridctl/gridctl/main/install.sh | sh` runs the installer end-to-end on Debian, macOS, and a `linux/amd64` Docker container, installing the latest release to `~/.local/bin/gridctl`.
5. `.github/workflows/install-smoke.yaml` includes a `documented-url` job that asserts HTTP 200 on the documented URL, and this job passes on the fix PR.
6. The existing install-smoke jobs (install, install-then-upgrade, uninstall, shellcheck) continue to pass after the path updates.
7. `README.md` is unchanged from before the fix (verified via `git diff main -- README.md`).
8. `AGENTS.md` contains zero references to `scripts/install.sh`; all references read `install.sh`.
9. No mention of Claude in branch name, commit message, or PR title/body.

## References

- Investigation: `prompts/gridctl/install-url-404-mismatch/bug-evaluation.md`
- Origin commit: `f445d5b` (PR #531, "feat: add curl install script with upgrade and uninstall", 2026-04-27)
- Convention examples for root-served installers: `https://get.k3s.io` (k3s), `https://sh.rustup.rs` (rustup), `https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh` (oh-my-zsh — note: zsh nests, but it's served via `https://install.ohmyz.sh` which redirects).
- GitHub raw-content path docs: `https://docs.github.com/en/repositories/working-with-files/using-files/viewing-a-file#viewing-or-copying-the-raw-file-content`
