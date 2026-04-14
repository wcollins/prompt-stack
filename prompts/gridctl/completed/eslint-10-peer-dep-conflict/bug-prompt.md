# Bug Fix: ESLint 10 Peer Dependency Conflict

## Context

**Project**: gridctl — a Go + React MCP orchestration gateway. The frontend lives in `web/` and is a React 19 + TypeScript + Vite app. ESLint is used for linting via the flat config format (`web/eslint.config.js`). CI runs `npm ci` → `tsc` → `vitest` → `npm audit` → `npm run build` in the `frontend` job defined in `.github/workflows/gatekeeper.yaml`.

## Investigation Context

- **Root cause confirmed**: `eslint@10.2.0` was merged into upstream main (commit `bea961f`, PR #446) but `eslint-plugin-react-hooks@7.0.1` declares a peer dep range ending at `^9.0.0` — ESLint 10 is explicitly excluded. `npm ci` fails with ERESOLVE immediately.
- **No npm fix available**: The React team merged a source fix (facebook/react PR #35720) adding `^10.0.0` to the peer range, but it has not been published to npm as of April 2026.
- **PR #447 also blocked**: The open dependabot PR bumping react and @types/react also includes eslint 10 in its branch and fails identically.
- **Fix is a one-line revert**: downgrade `eslint` back to `^9` and regenerate the lock file.
- Full investigation: see `eslint-10-peer-dep-conflict/bug-evaluation.md` in prompt-stack.

## Bug Description

`npm ci` fails with ERESOLVE on every CI run of the `frontend` job:

```
npm error ERESOLVE could not resolve
npm error peer eslint@"^3.0.0 || ^4.0.0 || ^5.0.0 || ^6.0.0 || ^7.0.0 || ^8.0.0-0 || ^9.0.0"
npm error   from eslint-plugin-react-hooks@7.0.1
npm error Found: eslint@10.2.0
```

This blocks all CI on `main` and prevents PR #447 from merging.

## Root Cause

**File**: `web/package.json`
**Line**: `"eslint": "^10.2.0"`

Dependabot PR #446 bumped `eslint` from `^9.39.2` to `^10.2.0`. ESLint 10 is not declared in `eslint-plugin-react-hooks@7.0.1`'s peer dependency range. npm's strict peer resolution (default since npm 7) treats this as a hard error.

Additionally, `@eslint/js` was NOT bumped alongside `eslint` — it remains at `^9.39.1` on upstream main. These two packages must share the same major version; the inconsistency would cause a secondary failure even if the react-hooks conflict were resolved.

## Fix Requirements

### Required Changes

1. In `web/package.json`, change `"eslint": "^10.2.0"` → `"eslint": "^9"`
2. Verify `"@eslint/js"` is also `"^9"` (it should already be `"^9.39.1"` — confirm it was not bumped)
3. Run `npm install` inside `web/` to regenerate `web/package-lock.json` with the correct resolved versions
4. Verify `npm ci` passes locally after the lock file is regenerated

### Constraints

- Do NOT use `--legacy-peer-deps` in the CI workflow or as an npm config — this masks real issues
- Do NOT add `package.json` overrides to force peer dep resolution — same concern
- Keep `eslint` and `@eslint/js` on the same major version at all times
- Do NOT upgrade `eslint-plugin-react-hooks` — no published version supports ESLint 10

### Out of Scope

- Upgrading to ESLint 10 (defer until `eslint-plugin-react-hooks` publishes ESLint 10 support)
- Fixing or rebasing PR #447 — close it after this fix and let dependabot recreate the react/types bump without the eslint grouping
- Any changes to `eslint.config.js` or linting rules

## Implementation Guidance

### Key Files to Read

1. `web/package.json` — the file to modify; check both `eslint` and `@eslint/js` versions
2. `web/package-lock.json` — will be regenerated; verify resolved eslint version after `npm install`
3. `.github/workflows/gatekeeper.yaml` — confirm the `frontend` job uses `npm ci` (do NOT modify)

### Files to Modify

**`web/package.json`**:
```diff
-  "eslint": "^10.2.0",
+  "eslint": "^9",
```
(`@eslint/js` should already be `^9` — verify but likely no change needed)

**`web/package-lock.json`**: regenerated automatically by running `npm install` in `web/`.

### Reusable Components

The existing CI `frontend` job is the test. No new code needed.

### Conventions to Follow

- Run `npm install` (not `npm ci`) to regenerate the lock file after changing `package.json`
- Commit both `web/package.json` and `web/package-lock.json` together in a single commit
- Commit message format: `fix: revert eslint to v9 to restore frontend CI`
- Branch naming: `fix/revert-eslint-v10`

## Regression Test

### Test Outline

After the fix, the following must pass:
```bash
cd web
npm ci          # must exit 0
npx tsc --noEmit  # type check
npx vitest run    # frontend tests
npm run build     # production build
```

This is exactly what the CI `frontend` job runs. No new test code is needed.

### Existing Test Patterns

The `frontend` CI job in `.github/workflows/gatekeeper.yaml` is the canonical integration test for this. It runs on every PR and must be green before merging.

## Potential Pitfalls

- **Lock file staleness**: After changing `package.json`, you must run `npm install` (not just edit the lock file manually) to get a valid `package-lock.json`. Commit both files.
- **`@eslint/js` version**: If upstream main had `@eslint/js: "^10.x"` (it doesn't — it stayed at `^9.39.1`), you would need to revert that too. Double-check before committing.
- **PR #447**: After fixing main, PR #447's branch still has eslint 10. Close it — do not attempt to rebase it. Dependabot will create a clean new PR for the react/types bump.
- **ESLint 10 revisit**: Once `eslint-plugin-react-hooks@7.1.0+` (or post-7.0.1) is published with `"eslint": "^10.0.0"` in its peer deps, you can accept the dependabot eslint 10 bump. Until then, close any dependabot PR that bumps `eslint` to v10.

## Acceptance Criteria

1. `web/package.json` has `"eslint": "^9"` (or a specific 9.x semver range)
2. `web/package.json` has `"@eslint/js"` on the same major version (`^9`)
3. `web/package-lock.json` resolves `eslint` to a `9.x` version
4. `cd web && npm ci` exits 0 with no ERESOLVE errors
5. The `frontend` CI check passes green on the fix PR
6. PR #447 is closed (it will be recreated by dependabot without the eslint grouping)

## References

- [eslint-plugin-react-hooks ESLint 10 issue · facebook/react #35758](https://github.com/facebook/react/issues/35758)
- [Upstream fix (source-only, not published) · facebook/react PR #35720](https://github.com/facebook/react/pull/35720)
- [ESLint v10.0.0 release](https://eslint.org/blog/2026/02/eslint-v10.0.0-released/)
- [typescript-eslint peer version support matrix](https://typescript-eslint.io/users/dependency-versions/)
