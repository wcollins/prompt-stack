# Feature Evaluation: Rename `deploy` to `apply`

**Date**: 2026-03-30
**Project**: gridctl
**Recommendation**: Build with caveats
**Value**: High
**Effort**: Small

## Summary

Rename the `gridctl deploy` command to `gridctl apply` to align with IaC ecosystem CLI conventions (Terraform, kubectl, OpenTofu). The project already uses IaC vocabulary throughout (`plan`, `validate`, `destroy`) and the internal codebase already uses "apply" language in comments and prompts — making `deploy` the semantic outlier. The rename is largely mechanical with one critical implementation constraint (hardcoded daemon spawn string), and should include a `deploy` alias with deprecation notice for backward compatibility.

## The Idea

**Feature**: Rename the primary `gridctl deploy <stack.yaml>` command to `gridctl apply <stack.yaml>`.

**Problem**: The word `deploy` creates a mental mismatch for the target audience of infrastructure practitioners. `deploy` implies a one-way imperative push ("ship it"). `apply` implies "reconcile desired state against actual state" — which is exactly what gridctl does when used with `plan`. The IaC ecosystem has strongly converged on `apply` as the canonical verb for this operation (Terraform, kubectl, OpenTofu, Crossplane), and not using it signals against the project's IaC positioning.

**Who benefits**: All users, particularly those coming from Terraform or Kubernetes backgrounds who would immediately recognize the `validate → plan → apply → destroy` lifecycle pattern.

## Project Context

### Current State

gridctl is a CLI tool for managing MCP (Model Context Protocol) server stacks declaratively. It uses a YAML-based stack file and provides a full lifecycle management workflow that closely mirrors Terraform's model:

- `validate` — schema and lint checks
- `plan` — diff desired spec against current running state
- `deploy` — start/reconcile the stack (the target of this rename)
- `destroy` — teardown

The project uses Cobra for CLI command management. The internal `StackController.Deploy()` method orchestrates the full lifecycle including daemon management, Docker networking, container startup, and state persistence.

### Current "Apply" Language in the Codebase

The codebase already uses "apply" semantics internally — making the naming gap even more apparent:

- `plan.go:76`: Prompt text is `"Apply these changes? [y/N] "` (not "Deploy these changes?")
- `plan.go:87`: Comment reads `"Apply via deploy with Replace to handle running stacks"`
- `plan.go:87-88`: Log output says `"Applying changes..."`
- `controller.go:59`: Config field comment: `"Stop a running stack before deploying (used by plan apply)"`
- `CHANGELOG.md`: Multiple entries reference "plan apply" as the conceptual operation

### Integration Surface

The rename touches these files:

| File | Type of change |
|------|----------------|
| `cmd/gridctl/deploy.go` | Primary: rename command, variables, flags, help text |
| `cmd/gridctl/root.go` | Command registration (add alias, update `AddCommand`) |
| `pkg/controller/daemon.go:44` | **CRITICAL**: hardcoded `"deploy"` string for daemon child spawn |
| `cmd/gridctl/plan.go` | Update help text reference to `deploy` |
| `README.md` | 10+ examples using `gridctl deploy` |
| `CHANGELOG.md` | Add deprecation/rename entry |
| `examples/` directory | Update commented example commands |

### Reusable Components

- Cobra's `Aliases` field handles backward-compatible aliasing with zero custom code
- The internal `ctrl.Deploy()` method name does NOT need to change — it's an unexported internal method
- All flag logic, flag variables, and controller config fields can remain as-is or be renamed mechanically

## Market Analysis

### Competitive Landscape

| Tool | Command | State model | Notes |
|------|---------|-------------|-------|
| Terraform | `terraform apply` | Full resource graph in `.tfstate` | Canonical IaC apply semantics |
| kubectl | `kubectl apply -f` | Server-side (Kubernetes API) | Lightweight state, closest analogue to gridctl |
| OpenTofu | `tofu apply` | Same as Terraform | Direct fork |
| Crossplane | `kubectl apply` | Kubernetes CRDs | Uses kubectl apply directly |
| Pulumi | `pulumi up` | Pulumi state backend | Deliberately chose `up` over `apply` for broader audience |
| Helm | `helm upgrade --install` | Kubernetes Secrets | Older conventions, not an `apply`-pattern tool |
| AWS CDK | `cdk deploy` | CloudFormation | Uses `deploy` but builds on a managed state system |
| FluxCD/ArgoCD | `sync` | Git-based | Different paradigm |

**Key insight**: AWS CDK uses `deploy` — but CDK delegates all state management to CloudFormation. When a tool handles its own state, `apply` is the expected verb. When a tool delegates to another system that handles state, `deploy` is more common. gridctl handles its own state, which tips toward `apply`.

### Market Positioning

`apply` is **table-stakes** for an IaC tool targeting infrastructure practitioners. It's not a differentiator — it's a qualifier. Tools that don't use it require users to unlearn the mental model. The `plan → apply` two-step is now the dominant IaC interaction pattern and is recognized immediately by the target audience.

### Ecosystem Support

No external libraries needed. This is a pure naming/convention change. Cobra's built-in alias support (`Aliases: []string{"deploy"}`) provides backward compatibility.

### Demand Signals

The two AI assistant responses provided by the user both recommend the rename. The internal codebase itself uses "apply" language in 4+ places while the command is named "deploy." The cognitive dissonance is real and currently present in the source code.

## User Experience

### Current Interaction Model

```bash
gridctl validate stack.yaml    # Check spec
gridctl plan stack.yaml        # Show diff (uses "Apply these changes?" prompt)
gridctl deploy stack.yaml      # Execute (naming breaks the IaC pattern)
gridctl destroy stack.yaml     # Teardown
```

### Post-Rename Interaction Model

```bash
gridctl validate stack.yaml    # Check spec
gridctl plan stack.yaml        # Show diff
gridctl apply stack.yaml       # Execute (IaC pattern complete)
gridctl destroy stack.yaml     # Teardown
```

This is immediately recognizable to any Terraform or kubectl user.

### Workflow Impact

**Positive**:
- IaC practitioners recognize the pattern instantly — zero onboarding friction for the most important user segment
- The `plan → apply` two-step is now self-documenting
- Documentation examples are cleaner and can reference Terraform familiarity

**Neutral/negative (mitigated)**:
- Breaking change for existing users/scripts: mitigated by keeping `deploy` as a Cobra alias with a deprecation warning
- Muscle memory for early adopters: minor, quickly resolved

### UX Recommendations

1. **Keep `deploy` as a Cobra alias** with a printed deprecation notice: `"Note: 'deploy' is deprecated and will be removed in a future version. Use 'apply' instead."` — print only when `deploy` alias is invoked
2. **Add `--auto-approve` flag**: For CI/CD and scripted use cases. This is the expected flag name from Terraform; `-y` (current `plan` flag) is idiosyncratic
3. **Update `plan` help text**: Change `"Use -y to auto-approve and apply changes via deploy"` to `"Use -y to auto-approve and apply changes"` (removing the now-redundant `via deploy`)
4. **Do NOT merge plan into apply** (out of scope for this change): Keep `plan` and `apply` as separate commands. The two-command flow is a feature, not a bug. Merging would be a separate, larger UX change.

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Significant | `deploy` is the only IaC-lifecycle command that breaks the Terraform/kubectl pattern; practitioners notice immediately |
| User impact | Broad + Deep | Every user sees this verb every time they use the tool |
| Strategic alignment | Core mission | gridctl is explicitly IaC for AI agent stacks; `apply` is the canonical IaC verb |
| Market positioning | Catch-up | Not using `apply` is now a signal against the project's positioning |

### Cost Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Moderate | One critical constraint: `daemon.go:44` hardcodes `"deploy"` for child process spawn |
| Effort estimate | Small | ~2-4 hours of focused work; mostly mechanical with one logic change |
| Risk level | Low | Daemon string is the only functional risk; alias preserves backward compatibility |
| Maintenance burden | Minimal | Alias removal in a future version; no ongoing cost |

## Recommendation

**Build with caveats.** The rename is clearly justified, low-risk, and high-signal. The internal codebase already uses "apply" semantics — fixing the external command name removes a cognitive gap that currently exists in the source code itself.

**Required caveats for implementation**:

1. **Update `daemon.go:44`**: Change the hardcoded `"deploy"` string to `"apply"` in the daemon child spawn args. This is the only functionally critical change. If using an alias approach, this still needs to change to match the primary command name (or the alias must also be tested as valid).

2. **Add Cobra alias with deprecation notice**: `Aliases: []string{"deploy"}` on the new `applyCmd`, plus a `PersistentPreRun` hook that prints a deprecation warning when the `deploy` alias is used.

3. **Add `--auto-approve` flag**: Rename the existing `-y` / `--yes` flag on `plan` (or add `--auto-approve` as an alias) for CI/CD consistency with ecosystem conventions.

4. **Do not merge plan into apply** (scope protection): Keep them as separate commands. Merging would be a valuable but separate feature that deserves its own evaluation.

**What gridctl's `apply` IS and IS NOT** (documentation note):
- IS: idempotent-by-intent config push with spec-vs-spec diff awareness (kubectl-style)
- IS NOT: full stateful resource graph reconciliation (Terraform-style) — gridctl tracks process state, not container-level resource IDs

This distinction should be documented clearly so that Terraform-fluent users don't arrive with wrong expectations about rollback, drift repair, or multi-user locking.

## References

- [Terraform apply documentation](https://developer.hashicorp.com/terraform/cli/commands/apply)
- [kubectl apply documentation](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_apply/)
- [Pulumi up documentation](https://www.pulumi.com/docs/reference/cli/pulumi_up/)
- [Cobra command aliases](https://pkg.go.dev/github.com/spf13/cobra#Command)
- [AWS CDK deploy](https://docs.aws.amazon.com/cdk/v2/guide/cli.html)
