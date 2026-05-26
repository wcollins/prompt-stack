# Feature Implementation: OpenTofu / IaC First-Class Runner (Phased)

## Context

**Gateway5** (`iagctl`) is a Go CLI/server automation gateway wrapping the absorbed Torero framework, at `/Users/william/code/itential/icarus/platform/gateway5/`. It runs at a customer's edge and dials home to the **Gateway Manager** — the IAP-side control plane `@itential/app-gateway_manager` (Node/TS pronghorn app, at `/Users/william/code/itential/icarus/platform/app-gateway_manager/`) — over an **outbound mTLS WebSocket** speaking JSON-RPC 2.0. The Gateway Manager runs the WebSocket server (`helpers/handlers.js`), a per-cluster BullMQ job queue (`helpers/workers.js`), the `RunService`/`GetServices` dispatch (`helpers/serviceManagement.js`, `helpers/requests.js`), and the `/gateway_manager/v1/*` REST API. (Do not confuse with `iap/services/app-ag_manager`, the unrelated legacy IAG 2.x manager.) Companion binaries: `iagdb`, `iagws`.

Key architecture (verify in `docs/developer/code-organization.md` and `ARCHITECTURE.md`):
- **CLI-first** (`internal/cli/`, Cobra) → **gRPC** (`internal/rpc/`, `api/*/v1/`) → runner.
- Two execution paths in `internal/runner/`: the **legacy synchronous `RunService`** (where OpenTofu lives today — no run state, no streaming) and the **modern streaming `RunTask`** (async events, persisted runs, cancellation, GC, crash recovery, sandboxing, resource limits — but no IaC spec yet).
- Storage: `internal/store/` (BoltDB local / etcd / DynamoDB cloud), keyed via `internal/prefixes/`.
- Config: Viper, read into `GatewayConfig` fields only (never `viper.Get*` in business logic).
- Build/test: `make build`, `make unittest`, `make integration`, `make system`, `make proto`, `make proto-check`, `gofmt -w ./...`. Vendor is committed (`go mod tidy && go mod vendor` after dep changes). Every new `.go` file needs the 3-line Itential copyright header. New code uses `fmt.Errorf("...: %w", err)` — never `pkg/errors`.

Tech stack already present: `go-git/v5`, `aws-sdk-go-v2` (core/config/credentials, **not** service/s3), `grpc`, `cobra`, `bbolt`, `etcd`, `ProtonMail/go-crypto`. Go 1.24.9.

## Evaluation Context

Findings that shaped this prompt (full evaluation: `prompts/gateway5/opentofu-iac-runner/feature-evaluation.md`):

- **The codebase already designed this migration.** `docs/developer/runner-task-execution.md` and `docs/developer/connect-methods.md` explicitly state OpenTofu plans should move off `RunService` onto `RunTask` using `LocalCommandSpec` + `GitClone`, exposed via the new `services/call` JSON-RPC taxonomy. Build *toward* that design, not around it.
- **Market validates the architecture.** Every serious IaC runner (HCP Agents, Spacelift, Scalr, env0) is outbound-only; the git webhook **terminates at the control plane**, never the agent. Building an inbound webhook server on the gateway is the "Atlantis trap." Webhooks are therefore **control-plane-mediated** (Phase 4).
- **Gated plan→apply is the category-defining feature.** v1 must produce a saved, machine-readable, content-bound plan and a gated apply that consumes *that exact plan* (no blind re-plan; refuse stale applies — the Atlantis #1122 bug class).
- **The runner generates config; OpenTofu does the protocol work.** Remote state (Phase 2) is mostly emitting a `backend "s3"` block + injecting creds — OpenTofu's native S3 backend already supports MinIO. Do **not** implement S3.
- **Licensing:** run the **OpenTofu `tofu` binary (MPL-2.0)** — avoids HashiCorp BUSL entirely. tfexec/terraform-json/hcl/go-version are MPL-2.0 (file-level copyleft, safe to vendor unmodified); tenv is Apache-2.0.
- **Don't make customers rewrite IaC.** Reuse `internal/repository/repository.go` to clone arbitrary repos; their `.tf` files run unmodified.

## Feature Description

Replace Gateway5's blind `tofu apply/destroy` shell-out with a first-class, gated **plan → review → apply** OpenTofu runner that: runs on the modern `RunTask` streaming path; manages tofu binary versions; configures customer-owned S3/MinIO remote state; caches providers; and is triggerable by git events via the control plane. Customers' existing IaC code runs unchanged. Each capability ships behind an off-by-default feature flag.

## Requirements

### Functional Requirements

**Phase 0 — Foundation (goals #1, #2):**
1. Add an IaC execution path on `RunTask`: either a new `OpenTofuSpec`/`IacSpec` in `api/runner/v1/specs.proto` with a dedicated executor in `internal/runner/executor/`, **or** `LocalCommandSpec` + `GitClone` as the docs propose — choose per the "Selecting a Spec" guidance and `adding-features.md`. Inherit streaming output, persisted run records, cancellation, GC, and crash recovery.
2. Drive tofu via `hashicorp/terraform-exec`: `Init` → `Plan(-out=<file>)` → `ShowPlanFile` (`show -json`) → `Apply(<savedplan>)`.
3. Add a `plan` action (extend `OpenTofuActions`) that produces a **saved plan artifact** with: a `plan_id`, an `add/change/destroy` summary, the rendered diff, the machine-readable plan JSON, and binding to the source content/commit hash. Persist it (store-backed, cluster-visible) with an expiry; make it **single-use**.
4. Gated `apply` consumes a `--plan <id>` (or `@file`); it must **refuse** to apply if the plan is not-found / expired / already-consumed / stale (source changed since plan). `--auto-approve` is the only escape hatch for ungated apply.
5. Serialize state-changing runs per workspace/target (exclusive lock; queue the rest with a visible reason).
6. CLI: add `plan` subcommand under `opentofuRunCommand` reusing existing flags; add `get plans` / `describe plan <id>`; stream output; support `--json` and `NO_COLOR`.
7. Persist cluster-visible run records; surface a "planned, awaiting apply" state in `cluster/activity` and `iagctl inspect cluster activity` (new lifecycle glyph).

**Phase 1 — Binary version management (goal #5):**
8. Resolve the tofu version from `required_version` / `.opentofu-version` (and/or a workspace pin), download + verify (SHA256 + cosign/PGP), and pin per run. Integrate `tofuutils/tenv` via its `tenvlib` library API, **or** mirror the `internal/netsdk/pexmgr` install/verify/store-metadata pattern. Support an air-gap mirror source.

**Phase 2 — Remote state (goal #3):**
9. Generate/inject a `backend "s3"` configuration (or `-backend-config`) targeting customer-owned S3 **or MinIO** (`endpoints`, `use_path_style=true`, `skip_*`, `use_lockfile=true` for locking without DynamoDB). Inject backend credentials via the existing secrets path. Stop round-tripping state in-band through gRPC.

**Phase 3 — Provider caching (goal #6):**
10. Provide a pre-populated, read-only `filesystem_mirror` (via `tofu providers mirror`) keyed off the dependency lock file, shared safely across concurrent runs; optionally support `TF_PLUGIN_CACHE_DIR` per concurrency domain and OpenTofu 1.10 `oci_mirror`.

**Phase 4 — Webhook trigger (goal #4, control-plane-mediated):**
11. A git event (push/PR/comment) hits a **new inbound webhook route in `app-gateway_manager`** (the control plane already has the Express/pronghorn route surface, RBAC, the per-cluster BullMQ queue, and the WebSocket to the gateway). It verifies the webhook (HMAC/secret), maps the event to a configured `opentofu-plan` service, and dispatches a `plan` run down the **existing** per-cluster WebSocket via `RunService`/`services/call` (reusing `helpers/serviceManagement.js` + `helpers/workers.js`). On the gateway side, implement the `services/call` dispatch for IaC. **Do not** add an inbound HTTP server to the gateway5 binary — the gateway stays outbound-only.

### Non-Functional Requirements
- **Feature gating:** each phase behind an off-by-default `GatewayConfig` bool following the `features.*_enabled` pattern in `internal/config/appconfig.go` (field + `features.<name>_enabled` key + default + `GATEWAY_FEATURES_<NAME>_ENABLED` env binding), enforced at handler/CLI entry points like the existing OpenTofu gates (`internal/handler/handler.go:165+`). MCP (`features.mcp_enabled: false`) is the dark-launch precedent.
- **Wire-compat:** all proto changes must pass `make proto-check` vs devel; both legacy `RunService` and new paths coexist during transition.
- **Store migration:** preserve/upgrade existing `opentofu-plan` store records.
- **Licensing:** run only the OpenTofu `tofu` binary; vendor MPL/Apache deps unmodified; update NOTICE via `make licenses`.
- **Accessibility:** diff rendering pairs color with `+`/`~`/`-`/`-/+` glyphs + text counts (WCAG 1.4.1); lead with the summary; concise-diff (hide-unchanged-with-counts).
- **Safety:** never blind-apply by default; never re-plan on apply; never allow two concurrent applies on one state.

### Out of Scope
- An inbound webhook HTTP server **on the gateway5 binary** (rejected by evaluation; the webhook lands in `app-gateway_manager` instead).
- Re-architecting the Gateway Manager transport. The webhook + `plan` action are *additive* to `app-gateway_manager`'s existing `RunService`/WebSocket/BullMQ stack — do not rebuild it. Full Automation Studio gated-flow UI beyond the additive node change (`Plan` action + `plan_id`/`diff`/`summary` outputs) is coordinated with the IAP team.
- Policy-as-code, cost estimation, drift detection, state rollback UI — valuable later differentiators, not v1.
- Running the HashiCorp `terraform` binary (BUSL).

## Architecture Guidance

### Recommended Approach
Migrate IaC onto `RunTask` (the documented target). Add the executor in `internal/runner/executor/` behind the pluggable `Executor` interface + `selectExecutor`. Keep transport-agnostic business logic in `internal/rpc/`, reachable from CLI, gRPC, and JSON-RPC alike. Use `terraform-exec` for all tofu invocation; never parse stdout for plan data — use `show -json` / `terraform-json`. Persist saved plans + run records via the store (`internal/prefixes/`), not runner-local disk, so they're cluster-visible.

### Key Files to Understand
- `internal/runner/handler.go` — both execution paths; the `RunTask` lifecycle and `selectExecutor`.
- `internal/runner/executor/executor.go` — the `Executor` interface insertion point.
- `api/runner/v1/specs.proto` + `tasks.proto` — spec `oneof` and task lifecycle (where an IaC spec is added).
- `internal/opentofu/opentofu.go`, `internal/runner/opentofu.go`, `internal/rpc/opentofu.go` — the current implementation being replaced.
- `api/core/v1/opentofu.proto` — `OpenTofuActions` (add `plan`), `state_file`/`backend_config` (already present).
- `internal/repository/repository.go` — reuse for cloning customer IaC.
- `internal/netsdk/pexmgr/installer.go` + `internal/venv/pruner.go` — templates for binary version mgmt and provider/workspace caching.
- `internal/connect/run.go`, `docs/developer/connect-methods.md` — the legacy dispatch and the `services/call` target.
- `internal/config/appconfig.go` (lines ~124–128, 303–307, 427–431, 535–539) — the feature-flag pattern to copy.
- `internal/cli/opentofu.go`, `internal/cli/actions.go`, `internal/cli/inspect.go` — CLI command tree, `get/describe` wiring, activity rendering.

### Integration Points
- Extend `OpenTofuActions` and the dispatch switches in `internal/runner/handler.go` and `internal/connect/run.go`; add the `plan_id` correlation to the run contract.
- Add a saved-plan store prefix in `internal/prefixes/prefixes.go`.
- Add feature flags in `internal/config/appconfig.go`; gate handlers in `internal/handler/handler.go`.
- Update DSL (`internal/dsl/`) and metrics/`iagdb` references when the proto changes.
- **IAP side (`app-gateway_manager`):** extend the `case 'opentofu-plan'` block in `helpers/serviceManagement.js` to allow `plan` and thread a `plan_id` through the `RunService` payload/response; (Phase 4) add the webhook route reusing `helpers/workers.js`/`helpers/requests.js`. **Automation Studio:** add `Plan` + `plan_id`/`diff`/`summary` to `RunGatewayService.jsx`. Keep `RunService` and `services/call`/`tasks/call` coexisting (runCode/httpRequest already use `tasks/call`).

### Reusable Components
Git clone (`internal/repository`), command exec (`internal/command`), secrets (`internal/secrets`, `decryptSecretEnvVars`), store + distributed lease, the `RunTask` lifecycle, the `pexmgr` and `venv.Pruner` patterns, the `features.*_enabled` gating pattern.

## UX Specification

- **Discovery:** `iagctl run service opentofu-plan --help` lists `plan`/`apply`/`destroy`; `iagctl get plans` lists saved plans; update the help string at `internal/cli/opentofu.go` (currently hardcodes "apply or destroy").
- **Activation:** `... plan <svc> [--set k=v] [--var-file f] [--out @plan.bin]` → returns a `plan_id` + summary; `... apply <svc> --plan <plan-id>` (gated) or `--auto-approve` (ungated).
- **Interaction:** plan prints the `add/change/destroy` summary first, then the concise diff; operator reviews; apply consumes the saved plan.
- **Feedback:** stream log chunks live; echo which `plan_id` apply consumed; on completion show return code + outcome; `--json` emits structured plan/result.
- **Error states:** distinct, actionable messages for plan not-found / expired / consumed / drift-detected / target-locked (queue position) — not raw gRPC errors.
- **IAP node (additive):** add `Plan` to the OpenTofu action enum in `RunGatewayService.jsx`; emit `plan_id`/`diff`/`summary` as output variables; the gate is IAP's existing manual-approval task wired between Plan and Apply via "Use as Variable."

## Implementation Notes

### Conventions to Follow
- 3-line Itential copyright header on every new `.go` file (see `CONVENTIONS.md`).
- Errors: `fmt.Errorf("context: %w", err)`; never log-and-return; migrate touched `pkg/errors` sites to the new style.
- Config via `GatewayConfig` fields only.
- `gofmt -w ./...` before `make unittest`. Run `make proto` after any `.proto` change and commit generated output; run `make proto-check`. `go mod tidy && go mod vendor` after dep changes; `make licenses`.
- Follow the TestMain pattern (`CONVENTIONS.md`); `internal/runner/` and `internal/store/dynamodbtest` show the mocks to extend (e.g., for an S3-backed test).

### Potential Pitfalls
- tfexec version-string parsing breaks on wrapper scripts — point it at the *real* `tofu` binary; pin tfexec↔tofu and smoke-test the pair in CI.
- `TF_PLUGIN_CACHE_DIR` is only best-effort concurrency-safe — prefer the read-only `filesystem_mirror` for fan-out.
- `make proto-check` will fail on breaking wire changes — additive fields only; keep both paths during transition.
- Phase 4 + the gated-flow UX span three repos (`gateway5`, `app-gateway_manager`, `app-automation_studio`) — sequence with the IAP/Gateway-Manager owners. The `RunService` payload contract lives in `app-gateway_manager/helpers/serviceManagement.js`; match it exactly and extend additively.
- `app-ag_manager` ≠ `app-gateway_manager`. The former is the legacy IAG 2.x manager (REST-adapter discovery); all gateway5 control-plane work is in the latter.
- tenv's `tenvlib` pulls transitive TUI deps — audit `go mod vendor` weight; consider extracting only `tofuretriever` + `pkg/download` + `pkg/check/*` if weight is unacceptable.
- Don't leak state into gRPC responses once Phase 2 lands — state belongs in the customer backend.

### Suggested Build Order
Phase 0 → 1 → 2 → 3 → 4 (per the table above). Each phase is independently shippable behind its flag. Phases 0–3 are self-contained in gateway5; Phase 4 requires coordinated IAP work. Within Phase 0, land the proto + spec + executor first, then the saved-plan store + gating, then the CLI surface and activity rendering.

## Acceptance Criteria

1. OpenTofu runs execute on the `RunTask` streaming path with persisted, cluster-visible run records, live-streamed output, and working cancellation.
2. A `plan` action produces a saved, single-use, expiring, content-bound plan with a `plan_id`, `add/change/destroy` summary, rendered diff, and machine-readable JSON (from `show -json`).
3. `apply --plan <id>` applies exactly the reviewed plan; it refuses not-found / expired / consumed / stale plans with distinct, actionable errors; `apply` without `--plan` or `--auto-approve` errors rather than blind-applies.
4. Concurrent state-changing runs on the same workspace/target are serialized; queued runs report why.
5. The tofu binary version is resolved (from `required_version`/pin), downloaded, signature-verified, and pinned per run, with an air-gap mirror option.
6. Remote state targets customer-owned S3 **and** MinIO (verified against a MinIO test) using `use_lockfile`; state is never returned in-band; backend creds come from the secrets path.
7. Providers are served from a shared read-only mirror across concurrent runs without races.
8. A git event hits a webhook route in `app-gateway_manager`, which dispatches a `plan` run down the existing per-cluster WebSocket; no inbound HTTP server is added to the gateway5 binary.
9. Every phase is gated by an off-by-default `features.*_enabled` flag, enforced at entry points; existing OpenTofu behavior is unaffected when flags are off.
10. Customers' existing `.tf` files run unmodified.
11. `make proto-check`, `make unittest`, `make integration`, and `gofmt` all pass; generated proto + vendor + NOTICE are committed.
12. Diff rendering is accessible (glyphs + text counts, not color-only; honors `NO_COLOR`).

## References

- terraform-exec / terraform-json (MPL-2.0): https://github.com/hashicorp/terraform-exec · https://github.com/hashicorp/terraform-json
- tenv / tenvlib (Apache-2.0): https://github.com/tofuutils/tenv/blob/main/TENV_AS_LIB.md
- OpenTofu S3 backend (MinIO, use_lockfile): https://opentofu.org/docs/language/settings/backends/s3/
- OpenTofu provider mirrors / CLI config / OCI: https://opentofu.org/docs/cli/config/config-file/ · https://opentofu.org/docs/cli/oci_registries/provider-mirror/
- Terraform saved-plan apply / concise diff: https://developer.hashicorp.com/terraform/cli/commands/apply · https://www.hashicorp.com/en/blog/terraform-0-14-adds-a-new-concise-diff-format-to-terraform-plans
- HCP Terraform run states / agents (outbound): https://developer.hashicorp.com/terraform/cloud-docs/workspaces/run/states · https://developer.hashicorp.com/terraform/cloud-docs/agents/requirements
- Spacelift run lifecycle / approval policy: https://docs.spacelift.io/concepts/run · https://docs.spacelift.io/concepts/policy/approval-policy
- Atlantis stale-plan bug class: https://github.com/runatlantis/atlantis/issues/1122
- HashiCorp BUSL FAQ: https://www.hashicorp.com/en/license-faq
- WCAG 1.4.1 Use of Color: https://www.w3.org/WAI/WCAG21/Understanding/use-of-color.html
- Internal (gateway5): `docs/developer/runner-task-execution.md`, `docs/developer/connect-methods.md`, `docs/developer/adding-features.md`, `docs/developer/code-organization.md`, `CONVENTIONS.md`
- Internal (control plane, `platform/app-gateway_manager`): `helpers/handlers.js` (WS server + mTLS handshake), `helpers/serviceManagement.js` (`runService`, opentofu action), `helpers/workers.js` (BullMQ), `helpers/requests.js` (`makeRequestAndWait`), `helpers/discover.js` (`GetServices`), `api/Services.js` (`/gateway_manager/v1/services`)
