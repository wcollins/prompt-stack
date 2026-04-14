# Feature Implementation: Stack Composition via `extends`

## Context

gridctl is a production-grade MCP (Model Context Protocol) orchestration platform
written in Go. It manages multiple MCP servers — containers, local processes, SSH
remotes, external URLs, and OpenAPI-backed services — through a unified gateway. Users
define infrastructure as code in YAML stack files and deploy with `gridctl apply stack.yaml`.

**Tech stack**: Go 1.22+, `gopkg.in/yaml.v3`, Cobra CLI, Docker SDK.

**Relevant architecture**:
```
cmd/gridctl/ (Cobra CLI commands)
    ↓
pkg/controller/ (lifecycle: deploy, destroy, reload)
    ↓
pkg/config/ (YAML parsing, validation, types)
    └── loader.go   ← primary implementation target
    └── types.go    ← Stack struct definition
    └── validate.go ← validation rules
    └── expand.go   ← variable expansion
    └── plan.go     ← diff computation
```

## Evaluation Context

- **Market insight**: Docker Compose's `extends` is the dominant mental model for this
  pattern. Users expect child-wins semantics with merge-by-key for named lists. Kustomize
  proved that tying merge logic to an external schema causes CRD failures — avoid it.
- **UX decision**: Merge MCPServers by `name` key (child overrides parent entry with same
  name; parent-only entries are appended). Top-level config blocks (Gateway, Network,
  Logging, Secrets) use child-wins-if-set semantics, not deep merge.
- **Risk mitigation**: `extends` is optional with no-op default — zero backward compat
  impact. Cycle detection prevents infinite loops.
- **Full evaluation**: `/Users/william/code/prompt-stack/prompts/gridctl/stack-composition-extends/feature-evaluation.md`

## Feature Description

Add an optional top-level `extends: <path>` field to gridctl stack YAML files. When
set, the loader reads the parent stack, deep-merges its servers into the child stack
(child wins on name collisions), then applies the child's gateway/network/secrets config
on top of the parent's. This eliminates copy-paste sprawl across multi-stack organizations.

**Example**:
```yaml
# base.yaml
version: "1"
name: base
gateway:
  auth:
    type: bearer
    token: ${GATEWAY_TOKEN}
mcp-servers:
  - name: auth-server
    url: https://auth.internal/mcp
  - name: logging
    image: myorg/mcp-logging:latest
    port: 8080

# dev.yaml
version: "1"
name: dev
extends: ./base.yaml
mcp-servers:
  - name: logging          # overrides parent's logging (same name → child wins)
    image: myorg/mcp-logging:dev
    port: 8080
  - name: github
    image: ghcr.io/github/mcp-server-github:latest
    port: 9000
```

Resolved `dev` stack: `auth-server` (from base) + `logging` (child override) + `github`
(child only). `gateway.auth` inherited from base since child doesn't define `gateway`.

## Requirements

### Functional Requirements

1. The `Stack` struct must include an optional `Extends` field (`yaml:"extends,omitempty"`)
2. When `extends` is set, `LoadStack` must resolve the path relative to the child file's
   directory (same convention as existing `source.path` and `ssh.identityFile`)
3. The parent stack must be loaded recursively, supporting multi-level inheritance
   (A extends B extends C). Cap recursion at 10 levels to prevent runaway chains.
4. Cycle detection: track the absolute path of each file in the chain; error immediately
   if the same path appears twice. Error message must show the full cycle.
5. **MCPServers merge semantics**: build a map of parent servers by `name`; for each
   child server with the same name, the child's definition replaces the parent's entirely
   (no field-level merge within a server). Parent-only servers are appended to the child's
   list in their original order.
6. **Resources merge semantics**: same as MCPServers — merge by name, child wins.
7. **Top-level block inheritance** (child-wins-if-set): for each of `Gateway`, `Logging`,
   `Secrets`, `Network`, `Networks` — if the child has a non-zero value, use it; otherwise
   inherit the parent's value.
8. `extends` must be resolved AFTER YAML unmarshal but BEFORE variable expansion, defaults,
   path resolution, and validation. This allows parent stacks to use `${VAR}` references
   that are expanded in the child's resolver context.
9. Validation must run on the fully merged stack (not on each file individually).
10. If the parent file does not exist, return a clear error: `extends: <path>: file not found`.

### Non-Functional Requirements

- The feature must not break any existing tests. All stacks without `extends` must behave identically.
- Circular reference detection must be O(n) in chain depth.
- Error messages must follow the existing `ValidationError{Field, Message}` pattern where applicable.
- The `extends` field itself should not appear in the merged/resolved stack (it is a loader directive, not runtime config).

### Out of Scope

- Per-server `extends` within a stack file
- Remote URLs for `extends` (file paths only)
- Merging `Gateway` at the sub-field level (entire block is child-wins or parent-inherited)
- A `!override` or `!remove` directive for removing parent servers from the child (can be added later)
- Any changes to the CLI interface, plan output formatting, or web UI

## Architecture Guidance

### Recommended Approach

Insert a `resolveExtends` function into `LoadStack` immediately after `yaml.Unmarshal`
and before the variable expansion step:

```go
func LoadStack(path string, opts ...LoadOption) (*Stack, error) {
    // ... existing unmarshal ...

    // NEW: resolve extends chain before expansion
    if err := resolveExtends(&stack, absPath, nil); err != nil {
        return nil, err
    }

    // ... existing expansion, defaults, path resolution, validation ...
}
```

`resolveExtends(child *Stack, childAbsPath string, visited map[string]bool) error`:
1. If `child.Extends == ""`, return nil (no-op for non-extending stacks)
2. Resolve `child.Extends` relative to `filepath.Dir(childAbsPath)`
3. Get absolute path; check `visited` map for cycles
4. Read and unmarshal the parent YAML into a `Stack`
5. Recurse: `resolveExtends(&parent, parentAbsPath, visited)`
6. Call `mergeStacks(child, &parent)` — mutates child in place
7. Clear `child.Extends` after merge (loader directive consumed)

`mergeStacks(child, parent *Stack)`:
- Merge MCPServers: build `map[string]MCPServer` from parent; for each child server with
  matching name, skip parent entry; append remaining parent servers after child's list
- Merge Resources: same algorithm
- Inherit top-level blocks from parent if child's value is zero:
  - `child.Gateway == nil → child.Gateway = parent.Gateway`
  - `child.Logging == nil → child.Logging = parent.Logging`
  - `child.Secrets == nil → child.Secrets = parent.Secrets`
  - `len(child.Networks) == 0 && child.Network.Name == "" → inherit parent's network config`

### Key Files to Understand

| File | Why |
|------|-----|
| `pkg/config/loader.go` | Full `LoadStack` pipeline — understand insertion point and data flow |
| `pkg/config/types.go` | `Stack` struct — add `Extends` field here, understand `MCPServer` and `Resource` types |
| `pkg/config/validate.go` | `ValidationError` / `ValidationErrors` pattern — follow for any new error messages |
| `pkg/config/loader_test.go` | Test patterns — `writeTempFile()` helper, table-driven tests |
| `pkg/config/expand.go` | Variable expansion — runs after `resolveExtends`, no changes needed |

### Integration Points

**`pkg/config/types.go`** — add one field to `Stack`:
```go
type Stack struct {
    Version    string          `yaml:"version"`
    Name       string          `yaml:"name"`
    Extends    string          `yaml:"extends,omitempty"`   // ← add this
    Gateway    *GatewayConfig  `yaml:"gateway,omitempty"`
    // ... rest unchanged
}
```

**`pkg/config/loader.go`** — add `resolveExtends` and `mergeStacks` functions; call
`resolveExtends` in `LoadStack` after `yaml.Unmarshal`, before `expandStackVars`.

**`pkg/config/loader_test.go`** — add test cases (see Acceptance Criteria).

No changes required to `validate.go`, `expand.go`, `plan.go`, or any cmd/ files.

### Reusable Components

- `expandTildeAndResolvePath(path, basePath string) string` — reuse for `extends` path resolution
- `writeTempFile(t, content)` test helper — use for creating parent/child test fixture files
- `ValidationErrors` type — use for cycle and missing-file errors if they surface through Validate

## UX Specification

**Discovery**: Users learn about `extends` through documentation and examples. The field
name is intentionally identical to Docker Compose to leverage existing mental models.

**Activation**: Add `extends: ./base.yaml` as the second line of any stack file (after
`version`). No flags, no commands, no configuration.

**Interaction**: transparent — `gridctl apply dev.yaml` behaves exactly as if the user
had written all servers in a single file. No special output during apply.

**Feedback**: On successful load, the resolved stack (including inherited servers) is
what gets deployed. No explicit merge confirmation is shown (consistent with how Docker
Compose handles this).

**Error states**:
- Parent file missing: `extends: reading parent stack: reading stack file: open ./base.yaml: no such file or directory`
- Circular dependency: `extends: circular dependency detected: dev.yaml → base.yaml → dev.yaml`
- Depth exceeded: `extends: maximum inheritance depth (10) exceeded`

## Implementation Notes

### Conventions to Follow

- All error messages use `fmt.Errorf("extends: %w", err)` wrapping for consistent prefix
- No new exported types — `resolveExtends` and `mergeStacks` are unexported package functions
- Tests use `writeTempFile(t, content)` helper already defined in `loader_test.go`
- `Stack.Extends` should be cleared to `""` after merge so it doesn't appear in the
  validated/deployed config (it's a loader directive, not a runtime field)
- Follow the existing `loadConfig` / `LoadOption` pattern — no new public API needed

### Potential Pitfalls

1. **Path resolution order**: resolve `extends` path relative to the *child* file's
   directory, not the working directory. Use `filepath.Dir(filepath.Abs(childPath))`.
2. **Visited set initialization**: create the `visited` map in `LoadStack` before the
   first call to `resolveExtends`, adding the child's absolute path to it first.
3. **Variable expansion timing**: parent YAML is merged BEFORE expansion. Do not call
   `expandStackVars` on the parent separately — the merged stack is expanded once in the
   main `LoadStack` pipeline.
4. **SetDefaults on merged stack**: `SetDefaults()` runs once on the final merged stack
   in the existing pipeline. Do not call it on the parent during `resolveExtends`.
5. **Network mode conflict**: if child uses `networks:` (advanced mode) and parent uses
   `network:` (simple mode), the child's mode wins per the child-wins rule. No error needed.

### Suggested Build Order

1. Add `Extends string` to `Stack` struct in `types.go`
2. Write `mergeStacks(child, parent *Stack)` function in `loader.go` with unit tests
3. Write `resolveExtends` function (path resolution + cycle detection + recursion)
4. Wire `resolveExtends` into `LoadStack`
5. Add integration tests covering extends scenarios (see Acceptance Criteria)
6. Verify all existing tests still pass

## Acceptance Criteria

1. A stack with `extends: ./base.yaml` loads all parent servers not named in the child
2. A child server with the same `name` as a parent server replaces the parent's definition
3. The child stack's `gateway`, `logging`, `secrets`, and `network` config is used when
   defined; parent values are used when child omits them
4. Multi-level inheritance works: A extends B extends C — servers resolved correctly
5. Circular dependency (`A extends B, B extends A`) returns an error containing "circular dependency"
6. Missing parent file returns an error containing the missing file path
7. A stack without `extends` behaves identically to current behavior (no regression)
8. The `extends` field is not present in the resolved stack passed to the gateway/controller
9. Variable references in parent stacks are expanded using the same resolver as the child
10. Depth limit: a chain of 11 files returns an error containing "maximum inheritance depth"

## References

- [Docker Compose extends](https://docs.docker.com/compose/how-tos/multiple-compose-files/extends/)
- [Docker Compose merge semantics](https://docs.docker.com/compose/how-tos/multiple-compose-files/merge/)
- [GitLab CI extends](https://docs.gitlab.com/ci/yaml/#extends)
- [Feature evaluation](./feature-evaluation.md)
