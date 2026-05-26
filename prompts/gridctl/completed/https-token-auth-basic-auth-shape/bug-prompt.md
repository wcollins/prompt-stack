# Bug Fix: HTTPSTokenAuth Wrong Basic-Auth Shape

## Context

`gridctl` is a Go-based MCP gateway / orchestration CLI. The `pkg/git` package wraps go-git and exposes an `Auther` interface used by the skills importer (`pkg/skills`), the HTTP API (`internal/api/skills.go`), and the MCP runtime (`pkg/runtime`). HTTPS token authentication for git remotes is implemented by `HTTPSTokenAuth.AuthFor`, which builds a `*http.BasicAuth` for go-git to send to the remote.

Stack: Go 1.26, `github.com/go-git/go-git/v5`, table-driven tests next to source, integration tests in `tests/integration/` behind the `integration` build tag.

## Investigation Context

Full investigation: `prompt-stack/prompts/gridctl/https-token-auth-basic-auth-shape/bug-evaluation.md`.

Key findings shaping this prompt:

- Root cause confirmed at `pkg/git/auth.go:81`: token is in the Username slot with empty Password. GitHub rejects this shape with "Invalid username or token. Password authentication is not supported for Git operations."
- Defect is reachable from real runtime paths — `gridctl skill add/update`, the HTTP skills API, and the MCP runtime when a source declares `source.auth.method: token`.
- Two tests currently mask the bug:
  - `pkg/git/auth_test.go:57-69` (`TestHTTPSTokenAuth_HappyPath`) asserts `Password == ""`, ratifying the wrong shape.
  - `tests/integration/skills_private_git_test.go:97-109` (`startAuthedGitHTTPServer`) gates the test server on `user != validToken` and ignores the password slot, so any basic-auth shape that puts the token in the username succeeds.
- Reproduction confirmed: deterministic with a fresh GitHub App installation token (`ghs_*`) against any private github.com repo via `gridctl skill add --auth-token <ghs_token> ...`.
- Fix is one line of production code plus a doc comment plus two test updates. Risk is low — `x-access-token` is the documented GitHub shape and is also accepted by GitLab and Bitbucket.

## Bug Description

`HTTPSTokenAuth.AuthFor` returns:

```go
return &http.BasicAuth{Username: a.Token, Password: ""}, nil
```

Expected: the GitHub-documented shape `Username: "x-access-token", Password: <token>`.

This breaks token-authenticated HTTPS git operations against GitHub for App installation tokens (`ghs_*`) and fine-grained PATs (`github_pat_*`). It works-by-accident for legacy classic PATs (`ghp_*`) only because of GitHub's lenient legacy handling.

User impact: every command that takes a token for an HTTPS git remote — `gridctl skill add`, `gridctl skill update`, equivalent HTTP API endpoints, and MCP source loading with `source.auth.method: token`.

## Root Cause

`pkg/git/auth.go:81` builds `*http.BasicAuth` with the wrong slot assignment. The doc comment at `pkg/git/auth.go:65-67` reinforces the wrong belief that "PAT as HTTP basic-auth username with an empty password" is the shape git hosts accept. It is not — GitHub explicitly requires the literal username `x-access-token` with the token in the password slot for App installation tokens, and the same shape works universally for PATs across GitHub, GitLab, and Bitbucket.

## Fix Requirements

### Required Changes

1. In `pkg/git/auth.go`, change the return statement at line 81 to:
   ```go
   return &http.BasicAuth{Username: "x-access-token", Password: a.Token}, nil
   ```
2. Rewrite the godoc on `HTTPSTokenAuth` (lines 65-67) and on `AuthFor` (lines 72-73) to describe the corrected shape. Keep both comments concise. Mention that `x-access-token` is the GitHub-documented username for token-based basic auth and that this shape is accepted by GitHub PATs, GitHub App installation tokens, GitLab, and Bitbucket.
3. In `pkg/git/auth_test.go`, update `TestHTTPSTokenAuth_HappyPath` (lines 57-69) so it asserts:
   - `ba.Username == "x-access-token"`
   - `ba.Password == "abc123"` (the token passed in)
4. In `tests/integration/skills_private_git_test.go`, change the auth gate inside `startAuthedGitHTTPServer` (lines 97-109) so it validates the **password** slot:
   - Replace `user, _, ok := r.BasicAuth()` with `_, pass, ok := r.BasicAuth()`.
   - Replace `user != validToken` with `pass != validToken`.
   - Leave the 401/403 status mapping unchanged.
   - This keeps the existing test cases meaningful and makes future regressions of the production shape actually fail.

### Constraints

- Do not change the `HTTPSTokenAuth` struct shape, exported API, or method signatures.
- Do not modify any other Auther (`NoAuth`, `SSHAgentAuth`, `SSHKeyFileAuth`).
- Do not modify error sentinels in `pkg/git/errors.go` or the `ClassifyError` logic.
- Do not refactor `pkg/skills/importer.go`, `pkg/runtime/auth.go`, or any caller — they all consume `HTTPSTokenAuth` through the `Auther` interface and need no change.
- Preserve the existing `TestHTTPSTokenAuth_EmptyToken` and `TestHTTPSTokenAuth_WrongProtocol` cases unchanged.

### Out of Scope

- Adding configurability for the basic-auth username (e.g. per-host overrides for older GitLab `oauth2` username). If a user reports breakage on a non-GitHub host, that's a follow-up.
- Refactoring tests to a hermetic `httptest.Server` instead of `git-http-backend`. The CGI-backed test still works after the gate change.
- Updating `grid-common/git/auth.go` or any sister project. This fix is gridctl-only.
- Cutting a release. The release happens via `/release-gridctl` after merge.

## Implementation Guidance

### Key Files to Read

- `pkg/git/auth.go` — the file containing the defect; read in full for the doc comment style.
- `pkg/git/auth_test.go` — read `TestHTTPSTokenAuth_HappyPath` to understand the assertion style used elsewhere in the file.
- `tests/integration/skills_private_git_test.go` — read `startAuthedGitHTTPServer` and at least one of the four `TestSkills_PrivateHTTPS_*` cases so you understand what the auth gate is asserting.
- `tests/integration/mcp_private_git_test.go` — confirm these tests do not need separate changes; they reuse `startAuthedGitHTTPServer` from the skills file (same package, same build tag).

### Files to Modify

- `pkg/git/auth.go` (lines 65-73 doc comments, line 81 return statement)
- `pkg/git/auth_test.go` (lines 57-69, the happy-path assertion)
- `tests/integration/skills_private_git_test.go` (lines 97-109, the auth gate)

### Reusable Components

None needed. The fix uses only existing `*http.BasicAuth` from `github.com/go-git/go-git/v5/plumbing/transport/http`.

### Conventions to Follow

- Conventional commits: `fix: <subject>` (max 50 chars, imperative mood).
- Sign commits with `-S`. No `Co-authored-by` trailers. No mention of AI / Claude / LLM in commits, branches, or PR titles.
- Keep doc comments tight; this codebase prefers one short paragraph over multi-line walls.
- Table-driven tests are the norm but `TestHTTPSTokenAuth_HappyPath` is intentionally a single case — keep it that way.

## Regression Test

### Test Outline

After the fix:

1. `pkg/git/auth_test.go::TestHTTPSTokenAuth_HappyPath`:
   - Input: `HTTPSTokenAuth{Token: "abc123"}.AuthFor("https://github.com/a/b")`
   - Expected: `*http.BasicAuth` with `Username == "x-access-token"`, `Password == "abc123"`, `err == nil`.
2. `tests/integration/skills_private_git_test.go::TestSkills_PrivateHTTPS_ValidToken_Succeeds`:
   - Should still pass. Before the fix it passes because the gate ignores the password; after the fix it passes because the production code now sends `x-access-token:<token>` and the tightened gate validates the password slot.
3. `tests/integration/skills_private_git_test.go::TestSkills_PrivateHTTPS_WrongToken_ReturnsAuthFailed`:
   - Should still pass and now actually exercises a wrong-password rejection rather than a wrong-username rejection.

### Existing Test Patterns

- Tests live in `*_test.go` next to source.
- Integration tests are under `tests/integration/` with `//go:build integration` and run via `go test -tags=integration ./tests/integration/...`.
- `TestHTTPSTokenAuth_HappyPath` uses direct assertions, not `testify`. Match that style.
- The integration server uses `net/http/httptest.Server` wrapping a `cgi.Handler` that runs the system `git http-backend`. Don't restructure it; just change the gate's basic-auth check.

## Potential Pitfalls

- **Don't drop the username check entirely.** Switching from `user != validToken` to `pass != validToken` is the right move. Don't remove the `BasicAuth()` parse or the 401/403 distinction — both are load-bearing for the existing test cases.
- **Update the doc comment.** A future reader who only changes the code without the doc will create a fresh source of truth conflict; the misleading comment is part of why this bug shipped.
- **Verify `go test ./pkg/git/...` passes** without the integration build tag. The unit-level happy-path change must not require the integration server.
- **Verify `go test -tags=integration ./tests/integration/...` passes** — both the skills and MCP private-git suites use the shared `startAuthedGitHTTPServer`, so any change to the gate affects both files. Read both before submitting.
- **Don't bump or alter the failing fixture token** (`privateRepoValidToken = "correct-horse-battery-staple"`). It's still a valid string; only the slot it lands in changes.

## Acceptance Criteria

1. `pkg/git/auth.go:81` returns `&http.BasicAuth{Username: "x-access-token", Password: a.Token}, nil`.
2. The godoc on `HTTPSTokenAuth` and `HTTPSTokenAuth.AuthFor` describes the corrected shape and no longer claims an empty-password shape is what hosts accept.
3. `TestHTTPSTokenAuth_HappyPath` asserts the new shape and fails if the production code regresses.
4. `startAuthedGitHTTPServer`'s auth gate validates the password slot of basic auth.
5. `go test ./...` passes.
6. `go test -tags=integration ./tests/integration/...` passes.
7. `golangci-lint run` (if configured locally) reports no new findings.
8. Commit message follows conventional-commits (`fix: ...`) and is signed with `-S`.
9. No changes outside `pkg/git/auth.go`, `pkg/git/auth_test.go`, and `tests/integration/skills_private_git_test.go`.

## References

- Investigation: `prompt-stack/prompts/gridctl/https-token-auth-basic-auth-shape/bug-evaluation.md`
- GitHub docs — Authenticating as a GitHub App installation: https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation
- Introducing commit: `598ab82` "feat: add git auth primitives (#502)"
- Shipping tag containing the bug: `v0.1.0-beta.7`
