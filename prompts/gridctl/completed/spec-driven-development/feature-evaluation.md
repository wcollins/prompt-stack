# Feature Evaluation: Spec-Driven Stack Development

**Date**: 2026-03-12 (updated 2026-03-13)
**Project**: gridctl
**Recommendation**: Build
**Value**: High
**Effort**: Very Large (phased delivery)

## Summary

A unified feature set that makes spec-driven development a first-class citizen in gridctl. Three interconnected capabilities sharing infrastructure: (1) **Spec Foundation** — `gridctl validate` and `gridctl plan` commands, spec health indicators, drift detection, and spec-vs-reality overlays that elevate `stack.yaml` from configuration to living specification. (2) **Visual Spec Builder** — A Universal Creation Wizard in the web UI that authors stack specifications through guided forms with smart dropdowns, live YAML preview, real-time validation, and secure vault-integrated secrets input. (3) **Spec Dependency Management** — Import Agent Skills from public GitHub repositories with version pinning via lock file, SemVer constraints, security scanning, and auto-update. The Skills Builder wizard becomes one mode of the Visual Spec Builder.

## Spec-Driven Development Context

Spec-driven development (SDD) is emerging as one of 2025-2026's key new AI-assisted engineering practices (Thoughtworks Technology Radar). The paradigm uses well-crafted software specifications as the primary development artifact, consumed by AI agents to generate implementations.

**Why this matters for gridctl**: gridctl already IS spec-driven. `stack.yaml` is a declarative specification that defines intent — what MCP servers, agents, and resources should exist — and gridctl realizes that intent as running infrastructure. `SKILL.md` files are structured agent behavior specifications with workflows, dependencies, and error handling. What's missing is the tooling and UX that communicates "these are specs" and enables the full spec lifecycle: author → validate → plan → apply → monitor → evolve.

**Industry landscape** (as of March 2026):
- **Amazon Kiro**: IDE with built-in SDD pipeline (Requirements → Design → Tasks). Produces 3 markdown files per spec. Criticized for excessive verbosity on small changes.
- **GitHub Spec Kit**: Agent-agnostic SDD toolkit (72.7k stars). Slash commands for specify/plan/tasks/implement. Criticized for 3:1 doc-to-code ratio.
- **Tessl**: Spec-as-source where generated code is marked "DO NOT EDIT." Most radical approach. Private beta.
- **OpenSpec**: Three-phase state machine with approval gates before implementation.

**gridctl's advantage**: Unlike tools that create SEPARATE spec documents alongside code, gridctl's spec IS the YAML. No parallel artifact layer — `stack.yaml` is both the specification and the input. This avoids the 3:1 doc-to-code ratio trap that plagues Spec Kit and Kiro.

**Key design principles** (from industry research):
1. **Right-size the workflow** — Don't force full spec authoring for a one-server stack
2. **Avoid the markdown trap** — The spec is the YAML itself, not additional documents on top
3. **Approval gates before execution** — `gridctl plan` shows what will change; user confirms
4. **Living specs, not static documents** — Drift detection and spec-vs-reality overlays
5. **Spec is the YAML, not a separate artifact** — Elevate existing config files, don't create parallel layers

## The Idea

### Feature A: Spec Foundation — Validate, Plan, Monitor

New CLI commands and web UI features that treat `stack.yaml` as a living specification with a full lifecycle. `gridctl validate` checks the complete Stack Spec (config + skills + references) without deploying. `gridctl plan` compares the spec against current running state and shows a diff of what will change — the Terraform `plan` → `apply` pattern. The web UI gains a Spec tab (alongside Logs and Metrics) showing the current specification with live validation annotations, a drift detection overlay on the canvas comparing declared vs running state, and spec health indicators in the status bar.

**Problem**: gridctl's `stack.yaml` is already a specification, but the product doesn't treat it that way. There's no way to validate without deploying, no way to preview changes before applying, and the web UI shows what IS running but not what SHOULD BE running. Users have no visibility into spec health or configuration drift.

### Feature B: Visual Spec Builder (Universal Creation Wizard)

A unified wizard UI that authors stack specifications through guided forms. Users select a resource type (Stack, MCP Server, Agent, Resource, Skill, Secret), choose from templates (recipes), fill in fields with smart dropdowns, and the wizard generates validated YAML with live preview. A Form/YAML expert mode toggle enables bidirectional editing. Secrets input integrates with the vault, auto-generating `${vault:KEY}` references. The review step is a spec validation gate — not just "is this valid YAML?" but "will this spec produce a working deployment?"

**Problem**: gridctl requires hand-writing YAML to configure stacks. This creates a barrier for users unfamiliar with the config schema and slows iteration for experienced users. The web UI can visualize stacks but cannot create them.

### Feature C: Spec Dependency Management (Remote Skill Import)

Users declare skill dependencies in `skills.yaml` with version-pinned lock files (`skills.lock.yaml`), SemVer constraints, and security scanning. On `gridctl deploy` or `gridctl skill update`, gridctl resolves dependencies, clones repos, discovers SKILL.md files, and imports them into the local registry. Auto-update checks run non-blocking on launch. Individual skills can be pinned or have auto-update disabled.

**Problem**: The agentskills.io spec deliberately punted on distribution. 350k+ skills exist across fragmented registries with no standard way to import, version-pin, or auto-update them. gridctl's registry is currently local-only.

**Who benefits**: All gridctl users — new users (lower barrier via wizard), experienced users (faster iteration via validate/plan, fewer typos), teams (reproducible spec dependencies, standardized stack creation, drift detection), and skill authors (distribution path).

## Project Context

### Current State

gridctl is a "Stack as Code" CLI tool for orchestrating MCP servers, agents, and resources with a unified gateway. It has a Go backend (cobra CLI, net/http server) with an embedded React 19 SPA. The project is mature with 75 Go test files, 232 TypeScript tests, comprehensive docs, and a clean architecture.

**Skill registry** (`pkg/registry/`): Full CRUD, SKILL.md format (agentskills.io spec), workflow execution, validation. Explicitly noted as "local-only with no remote discovery."

**Config system** (`pkg/config/`): Complete YAML schema with 6 mutually exclusive MCP server types (image, source, URL, local process, SSH, OpenAPI), transport-specific validation rules, `SetDefaults()` for auto-inference, and vault variable expansion (`${vault:KEY}`).

**Git utilities** (`pkg/builder/git.go`): Production-ready `CloneOrUpdate()` with branch/tag/commit ref support via go-git.

**Web UI**: React 19 + Zustand 5 + TailwindCSS 4 with "Obsidian Observatory" theme (glass-panel design, amber/teal/purple palette). Existing components: Modal (expand/popout), SkillEditor (823-line multi-step editor with frontmatter forms), VaultPanel (secure secrets CRUD), MetadataEditor (dynamic key-value), Button (variant system).

### Integration Surface

| Area | Files | Impact |
|------|-------|--------|
| **Skill Import** | | |
| New package | `pkg/skills/` (new) | Remote source management, update checking, lock file |
| CLI commands | `cmd/gridctl/skill.go` (new) | `skill add/list/update/remove/pin/info/try` subcommands |
| Configuration | `pkg/config/types.go` | New `SkillSource` type, optional `remote_skills` in Stack |
| Registry store | `pkg/registry/store.go` | Origin tracking via `.origin.json` sidecar files |
| API handlers | `internal/api/skills.go` (new) | REST endpoints for remote skill operations |
| Git utilities | `pkg/builder/git.go` | Reuse `CloneOrUpdate`, add `Remote.List` for update checks |
| **Universal Wizard** | | |
| Wizard shell | `web/src/components/wizard/` (new) | CreationWizard, step components, YAML preview |
| Config generation | `web/src/lib/yaml-builder.ts` (new) | Pure functions converting form state to YAML |
| State store | `web/src/stores/useWizardStore.ts` (new) | Zustand store for wizard form state |
| API endpoints | `internal/api/stack.go` (new) | Config validation, file generation endpoints |
| Header entry | `web/src/components/layout/Header.tsx` | Add "+" button entry point |

### Reusable Components

**Go backend**:
- `pkg/builder/git.go` — `CloneOrUpdate()` with go-git, extensible with `Remote.List`
- `pkg/registry/store.go` — `loadSkills()` recursive discovery, `atomicWriteBytes()` pattern
- `pkg/registry/frontmatter.go` — `ParseSkillMD()` / `RenderSkillMD()`
- `pkg/config/types.go` — `Source` struct pattern, complete Stack schema with YAML tags
- `pkg/config/validate.go` — Full validation with field-level errors, transport rules
- `pkg/config/loader.go` — `SetDefaults()` logic, env var expansion, vault resolution
- `pkg/vault/store.go` — Vault CRUD, encryption, set management

**Web frontend**:
- `Modal.tsx` — Expandable modal with size variants
- `SkillEditor.tsx` — Split-pane form/preview, frontmatter builder, debounced validation
- `VaultPanel.tsx` — Secure password input, reveal/hide toggle, vault CRUD
- `Button.tsx` — Variant system (primary/secondary/ghost/danger)
- `useRegistryStore.ts` — Zustand with subscribeWithSelector pattern
- Design tokens: glass-panel, surface colors, `animate-fade-in-up`

## Market Analysis

### Competitive Landscape

**Skill distribution in developer tools**:
- **Homebrew taps**: Git-cloned repos, `brew update` pulls all. No lock file.
- **Terraform providers**: HCL constraints + `.terraform.lock.hcl` for reproducibility.
- **lazy.nvim**: Git-based plugins with `lazy-lock.json`, `pin: true` per-plugin.
- **skills.sh (Vercel)**: 83k+ agent skills indexed, 8M+ installs. No version pinning.
- **MCP ecosystem**: Fragmented across Smithery, GitHub MCP Registry, mcp.run. No standard versioning.

**Visual config builders**:
- **Portainer**: Container creation wizard, "Advanced mode" toggle for YAML, dual-mode env editor.
- **Rancher**: Form/YAML bidirectional toggle — the gold standard. Accordion sections, progressive disclosure.
- **Backstage (Spotify)**: JSON Schema-driven template wizard with multi-step forms, review step. Enterprise-grade.
- **n8n**: Operation-driven field switching — single dropdown reconfigures entire form.
- **Render**: "Generate Blueprint" reverse-engineers config from UI. Auto-strips secrets.
- **Terraform Cloud**: Auto-scans config, generates form for only missing values.

### Spec-Driven Development Tools

- **Amazon Kiro**: Full SDD IDE with Requirements → Design → Tasks pipeline. Produces 3 markdown files per spec. Sidebar-integrated spec management. Criticized for verbosity and slowness.
- **GitHub Spec Kit**: Agent-agnostic slash commands (/specify, /plan, /tasks, /implement). All-markdown output. Criticized for 3:1 doc-to-code ratio, 10x slower than iterative development.
- **Tessl**: Spec-as-source model where code is generated output. One spec per code file. Private beta, $500M+ valuation.
- **OpenSpec**: Approval gates before implementation. Spec deltas with visual diff markers. Lighter output than Spec Kit.
- **Backstage Scaffolder**: JSON Schema-driven template wizard with multi-step forms, review step, progress logging. The enterprise reference for guided spec-to-resource workflows.

### Market Positioning

**Spec Foundation**: **Differentiate**. No MCP orchestration tool has a validate/plan/apply workflow. gridctl would be the first to bring the Terraform spec lifecycle pattern to AI agent infrastructure.

**Visual Spec Builder**: **Catch up + Differentiate**. Form-to-YAML is table stakes in infrastructure (Portainer, Rancher). The SDD framing (recipes as spec templates, review as validation gate, output as Stack Spec directory) pushes beyond parity. No SDD tool offers a visual spec builder — this is an open gap identified in research.

**Spec Dependencies**: **Leap ahead**. No tool offers version-pinned, lock-file-backed skill imports. First-mover in "dependency management for agent skills."

**Overall SDD positioning**: gridctl avoids the common SDD pitfalls. The spec IS the YAML (no 3:1 doc-to-code ratio). Validation is fast and continuous (no 8-13 minute step times). The workflow right-sizes (quick mode for simple stacks, full spec mode for complex ones).

### Ecosystem Support

**Backend libraries**:
- `go-git/go-git/v5` (already in project) — Clone, fetch, `Remote.List` for efficient update checks
- `Masterminds/semver/v3` — Semver constraint parsing
- `gopkg.in/yaml.v3` (already in project) — Config/lock file I/O, YAML marshaling for config generation

**Frontend libraries** (recommended additions):
- `react-hook-form` + `zod` — Form state management + validation for wizard
- `@monaco-editor/react` + `monaco-yaml` — YAML preview/edit with autocomplete
- `js-yaml` — Serialize form state to YAML in browser

### Demand Signals

- 350k+ agent skills with no standard distribution mechanism
- Enterprise adoption of agent skills: Stripe, Notion, Canva, Zapier, Microsoft
- Form-to-YAML is the expected UI pattern for infrastructure tools (Portainer, Rancher, K8s Dashboard)
- RedMonk survey: developers want "agents that remember institutional knowledge and enforce consistent standards"

## User Experience

### Feature A: Spec Foundation

**CLI surface**:
- `gridctl validate [stack.yaml]` — Validate the full Stack Spec (config + skill references + vault refs) without deploying. Returns structured field-level errors. Exit code 0/1 for CI integration.
- `gridctl plan [stack.yaml]` — Compare spec against current running state. Show diff of what will change (new servers, updated images, removed resources, config changes). Require confirmation before applying. Follows the Terraform plan → apply pattern.
- `gridctl export [--output dir]` — Generate a complete Stack Spec directory from the current running deployment. Reverse-engineers spec from running state.

**Web UI**:
- **Spec tab** in bottom panel (alongside Logs, Metrics): Shows current `stack.yaml` with syntax highlighting and live validation annotations (green/amber/red markers). "Compare to running" toggle highlights drift.
- **Spec health indicators** in status bar: "Spec: Valid" / "Spec: 2 warnings" / "Spec: 3 errors" with color coding. Clickable to open Spec tab.
- **Drift detection overlay** on canvas: Toggle that highlights differences between declared spec and running state. Nodes in spec but not running show as ghost/dashed outlines. Nodes running but not in spec show with warning badges.
- **Spec diff on reload**: When `--watch` detects config changes, show a diff modal before applying. This is the spec-first review gate.

### Feature B: Remote Skill Import (Spec Dependencies)

**CLI surface**: `gridctl skill` subcommand tree (add/list/update/remove/pin/info/try). Fits existing `vault` pattern.

**Configuration**: `~/.gridctl/skills.yaml` for sources + `skills.lock.yaml` for reproducibility. `.origin.json` sidecar per imported skill (keeps SKILL.md spec-clean).

**Version constraints**: Sources support SemVer constraints (e.g., `^1.2.0`, `~2.0`) in `skills.yaml`. gridctl resolves constraints against git tags, pinning the exact matching SHA in the lock file. This mirrors Terraform/npm patterns for reproducible yet flexible version management.

**Update flow**: Non-blocking background check on `gridctl deploy` → state file → notification on next command. Configurable interval (default 24h). Disable via env var or per-source config.

**Novel UX**:
1. **"Try Before You Install"** — Ephemeral skill activation with auto-cleanup timer
2. **"Skill Lineage" diffs** — Show workflow changes vs metadata changes on update
3. **"Skill Composition Graph"** — Overlay tool requirements on ReactFlow DAG
4. **"Skill Subscriptions"** — Subscribe to repos as capability packs with grouped changelogs
5. **"Skill Fingerprinting"** — SHA-256 trust-on-first-use with behavioral change detection
6. **"Security Scanning"** — Static analysis on SKILL.md workflows and scripts before import to flag potentially malicious shell commands or unauthorized network access

### Feature C: Visual Spec Builder (Universal Creation Wizard)

**Entry points**:
1. Header "+" button (always visible, opens wizard modal)
2. Empty-state canvas CTA ("Create your first stack")
3. Sidebar quick-add links (context-aware, pre-targeted to resource type)

**Wizard architecture**: Single-column accordion form with live YAML preview sidebar (split-pane). Not paginated steps — users can jump freely between sections.

**Resource Type Picker → Template Cards → Guided Form**:
- Stack: "Blank", "Single Server", "Multi-Agent", "Platform Integration"
- MCP Server: radio cards for 6 types → dynamic field switching per type
- Agent: Container vs Headless Runtime vs A2A
- Resource: Presets (PostgreSQL, Redis, MySQL) or Custom
- Skill: Routes to SkillEditor or Skills Builder (import from GitHub)
- Secret: Inline vault form

**Dynamic form behavior**: Transport/type selection reconfigures the entire form section. `stdio` → port hidden, `http` → port required. Data preserved on type switch (no loss on accidental click).

**Secrets integration**: Every env value input gets a vault popover — browse existing secrets or create new → auto-inserts `${vault:KEY}` reference. Generated YAML never contains raw secrets.

**Expert mode**: Form/YAML segmented control toggle (Rancher pattern). Bidirectional sync with parse error handling.

**Real-time validation**: The live YAML preview connects to the backend `Validate()` endpoint (debounced), showing inline linting errors in the preview panel as the user fills the form — not just at the review step. This shifts validation left and prevents error accumulation.

**Drafts**: Wizard state persists beyond session storage with explicit named drafts. Users can save complex multi-agent stack configurations, switch contexts, and resume days later. Drafts stored in `~/.gridctl/cache/wizard-drafts/`.

**Review step**: Validation panel (green/amber/red), resource summary, "Generate stack.yaml" action with output options (download, clipboard, deploy immediately).

**Novel UX**:
1. **Wiring Mode** — Drag connections on ReactFlow canvas to wire agents to servers, auto-updating `uses[]`
2. **Stack Recipes with Live Diffing** — Templates as interactive diffs, see customizations vs original
3. **Secret Heatmap Overlay** — Canvas view showing which nodes share vault secrets
4. **Transport Compatibility Advisor** — Proactive mismatch warnings teaching the transport model
5. **Stack Timeline Replay** — Scrubber to replay deployment state changes on canvas

## Feasibility

### Value Breakdown
| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Critical | No validate/plan workflow + distribution gap (skills) + YAML barrier (wizard) are the top friction points |
| User impact | Broad + Deep | Every user benefits; transforms gridctl from CLI-only to spec-driven visual+CLI platform |
| Strategic alignment | Core mission | "Stack as Code" is literally spec-driven development. These features make that explicit. |
| Market positioning | Leap ahead | First MCP tool with Terraform-style validate/plan, version-pinned skill imports, AND visual spec builder |
| SDD positioning | Differentiate | Avoids common SDD pitfalls (spec IS the YAML, no doc-to-code ratio bloat, fast validation) |

### Cost Breakdown
| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Moderate | Additive code; foundations exist. validate/plan reuse existing config.Validate() and state comparison |
| Effort estimate | Very Large | Three major features sharing infrastructure. Phased delivery makes it manageable |
| Risk level | Low-Medium | Spec foundation: low risk (read-only commands). Skills import: network/security risks (mitigated). Wizard: purely additive UI |
| Maintenance burden | Moderate | Schema changes require wizard form updates; git hosting edge cases for skill import |

## Recommendation

**Build**. All three features are high-value, strategically aligned, and share infrastructure. The spec foundation reframes gridctl's identity ("Stack as Code" → "Spec-Driven Stack Development"), the wizard is one mode of spec authoring, and skill import is spec dependency management. Build as a **unified system** with phased delivery:

- **Phase 1 — Spec Foundation**: `gridctl validate` command, `gridctl plan` command, spec health indicators in web UI status bar, Spec tab in bottom panel (syntax-highlighted stack.yaml with live validation)
- **Phase 2 — Spec Dependencies**: `gridctl skill` CLI (add/list/update/remove) + `skills.yaml` + `skills.lock.yaml` + origin tracking + SemVer constraint resolution + security scanning
- **Phase 3 — Visual Spec Builder Shell**: Universal Wizard shell + MCP Server creation form (most complex, highest immediate value) + real-time backend validation + named drafts
- **Phase 4 — Stack Spec Composition**: Stack composition wizard + YAML preview + expert mode toggle + output as complete Stack Spec directory
- **Phase 5 — Spec Dependencies UI**: Skills Builder integrated as wizard mode (import from GitHub, 4-step flow)
- **Phase 6 — Agent + Resource Spec Forms**: Agent + Resource creation forms with presets, vault-integrated secrets
- **Phase 7 — Spec Monitoring**: Background auto-update checker, update notifications, drift detection overlay on canvas, spec diff on reload
- **Phase 8 — Spec-Aware Canvas + Novel UX**: Spec mode toggle on canvas (ghost nodes for undeployed declarations), wiring mode, recipes, secret heatmap, `gridctl export`, timeline replay

## References

### Spec-Driven Development
- Thoughtworks SDD analysis: https://www.thoughtworks.com/en-us/insights/blog/agile-engineering-practices/spec-driven-development-unpacking-2025-new-engineering-practices
- Martin Fowler — SDD tools comparison (Kiro, Spec Kit, Tessl): https://martinfowler.com/articles/exploring-gen-ai/sdd-3-tools.html
- GitHub Blog — Spec-driven development with Spec Kit: https://github.blog/ai-and-ml/generative-ai/spec-driven-development-with-ai-get-started-with-a-new-open-source-toolkit/
- Addy Osmani — How to write a good spec for AI agents: https://addyosmani.com/blog/good-spec/
- Amazon Kiro specs documentation: https://kiro.dev/docs/specs/
- OpenSpec: https://openspec.dev/
- Augment Code — SDD guide: https://www.augmentcode.com/guides/what-is-spec-driven-development
- Scott Logic — Spec Kit review (critical): https://blog.scottlogic.com/2025/11/26/putting-spec-kit-through-its-paces-radical-idea-or-reinvented-waterfall.html
- Stack Overflow 2025 survey (72% say vibe coding is not professional): https://survey.stackoverflow.co/2025/ai

### Skills & Distribution
- agentskills.io specification: https://agentskills.io/specification
- skills.sh (Vercel): de facto package manager for agent skills
- awesome-agent-skills: https://github.com/heilcheng/awesome-agent-skills
- FluxCD source-controller: Go reference for git-based dependency reconciliation
- go-git v5: https://github.com/go-git/go-git
- Masterminds/semver: https://github.com/Masterminds/semver
- lazy.nvim lock file: https://github.com/folke/lazy.nvim
- Terraform lock file: https://developer.hashicorp.com/terraform/language/files/dependency-lock
- Helm Chart.lock: https://helm.sh/docs/helm/helm_dependency/
- RedMonk agentic IDE survey: https://redmonk.com/kholterhoff/2025/12/22/10-things-developers-want-from-their-agentic-ides-in-2025/
- Backstage Scaffolder: https://backstage.spotify.com/docs/portal/core-features-and-plugins/scaffolder
- Rancher Form/YAML toggle: industry gold standard for config builder UX
- react-hook-form: https://react-hook-form.com/
- @monaco-editor/react: https://www.npmjs.com/package/@monaco-editor/react
- monaco-yaml: https://github.com/remcohaszing/monaco-yaml
- NNG Wizard UX: https://www.nngroup.com/articles/wizards/
