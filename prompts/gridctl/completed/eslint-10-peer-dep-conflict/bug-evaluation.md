# Bug Investigation: ESLint 10 Peer Dependency Conflict

**Date**: 2026-04-11
**Project**: gridctl
**Recommendation**: Fix immediately
**Severity**: High
**Fix Complexity**: Trivial

## Summary

Dependabot PR #446 merged `eslint@10.2.0` into upstream main (commit `bea961f`), but `eslint-plugin-react-hooks@7.0.1` declares a peer dependency range that explicitly excludes ESLint 10. `npm ci` now fails with ERESOLVE on every CI run, breaking the `frontend` gate on main and blocking PR #447. Fix is a one-line revert in `web/package.json` + lock file regeneration.

## The Bug

**Expected**: `npm ci` in `web/` succeeds; `frontend` CI check is green.
**Actual**: `npm ci` fails immediately with `npm error ERESOLVE could not resolve` — `eslint-plugin-react-hooks@7.0.1` peer dependency rejects `eslint@10.2.0`.
**Discovered**: CI check failure on merged PR #446 and open PR #447 on upstream `gridctl/gridctl`.

## Root Cause

### Defect Location
`web/package.json` — `"eslint": "^10.2.0"` (introduced by dependabot PR #446, commit `bea961f`)

### Code Path
1. CI `frontend` job checks out `main` at `65c116f`
2. Runs `npm ci` in `web/`
3. npm resolves `eslint@10.2.0` (from `package.json`)
4. npm resolves `eslint-plugin-react-hooks@7.0.1` (from `package.json`)
5. npm checks peer deps: `eslint-plugin-react-hooks@7.0.1` requires `eslint@"^3 || ^4 || ^5 || ^6 || ^7 || ^8 || ^9"` — ESLint 10 not in range
6. ERESOLVE — install aborted, exit code 1
7. All subsequent CI steps (type check, vitest, audit, build) never run

### Why It Happens
ESLint 10.0.0 GA was released February 6, 2026. `eslint-plugin-react-hooks@7.0.1` was published before ESLint 10 and its peer dependency range caps at `^9.0.0`. The React team merged a fix (facebook/react PR #35720) to add `^10.0.0` to the peer range on February 13, 2026, but as of April 2026 that fix has **not been published to npm**. No version of `eslint-plugin-react-hooks` on npm declares ESLint 10 support.

Secondary issue: `@eslint/js` remained at `^9.39.1` while `eslint` jumped to `^10.2.0` — these packages should share the same major version, creating an additional inconsistency.

### Similar Instances
- PR #447 (`dependabot/npm_and_yarn/web/multi-0193e73c84`) independently introduced `eslint@^10.2.0` as part of a grouped dependabot update and fails identically.
- No other locations in the codebase are affected — this project does not use `eslint-plugin-react` or `eslint-plugin-import` (the other major plugins with ESLint 10 runtime incompatibilities).

## Impact

### Severity Classification
**High — CI regression.** Not a production defect; no end-user impact. But the `frontend` gate on main is broken, which means every future PR touching `web/` will fail CI, and dependabot npm PRs cannot land.

### User Reach
All developers opening PRs that touch the frontend, and all automated dependabot npm PRs, are blocked.

### Workflow Impact
Critical path for frontend development. The `frontend` CI job gates all merges via Gatekeeper workflow; nothing frontend-related can land until this is resolved.

### Workarounds
None suitable for CI. Using `--legacy-peer-deps` in the `npm ci` command would unblock installation but is unsafe practice in CI and masks real compatibility issues.

### Urgency Signals
- `main` is actively broken (confirmed: upstream HEAD `65c116f` has eslint 10)
- PR #447 (react/types bump) is blocked
- All future dependabot npm PRs will fail the same check
- No published fix available from upstream (`eslint-plugin-react-hooks`) — only a source-only fix

## Reproduction

### Minimum Reproduction Steps
```bash
git checkout 65c116f   # upstream main HEAD
cd web
npm ci                 # fails with ERESOLVE
```

Or locally:
```bash
cd web
# Temporarily set eslint to ^10.2.0 in package.json
npm ci   # ERESOLVE
```

### Affected Environments
- Any environment running `npm ci` with `web/package.json` at the broken state
- npm ≥ 7 (strict peer deps by default)
- All platforms (Linux, macOS, Windows)

### Non-Affected Environments
- Local main at `b7e3c4f` (pre-#446) — eslint is `^9.39.1`, passes
- Any branch not including the eslint 10 bump

### Failure Mode
Fast-fail at `npm ci` — no files are written, no state is corrupted. CI exits 1, all subsequent steps are skipped.

## Fix Assessment

### Fix Surface
- `web/package.json` — change `"eslint": "^10.2.0"` back to `"^9"` (or latest 9.x)
- `web/package-lock.json` — regenerate via `npm install` after package.json change

### Risk Factors
- Minimal. Reverting to a known-good version with zero code changes.
- `@eslint/js` must stay aligned with `eslint` major version — both should be `^9`.

### Regression Test Outline
No new test needed. The existing `frontend` CI job (`npm ci` → `tsc` → `vitest` → `build`) is the regression test. After the fix, all four steps should pass green.

Optional hardening: Add a CI step or pre-commit hook that validates `eslint` and `@eslint/js` share the same major version in `web/package.json`.

## Recommendation

**Fix immediately.** Change `eslint` in `web/package.json` from `^10.2.0` to `^9` and regenerate the lock file. Close PR #447 and let dependabot recreate the react/types bump cleanly without the grouped eslint 10 change.

**Do not attempt ESLint 10 upgrade** until `eslint-plugin-react-hooks` publishes a version with `"eslint": "^10.0.0"` in its peer dependency range. Watch for `eslint-plugin-react-hooks@7.1.0+` or the post-7.0.1 release from the React team.

## References

- [eslint-plugin-react-hooks does not support ESLint 10 in peerDependencies · facebook/react #35758](https://github.com/facebook/react/issues/35758)
- [Add ESLint v10 support · facebook/react PR #35720](https://github.com/facebook/react/pull/35720)
- [ESLint v10.0.0 released](https://eslint.org/blog/2026/02/eslint-v10.0.0-released/)
- [ESLint v10 migration guide](https://eslint.org/docs/latest/use/migrate-to-10.0.0)
- [typescript-eslint ESLint 10 support](https://typescript-eslint.io/users/dependency-versions/)
