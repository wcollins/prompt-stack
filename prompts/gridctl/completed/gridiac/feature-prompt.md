# Feature Implementation: gridiac — Wedge MVP

## Pre-Flight (human-side setup)

> **Read this section before invoking this prompt with a coding agent.** The steps below establish the directory state and GitHub repos that the prompt assumes. They are explicitly *not* tasks for the coding agent — visibility, license, and org placement are user decisions, and `gh repo create` should not run unattended. Once these steps are complete, run the agent from `~/code/grid/` (the workspace root) for the initial Phase 0 scaffolding, then switch to single-repo Claude Code sessions for all subsequent feature work.

### 1. Create the empty repos on GitHub
```bash
gh repo create <org>/gridiac --private \
  --description "Spec-first agentic IaC platform (alpha)"
gh repo create <org>/grid-common --private \
  --description "Shared Go library for gridctl and gridiac"
```
Configure branch protection on `main` for both before the agent commits anything.

### 2. Lay out the workspace directory
```
~/code/grid/
├── CLAUDE.md           # workspace-level guidance (see below)
├── go.work             # local-only; gitignored in each repo
├── gridctl/            # move existing clone here
├── gridiac/            # fresh clone
└── grid-common/        # fresh clone
```
```bash
mkdir ~/code/grid
mv ~/code/gridctl ~/code/grid/
cd ~/code/grid
gh repo clone <org>/gridiac
gh repo clone <org>/grid-common
```

### 3. Add `go.work` at the workspace root
```go
go 1.26

use (
    ./gridctl
    ./gridiac
    ./grid-common
)
```

### 4. Gitignore `go.work` in all three repos
```bash
for r in gridctl gridiac grid-common; do
  echo 'go.work' >> "$r/.gitignore"
  echo 'go.work.sum' >> "$r/.gitignore"
done
```
Workspaces are local-dev only; CI and other consumers continue resolving modules through each repo's `go.mod`.

### 5. Add a workspace-level `CLAUDE.md`
Create `~/code/grid/CLAUDE.md`:
```markdown
# grid workspace

Multi-repo Go workspace for the spec-first orchestration portfolio.

- `gridctl/` — existing MCP gateway (beta). Read-only at MVP per gridiac's
  phased-extraction plan; do not modify.
- `gridiac/` — agentic IaC platform (alpha; current build target).
- `grid-common/` — shared Go library; populated by mirroring packages from
  gridctl. Each mirrored file carries a `// MIRROR: ...` comment.

Each subdirectory has its own AGENTS.md / CLAUDE.md with repo-specific
guidance. When working inside one repo, prefer running Claude Code from
that repo's directory directly. Cross-repo work (initial scaffolding,
the post-alpha gridctl refactor) is the only reason to run from the
workspace root.
```

### 6. Where to run Claude Code

| Mode | Command | When |
|---|---|---|
| Workspace root | `cd ~/code/grid && claude` | Phase 0 scaffolding (cross-repo mirroring); eventual post-alpha gridctl refactor. Use sparingly. |
| Single repo | `cd ~/code/grid/gridiac && claude` | All normal feature work. ~95% of sessions. |

Branch and PR skills (`/branch-trunk`, `/pr-trunk`) are repo-scoped — invoke them from inside one repo's directory, never from the workspace root.

### Pre-flight checklist
- [ ] `<org>/gridiac` repo created with branch protection on `main`
- [ ] `<org>/grid-common` repo created with branch protection on `main`
- [ ] `~/code/grid/` workspace directory exists with all three repos cloned
- [ ] `~/code/grid/go.work` created
- [ ] `go.work` and `go.work.sum` gitignored in all three repos
- [ ] `~/code/grid/CLAUDE.md` written
- [ ] Coding agent invoked from `~/code/grid/` for Phase 0

## Context

**gridiac** is a new product (separate repository, sibling to `gridctl`) under William's "spec-first orchestration" portfolio. It is a **closed-loop agentic Infrastructure-as-Code platform**: an AI agent reads a Git-checked-in spec file, generates OpenTofu HCL, runs policy-as-code, opens a pull request with a verifiable signed attestation, and on merge runs `tofu apply` and watches for drift.

This implementation prompt scopes a **wedge-thesis MVP** — narrow on purpose. It is **not** the broader original gridiac brief. The broader brief (multi-cloud, multi-VCS, full TACoS competitor) was evaluated and rejected as the right MVP scope; see `feature-evaluation.md` in the same directory.

The wedge buyer is a platform engineer or DevSecOps lead in a **regulated organization** (defense / federal / finance / healthcare) who:
- Cannot use SaaS IaC (data residency, FedRAMP/HIPAA/PCI/IL5 constraints)
- Already runs OpenTofu (or wants to migrate off Terraform BSL)
- Needs verifiable audit lineage for every infra change
- Has been told "no" on Pulumi Cloud, HCP Terraform, and Spacelift SaaS

**Tech stack baseline** (mirrors gridctl):
- **Backend**: Go 1.26
- **Frontend**: React 19 + Vite + TypeScript + Tailwind + Zustand + React Flow
- **Distribution**: Helm chart for self-hosted; CLI installer (`gridiac`); GoReleaser; Homebrew tap; container images
- **Observability**: OpenTelemetry traces + slog structured logging
- **Secrets**: vault-only invariant (no raw credentials in memory or logs)
- **Crypto**: XChaCha20-Poly1305 envelope encryption; FIPS-mode flag

**Repository**: A new repository under the same GitHub org as `gridctl`. Name suggestion: `gridiac`. Structure follows gridctl conventions.

## Evaluation Context

This prompt incorporates these key findings from the evaluation:

- **Three funded incumbents already ship the generic thesis** — Pulumi Neo, Project Infragraph (HashiCorp/IBM), Spacelift Saturnhead AI. Generic agentic Terraform is table-stakes, not differentiated.
- **The defensible wedge is OpenTofu-first + self-hosted + regulated-buyer + verifiable policy chain.** None of the funded incumbents serve this combination cleanly. This shapes every requirement below.
- **Practitioner sentiment on AI-authored infra is deeply skeptical.** Trust deficit closes via *visible, signed lineage*, not by hiding the agent. UX must privilege legibility over magic.
- **The "Compliance View" is the differentiated artifact** — the screen an auditor opens that shows spec → plan → policy → approver → apply → drift with click-through to in-toto attestations. No comparable UI exists in the field. Build this view first; everything else is plumbing.
- **Reuse from `gridctl`** saves an estimated 6–8 weeks of plumbing (`pkg/git`, `pkg/vault`, `pkg/registry`, `pkg/config`, `internal/api` patterns, web UI patterns, release tooling). The reuse strategy is **phased extraction** — at MVP, mirror these packages into a new `grid-common` repo while leaving gridctl unchanged; gridctl is refactored to consume `grid-common` post-alpha. Details in Architecture Guidance.
- **Design-partner gate is mandatory.** Build a 2-week prototype demonstrating only the spec → HCL → policy → attestation → PR comment chain *before* committing to the full alpha. Take it to a regulated-buyer contact. Do not commit 12+ weeks without that signal.

Full evaluation: `prompts/gridctl/gridiac/feature-evaluation.md`.

## Feature Description

gridiac is a self-hostable platform that transforms an engineer's intent (`.spec/infra.yaml` checked into their own Git repo) into running infrastructure through a closed agentic loop:

1. **Trigger**: engineer edits `.spec/infra.yaml` on a branch, OR a webhook arrives via Slack/Jira/API, OR a cron drift-check runs.
2. **Generate**: gridiac agent creates a new branch (`agent/<short-uuid>-<slug>`) and generates or updates OpenTofu HCL based on the spec, using the customer's BYO LLM endpoint.
3. **Validate**: agent runs `tofu init`, `tofu plan`, OPA/Cedar policy evaluation, cost estimate (Infracost), and security scan (tfsec or Checkov).
4. **Sign**: agent produces an **in-toto attestation** chaining spec digest → generated HCL digest → plan digest → policy verdict → cost delta. Signature is via the customer's KMS key.
5. **Open PR**: agent opens a pull request with a fixed-shape, scannable comment containing status badges, blast-radius score, cost delta, policy verdict + signature short-hash, and collapsible details sections.
6. **Approve**: human reviewer approves OR a checked-in Cedar/OPA approval rule auto-approves low-risk paths.
7. **Apply**: on merge, agent runs `tofu apply`. Apply receipt (signed) is stored in the audit log.
8. **Watch**: drift detection runs on a schedule. Detected drift opens a *new* PR offering "revert to spec" or "adopt to spec." Never auto-revert.

Every artifact is signed; the full lineage is queryable from a single "Compliance View" screen and exportable as a SOC2/FedRAMP evidence pack.

## Requirements

### Functional Requirements (MVP wedge scope)

1. **Self-hostable deployment** via Helm chart and `docker compose` reference; no SaaS at MVP.
2. **`.spec/infra.yaml` parser** with JSON Schema validation (`spec_version`, `environment`, `description`, `budget_monthly_usd`, `compliance`, `requirements` blocks) and env / vault / KMS-ref expansion (mirror `pkg/config/expand.go` patterns).
3. **GitHub App registration** for repo access, branch creation, PR opening, status checks, branch-protection-aware merge gates. (GitLab and Bitbucket: deferred.)
4. **OpenTofu execution sandbox** — wrap `tofu` CLI with strict subprocess isolation (no network egress except to the configured providers; no host filesystem access outside a per-run scratch dir; resource limits via cgroups).
5. **AI agent core** that reads a spec, generates/updates HCL via tool-calling against the BYO LLM endpoint. **The agent's tool layer is MCP (Model Context Protocol), not bespoke function calling.** gridiac ships an MCP client that consumes tools from configured MCP servers — `terraform-mcp` (provider schemas + module registry), `aws-mcp` (cloud reads), `opa-mcp` (policy queries), and gridiac's own `gridiac-mcp` (spec read/write, attestation builder). Operators can add tenant-specific MCP servers. This deliberately reuses the gridctl ecosystem (gridctl is an MCP gateway) and aligns with the emerging industry standard for agent ↔ infrastructure communication. Default model: Claude Opus 4.7 (configurable). Hard requirement: every tool call is logged + signed.

5a. **Provider-schema grounding (top-level requirement, not a pitfall).** Public-data scarcity makes raw HCL synthesis accuracy under 20% on production-grade configs. To counter this: every generated `.tf` file passes through `tofu validate` AND a provider-schema cross-check (via `terraform-mcp` query) **before** plan. Schema mismatches produce a typed error fed back into the agent loop for a bounded retry (max 3). The agent must never produce a plan against unvalidated HCL. Schema-grounding-failure metrics are surfaced in the audit log and the run timeline UI.
6. **Policy evaluation** via Open Policy Agent (OPA) with Rego policies. Policy bundle is loaded from a checked-in `.spec/policy/` directory or a configured remote bundle URL. Cedar can be added later.
7. **Cost estimation** via Infracost CLI (offline-capable mode for air-gap).
8. **Security scan** via tfsec OR Checkov (operator's choice via config).
9. **In-toto attestation chain** — every artifact in the loop produces a signed in-toto predicate. Predicates use customer-controlled KMS key (AWS KMS for MVP; HSM-backed key support later). Signatures are verifiable with `cosign verify-attestation` and a documented `gridiac verify` CLI subcommand.
10. **PR comment renderer** — fixed-shape header (status / blast-radius / cost / policy / signature short-hash) + collapsible `<details>` sections. Single comment per run, edited in place (not appended). Survives GitHub comment-size limits via summarization + linkout.
11. **Approval policy as code** — `.spec/approval.cedar` (or `.rego`) checked into the repo defines auto-approval rules (per-path, per-cost-threshold, per-resource-kind). Override path via PR comment `/approve override reason="..."` which itself becomes an attested event.
12. **Apply executor** — on merge to default branch, runs `tofu apply` with the same signed-attestation chain. Apply log + state-change diff are signed and persisted.
13. **Drift detection** — scheduled job runs `tofu plan` against deployed state. Drift produces a *new* PR offering "revert to spec" or "adopt to spec." No auto-revert.
14. **Compliance View (web UI)** — single-screen audit view for any resource showing spec commit → generated HCL → plan digest → policy version → approver → apply receipt → drift state, with click-through to each in-toto attestation. Export-as-PDF for evidence packs.
15. **Run timeline (web UI)** — DAG view of the agent's tool calls with one-line intent per node, click-through to full I/O. Inspired by Argo Workflows.
16. **CLI** — `gridiac init`, `gridiac doctor` (green/red checklist: LLM reachable, GitHub App installed, OPA loaded, KMS key signs test attestation), `gridiac scaffold` (bootstrap a starter `.spec/infra.yaml`), `gridiac verify <sha>` (verify attestation chain).
17. **OpenTelemetry instrumentation** — every agent run is a trace; every tool call is a span. Exporters: OTLP (Tempo / Jaeger / Honeycomb).
18. **Audit log export** — JSONL sink to S3 / syslog / Splunk-HEC. Replayable and tamper-evident (Merkle-chained).
19. **Air-gap / no-egress mode** — startup flag `--no-egress` that hard-disables outbound traffic except to configured BYO-LLM endpoint and configured Git server. UI shows persistent `air-gapped: yes` badge.
20. **FIPS mode** — `--fips` flag switches signing/hashing to FIPS-validated libraries. UI shows `FIPS` chip on every attestation.

### Non-Functional Requirements

- **Single-tenant**: gridiac MVP is per-organization-deployment. Multi-tenant SaaS is out of scope.
- **Crypto**: all signing uses KMS-backed keys; private keys never leave KMS. XChaCha20-Poly1305 for vault-at-rest. SLSA-compliant build pipeline for binaries (provenance generated by GoReleaser + cosign).
- **RBAC**: SAML/OIDC SSO from day one; per-path, per-action permissions. No local-account fallback in production deployments.
- **Concurrency**: handle ~20 concurrent agent runs per node at MVP. Horizontal scale-out via shared queue (defer to Postgres LISTEN/NOTIFY for MVP, not Kafka).
- **Reliability**: agent runs are idempotent; on crash, an interrupted run is resumable from the last checkpoint (last signed event in the audit log).
- **Performance**: PR comment posted within 90 seconds of spec change for a typical 50-resource spec.
- **Compatibility**: OpenTofu 1.8+ only. Terraform (BSL) explicitly unsupported. AWS only at MVP. Multi-cloud deferred.
- **Security**: every external input (LLM output, spec file, webhook payload) is treated as untrusted. Sandboxed subprocess execution. No `eval` or string-templated shell commands.
- **Compliance posture docs**: ship a "SOC2 Evidence Mapping" and "FedRAMP Control Mapping" as first-class repo docs, not a marketing PDF.

### Out of Scope (MVP)

These are explicitly **not** in the MVP. Resist scope creep on each:

- Multi-cloud (Azure, GCP, OCI). AWS only.
- Multi-VCS (GitLab, Bitbucket). GitHub only.
- Pulumi / CDK / Crossplane support. OpenTofu HCL only.
- Terraform (BSL) support. Pick the OpenTofu side.
- Sentinel policy support. OPA Rego only at MVP; Cedar is a fast-follow.
- Multi-tenant SaaS. Self-host only.
- Slack / Jira / API webhook triggers. Spec-edit-on-branch only at MVP.
- Visual spec authoring UI. CLI scaffolder + raw YAML editing.
- Cost optimization recommendations. Cost reporting only.
- Resource graph visualization. Compliance View only.
- Auto-remediation of drift. Drift produces a PR; never auto-applies.
- Custom LLM training. BYO endpoint only.
- Multi-region failover. Single-region deployment only.

## Architecture Guidance

### Recommended Approach

**MCP-native agent layer.** The agent does not own its toolset directly. It consumes tools and resources via the Model Context Protocol from a configured set of MCP servers. This has three concrete benefits: (1) reuses the gridctl ecosystem — gridctl already aggregates MCP servers, so gridiac can be deployed alongside a gridctl gateway and inherit any tools the operator has wired up; (2) aligns with the emerging cross-vendor standard so the agent can swap LLMs and tool providers without re-implementation; (3) makes the agent's authority surface auditable — the set of MCP tools the agent has access to is a checked-in config artifact, not a hardcoded list.

**Layered architecture, mirrored from gridctl**:

```
gridiac/
  cmd/
    gridiac/          # CLI entry point
    gridiac-server/   # control-plane HTTP + gRPC server
    gridiac-runner/   # per-run sandboxed agent worker
  pkg/
    spec/                 # .spec/infra.yaml parser + JSON Schema validator
    agent/                # AI agent core: MCP client, LLM client, run orchestrator
    mcp/                  # MCP server registry, tool discovery, signed-call wrapper
    mcpserver/            # gridiac's own MCP server (spec read/write, attest)
    tofu/                 # OpenTofu CLI wrapper with sandboxing
    policy/               # OPA bundle loader + evaluator
    cost/                 # Infracost integration
    security/             # tfsec / Checkov integration
    attest/               # in-toto attestation builder + KMS signer
    pr/                   # PR comment renderer (Markdown templates)
    drift/                # scheduled drift detector
    audit/                # tamper-evident JSONL log writer + exporters
    git/                  # multi-VCS git ops (consumed from grid-common; mirrored from gridctl at MVP)
    vault/                # encrypted-at-rest store (consumed from grid-common; mirrored from gridctl at MVP)
    config/               # YAML loader with env/vault/KMS expansion (consumed from grid-common; mirrored from gridctl at MVP)
    registry/             # workflow DAG executor (consumed from grid-common; mirrored from gridctl at MVP)
    tracing/              # OpenTelemetry plumbing (consumed from grid-common; mirrored from gridctl at MVP)
  internal/
    api/                  # control-plane HTTP/REST API
    server/               # server lifecycle
    db/                   # state store (Postgres for MVP)
  web/
    src/                  # React 19 + Vite + TypeScript control plane UI
  charts/
    gridiac/          # Helm chart
  scripts/
    install.sh            # curl installer (mirror gridctl pattern)
  docs/
    soc2-evidence-mapping.md
    fedramp-control-mapping.md
    architecture.md
    spec-reference.md
```

**Process model**:
- `gridiac-server`: long-running control plane. Receives webhooks, schedules runs, serves API + UI. Stateless (state in Postgres).
- `gridiac-runner`: per-run worker process. Dispatched by the server. Runs the agent loop in a sandboxed environment (separate user, cgroups, no privileged access).
- Worker isolation is critical — agents execute LLM-suggested code paths and run `tofu` against real cloud credentials. Server and runner must be process-isolated.

**Three-repo layout with phased extraction.** Day-1 layout is three repositories under the same GitHub org:

```
github.com/<org>/gridctl       # existing — MCP gateway, untouched at MVP
github.com/<org>/gridiac       # new — IaC agent (this alpha)
github.com/<org>/grid-common   # new — shared Go library
```

`gridiac` imports `github.com/<org>/grid-common` from its first commit. `grid-common` is **populated by mirroring** the relevant packages from `gridctl/pkg/*` (`git`, `vault`, `config`, `registry`, `tracing`, plus `internal/api` middleware patterns). **`gridctl` itself is not refactored at MVP** — it keeps its current internal packages unchanged. This is a deliberate, time-boxed dual-source-of-truth window that avoids destabilizing gridctl's beta and avoids forcing gridiac to refactor away from internal copies later.

**Discipline during the duplication window:**
- Every duplicated file in `grid-common` carries a top-line comment: `// MIRROR: github.com/<org>/gridctl/pkg/<name> — keep in sync until gridctl extraction PR lands.`
- Bug fixes / improvements in either side must be applied to both. The mirror comment is the prompt to do so.
- Open a tracking issue in `gridctl` titled "Refactor pkg/* → grid-common dependency" with a target version (suggested: post-gridiac-alpha, gridctl 0.2 milestone).
- Keep the mirrored package set small and stable. The packages chosen (git auth, vault, config, registry/DAG, tracing) are mature in gridctl with low churn — that's *why* they're appropriate for the dual-source window. Do not mirror packages that are actively churning.

**Why this approach, not the alternatives:**
- Vendoring or `internal/sharedfromgridctl/` copies would marry gridiac to a snapshot and make later extraction painful.
- Importing gridctl directly (`import "github.com/<org>/gridctl/pkg/git"`) couples gridiac to gridctl's *entire* public surface and prevents API curation.
- A monorepo would force shared release cadence and CI on two products that ship independently.
- Real extraction-at-MVP (refactoring gridctl now) destabilizes a beta product in service of the alpha — wrong order.

**Local development uses Go workspaces.** The recommended single-author dev setup is:

```
~/code/
├── go.work              # local-only; gitignored in each repo
├── gridctl/
├── gridiac/
└── grid-common/
```

`go.work` contents:
```go
go 1.26

use (
    ./gridctl
    ./gridiac
    ./grid-common
)
```

`go.work` and `go.work.sum` must be added to `.gitignore` in all three repos. Workspaces affect local dev only; CI for each repo continues to resolve modules through `go.mod`. With the workspace in place, edits in `grid-common` are picked up immediately by `gridiac` without `replace` directives or version bumps.

### Key Files to Understand (in `gridctl` for reuse)

The implementer should read these gridctl files before mirroring them into `grid-common`. The goal at MVP is faithful mirroring with curated public APIs, not redesign:

1. **`pkg/mcp/gateway.go`** (gridctl) — protocol bridge logic, replica health monitoring, exponential backoff with jitter. Pattern for drift-detection polling.
2. **`pkg/git/auth.go`** (gridctl) — `Auther` interface + HTTPS PAT / SSH agent / NoAuth implementations; credential redaction; error classification. Reuse verbatim.
3. **`pkg/skills/importer.go`** (gridctl) — remote-repo clone with private-repo support and credential threading. Template for "clone customer repo to read spec."
4. **`pkg/registry/executor.go`** (gridctl) — DAG workflow execution with parallel dispatch, error policies (`fail`/`skip`/`continue`), step timeouts. Adapt to drive the validate→plan→policy→cost→security→attest pipeline.
5. **`pkg/config/loader.go`** + `expand.go` (gridctl) — YAML parsing with env / vault expansion. Template for `.spec/infra.yaml` parser.
6. **`pkg/vault/store.go`** (gridctl) — XChaCha20-Poly1305 envelope encryption with lock/unlock and import/export. Reusable for state-at-rest.
7. **`pkg/controller/controller.go`** (gridctl) — deploy orchestration, dependency graph for startup ordering. Pattern for managing per-run worker lifecycle.
8. **`internal/api/api.go`** (gridctl) — API server setup, route registration, bearer/api-key middleware, structured error responses.
9. **`web/src/`** (gridctl) — React 19 + Vite + Tailwind + Zustand + React Flow patterns; wizard UX; design tokens.
10. **`scripts/install.sh`, `.goreleaser.yaml`, `Makefile`** (gridctl) — release tooling; reuse and adapt.

### Integration Points

- **GitHub** (only at MVP): GitHub App with permissions for contents:write, pull_requests:write, statuses:write, metadata:read. Webhook for push and pull_request events. Use `go-github`.
- **MCP servers** (the agent's tool layer): bundle reference servers — `terraform-mcp` (HashiCorp's official server for provider schemas + module registry queries), `aws-mcp` (read-only cloud queries), `opa-mcp` (policy evaluation queries), and gridiac's first-party `gridiac-mcp` (spec read/write + attestation builder). Operators can register additional MCP servers via config. Transport: JSON-RPC 2.0 over stdio for in-process servers and HTTP for remote. Every MCP tool call is logged with input/output digests and signed into the audit chain.
- **OpenTofu**: shell out to `tofu` CLI with sandboxing. Plan is to vendor a known-good OpenTofu binary inside the runner container.
- **OPA**: embed OPA as a Go library (`github.com/open-policy-agent/opa/rego`) for synchronous evaluation; bundle hot-reload from a configured URL. Also exposed to the agent via `opa-mcp` for query-time reasoning ("what policy applies to this resource?").
- **Infracost**: shell out to `infracost` CLI in offline-pricing mode.
- **tfsec / Checkov**: shell out; operator picks one via config.
- **AWS KMS**: for attestation signing. Use AWS SDK v2 for Go. KMS key is customer-controlled.
- **LLM**: HTTP client targeting OpenAI-compatible API spec (Anthropic, OpenAI, Bedrock, vLLM, Ollama all conform). Default model: Claude Opus 4.7. Operator configures endpoint + API key via vault ref.
- **Postgres** (state store): runs, attestations, audit log index, RBAC, approval-rule evaluations. Ship a schema migration tool.
- **OTLP** (telemetry): standard OpenTelemetry SDK.

### Reusable Components

These are the gridctl packages mirrored into `grid-common` at MVP (per the phased-extraction plan above — gridctl itself is not modified). Each entry lists the source path in gridctl, the destination path in `grid-common`, and gridiac's use:

| gridctl source (read-only at MVP) | grid-common destination (mirror) | gridiac use |
|---|---|---|
| `pkg/git/*` | `grid-common/git/*` | Clone customer repo, branch ops, multi-VCS auth |
| `pkg/config/loader.go`, `expand.go` | `grid-common/config/*` | `.spec/infra.yaml` parser with env/vault/KMS expansion |
| `pkg/vault/store.go` | `grid-common/vault/*` | Encrypted-at-rest secrets |
| `pkg/registry/executor.go` | `grid-common/dag/*` | Validate→plan→policy→cost→security pipeline |
| `pkg/tracing/*` | `grid-common/tracing/*` | OpenTelemetry trace plumbing |
| `pkg/metrics/*` | `grid-common/metrics/*` | Prometheus / OTLP metrics |
| `internal/api` middleware | `grid-common/api/middleware/*` | Auth middleware, error responses |

Each mirrored file in `grid-common` must carry the `// MIRROR: ...` comment described in the phased-extraction plan. The post-alpha gridctl refactor will remove the duplicates from gridctl in a single PR; until then, fixes to either side propagate manually.

UI patterns (web/src) that should be lifted as a shared component library:
- Auth-required route wrapper
- Polling hook for long-running operations
- Wizard component with field-level validation
- DAG view (extend gridctl's React Flow patterns)
- Status badge component
- Code/diff viewer

## UX Specification

### Discovery
Public OSS GitHub repo. Marketing entry point is the **Compliance View screenshot** — auditors and CISOs recognize it instantly. Docs feature SOC2 / FedRAMP control mappings as a top-nav item.

### Activation
1. `helm install gridiac` (or `docker compose up` for evaluation).
2. `gridiac init`:
   - Prompts for GitHub App registration; opens browser to install on selected org/repos.
   - Validates BYO-LLM endpoint reachability and prompts for API key (stored in vault).
   - Loads OPA bundle from a default-deny starter pack.
   - Generates KMS signing key (or imports existing).
   - Signs a test attestation end-to-end and verifies it.
3. `gridiac doctor` — green/red checklist of all subsystems. Hard-fails if any subsystem is misconfigured (especially: LLM endpoint unset, KMS key unset, OPA bundle absent).
4. `gridiac scaffold` in a target repo — creates a minimal `.spec/infra.yaml`, `.spec/policy/`, and `.gridiac.yaml` config file via PR.

15-minute happy path is the bar.

### Interaction (steady state)
1. Engineer edits `.spec/infra.yaml` and pushes to a branch.
2. Webhook fires; agent picks up the change. The web UI shows a new run in the **Run Timeline** (Argo-style DAG).
3. Within 60–90 seconds, the agent opens a PR. PR comment shows fixed-shape header:
   ```
   [STATUS] plan-ok  policy-pass  cost +$42/mo  blast: 3 created / 0 destroyed
   attestation: sha256:a1b2... (verify: gridiac verify <sha>)
   > Details ▶  Plan ▶  Policy ▶  Security ▶  Run log ▶
   ```
4. Engineer reviews PR. Comments `/spec suggest add postgres` to ask the agent to refine the spec via PR review comments (not silent rewrites).
5. Approval: matched against `.spec/approval.cedar`. If auto-approved, header shows the matching rule + signature. Otherwise: human approves.
6. On merge, apply runs. Apply receipt visible in PR within seconds of merge.

### Compliance View (the auditor screen)
Single-pane view, one resource at a time. Layout (per Phase 4 UX analysis):

```
Resource: aws_rds_cluster.payments-prod
  Spec:        .spec/infra.yaml @ commit 8a3f… (signed: alice@acme)
  Generated:   modules/payments/rds.tf @ commit 9b1c… (agent run #4421)
  Plan:        sha256:c7d9…  (cost +$184/mo, 1 created)
  Policy:      pci-dss/v4.2  PASS  (signed: opa-prod-key)
  Approval:    auto, rule low-risk:v3  OR  bob@acme @ 2026-04-12T14:02Z
  Apply:       2026-04-12T14:05Z  exit 0  receipt sha256:e2f1…
  Drift:       none (last checked 2026-04-30T09:00Z)
  Attestations (in-toto, click to verify):
    [spec→plan]  [plan→policy]  [policy→apply]  [apply→state]

[Export evidence pack ▼]  PDF | JSON | tar.gz
```

### Failure states
Every failure produces a typed error card: `kind: hcl-syntax | plan-error | policy-deny | apply-partial | drift-conflict`. Each kind has a canned remediation flow. `apply-partial` immediately opens a remediation PR listing orphaned resources.

### Air-gap / FIPS UX
Persistent top-bar badges:
- `air-gapped: yes` (or hidden if egress allowed)
- `FIPS` chip on every attestation when FIPS mode is on
- `no-telemetry: yes` if OTLP export is disabled

## Implementation Notes

### Conventions to Follow

Mirror gridctl conventions:
- Go 1.26 module layout, `cmd/` + `pkg/` + `internal/`
- Interface-driven design with mockgen-generated mocks (`go:generate mockgen -source=foo.go ...`)
- Table-driven tests; aim for 70%+ coverage on `pkg/`
- Structured logging via `slog` with consistent fields (`run_id`, `repo`, `actor`)
- Context propagation throughout; no `context.Background()` in deep call paths
- Errors classified via typed error kinds (mirror `pkg/git/errors.go`)
- Vault-only invariant for credentials — credentials never appear as raw strings except inside KMS-encrypted memory windows
- All commits signed (`git commit -S`)
- No "Co-authored-by" trailers
- Conventional commits (`feat:`, `fix:`, `docs:`, etc.)
- No mention of Claude / AI / LLM in commit messages or PR titles (per William's working style)

### Potential Pitfalls

1. **OpenTofu binary version drift** — vendor a known-good binary or pin via SHA-256 in the runner image. Provider plugins are downloaded at runtime; cache them per-runner to avoid network thrashing.
2. **LLM hallucinated provider attributes** — see FR 5a (provider-schema grounding). The non-obvious failure mode: `terraform plan` does not always catch invalid attributes that the schema accepts but the provider rejects at apply-time. Cross-check via the `terraform-mcp` schema query is the second line of defense after `tofu validate`. The retry budget is bounded (max 3) — beyond that the agent surfaces a typed error rather than thrashing. Watch for: schemas that drift between provider versions; the runner image must pin provider versions and re-pull only on operator-approved version bumps.
3. **Sandboxing escapes** — the runner runs LLM-driven code paths. Treat the LLM as adversarial. Use cgroups + seccomp + dropped capabilities + read-only root FS in the runner container. No host networking, no docker socket, no AWS metadata service access (block 169.254.169.254).
4. **KMS key rotation** — design the attestation chain to record the signing-key fingerprint, not just the signature. Old attestations remain verifiable after rotation via a key-history map in the audit log.
5. **GitHub PR comment size limits** — comment renderer must summarize-and-link rather than dump full plan output. Limit comment to ~5 KB; attach plan output as a release artifact or downloadable file linked from the comment.
6. **Drift false positives from terraform-managed-but-out-of-band resources** — drift detection must respect ignored fields (`ignore_changes`) and a checked-in `.spec/drift-allowlist.yaml`.
7. **Multi-repo onboarding overhead** — implement org-level template config (single `gridiac-config` repo) referenced by repo-level `.gridiac.yaml` (5 lines max). Avoid per-repo full-config duplication.
8. **Approval rule overrides** — `/approve override reason="..."` must be cryptographically attested as a *separate* event with the human's identity. Auditors must be able to find every override.
9. **State backend coupling** — MVP uses customer's existing S3/Terraform state backend. Do NOT host state in gridiac. Document the state-backend setup explicitly.
10. **In-toto predicate format stability** — define the predicate types once and version them (`gridiac.dev/spec-to-plan/v1`, etc.). Old verifiers must still work after schema evolution.

### Suggested Build Order

The 12–16 week alpha targets six milestones. Each milestone is itself shippable.

**Phase 0: Design-partner prototype (2 weeks).** *Build before committing to the full alpha.*
- **Repo scaffold (day 1)**: create `gridiac` and `grid-common` repos under the same GitHub org as `gridctl`. Mirror the minimal subset of gridctl packages needed for the prototype into `grid-common` (likely just `git/auth.go` and `config/loader.go` at this stage) with `// MIRROR:` comments. Set up `~/code/go.work` covering all three. Do not modify gridctl.
- Bare-bones CLI: read `.spec/infra.yaml`, call LLM, generate one HCL file, run `tofu plan`, evaluate one OPA rule, produce one in-toto attestation, post a stub PR comment.
- One AWS resource type (VPC), GitHub-only, no UI, no Helm chart.
- **Goal**: take this to a regulated-buyer contact. If they don't say "tell me more," kill the project. Do not proceed to Phase 1.

**Phase 1: Closed-loop minimum (weeks 3–6).**
- Spec parser + JSON Schema
- Agent core with tool-calling against BYO LLM
- OpenTofu sandbox (subprocess + cgroups + read-only FS)
- OPA evaluation
- In-toto attestation chain (spec → plan → policy)
- PR comment renderer (fixed-shape header + collapsible details)
- Audit log JSONL writer + S3 sink
- CLI: `init`, `doctor`, `verify`
- **Acceptance**: a real platform engineer can fork a sample repo, run `helm install` + `gridiac init`, edit `.spec/infra.yaml`, see a signed PR appear, merge it, see `tofu apply` run. End-to-end on AWS sandbox account.

**Phase 2: Compliance View + approval policy (weeks 7–9).**
- Web UI (React + Vite) with control-plane API
- Compliance View screen (per-resource lineage)
- Run Timeline (Argo-style DAG)
- `.spec/approval.cedar` evaluation + `/approve override` flow
- Apply receipt + drift detection (read-only PRs only)
- Cost estimation (Infracost) + security scan (tfsec)
- **Acceptance**: an auditor can open the Compliance View for any deployed resource and export an evidence pack PDF.

**Phase 3: Air-gap + FIPS + RBAC (weeks 10–12).**
- `--no-egress` startup flag with hard egress block
- `--fips` flag with FIPS-validated crypto (use `BoringCrypto` Go build)
- SAML / OIDC SSO + per-path RBAC
- KMS key rotation flow
- Tamper-evident audit log (Merkle-chained)
- SOC2 Evidence Mapping doc + FedRAMP Control Mapping doc
- **Acceptance**: a CISO can audit the deployment and find no SaaS dependencies, no plaintext credentials, no unsigned artifacts.

**Phase 4: Drift + multi-repo (weeks 13–14).**
- Drift detection scheduler + drift-PR generator
- Org-level template config (single `gridiac-config` repo)
- `gridiac onboard <repo>` CLI flow
- **Acceptance**: 20 repos onboarded with a single template; drift on any repo produces a PR within 1 hour.

**Phase 5: Hardening + alpha release (weeks 15–16).**
- Security review (penetration test of sandbox + agent)
- Performance pass (PR comment within 90s for 50-resource specs)
- Helm chart polish
- Installer + Homebrew tap
- Docs site
- Release as `v0.1.0-alpha.1`
- **Acceptance**: a design-partner organization can run the full closed loop in their environment without William's hands-on involvement.

## Fast-Follow / v0.2 Roadmap (post-alpha, scope hints only)

These are explicitly **not in the MVP**. They are recorded here so MVP architecture decisions don't paint the project into a corner. Do not start any of these until the alpha is in a design partner's hands.

### Promotion engine (sandbox → governed prod)

Mirroring the dual-path pattern emerging in the field (e.g., Spacelift Intent), the agent gains an additional operating mode for short-lived environments:

- **Sandbox mode**: agent operates against the cloud directly via MCP tools (e.g., `aws-mcp`) without generating HCL first. Every direct API call is signed into the audit chain identically to the IaC path. Speed-of-iteration trades against traditional `terraform plan` semantics; this mode is gated by approval policy and only allowed on configured paths (`environments/dev/**`, `sandbox/**`).
- **Promotion**: a single command (`gridiac promote <run-id>`) reverse-engineers the discovered cloud state into governed OpenTofu HCL, opens a PR, and runs the full attestation chain. The promoted resources are tagged with the originating sandbox run-id so the audit chain links the experimental work to the governed prod artifact.
- **MCP architecture pays off here**: because the agent already calls cloud APIs through MCP tools in the IaC path (for read-only schema grounding), extending to direct-write in sandbox mode is a config-level expansion of the tool's allowed methods, not a re-architecture.

This is the **single highest-value v0.2 feature** — it bridges the "agile path" (where AI is fastest) and the "governed path" (where the regulated buyer wants to live).

### Real-time infrastructure graph (post-v0.2)

Project Infragraph and similar approaches replace the static `.tfstate` with a live relational graph of resources, applications, and ownership. gridiac's MVP relies on the customer's existing remote state backend (S3, etc.) — correct for regulated buyers who don't want vendor lock-in. A v1+ direction is a **graph layer over the existing state**: gridiac syncs state files into an in-cluster graph store (Postgres + recursive CTEs at small scale; defer Neo4j or similar) that the agent queries via an `gridiac-graph-mcp` server. This is a meaningful product expansion and competes with HashiCorp directly — defer until alpha validates the core thesis.

### Additional VCS, cloud, and IaC dialects

Per the MVP scope, GitHub + AWS + OpenTofu only. Once the wedge is validated, the natural expansion order (driven by design-partner demand, not roadmap intuition):

1. GitLab self-hosted (regulated buyers run GitLab on-prem more than GitHub)
2. Azure (FedRAMP High and DoD IL5 customers concentrated here)
3. Cedar policy engine alongside OPA (AWS-native policy DSL; useful for AWS-heavy fed customers)
4. Terraform (BSL) support — only if a design partner has a hard requirement; OpenTofu-first remains the brand position

### MCP-native ecosystem expansion

Because the agent's tool layer is MCP, the natural extension is to publish gridiac's MCP servers and consume third-party MCP servers from the wider gridctl ecosystem. Examples that would extend gridiac's surface without core changes:
- `vault-mcp` (HashiCorp Vault) — secrets retrieval in regulated environments
- `slsa-mcp` — SLSA-compliant build provenance for the gridiac binary itself, surfaced in the audit chain
- Customer-private MCP servers (e.g., a tenant's CMDB) — the agent gains tenant context without code changes

## Acceptance Criteria

The MVP is considered complete when:

1. A platform engineer can install gridiac via `helm install gridiac` + `gridiac init` in under 15 minutes on a fresh Kubernetes cluster with a configured BYO-LLM endpoint.
2. Editing `.spec/infra.yaml` on a branch and pushing produces a PR with generated OpenTofu HCL, plan output, OPA policy verdict, cost estimate, and security scan within 90 seconds for a 50-resource spec.
3. The PR comment fits on one screen at the GitHub default zoom level and never exceeds 5 KB.
4. Every artifact produced by the run (spec digest, generated HCL, plan output, policy verdict, apply receipt) carries an in-toto attestation signed by a customer-controlled KMS key. `gridiac verify <sha>` returns success on a healthy chain and a typed error on tampering.
5. Merging the PR triggers `tofu apply` within 30 seconds, and the apply receipt appears in the PR within 60 seconds of completion.
6. The Compliance View shows the full lineage for any resource (spec → plan → policy → approver → apply → drift) and exports an evidence pack PDF.
7. A `/approve override reason="..."` comment from an authorized user produces a separate signed override attestation visible in the audit log.
8. Drift detection on a deployed resource produces a new PR offering "revert to spec" or "adopt to spec" within the configured polling interval (default 1 hour).
9. The `--no-egress` flag hard-blocks all outbound traffic except to the configured BYO-LLM endpoint and configured Git server, verified by netfilter logs.
10. The `--fips` flag activates FIPS-validated crypto for all signing and hashing operations, and every attestation produced under FIPS mode is marked with a `fips: true` predicate field.
11. The full audit log is exportable as tamper-evident JSONL to S3 / syslog / Splunk-HEC, and a Merkle proof can be regenerated to prove no tampering since a known checkpoint.
12. SOC2 Evidence Mapping and FedRAMP Control Mapping docs are present, accurate, and link each control to the gridiac feature that satisfies it.
13. Test coverage on `pkg/` ≥ 70%; integration tests cover the full end-to-end loop on a staging AWS account.
14. A regulated-buyer design partner has installed the alpha in their own environment and run a full closed-loop change without William's hands-on involvement.
15. The agent's tool layer is implemented as an MCP client; the set of MCP servers the agent has access to is fully expressed in checked-in config and visible in the audit log. Swapping the provider-schema source from `terraform-mcp` to a custom MCP server requires only a config change, no code change.
16. Provider-schema grounding (FR 5a) measurably reduces hallucinated-attribute failures: on a benchmark of 100 representative spec-to-HCL generations, fewer than 5% require manual fix-up after the agent's bounded retry budget.

## References

### Direct competitor docs (study before designing the equivalents)
- [Pulumi Neo Documentation](https://www.pulumi.com/docs/pulumi-cloud/neo/)
- [Pulumi Neo Plan Mode](https://www.pulumi.com/blog/neo-plan-mode/)
- [HashiCorp Project Infragraph announcement](https://newsroom.ibm.com/2025-09-25-hashicorp-previews-the-future-of-agentic-infrastructure-automation-with-project-infragraph)
- [Spacelift Saturnhead AI](https://docs.spacelift.io/concepts/run/ai)
- [HCP Terraform Policy Enforcement Results](https://developer.hashicorp.com/terraform/cloud-docs/workspaces/policy-enforcement/view-results)
- [Atlantis Documentation](https://www.runatlantis.io/docs/using-atlantis)
- [DoorDash Atlantis hardening / review fatigue post](https://careersatdoordash.com/blog/atlantis-hardening-and-review-fatigue/)

### Building blocks
- [OpenTofu Documentation](https://opentofu.org/docs/)
- [Open Policy Agent (OPA) Go SDK](https://www.openpolicyagent.org/docs/latest/integration/)
- [Cedar Policy Language](https://www.cedarpolicy.com/)
- [in-toto Specification](https://github.com/in-toto/attestation)
- [Sigstore cosign verify-attestation](https://docs.sigstore.dev/cosign/verifying/attestation/)
- [SLSA Provenance v1.0](https://slsa.dev/spec/v1.0/provenance)
- [Score Specification](https://score.dev/)
- [Infracost](https://www.infracost.io/docs/)
- [tfsec](https://github.com/aquasecurity/tfsec)
- [Checkov](https://www.checkov.io/)
- [Argo Workflows DAG patterns](https://argoproj.github.io/argo-workflows/walk-through/dag/)
- [Backstage Software Templates](https://backstage.spotify.com/discover/backstage-101)
- [GitHub Apps documentation](https://docs.github.com/en/apps)

### Adjacent patterns
- [OpenTofu vs Terraform Enterprise Guide (env0)](https://www.env0.com/blog/opentofu-vs-terraform-a-practical-guide-for-enterprise-infrastructure-teams)
- [Crossplane 2.0](https://www.infoq.com/news/2025/08/crossplane-applications-v2/)
- [Stakpak Agent (Rust reference)](https://github.com/stakpak/agent)
