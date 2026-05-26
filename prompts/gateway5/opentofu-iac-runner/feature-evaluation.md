# Feature Evaluation: OpenTofu / IaC First-Class Runner

**Date**: 2026-05-26
**Project**: gateway5 (`iagctl`)
**Recommendation**: **Build** (phased, with two caveats)
**Value**: High
**Effort**: Large (initiative); Small–Medium per phase

## Summary

Gateway5's current OpenTofu support is a thin, blind `tofu apply/destroy` shell-out with no `plan`, no managed state, no version management, and no provider caching — not credible as an "IaC runner." This evaluation recommends **building** a first-class, gated plan→apply OpenTofu runner, executed in five sequenced phases. The decisive finding: the Gateway5 team has **already designed and built the hard machinery** this needs — the streaming `RunTask` run-lifecycle (async output, persisted runs, cancellation, GC, crash recovery, sandboxing) — and the developer docs explicitly name OpenTofu as the intended consumer of it via `LocalCommandSpec` + `GitClone` over the new `services/call` taxonomy. The initiative is largely *moving IaC onto the modern path the codebase already heads toward* plus adding IaC-specific layers, not rebuilding the core. Market research validates every major architectural choice (outbound agent, control-plane-mediated webhooks, OpenTofu-first), and a licensing tailwind (running OpenTofu/MPL avoids HashiCorp's BUSL) makes the strategy defensible.

## The Idea

Make Gateway5 (`iagctl`) a first-class runner/executor for OpenTofu + Infrastructure-as-Code, matching the industry pattern for IaC runners (HCP Terraform Agents / Spacelift workers / Atlantis), while reusing the customer's existing IaC code unchanged. Six goals from the originating context (`gw-context.md`):

1. First-class OpenTofu/IaC runner
2. Rip-and-replace the existing OpenTofu functionality
3. Native remote state backend support pointing to **customer-owned** S3 or MinIO
4. Native/basic inbound webhooks so git events trigger a `plan`
5. Binary version management (harvesting OpenTofu-relevant parts of the `version-manager` / `tenv` clone)
6. Provider caching

**Constraints:** scalable for the broader IaC roadmap; must **not** require customers to rewrite their IaC files; must fit existing industry runner patterns.

**Who benefits:** Itential customers automating infrastructure (broad+deep within the IaC segment), especially those running private/air-gapped infrastructure that the outbound edge-agent model reaches without inbound firewall changes; and Itential strategically (an OpenSource-IaC-engine position with no IBM/BSL entanglement).

## Project Context

### Current State

The current OpenTofu implementation is a **145-line shell-out** (`internal/opentofu/opentofu.go`): write inbound state to `terraform.tfstate` → `tofu init` → `tofu apply|destroy -auto-approve -no-color` → read state back → return it as a `structpb.Struct` over gRPC.

- **No `plan` action.** The `OpenTofuActions` enum is `{apply, destroy}` (`api/core/v1/opentofu.proto:32`). The CLI exposes only `apply`/`destroy` (`internal/cli/opentofu.go`). The IAP Automation Studio node offers only Apply/Destroy (`RunGatewayService.jsx:339`).
- **Blind auto-apply.** The diff OpenTofu computes is buried in the post-hoc stdout dump; the operator never reviews what *will* change before it happens.
- **`tofu` binary comes from `$PATH`** (or an operator-set `ExecutableObject` path). No download/pin/cache. It is installed only in the container images (`build/Containerfile` pins 1.11.6), **not** in the deb/rpm packages.
- **State is an in-band gRPC blob** — though `backend_config` and `state_file` proto fields already exist and are plumbed end-to-end.
- **Two parallel execution paths exist.** OpenTofu rides the **legacy synchronous `RunService`** RPC (no run state, no streaming, no lifecycle). The modern **`RunTask`** streaming RPC has the full lifecycle but its spec `oneof` has no IaC type yet.
- **The gateway is outbound-only.** It dials home to IAP's Gateway Manager over an mTLS WebSocket (JSON-RPC 2.0). **No inbound HTTP server exists in production** (`iagws` is a dev-only stand-in).

### Integration Surface

**Files the rip-and-replace touches directly (the OpenTofu-specific surface, ~900 LOC):**
- `internal/opentofu/opentofu.go` — the `tofu` exec wrapper
- `internal/runner/opentofu.go` — runner-side orchestration
- `internal/rpc/opentofu.go` — CRUD + run RPC business logic (heavy legacy `pkg/errors` use)
- `internal/cli/opentofu.go` + `internal/cli/md/opentofu/*.md` — CLI + help
- `api/core/v1/opentofu.proto` (+ generated `.pb.go`) — `OpenTofuPlan`, `OpenTofuActions`

**Shared files that need edits (the real blast radius, ~12 files):**
- `internal/handler/handler.go` (gRPC method wrappers + the `FeaturesOpenTofuEnabled` gates, lines 161–233)
- `internal/runner/handler.go` (the `RunService` dispatch switch; also home of the `RunTask` path)
- `internal/connect/run.go` + `describe.go` + `jsonrpc.go` (JSON-RPC routing from Gateway Manager)
- `internal/dsl/services.go`, `dsl.go`, `export.go`, `comparison.go` (DSL import/export/diff)
- `internal/cli/services.go`, `actions.go`, `import-export.go` (service registration/list/describe)
- `internal/prefixes/prefixes.go` (store key `opentofu-plan`)
- `internal/config/appconfig.go` (`FeaturesOpenTofuEnabled` + defaults/env bindings)
- `api/runner/v1/legacy.proto` (`RunnerOpenTofuPlanRequest`, oneof) + `api/runner/v1/specs.proto` (new IaC spec)
- `internal/metrics/resources.go`, `internal/iagdb/proto.go`, `internal/store/local.go` (metrics, DB inspect, store migration)

**IAP side (spans the gateway5, app-gateway_manager, and app-automation_studio repos):**
- **`app-gateway_manager`** (`@itential/app-gateway_manager`, Node/TS pronghorn app — the gateway5 control plane, cloned at `platform/app-gateway_manager`). Verified integration points:
  - `helpers/handlers.js` — the mTLS WebSocket server gateway5 dials into (`requestCert: true`, `x-itential-websocket-clientcert` validation, `GetClusterInfo` handshake, one-connection-per-cluster, `global.connectedGateways`).
  - `helpers/serviceManagement.js:128` (`case 'opentofu-plan'`) — where the action is validated as apply/destroy-only today; the exact spot to add `plan` + carry a `plan_id` through the `RunService` payload/response.
  - `helpers/workers.js` (per-cluster BullMQ queue) + `helpers/requests.js` (`makeRequestAndWait`, `writeMethods`/readonly enforcement) — the dispatch/correlation path a webhook-triggered run reuses.
  - `helpers/discover.js` (`GetServices`) + `api/Services.js` (`/gateway_manager/v1/services`) — the service registry and REST surface.
  - `src/Views/Gateways/Details/Services/index.tsx` — the OpenTofu service UI in the Gateway Manager dashboard.
  - Note: `runCode`/`httpRequest` already use `tasks/call`, proving the modern taxonomy works through this stack; services still ride legacy `RunService`.
- `iap/services/app-automation_studio/.../RunGatewayService/RunGatewayService.jsx` (the workflow node; add `Plan` action + `plan_id`/`diff` outputs).
- (Not to be confused with `iap/services/app-ag_manager` — that is the **legacy IAG 2.x** manager: REST-adapter discovery into a Redis pronghorn model, unrelated to the gateway5 WebSocket path.)

### Reusable Components

| Component | File | Reuse |
|-----------|------|-------|
| Modern run lifecycle (streaming, persistence, cancel, GC, crash recovery, sandbox) | `internal/runner/handler.go` (`RunTask`), `internal/runner/task/`, `internal/runner/executor/` | The intended home for IaC; add an executor/spec and inherit all of it |
| Git clone + auth + ref resolution | `internal/repository/repository.go` | Reuse as-is (satisfies "don't rewrite customer IaC") — also exposed as the `GitClone` setup step in `LocalCommandSpec` |
| Command exec wrapper (working-dir, env, ctx-cancel, redaction) | `internal/command/command.go` | Reuse |
| Secrets encrypt/decrypt | `internal/secrets/`, `decryptSecretEnvVars` | Reuse for backend creds (S3/MinIO) and provider/registry auth |
| Binary install/verify/store-metadata pattern | `internal/netsdk/pexmgr/installer.go` (+ `manager.go`) | **Template** for tofu version management (atomic write, SHA256 dedup, store-backed metadata) |
| Content-addressed cache + retention pruner | `internal/venv/pruner.go` (`VenvMode` CACHED) | **Template** for provider cache + workspace reuse |
| Store abstraction (BoltDB/etcd/DynamoDB, distributed lease) | `internal/store/`, `internal/prefixes/` | Persist cluster-visible run records + saved plans |
| Feature gating (config-flag pattern) | `internal/config/appconfig.go` (`features.*_enabled`) | Gate each phase off-by-default (MCP precedent) |

### tenv (`version-manager/`) Harvest Assessment

`version-manager/` is an **Apache-2.0 clone of `tofuutils/tenv`** (module `github.com/tofuutils/tenv/v4`). It cleanly solves **goal #5** (binary version management): version discovery/resolve from `required_version`/`.opentofu-version` constraints, download/install with **direct/GitHub-API/mirror** modes (mirror matters for air-gap), and **signature verification** (SHA256 pure-Go; cosign shells out to a `cosign` binary, PGP via `ProtonMail/gopenpgp` — gateway5 already vendors `ProtonMail/go-crypto`). Integrate via the documented `tenvlib` library API (`versionmanager/tenvlib/lib.go`, `TENV_AS_LIB.md`) rather than copy-extracting. Caveat: `tenvlib` pulls transitive weight (a `charmbracelet` TUI tree used only by tenv's own CLI; audit `go mod vendor` output). tenv contributes **nothing** to goals #3, #4, #6 — those are net-new.

## Market Analysis

### Competitive Landscape

Benchmarked against HCP Terraform (Cloud/Enterprise), Spacelift, Scalr, env0, Atlantis, Terrateam, Digger.

- **Run lifecycle:** Universally a two-phase, control-plane-tracked state machine — **plan is always separate from apply**, the reviewed plan is persisted, and apply consumes that saved plan (not a re-plan). Gated apply via UI buttons (HCP "Confirm & Apply"/"Discard"; Spacelift "unconfirmed") or PR comment (`atlantis apply`).
- **Agent architecture:** Every serious self-hosted runner is **outbound-only**. Gateway5's outbound mTLS WebSocket maps almost exactly to Spacelift's MQTT push model. **Atlantis is the lone inbound design** and pays for it with a mandatory public endpoint.
- **Webhooks:** The git webhook **terminates at the control plane, never at the agent**; the control plane creates the run and pushes it down the agent's already-open outbound channel. (This contradicts goal #4 as literally written — see Recommendation.)
- **State:** A spectrum from SaaS-hosted (HCP, Scalr) to strictly BYO-backend (Atlantis, Digger, Terrateam) to E2E-encrypted-but-orchestrated (Spacelift). For an edge agent, the defensible posture is **state stays in the customer environment; the control plane never holds credentials or decrypts state**.
- **Version + provider mgmt:** Per-workspace version pin resolved from a constraint, downloaded+verified on demand; provider caching via `TF_PLUGIN_CACHE_DIR` or (more robustly for concurrency) a read-only `filesystem_mirror`.

### Market Positioning

**Catch up + a real differentiator.** Gated plan/apply, managed remote state, and version pinning are pure table-stakes — having them makes Gateway5 *credible*. The differentiated angle is the bundle: **"OpenTofu-first, Terraform-compatible, no IBM/BSL entanglement, on an agent already inside your network,"** plus OpenTofu-specific features (native state encryption, OCI provider mirrors for air-gap). The self-hosted edge agent — which Gateway5 already has — is a deployment-model table-stake competitors charge enterprise tiers for.

### Ecosystem Support

- **Drive tofu** with `hashicorp/terraform-exec` (tfexec) + `hashicorp/terraform-json` (both MPL-2.0, mature). `Plan(-out)` → `ShowPlanFile` (`show -json`) → `Apply(savedplan)` gives the machine-readable diff and the gated, saved-plan apply. Gotcha: point tfexec at the *real unwrapped* `tofu` binary (version-string parsing breaks on wrapper scripts); pin tfexec↔tofu and smoke-test. Avoid `opentofu/tofu-exec` (explicitly not production-ready).
- **Version mgmt:** `tenvlib` (Apache-2.0) or the `pexmgr` pattern + OpenTofu standalone installer; `hashicorp/go-version` + `hashicorp/hcl/v2` for constraint resolution.
- **Remote state:** **OpenTofu's native S3 backend already supports MinIO** (`endpoints`, `use_path_style`, `skip_*`, and `use_lockfile=true` for locking without DynamoDB). The runner only generates the backend block + injects credentials — it does **not** implement S3. Add `aws-sdk-go-v2/service/s3` only if the runner independently inspects buckets.
- **Provider caching:** prefer a pre-populated read-only `filesystem_mirror` (sidesteps the documented `TF_PLUGIN_CACHE_DIR` concurrency races); OpenTofu 1.10 `oci_mirror` is the air-gap differentiator.
- **Webhooks:** stdlib `net/http` (Go 1.22+ ServeMux; gateway is on 1.24.9) or `chi`; verify/parse with `go-playground/webhooks` / `google/go-github` / `gitlab-org/api/client-go` (note `xanzy/go-gitlab` is archived).

### Demand Signals

OpenTofu momentum is real: ~300% YoY growth, CNCF acceptance (Apr 2025), Linux Foundation governance, large reference migrations. The HashiCorp→IBM acquisition is an active tailwind for enterprises wary of BSL. Every modern competitor already supports OpenTofu first-class, so OpenTofu-first is table-stakes among modern platforms — its value here is primarily **licensing freedom** (embedding the MPL `tofu` binary in a commercial product is unrestricted; embedding BUSL Terraform is not).

## User Experience

### Interaction Model

Gated plan→apply is a **net UX win** — it converts today's irreversible blind-apply surprise into a reviewed decision. Three surfaces:

- **`iagctl` CLI:** Add `plan` beside `apply`/`destroy` in `opentofuRunCommand`, reusing every existing flag. Model the saved plan as `--plan @file | <plan-id>`, mirroring the established `--state` convention (zero new mental model). Gate `apply` by default; `--auto-approve` is the explicit escape hatch. **Biggest gap: no saved-plan listing** — add `get plans` / `describe plan <id>`.
- **IAP Automation Studio:** A gate is inherently three tasks — Plan → manual approval → Apply. Frontend change is small/additive (add `Plan` to the action enum; emit `plan_id`/`diff`/`summary` outputs; reuse "Use as Variable" wiring + IAP's existing manual-approval task). The integration weight lives in **`app-gateway_manager`** — specifically extending the `opentofu-plan` action handling in `helpers/serviceManagement.js` to allow `plan` and correlate a `plan_id` through the `RunService` payload/response, plus the Gateway Manager dashboard service view.
- **Run visibility:** the activity model (`cluster/activity`) has no bucket for a "planned, awaiting apply" run; needs a plan store + a new lifecycle glyph.

### Workflow Impact

Adds a deliberate review step (two CLI commands / three workflow tasks). This is the *right* friction and is the category norm. `--auto-approve` preserves the low-stakes/scripted path and back-compat.

### UX Recommendations

- Lead with the `add/change/destroy` summary; adopt the concise-diff (hide-unchanged-with-counts) model; keep `+`/`~`/`-`/`-/+` glyphs so meaning survives `NO_COLOR` and screen readers (WCAG 1.4.1).
- **Bind the apply to the exact reviewed plan** (content/commit hash); refuse stale applies (the Atlantis #1122 bug class). Make saved plans single-use + expiring with clear, actionable error classes (not found / expired / consumed / drift-detected).
- **Serialize state-changing runs per workspace/target**; surface queued/blocked reasons; provide cancel + discard.
- Stream output; support `--json`; never lose the full plan as an artifact.

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Significant | Today's blind-apply shell-out isn't a credible IaC runner; this is an explicit product-roadmap direction |
| User impact | Broad + Deep (IaC segment) | Gated plan/apply + managed state + private-edge reach is meaningful for any infra-automation customer |
| Strategic alignment | Core mission | Gateway already absorbed Torero as the execution edge; OpenTofu-first removes a legal dependency on a competitor |
| Market positioning | Catch up + differentiator | Reaches table-stakes parity; differentiated by edge-agent + OpenTofu/no-BSL + air-gap (OCI mirrors, state encryption) |

### Cost Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Moderate→Significant | The hard `RunTask` lifecycle already exists and is the documented intended home for IaC; but rip-and-replace touches ~12 shared files, protos (wire-compat), DSL, store prefixes, 3 codebases |
| Effort estimate | Large (initiative) | Phase 0 Medium–Large; state/version/cache Small–Medium each; IAP webhook/UX Medium + cross-team |
| Risk level | Medium | OpenTofu owns the S3/provider protocols (we generate config); state stays in customer backend (no data-loss path if done right). Risks: GatewayManager backend not in checkout, IAP run-contract change for `plan_id`, proto wire-compat, tfexec↔tofu drift, stale-plan safety |
| Maintenance burden | Moderate | New deps (tfexec, terraform-json, tenv, s3 SDK, webhook libs); tofu/tfexec version-pair smoke test; provider-cache concurrency; migrate 114 legacy `pkg/errors` sites as touched |

## Recommendation

**Build**, in five sequenced phases, each gated off-by-default behind a config flag (per the existing `features.*_enabled` pattern; MCP is the dark-launch precedent).

The architecture is genuinely well-positioned — the team already designed this exact migration (`RunTask` + `LocalCommandSpec` + `services/call`) and built the run-lifecycle machinery; OpenTofu just hasn't moved onto it. The licensing/strategy case is strong, the market validates every design choice, and OpenTofu doing the protocol heavy-lifting makes goals #3 and #6 far cheaper than they sound.

**Build sequence:**

| Phase | Goal(s) | Scope | Size |
|-------|---------|-------|------|
| 0 — Foundation | #1 + #2 | Migrate OpenTofu off `RunService` onto `RunTask` (`LocalCommandSpec`+`GitClone`); drive tofu via `terraform-exec`; add real `plan` → saved, content-bound, machine-readable plan; gated `apply` consumes it; persist run records; CLI `plan` + `get/describe plans`. Rip-and-replace *is* this migration. | Medium–Large |
| 1 — Version mgmt | #5 | Provision/pin/verify `tofu` per run via `tenvlib` (Apache-2.0) or the `pexmgr` pattern; resolve `required_version`. | Medium |
| 2 — Remote state | #3 | Generate `backend "s3"` (MinIO via `endpoints`+`use_path_style`+`use_lockfile`); inject creds via existing secrets path; stop in-band state round-trip. | Small–Medium |
| 3 — Provider cache | #6 | Pre-populated read-only `filesystem_mirror` (dodges plugin-cache races); optional OCI mirror for air-gap. | Small–Medium |
| 4 — Webhook trigger | #4 | **Control-plane-mediated**: a git event hits a new inbound route in `app-gateway_manager`, which creates a run and pushes it down the existing per-cluster BullMQ→WebSocket channel to gateway5 (via `RunService`/`services/call` with a `plan` action). No inbound ingress on the gateway. | Medium (cross-repo) |

**Caveat 1 — Cross-repo coordination (now scoped, not blocked):** Phases 0–3 are largely self-contained in `gateway5` and deliver early, shippable value. Phase 4 and the full IAP gated-flow UX land in **`app-gateway_manager`** (control plane: `helpers/serviceManagement.js`, `helpers/workers.js`, a new webhook route) and **`app-automation_studio`** (the workflow node). With both repos now available, this is concrete coordinated work across three repos rather than an unknown — but it is still cross-team and must be sequenced with the IAP/Gateway-Manager owners.

**Caveat 2 — Wire-compat & migration:** Proto changes (adding `plan`, `plan_id`, dropping in-band state) and the store-key migration for existing `opentofu-plan` records must pass `make proto-check` and preserve back-compat during transition. The `RunService` JSON-RPC contract (`helpers/serviceManagement.js`) and gateway5's `connect-methods.md` both confirm `RunService` and the newer `services/call`/`tasks/call` taxonomy coexist — add `plan` additively and migrate gradually.

**What would change this to "Skip/Defer":** If the `app-gateway_manager`/IAP work cannot be coordinated on a compatible timeline, the IAP-facing value (Phase 4, full gated UX in workflows) stalls — but the gateway-side foundation (Phases 0–3, usable via `iagctl` and the existing `RunService` action path) still stands alone and is worth building.

## References

- HCP Terraform run states / agents: https://developer.hashicorp.com/terraform/cloud-docs/workspaces/run/states · https://developer.hashicorp.com/terraform/cloud-docs/agents/requirements
- Spacelift worker pools / run lifecycle / version mgmt: https://docs.spacelift.io/concepts/worker-pools · https://docs.spacelift.io/concepts/run · https://docs.spacelift.io/vendors/terraform/version-management
- Atlantis (inbound-webhook counter-example, locking, stale-plan bug): https://www.runatlantis.io/docs/locking · https://github.com/runatlantis/atlantis/issues/1122
- Scalr / env0 self-hosted outbound agents: https://scalr.com/blog/self-hosted-agents · https://docs.env0.com/docs/self-hosted-kubernetes-agent · https://www.env0.com/blog/announcing-self-hosted-remote-state-and-remote-apply
- OpenTofu S3 backend (MinIO endpoints, use_lockfile): https://opentofu.org/docs/language/settings/backends/s3/
- OpenTofu provider mirrors / OCI / CLI config: https://opentofu.org/docs/cli/config/config-file/ · https://opentofu.org/docs/cli/oci_registries/provider-mirror/ · https://opentofu.org/docs/v1.10/intro/whats-new/
- terraform-exec / terraform-json (MPL-2.0): https://github.com/hashicorp/terraform-exec · https://github.com/hashicorp/terraform-json
- tenv / tenvlib (Apache-2.0): https://github.com/tofuutils/tenv · https://github.com/tofuutils/tenv/blob/main/TENV_AS_LIB.md
- Terraform concise diff format / apply saved plan: https://www.hashicorp.com/en/blog/terraform-0-14-adds-a-new-concise-diff-format-to-terraform-plans · https://developer.hashicorp.com/terraform/cli/commands/apply
- HashiCorp BUSL license FAQ ("competitive offering"/"embedded"): https://www.hashicorp.com/en/license-faq
- WCAG 1.4.1 Use of Color: https://www.w3.org/WAI/WCAG21/Understanding/use-of-color.html
- Webhook libs: https://github.com/go-playground/webhooks · https://gitlab.com/gitlab-org/api/client-go
- OpenTofu adoption / GA: https://www.linuxfoundation.org/press/opentofu-announces-general-availability · https://www.cncf.io/projects/opentofu/
- Internal — gateway5 control plane (IAP side): `platform/app-gateway_manager` (`helpers/handlers.js` WS server, `helpers/serviceManagement.js` runService/opentofu action, `helpers/workers.js` BullMQ, `api/Services.js`); legacy IAG manager: `iap/services/app-ag_manager`; gateway5 docs: `docs/developer/connect-methods.md`, `runner-task-execution.md`
