# Feature Implementation: Rename `deploy` to `apply`

## Context

gridctl is a Go CLI tool (using Cobra) for managing MCP (Model Context Protocol) server stacks declaratively. It uses a YAML-based stack file and provides a Terraform-inspired lifecycle:

```
validate → plan → deploy → destroy
```

The project is at `/Users/william/code/gridctl`. Key directories:
- `cmd/gridctl/` — CLI commands (one file per command)
- `pkg/controller/` — core orchestration logic
- `pkg/state/` — state persistence
- `pkg/config/` — stack config, validation, plan diff

The CLI framework is Cobra (`github.com/spf13/cobra`).

## Evaluation Context

- The internal codebase already uses "apply" language in 4+ places (`plan.go` prompts say "Apply these changes?", comments say "Apply via deploy with Replace") while the external command is named `deploy`. This rename removes an existing cognitive dissonance in the source code itself.
- Market research confirms `apply` is the canonical IaC verb for reconciling desired state. Not using it signals against the project's positioning as IaC for AI agent stacks.
- The closest model is `kubectl apply` (lightweight state, not full resource graph) — NOT `terraform apply` (which has heavier state expectations). This distinction matters for documentation.
- Full evaluation: `/Users/william/code/prompt-stack/prompts/gridctl/deploy-to-apply-rename/feature-evaluation.md`

## Feature Description

Hard-rename `gridctl deploy <stack.yaml>` to `gridctl apply <stack.yaml>`. No alias, no deprecation shim — `deploy` is removed entirely. Add `--auto-approve` as an alias for the plan command's `-y` flag.

This completes the IaC lifecycle pattern: `validate → plan → apply → destroy`.

## Requirements

### Functional Requirements

1. The command name changes from `deploy` to `apply`: `gridctl apply <stack.yaml>`
2. `gridctl deploy` is removed entirely — no alias, no backward compatibility shim
3. All flags currently on `deploy` are available on `apply` unchanged: `--verbose`, `--quiet`, `--no-cache`, `--port`, `--base-port`, `--foreground`, `--no-expand`, `--watch`, `--flash`, `--code-mode`, `--log-file`, `--daemon-child` (hidden)
4. The daemon child spawn in `pkg/controller/daemon.go` uses `"apply"` (not `"deploy"`)
5. The `plan` command's `-y` / `--yes` flag gains `--auto-approve` as an additional flag name for CI/CD ecosystem consistency
6. `gridctl --help` and `gridctl help` show `apply` as the command name
7. README.md, CHANGELOG.md, and all examples updated to use `apply`

### Non-Functional Requirements

- No behavior change: `apply` does exactly what `deploy` currently does
- No changes to internal method names (`ctrl.Deploy()`, `controller.Config`, etc.) — these are unexported implementation details

### Out of Scope

- Merging `plan` into `apply` (auto-showing diff before executing) — separate, larger UX change
- Changing the state model or adding container-level resource tracking
- Adding `--auto-approve` to the `apply` command itself (it belongs on `plan`, which is the confirm step)
- Any other command renames

## Architecture Guidance

### Key Files to Understand

| File | Why it matters |
|------|----------------|
| `cmd/gridctl/deploy.go` | Primary target: rename file, command struct, all variables, flags, help text |
| `cmd/gridctl/root.go` | Registration: update `rootCmd.AddCommand(deployCmd)` → `applyCmd` |
| `pkg/controller/daemon.go:44` | **CRITICAL**: hardcoded `"deploy"` string for daemon child process spawn — must become `"apply"` |
| `cmd/gridctl/plan.go` | Update help text (remove "via deploy" language), add `--auto-approve` flag |
| `README.md` | Documentation — ~10 examples using `gridctl deploy` |
| `CHANGELOG.md` | Add rename entry |

### Integration Points

**`cmd/gridctl/deploy.go`** → rename file to `apply.go`. Key changes:
- `var deployCmd = &cobra.Command{Use: "deploy"...}` → `var applyCmd = &cobra.Command{Use: "apply"...}` (no `Aliases` field)
- All `deployXXX` variable names → `applyXXX` (mechanical)
- `runDeploy()` → `runApply()` (mechanical)
- Update help text: replace all references to `deploy` with `apply`

**`pkg/controller/daemon.go:44`** — the single functional risk:
```go
// Before:
args := []string{"deploy", d.config.StackPath, "--daemon-child", ...}

// After:
args := []string{"apply", d.config.StackPath, "--daemon-child", ...}
```
This MUST be updated. The daemon fork spawns a child process by calling the binary with this command name. If left as `"deploy"`, daemon mode will fail to start since `deploy` no longer exists.

**`cmd/gridctl/plan.go`** — add `--auto-approve` flag alongside existing `-y`/`--yes`:
```go
var (
    planAutoApprove    bool
    planAutoApproveCI  bool
)

// In init():
planCmd.Flags().BoolVarP(&planAutoApprove, "yes", "y", false, "Auto-approve and apply changes")
planCmd.Flags().BoolVar(&planAutoApproveCI, "auto-approve", false, "Auto-approve and apply changes (CI/CD equivalent of -y)")

// In runPlan(), update the condition:
if !planAutoApprove && !planAutoApproveCI {
    // prompt user
}
```
Also update the Long help text to remove the phrase "via deploy".

**`cmd/gridctl/root.go`** — update command registration:
```go
// Before:
rootCmd.AddCommand(deployCmd)

// After:
rootCmd.AddCommand(applyCmd)
```

## UX Specification

**Discovery**: `--help` output shows `apply`. `deploy` is gone.

**Activation**:
```bash
gridctl apply stack.yaml              # Standard usage
gridctl apply stack.yaml --flash      # With auto-linking
gridctl apply stack.yaml --foreground # Foreground mode
```

**Interaction**: Identical to current `deploy` behavior. No behavioral change.

**Error states**: No new error states introduced.

## Implementation Notes

### Conventions to Follow

- Rename `deploy.go` → `apply.go`
- Rename all `deployXXX` vars to `applyXXX` for internal consistency
- Commit type: `feat: rename deploy command to apply`
- Internal method `ctrl.Deploy()` stays as-is — it's an unexported implementation detail

### Potential Pitfalls

1. **Daemon child invocation** (`daemon.go:44`): The most common mistake is updating the command name everywhere except here. If this string is not updated, daemon (background) mode will break entirely — the parent forks a child by calling `gridctl deploy --daemon-child`, which will fail with an unknown command error.

2. **Test references**: Search for any test files that construct expected daemon args with `"deploy"` — they will need updating. Check `pkg/controller/` for test files.

3. **Grep for remaining `"deploy"` strings**: After the mechanical rename, run a search for any remaining `"deploy"` string literals in Go files. The daemon string is the critical one, but there may be others in comments or error messages.

### Suggested Build Order

1. Rename `deploy.go` → `apply.go`. Update command struct, all variables, flags, help text, `runDeploy` → `runApply`
2. Update `root.go` registration
3. Update `daemon.go:44` — the critical string
4. Update `plan.go`: remove "via deploy" from help text, add `--auto-approve` flag
5. Update `README.md` and `CHANGELOG.md`
6. Update `examples/` directory
7. Verify: `go build ./...` passes; `gridctl apply --help` shows correct output; `gridctl deploy` returns an unknown command error
8. Run `/docs sync` to audit and sync all project documentation with the renamed command

## Acceptance Criteria

1. `gridctl apply stack.yaml` executes the stack deployment (identical behavior to former `deploy`)
2. `gridctl deploy stack.yaml` returns an unknown command error
3. `gridctl --help` shows `apply`; `deploy` does not appear
4. The daemon child process is spawned with `"apply"` — verify `daemon.go:44`
5. `gridctl plan stack.yaml --auto-approve` is equivalent to `gridctl plan stack.yaml -y`
6. `go build ./...` passes without errors
7. All README and example references use `gridctl apply`
8. CHANGELOG entry documents the rename as a breaking change
9. `/docs sync` has been run and all project documentation is consistent with the renamed command

## References

- [Terraform apply](https://developer.hashicorp.com/terraform/cli/commands/apply) — canonical reference for apply semantics
- [kubectl apply](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_apply/) — closest model to gridctl's state depth
- Full evaluation: `/Users/william/code/prompt-stack/prompts/gridctl/deploy-to-apply-rename/feature-evaluation.md`
