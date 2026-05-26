---
name: HTTPSTokenAuth uses wrong Basic-Auth slot for GitHub
description: pkg/git/auth.go puts the token in the Username slot with an empty password — breaks GitHub App installation tokens and is unreliable for fine-grained PATs
type: bug-investigation
---

# Bug Investigation: HTTPSTokenAuth Wrong Basic-Auth Shape

**Date**: 2026-05-04
**Project**: gridctl
**Recommendation**: Fix immediately
**Severity**: High
**Fix Complexity**: Trivial

## Summary

`pkg/git/auth.go`'s `HTTPSTokenAuth.AuthFor` populates `*http.BasicAuth` with the token in the Username slot and an empty Password. GitHub rejects this shape for GitHub App installation tokens (`ghs_*`) with "Invalid username or token. Password authentication is not supported for Git operations." The correct shape is `Username: "x-access-token", Password: <token>`. The defect ships in `v0.1.0-beta.7`, is reachable from real CLI/API/MCP code paths, and is masked by a unit test that asserts the wrong shape and an integration test whose auth gate ignores the password slot.

## The Bug

`HTTPSTokenAuth` is the canonical token-based Auther for HTTPS git remotes. Its `AuthFor` returns:

```go
return &http.BasicAuth{Username: a.Token, Password: ""}, nil
```

Expected behavior: the basic-auth shape that GitHub (and most modern git hosts) accept for both Personal Access Tokens and App installation tokens — `Username: "x-access-token", Password: <token>`.

Actual behavior: GitHub rejects pushes/clones authenticated with this shape, especially for GitHub App installation tokens minted via the App JWT exchange. Classic PATs (`ghp_*`) sometimes succeed by accident due to GitHub's lenient legacy handling, but this is undocumented and unreliable.

Discovered while integration-testing token-authenticated git operations against a fresh GitHub App installation token (`ghs_*`). The clone/push fails with the GitHub auth error above, which `pkg/git/errors.go` classifies as `ErrAuthFailed`.

## Root Cause

### Defect Location

- `pkg/git/auth.go:81` — the `*http.BasicAuth` literal puts the token in the wrong slot.
- `pkg/git/auth.go:65-67` — the godoc comment on `HTTPSTokenAuth` documents the wrong shape ("PAT as HTTP basic-auth username with an empty password — the shape GitHub, GitLab, Bitbucket, and most self-hosted servers accept"), so anyone reading the code will think the current behavior is intentional.

### Code Path

1. User runs `gridctl skill add --auth-token <token> https://github.com/owner/repo` (or sets `GITHUB_TOKEN`, or uses `--vault-key`).
2. `cmd/gridctl/skill.go:283` calls `Importer.Import` with `AuthConfig{Method: "token", Token: <token>}`.
3. `pkg/skills/importer.go` resolves an Auther via `BuildAuther` (line 37) or `resolveAuther` (line 62).
4. `BuildAuther` returns `gitpkg.HTTPSTokenAuth{Token: cfg.Token}`.
5. The clone path in `pkg/skills/remote.go` calls `auther.AuthFor(url)`.
6. `HTTPSTokenAuth.AuthFor` returns the malformed `*http.BasicAuth`.
7. go-git submits it to the remote; GitHub rejects with the "Invalid username or token" message.

The same defect is reachable from the MCP runtime via `pkg/runtime/auth.go:31` (`AuthForSource` → `HTTPSTokenAuth{...}.AuthFor`), called from `pkg/runtime/orchestrator.go:390` whenever an MCP server source declares `source.auth.method: token`.

### Why It Happens

The author wrote the basic-auth literal based on the older, lenient GitHub.com behavior where putting a PAT in the username slot "just worked." That hasn't been the supported shape since GitHub deprecated password-style auth, and it has *never* worked for GitHub App installation tokens, which require the literal username `x-access-token`. The doc comment locked the wrong belief into the codebase, and the unit test ratified it.

### Similar Instances

None — `HTTPSTokenAuth` is the only token-bearing Auther. SSH paths (`SSHAgentAuth`, `SSHKeyFileAuth`) are unaffected.

## Impact

### Severity Classification

**High.** The defect blocks token-authenticated HTTPS git operations against GitHub for the supported token types most users would mint today (GitHub App installation tokens, fine-grained PATs). It works-by-accident for legacy classic PATs, which masks the breakage in casual testing but does not make the code correct.

### User Reach

- **Hard-broken**: anyone authenticating with a GitHub App installation token (`ghs_*`) or a fine-grained PAT (`github_pat_*`).
- **Fragile**: anyone using a classic PAT (`ghp_*`) — currently works against github.com only because of GitHub's legacy handling; could break at any time.
- **Unaffected**: SSH users, public-repo users, hosts that ignore the password slot.

### Workflow Impact

Critical-path blocker for the following surfaces:

- **CLI**: `gridctl skill add --auth-token` / `--vault-key` / ambient `GITHUB_TOKEN`; `gridctl skill update` (re-resolves vault refs at update time).
- **HTTP API**: `internal/api/skills.go` lines 286–288, 446–453, 387, 532, 607 (POST skills, POST update, fetch-and-compare).
- **MCP runtime**: any source config block with `source.auth.method: token` (handled by `pkg/runtime/orchestrator.go:390` → `AuthForSource`).

### Workarounds

- Switch to SSH (`--ssh-key` / `ssh-agent`) — works, but not always operationally feasible (CI environments, App-token flows).
- Clone outside gridctl and import via local path — works, but loses the origin/lockfile + update tracking.

There is no in-code workaround for HTTPS token auth: every "token" method funnels through the broken function.

### Urgency Signals

- Bug ships in `v0.1.0-beta.7`, the most recent tag. HEAD is 10 commits past beta.7 and still carries the bug.
- Introduced in `598ab82` (2026-04-20) "feat: add git auth primitives (#502)" — born broken; no regression in older tags.
- The unit test `TestHTTPSTokenAuth_HappyPath` actively asserts the wrong shape (`ba.Password != ""` is treated as failure), so any well-meaning fix without simultaneously updating the test will be reverted by CI.
- The integration test (`TestSkills_PrivateHTTPS_ValidToken_Succeeds`) passes today against a real `git http-backend` — but only because the test fixture's auth gate at `tests/integration/skills_private_git_test.go:104` validates `user != validToken` and ignores the password slot, replicating the same defect.

## Reproduction

### Minimum Reproduction Steps

1. Create or use a private GitHub repo at `github.com/<owner>/<repo>`.
2. Mint a GitHub App installation token (`ghs_*`) via the App JWT → installation-token exchange. (A `github_pat_*` fine-grained PAT also reproduces.)
3. From the gridctl repo, run:
   ```
   GITHUB_TOKEN=ghs_xxx gridctl skill add https://github.com/<owner>/<repo>
   ```
   or:
   ```
   gridctl skill add --auth-token ghs_xxx https://github.com/<owner>/<repo>
   ```
4. Observe failure. After error classification through `gitpkg.ClassifyError`, the user sees `ErrAuthFailed` plus the hint "credentials were rejected; verify the token has repo-read access" (`cmd/gridctl/skill.go:259`). The underlying go-git error wraps GitHub's "Invalid username or token. Password authentication is not supported for Git operations."

### Affected Environments

All. The defect is pure logic with no platform dependence.

### Non-Affected Environments

- SSH paths (`SSHAgentAuth`, `SSHKeyFileAuth`).
- Public repos (no auth).
- Self-hosted Git Smart-HTTP servers that accept any non-empty username and ignore the password — the breakage will only be visible against strict servers.

### Failure Mode

`go-git` sends `Authorization: Basic base64("<token>:")`. GitHub returns 403 with the "Invalid username or token" message. The clone aborts cleanly; nothing is written to the registry, lockfile, or origin sidecar. No corrupted state.

## Fix Assessment

### Fix Surface

- `pkg/git/auth.go:81` — flip the basic-auth slots.
- `pkg/git/auth.go:65-73` — rewrite the godoc comment to describe the corrected shape.
- `pkg/git/auth_test.go:57-69` (`TestHTTPSTokenAuth_HappyPath`) — flip the assertion to require `Username == "x-access-token"` and `Password == <token>`.
- `tests/integration/skills_private_git_test.go:97-109` — tighten the auth gate so the round-trip actually validates the GitHub-shaped basic-auth (require `password == validToken` rather than `user == validToken`). Without this change, the test passes either shape and the regression test regresses silently.

No public API change: `HTTPSTokenAuth` keeps the same struct shape and method signatures. Behavior change is internal to `AuthFor`.

### Risk Factors

- **Hosts that strictly require a different username**: GitHub Enterprise, GitLab, Bitbucket, and most modern self-hosted servers all accept `x-access-token` as the username for token-based basic auth. If a user's host is unusually strict and requires e.g. `oauth2` (older GitLab) instead, that's a follow-up — not introduced by this fix; the current behavior is broken for them anyway.
- **The masking integration test**: tightening the test fixture's auth gate is non-optional. If only the production code is fixed and the test gate is left lax, future regressions in production will pass CI.

### Regression Test Outline

1. **Unit-level**: `TestHTTPSTokenAuth_HappyPath` asserts `ba.Username == "x-access-token"` and `ba.Password == "<token-passed-in>"`.
2. **Integration**: `startAuthedGitHTTPServer` validates the password slot of basic auth, not the username. After the fix, all four `TestSkills_PrivateHTTPS_*` cases and all three `TestMCP_PrivateHTTPS_*` cases should still pass; before the fix, `*_ValidToken_Succeeds` should fail.
3. (Optional) A focused unit test against an `httptest.Server` whose handler reads both fields and asserts the GitHub shape, decoupled from `git-http-backend`.

## Recommendation

**Fix immediately.** The change is one line of production code plus a doc comment, with two test updates to make the regression test actually regress. Cut `v0.1.0-beta.8` after merge so the broken auth path doesn't survive into the next stable.

Keep the patch tightly scoped to `pkg/git/auth.go` and the two test files. Do not refactor surrounding code or change unrelated Auther implementations as part of this fix — the goal is the smallest credible change that makes token-authenticated HTTPS work.

## References

- GitHub docs — Authenticating as a GitHub App installation: https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation
- go-git basic auth: `github.com/go-git/go-git/v5/plumbing/transport/http`
- Introducing commit: `598ab82` "feat: add git auth primitives (#502)" (2026-04-20)
- Shipping tag containing the bug: `v0.1.0-beta.7`
