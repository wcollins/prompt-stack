# Bug Fix: Extends Relative Path Resolution

## Context

gridctl is a Go CLI tool for deploying and managing MCP (Model Context Protocol) server stacks defined in YAML files. Stacks are loaded via `pkg/config/loader.go`, which parses YAML, resolves variable references, applies defaults, resolves relative filesystem paths to absolute paths, and validates the result.

PR #388 added a stack composition feature: a `extends` field that allows a child stack YAML to inherit MCP servers, resources, gateway config, and other settings from a parent YAML. The feature supports multi-level inheritance and cycle detection.

**Tech stack**: Go 1.22+, `gopkg.in/yaml.v3`, standard library only for path/file operations.

## Investigation Context

- Root cause confirmed at `pkg/config/loader.go:88` — `basePath` is derived from the child stack's path and used for all relative path resolution, including paths inherited from parent stacks
- Risk: Low (fix is isolated to `resolveExtends()`; `resolveRelativePaths()` is idempotent for already-absolute paths)
- Reproduction: deterministic for any cross-directory extends scenario with relative paths in parent
- Full investigation: `prompts/gridctl/extends-relative-path-resolution/bug-evaluation.md`

## Bug Description

When a stack YAML uses `extends` to inherit from a parent stack located in a **different directory**, relative filesystem paths defined in the parent (e.g., `source: {type: local, path: ./src}`) are resolved against the **child's** directory instead of the **parent's** directory.

**Example**:
```
projects/
├── parents/
│   ├── base.yaml       # defines source.path: ./src
│   └── src/            # actual source code
└── children/
    └── child.yaml      # extends: ../parents/base.yaml
```

Loading `children/child.yaml` produces `source.path = "children/src"` instead of `"parents/src"`.

**Affected fields** (any relative path in an inherited MCP server):
- `source.path` (local build context)
- `ssh.identityFile`
- `ssh.knownHostsFile`
- `openapi.spec` (when not a URL)

## Root Cause

In `pkg/config/loader.go`:

```go
// Line 55: resolveExtends merges parent fields into child — relative paths come along as-is
if err := resolveExtends(&stack, absPath, visited, 0); err != nil {
    return nil, err
}

// Line 88: basePath is always the child's directory
basePath := filepath.Dir(path)

// Line 89: ALL relative paths resolved against child's basePath — wrong for inherited paths
resolveRelativePaths(&stack, basePath)
```

Inside `resolveExtends()` (lines 276–322):
```go
// Line 319: parent merged into child BEFORE parent's paths are resolved
mergeStacks(child, &parent)
```

The fix: call `resolveRelativePaths(&parent, filepath.Dir(absParentPath))` on the parent **before** calling `mergeStacks(child, &parent)`. This converts parent-relative paths to absolute paths before they enter the child's namespace. Because `resolveRelativePaths()` skips already-absolute paths (`filepath.IsAbs` guard at line 225), calling it again in `LoadStack` on the merged stack is safe.

## Fix Requirements

### Required Changes

1. In `resolveExtends()` in `pkg/config/loader.go`, add a call to resolve the parent's relative paths using the parent's own directory, immediately after the recursive `resolveExtends` call and before `mergeStacks`:

   ```go
   // Recurse before merging so the full ancestor chain is resolved first
   if err := resolveExtends(&parent, absParentPath, visited, depth+1); err != nil {
       return err
   }

   // NEW: resolve parent's relative paths against parent's directory before merging
   resolveRelativePaths(&parent, filepath.Dir(absParentPath))

   mergeStacks(child, &parent)
   ```

2. Add a regression test `TestLoadStack_Extends_CrossDirectory_LocalSource` in `pkg/config/loader_test.go` that uses parent and child stacks in different directories and verifies that inherited `source.path` resolves to the parent's directory.

3. Optionally add additional cross-directory tests for `ssh.identityFile` and `openapi.spec`.

### Constraints

- Do NOT change `resolveRelativePaths()` itself — the function is correct; the call site ordering is the bug
- Do NOT change `mergeStacks()` — the merge logic is correct
- Do NOT change `LoadStack()` — the final `resolveRelativePaths` call at line 89 is still needed for the child's own paths
- Preserve existing behavior: same-directory extends must continue to work identically

### Out of Scope

- Adding a `source.dockerfile` relative path resolver (separate concern)
- Adding a `logging.file` relative path resolver (separate concern)
- Refactoring `resolveRelativePaths` to accept per-server basePaths
- Any changes to the merge semantics

## Implementation Guidance

### Key Files to Read

| File | Why |
|------|-----|
| `pkg/config/loader.go` | Contains the bug; read in full before editing |
| `pkg/config/loader_test.go` | Understand existing test patterns, especially `TestLoadStack_Extends_*` (lines 788–1167) and the `writeFile` helper |
| `pkg/config/types.go` | Understand `Stack`, `MCPServer`, `Source`, `SSHConfig`, `OpenAPIConfig` structs |

### Files to Modify

**`pkg/config/loader.go`** — add one call before line 319 (`mergeStacks`):

```go
// around line 314–320
if err := resolveExtends(&parent, absParentPath, visited, depth+1); err != nil {
    return err
}

// Resolve parent's relative paths against parent's directory before merging into child
resolveRelativePaths(&parent, filepath.Dir(absParentPath))

mergeStacks(child, &parent)
```

**`pkg/config/loader_test.go`** — add new test function. Pattern matches existing extends tests:

```go
func TestLoadStack_Extends_CrossDirectory_LocalSource(t *testing.T) {
    tmpRoot := t.TempDir()
    parentsDir := filepath.Join(tmpRoot, "parents")
    childrenDir := filepath.Join(tmpRoot, "children")

    // Create the actual source directory so validation passes
    if err := os.MkdirAll(filepath.Join(parentsDir, "src", "server"), 0755); err != nil {
        t.Fatal(err)
    }

    writeFile(t, filepath.Join(parentsDir, "base.yaml"), `
version: "1"
name: base
mcp-servers:
  - name: my-server
    source:
      type: local
      path: ./src/server
`)
    writeFile(t, filepath.Join(childrenDir, "child.yaml"), `
version: "1"
name: child
extends: ../parents/base.yaml
`)

    stack, err := LoadStack(filepath.Join(childrenDir, "child.yaml"))
    if err != nil {
        t.Fatalf("unexpected error: %v", err)
    }

    var inherited *MCPServer
    for i := range stack.MCPServers {
        if stack.MCPServers[i].Name == "my-server" {
            inherited = &stack.MCPServers[i]
        }
    }
    if inherited == nil {
        t.Fatal("inherited server 'my-server' not found")
    }

    want := filepath.Join(parentsDir, "src", "server")
    if inherited.Source.Path != want {
        t.Errorf("inherited source.path:\n  got  %q\n  want %q", inherited.Source.Path, want)
    }
}
```

### Reusable Components

- `resolveRelativePaths(s *Stack, basePath string)` — already exists and handles all affected fields; just needs to be called earlier with the correct basePath
- `writeFile(t, path, content)` — test helper already defined in `loader_test.go`

### Conventions to Follow

- Go error wrapping with `fmt.Errorf("context: %w", err)` style
- Test names follow `TestLoadStack_Extends_<Description>` pattern
- Tests use `t.TempDir()` for temporary directories
- No external test dependencies; standard library only

## Regression Test

### Test Outline

**`TestLoadStack_Extends_CrossDirectory_LocalSource`**

- Parent at `tmpRoot/parents/base.yaml` with `source: {type: local, path: ./src/server}`
- Source directory `tmpRoot/parents/src/server/` must be created (validation checks existence)
- Child at `tmpRoot/children/child.yaml` with `extends: ../parents/base.yaml`
- Assert: `stack.MCPServers[n].Source.Path == filepath.Join(tmpRoot, "parents", "src", "server")`

**`TestLoadStack_Extends_CrossDirectory_SSHIdentityFile`** (optional but recommended)

- Parent defines `ssh: {host: example.com, user: git, identityFile: ./keys/id_rsa}`
- Child in different directory extends parent
- Assert: `ssh.IdentityFile == filepath.Join(parentsDir, "keys", "id_rsa")`

### Existing Test Patterns

All `TestLoadStack_Extends_*` tests follow the same structure:
1. `dir := t.TempDir()` — one temp dir for all files
2. `writeFile(t, filepath.Join(dir, "base.yaml"), ...)` — write YAML inline
3. `stack, err := LoadStack(filepath.Join(dir, "child.yaml"))` — load
4. Assertions directly on `stack` fields

The new tests diverge only in using **two** subdirectories (`parentsDir`, `childrenDir`) instead of one shared `dir`.

## Potential Pitfalls

1. **Validation failure**: `resolveRelativePaths` for `source.path` (local type) must point to a real directory, or `Validate()` will reject it. Create the directory in the test setup with `os.MkdirAll`.

2. **Multi-level inheritance**: The recursive `resolveExtends` call already handles grandparent chains. Because the fix calls `resolveRelativePaths` after recursion returns, grandparent paths are correctly resolved (absolute) before the parent merges them, and then the parent's own paths are resolved before the parent merges into the child. The ordering is correct.

3. **Idempotency**: `resolveRelativePaths` skips paths where `filepath.IsAbs()` is true (lines 225, 262). Calling it twice on an already-absolute path is safe and produces no change. No double-resolution risk.

4. **`extends` path itself**: The `child.Extends` field is a path to the parent YAML, resolved inside `resolveExtends()` (line 290). It is cleared after merge (line 320). It is NOT processed by `resolveRelativePaths`. This is unaffected by the fix.

## Acceptance Criteria

1. `TestLoadStack_Extends_CrossDirectory_LocalSource` passes: inherited `source.path` resolves to the parent's directory
2. All existing `TestLoadStack_Extends_*` tests continue to pass unchanged
3. The full test suite (`go test ./pkg/config/...`) passes
4. `go build ./...` succeeds with no new warnings

## References

- Bug investigation: `prompts/gridctl/extends-relative-path-resolution/bug-evaluation.md`
- PR #388: stack composition via extends field (introduces the bug)
- `pkg/config/loader.go:276–322` — `resolveExtends` function
- `pkg/config/loader.go:221–246` — `resolveRelativePaths` function
