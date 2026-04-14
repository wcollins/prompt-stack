# Bug Investigation: Extends Relative Path Resolution

**Date**: 2026-04-07
**Project**: gridctl
**Recommendation**: Fix immediately
**Severity**: Medium
**Fix Complexity**: Small

## Summary

When a stack YAML uses `extends` to inherit from a parent stack in a different directory, relative paths in inherited fields are resolved against the child stack's directory instead of the parent's. The bug exists in a brand-new, unreleased feature (merged after v0.1.0-beta.4), making this an ideal time to fix before any public exposure.

## The Bug

**Expected**: A parent stack at `parents/base.yaml` with `source: {type: local, path: ./src}` should resolve to `parents/src/`.

**Actual**: The same path resolves to `children/src/` when loaded by a child stack at `children/child.yaml` via `extends: ../parents/base.yaml`.

**Discovered**: Code review of PR #388 (stack composition via extends field).

**Affected fields** (all relative paths in inherited MCP server definitions):
- `source.path` — local build context directory
- `ssh.identityFile` — SSH private key
- `ssh.knownHostsFile` — known hosts file
- `openapi.spec` — local OpenAPI specification file

## Root Cause

### Defect Location

`pkg/config/loader.go:88` — `basePath` is derived from the child's file path and used for all path resolution, including paths inherited from parent stacks.

### Code Path

```
LoadStack("children/child.yaml")
  resolveExtends(&child, "children/child.yaml", visited, 0)
    → loads "parents/base.yaml"
    → mergeStacks(child, parent)   // parent's ./src merged in as-is
  basePath := filepath.Dir("children/child.yaml")  // = "children/"  ← BUG
  resolveRelativePaths(&stack, "children/")
    → source.path "./src" → "children/src"  ← WRONG (should be "parents/src")
```

### Why It Happens

`resolveExtends()` (lines 276–322) loads and merges parent stacks before `resolveRelativePaths()` is called (line 89). After merge, inherited relative paths have lost their origin context. `resolveRelativePaths()` uses a single `basePath` derived from the child's location (line 88) and applies it to every relative path in the merged stack — including those that originated in the parent.

The fix is to pre-resolve relative paths on the parent stack (using the parent's `basePath`) inside `resolveExtends()`, before `mergeStacks()` is called. This converts inherited relative paths to absolute paths that survive the merge correctly.

### Similar Instances

No identical pattern found elsewhere. The `skills` config package loads YAML but does not implement composition/inheritance.

## Impact

### Severity Classification

**Incorrect behavior** — wrong filesystem path is used for local builds, SSH keys, and OpenAPI specs inherited from parent stacks. No crash, no data loss, no security exposure (SSH key resolution failure blocks the connection rather than leaking keys).

### User Reach

Minimal today: the feature was merged on 2026-04-06, is not yet in any release tag, and has no official documentation. Real-world exposure is effectively zero.

Once released and documented, this affects any user who:
- Uses `extends` for stack composition
- Has parent and child stacks in different directories
- Uses relative paths in the parent stack for local sources, SSH keys, or OpenAPI specs

### Workflow Impact

Blocked workflows (when the bug is eventually hit):
- Local Docker builds from parent-defined source paths fail with "directory not found"
- SSH tunnel connections fail if the parent defines a relative identity file
- OpenAPI proxy servers fail if the parent references a local spec file

### Workarounds

1. **Use absolute paths in parent stacks** — most reliable, works immediately
2. **Co-locate parent and child stacks** in the same directory — `basePath` coincidentally correct
3. **Use `${ENV_VAR}` references** for filesystem paths in parent stacks

### Urgency Signals

- Feature merged after v0.1.0-beta.4; not yet in any release
- Zero active production users of this feature
- No urgency signals from issue tracker or user reports
- Low-risk fix window: optimal to fix now before the feature ships in beta.5

## Reproduction

### Minimum Reproduction Steps

1. Create directory structure:
   ```
   /tmp/test/
   ├── parents/
   │   ├── base.yaml
   │   └── src/server/       ← source code lives here
   └── children/
       └── child.yaml
   ```

2. `parents/base.yaml`:
   ```yaml
   version: "1"
   name: base
   mcp-servers:
     - name: my-server
       source:
         type: local
         path: ./src/server
   ```

3. `children/child.yaml`:
   ```yaml
   version: "1"
   name: child
   extends: ../parents/base.yaml
   ```

4. Call `LoadStack("children/child.yaml")`

5. Observe: `stack.MCPServers[0].Source.Path` is `children/src/server` (wrong), not `parents/src/server` (correct)

### Affected Environments

All platforms; deterministic. Any scenario where:
- Parent and child stacks are in different directories
- Parent stack contains relative paths in `source.path`, `ssh.identityFile`, `ssh.knownHostsFile`, or `openapi.spec`

### Non-Affected Environments

- Parent and child in the same directory (basePath coincidentally correct)
- Absolute paths in parent stack fields
- URL-valued fields (`image`, `url`, `source.url`)

### Failure Mode

`resolveRelativePaths()` silently produces a wrong absolute path. The error surfaces downstream when the builder or SSH client tries to access the nonexistent path (e.g., Docker build context not found, SSH key file missing). The system reaches a recoverable error state — no corruption, clean failure.

## Fix Assessment

### Fix Surface

Single file: `pkg/config/loader.go`

Changes needed:
1. In `resolveExtends()`, call `resolveRelativePaths(&parent, filepath.Dir(absParentPath))` on the parent stack before calling `mergeStacks(child, &parent)`.
2. Add a regression test in `pkg/config/loader_test.go` covering cross-directory extends with relative `source.path`.

### Risk Factors

- `resolveRelativePaths()` is idempotent for absolute paths (uses `filepath.IsAbs` guard), so calling it twice (once in `resolveExtends` for the parent, then again in `LoadStack` for the child's own paths) is safe.
- Multi-level inheritance is handled correctly: `resolveExtends()` recurses before merging, so grandparent paths are resolved against the grandparent's directory before being merged up the chain.

### Regression Test Outline

**Test**: `TestLoadStack_Extends_CrossDirectory_LocalSource`

Setup:
- `tmpRoot/parents/base.yaml` — defines `source: {type: local, path: ./src/server}`
- `tmpRoot/parents/src/server/` — the actual source directory
- `tmpRoot/children/child.yaml` — `extends: ../parents/base.yaml`

Assertion: `stack.MCPServers[0].Source.Path == filepath.Join(tmpRoot, "parents", "src", "server")`

Additional tests: cross-directory `ssh.identityFile` and `openapi.spec` resolution.

## Recommendation

**Fix immediately.** The fix is small (one line added inside `resolveExtends()`), isolated, low-risk, and idempotent. The feature is pre-release with zero production exposure. Fixing now — before beta.5 ships — costs almost nothing and makes the `extends` feature correct from its first public release. Deferring would mean shipping a subtly broken feature that silently misdirects filesystem paths.

## References

- PR #388: stack composition via extends field (introduces the bug)
- `pkg/config/loader.go` — root cause at lines 88, 319
- `pkg/config/loader_test.go` — existing extends tests at lines 788–1167 (all same-directory, missing cross-directory coverage)
