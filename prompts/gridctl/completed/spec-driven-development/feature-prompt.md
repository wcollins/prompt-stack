# Feature Implementation: Spec-Driven Stack Development

## Context

**gridctl** is a Go CLI tool (cobra framework) with an embedded React 19 SPA that orchestrates MCP servers, agents, and resources via a unified gateway. The tech stack is:

- **Backend**: Go 1.24, cobra CLI, net/http server, go-git v5, yaml.v3
- **Frontend**: React 19, TypeScript 5.9, Zustand 5, React Router 7, TailwindCSS 4, Vite 7
- **Testing**: Go test + testify (backend), Vitest + React Testing Library (frontend)
- **State**: `~/.gridctl/` for persistent state (state files, vault, logs, registry)
- **Registry**: `~/.gridctl/registry/skills/` containing SKILL.md files per agentskills.io spec
- **Design System**: "Obsidian Observatory" theme — glass-panel, amber primary (#f59e0b), teal secondary (#0d9488), purple tertiary (#8b5cf6)

The project already has:
- Full skill registry with CRUD, validation, workflow execution (`pkg/registry/`)
- Git clone/update utilities via go-git (`pkg/builder/git.go`)
- `Source` struct pattern for external git resources (`pkg/config/types.go`)
- Complete config validation with transport-specific rules (`pkg/config/validate.go`)
- `SetDefaults()` for auto-inference (`pkg/config/loader.go`)
- Vault CRUD with encryption (`pkg/vault/store.go`, `internal/api/vault.go`)
- REST API for registry operations (`internal/api/registry.go`)
- React components: Modal (expand/popout), SkillEditor (823-line multi-step editor), VaultPanel (secure secrets CRUD), MetadataEditor (key-value), Button (variant system)
- Zustand stores: useRegistryStore, useStackStore, useUIStore, useVaultStore, useAuthStore

## Evaluation Context

- **Spec-driven development**: SDD is emerging as a key 2025-2026 engineering practice (Thoughtworks, GitHub, Amazon Kiro). gridctl already IS spec-driven — `stack.yaml` declares intent and gridctl realizes it. This feature set makes that identity explicit with validate/plan/monitor tooling, a visual spec builder, and spec dependency management. The key advantage: gridctl's spec IS the YAML (no 3:1 doc-to-code ratio bloat that plagues Spec Kit and Kiro).
- **Market insight**: agentskills.io has 350k+ skills but no distribution standard. No MCP tool has a Terraform-style validate/plan/apply workflow. Visual spec builders are an open gap — no SDD tool offers structured form-based spec creation.
- **UX decisions**: Rancher's Form/YAML bidirectional toggle is the gold standard; Backstage's template-first wizard is the enterprise reference. Terraform's plan → apply pattern is the spec lifecycle reference. Living specs beat static specs (drift detection, not just one-time generation).
- **Risk mitigations**: Non-blocking update checks (gh CLI pattern), `.origin.json` sidecar for origin tracking (keeps SKILL.md spec-clean), generated YAML never contains raw secrets (only `${vault:KEY}` references).
- Full evaluation: `plan/remote-skill-import/feature-evaluation.md`

## Feature Description

Three interconnected features that make spec-driven development a first-class citizen in gridctl:

### Feature A: Spec Foundation — Validate, Plan, Monitor
New CLI commands and web UI features that treat `stack.yaml` as a living specification with a full lifecycle. `gridctl validate` checks the full Stack Spec without deploying. `gridctl plan` compares the spec against current running state and shows a diff (Terraform pattern). The web UI gains a Spec tab, drift detection overlays, and spec health indicators.

### Feature B: Visual Spec Builder (Universal Creation Wizard)
A wizard UI that authors stack specifications through guided forms. Template-first entry (recipes), dynamic forms that reconfigure based on transport/server type selection, live YAML preview sidebar with real-time backend validation, Form/YAML expert mode toggle, and inline vault integration for secrets. The review step is a spec validation gate.

### Feature C: Spec Dependency Management (Remote Skill Import)
Users declare skill dependencies in `skills.yaml` or via `gridctl skill add`. gridctl resolves dependencies, clones repos, discovers SKILL.md files, imports to local registry. A `skills.lock.yaml` pins exact commit SHAs. SemVer constraints supported. Security scanning before import. Auto-update checks run non-blocking on launch.

**Combined**: The Skills Builder wizard (browsing/importing skill dependencies) is one mode of the Visual Spec Builder alongside stack/server/agent/resource spec authoring. The spec foundation provides the validate/plan lifecycle that both the wizard and CLI share.

## Requirements

### Functional Requirements

#### Spec Foundation (CLI)

S1. `gridctl validate [stack.yaml]` — Validate the full Stack Spec (config schema, transport rules, vault references, skill references) without deploying. Return structured field-level errors with file/line context. Exit code 0 (valid), 1 (errors), 2 (warnings only). Support `--format json` for CI integration.
S2. `gridctl plan [stack.yaml]` — Load spec, compare against current running state (via `~/.gridctl/state/`), and display a structured diff: added servers/agents/resources, removed items, changed configuration fields, image updates. Require explicit confirmation (`-y` to auto-approve) before applying changes via deploy.
S3. `gridctl export [--output dir]` — Generate a complete Stack Spec directory from the current running deployment. Reverse-engineer `stack.yaml` from gateway status + container inspection. Include `skills.yaml` if remote skills are active. Never include raw secrets (use `${vault:KEY}` placeholders).

#### Spec Foundation (API)

S4. `POST /api/stack/validate` — Validate a stack YAML body and return field-level errors with severity (error/warning/info). Used by both the review step and real-time YAML preview validation in the wizard.
S5. `GET /api/stack/plan` — Compare current spec against running state. Return structured diff (added/removed/changed items).
S6. `GET /api/stack/health` — Return spec health summary: validation status (valid/warnings/errors), drift status (in-sync/drifted with details), dependency status (all skills resolved/missing).
S7. `GET /api/stack/spec` — Return the current stack.yaml content for display in the Spec tab.

#### Spec Foundation (Web UI)

S8. **Spec tab** in bottom panel (alongside Logs, Metrics): Shows current `stack.yaml` with syntax highlighting. Live validation annotations (green/amber/red markers per line). "Compare to running" toggle that highlights drift inline.
S9. **Spec health indicator** in status bar: "Spec: Valid" / "Spec: 2 warnings" / "Spec: 3 errors" with color coding. Clickable to open Spec tab.
S10. **Drift detection overlay** on canvas: Toggle button in canvas controls. Nodes declared in spec but not running show as ghost/dashed outlines. Nodes running but removed from spec show with warning badge. Connections from `uses[]` show even when agents aren't running.
S11. **Spec diff on reload**: When config reload is triggered (via button or `--watch`), show a diff modal comparing old spec vs new spec before applying. User can approve or cancel.

#### Remote Skill Import (CLI + Backend)

1. `gridctl skill add <repo-url> [--ref <ref>] [--path <path>] [--no-activate]` — Clone repo, discover SKILL.md files, import into local registry, write `.origin.json` sidecar, update `skills.lock.yaml`
2. `gridctl skill list [--remote] [--format json]` — List all skills with source origin and update status
3. `gridctl skill update [name] [--dry-run] [--force]` — Fetch latest from source repos, show diff, apply updates
4. `gridctl skill remove <name>` — Remove imported skill, origin file, and lock entry
5. `gridctl skill pin <name> <ref>` — Pin to specific version/ref, disable auto-update
6. `gridctl skill info <name>` — Show origin, current ref, last checked, available update
7. `gridctl skill try <repo-url/skill-name> [--duration 10m]` — Ephemeral import with auto-cleanup
8. Parse `~/.gridctl/skills.yaml` defining sources with: name, repo, ref, path, auto_update toggle, update_interval
9. Support global defaults section for auto_update (default: true) and update_interval (default: 24h)
9a. Support SemVer constraints (e.g., `^1.2.0`, `~2.0`) in the `ref` field of `skills.yaml`. Resolve constraints against git tags using `Masterminds/semver/v3`, pin the exact matching tag's commit SHA in the lock file. Exact refs (branches, commits, tags) continue to work as before.
9b. Perform security scanning on SKILL.md workflow steps and referenced scripts before import. Flag potentially dangerous patterns (unrestricted shell commands, network access, file system writes outside expected paths). Warn the user and require `--trust` flag or interactive confirmation to proceed.
10. `skills.lock.yaml` records resolved commit SHA, fetch timestamp, content hash per source, and per-skill checksums
11. `.origin.json` sidecar per imported skill: repo URL, ref, path, import timestamp, content hash
12. Non-blocking background update check during `gridctl deploy` using go-git `Remote.List()`
13. Write results to `~/.gridctl/cache/skill-updates.yaml`, display on next CLI command
14. Respect `GRIDCTL_NO_SKILL_UPDATE_CHECK=1` and `CI=true` to disable checks

#### Remote Skill Import (API)

15. `GET /api/skills/sources` — List configured skill sources with update status
16. `POST /api/skills/sources` — Add a new skill source (triggers clone + import)
17. `DELETE /api/skills/sources/{name}` — Remove a skill source
18. `POST /api/skills/sources/{name}/check` — Trigger update check for a source
19. `POST /api/skills/sources/{name}/update` — Apply available updates
20. `GET /api/skills/sources/{name}/preview` — Preview skills in a source without importing
21. `GET /api/skills/updates` — Get pending update summary across all sources

#### Visual Spec Builder (UI Shell)

22. Header "+" button opens wizard as full-size Modal
23. Empty-state canvas CTA ("Create your first stack") opens wizard pre-set to Stack mode
24. Sidebar quick-add links open wizard pre-targeted to resource type
25. Resource Type Picker: 6 glass-panel cards (Stack, MCP Server, Agent, Resource, Skill, Secret)
26. Template selection per resource type with 3-line YAML preview snippets
27. Single-column accordion form with sticky YAML preview sidebar (split-pane, 55%/45%)
28. Live YAML preview updates on every keystroke (debounced 150ms)
28a. Live YAML preview connects to backend `POST /api/stack/validate` (debounced 500ms) for real-time validation. Inline linting errors appear in the preview panel as the user fills the form, not just at the review step. Validation errors shown as amber/red annotations alongside the YAML.
29. Form/YAML segmented control toggle with bidirectional sync (Rancher pattern)
30. Review section with validation panel (green/amber/red), resource summary
31. Output options: download file, copy to clipboard, deploy immediately
32. Wizard state persists across close/reopen within a session (Zustand)
32a. Explicit named drafts for long-running wizard sessions. Users can save, list, and resume drafts stored in `~/.gridctl/cache/wizard-drafts/`. API endpoints: `GET /api/wizard/drafts`, `POST /api/wizard/drafts`, `DELETE /api/wizard/drafts/{id}`. Drafts persist across browser sessions.

#### MCP Server Form (Most Complex)

33. Section 1 "Identity": name (kebab-case enforced), description (optional)
34. Section 2 "Server Type": radio card group — Container, Source, External URL, Local Process, SSH, OpenAPI (mutually exclusive)
35. Section 3 "Type-Specific Config": dynamic fields based on selection:
    - Container: image (text + presets dropdown), port, transport (http/stdio/sse), command
    - Source: source.type (git/local), url, ref (default: main), path, dockerfile (default: Dockerfile), port, transport
    - External URL: url (validated), transport (http/sse only — stdio disabled)
    - Local Process: command (array builder), transport locked to stdio, no port
    - SSH: host, user, port (default: 22), identityFile, command
    - OpenAPI: spec (URL/path), baseUrl, auth sub-form, operations include/exclude
36. Section 4 "Environment & Secrets": key-value editor with vault popover per value
37. Section 5 "Advanced": tools whitelist, output_format select, build_args, network

#### Stack Composition Form

38. Section 1 "Identity": name (required), version (locked to "1")
39. Section 2 "Gateway" (optional, collapsible): allowed_origins, auth, code_mode, output_format
40. Section 3 "Network": simple mode (name, driver) with advanced toggle for multi-network
41. Section 4 "Secrets": variable set references (secrets.sets[])
42. Sections 5-7 "MCP Servers / Agents / Resources": repeating groups with inline creation sub-forms

#### Agent Form

43. Agent type radio cards: Container, Headless Runtime
44. Container: image or source fields (same pattern as MCP Server)
45. Headless: runtime select, prompt textarea (required)
46. Tool access: checkboxes for available MCP servers with per-tool filtering expandable
47. A2A configuration toggle with skills sub-form

#### Resource Form

48. Preset cards: PostgreSQL, Redis, MySQL, MongoDB, Custom
49. Presets pre-fill image, default env vars, default port mapping
50. Fields: name, image, env (key-value), ports (array), volumes (array)

#### Secrets Integration (Within Wizard)

51. Every env value input has a vault popover icon (KeyRound from lucide-react)
52. Popover shows filterable list of existing vault secrets
53. "Create New" in popover for inline key+value creation
54. Auto-inserts `${vault:KEY}` reference into the field
55. Generated YAML never contains raw secret values

#### Skills Builder (Wizard Mode)

56. "Import from GitHub" entry in resource type picker routes to 4-step flow
57. Step 1 "Add Source": URL input with repo metadata validation, recent sources
58. Step 2 "Browse & Select": two-column list+preview, checkbox batch selection, diff tab for updates
59. Step 3 "Configure": per-skill accordion with state selector (auto-skip if not needed)
60. Step 4 "Review & Install": summary table, install progress, success links
61. Update badges on skills in RegistrySidebar when updates available
62. "Update All" batch action, per-skill "Update" button with diff pre-loaded

#### Novel UX Features

63. **Wiring Mode**: Drag connections on ReactFlow canvas to wire agents to servers, auto-updating `uses[]`
64. **Stack Recipes**: Templates as interactive diffs showing customizations vs original
65. **Secret Heatmap Overlay**: Canvas toggle showing which nodes share vault secrets
66. **Transport Compatibility Advisor**: Proactive mismatch warnings during wizard form filling
67. **Try Before Install**: Ephemeral skill activation with countdown timer and auto-cleanup
68. **Skill Fingerprinting**: SHA-256 content hashing with behavioral change detection on update
69. **Stack Timeline Replay**: Scrubber to replay deployment state changes on canvas

### Non-Functional Requirements

S-NFR1. `gridctl validate` must complete in <500ms for typical stacks (no network calls, no container inspection)
S-NFR2. `gridctl plan` must complete in <2s (reads state files + optionally queries Docker for running container status)
S-NFR3. Spec health API endpoint must respond in <100ms (cached validation result, refreshed on config change)
S-NFR4. Drift detection compares declared spec against `~/.gridctl/state/` and optional Docker API queries. Gracefully degrade if Docker is unavailable (show "drift unknown").
S-NFR5. Spec tab YAML rendering must handle files up to 10,000 lines without jank (virtualized rendering or chunked loading)
70. Auto-update check must not block CLI startup (background goroutine)
71. Lock file and origin file writes must be atomic (existing `atomicWriteBytes` pattern)
72. Git operations handle network failures gracefully (log warning, continue with cached)
73. Imported skills must pass `ValidateSkillFull()` before acceptance
73a. Imported skills must pass security scanning before acceptance — flag dangerous patterns in workflow steps (unrestricted `exec`, `curl | sh`, broad filesystem writes). Require `--trust` flag or interactive confirmation for flagged skills.
73b. SemVer constraints in `skills.yaml` resolved against git tags at fetch time. Lock file records the resolved tag and commit SHA. Constraint resolution uses `Masterminds/semver/v3`.
74. Directory traversal prevention for repo paths (extend `safeFilePath` pattern)
75. Private repo support via `GITHUB_TOKEN` env var
76. Shallow clones (`Depth: 1`) by default to minimize bandwidth
77. Wizard YAML preview debounced at 150ms to prevent jank
78. Form data preserved on type switch (no data loss on accidental selection change)
79. Wizard state persists in Zustand with session storage for close/reopen recovery

### Out of Scope

- Centralized skill registry/marketplace (git-based distribution only)
- Skill publishing from gridctl (users publish via git push)
- Full bidirectional YAML editing with lossless round-tripping (form→YAML is primary; YAML→form is best-effort with error handling)
- Visual drag-and-drop canvas editor for building stacks (wiring mode is connection-only, not full visual builder)
- Auto-detection of available Docker images or running containers for wizard suggestions
- Separate spec documents alongside YAML (no requirements.md/design.md/tasks.md — the YAML IS the spec)
- Spec-as-source model where code is generated and non-editable (Tessl pattern — users always own their YAML)
- Multi-user collaborative spec editing (single-user authoring; teams collaborate via git)

## Architecture Guidance

### Recommended Approach

**Backend — Spec Foundation**: Extend existing `pkg/config/` with a `plan.go` for spec-vs-state comparison. Create `cmd/gridctl/validate.go` and `cmd/gridctl/plan.go` following the `vault.go` cobra pattern. Add spec health and plan endpoints to `internal/api/stack.go`.

```
pkg/config/
  plan.go        — SpecPlan: compare declared spec against running state, produce structured diff
  health.go      — SpecHealth: aggregate validation + drift + dependency status
```

```
cmd/gridctl/
  validate.go    — `gridctl validate` cobra command
  plan.go        — `gridctl plan` cobra command
  export.go      — `gridctl export` cobra command
```

**Backend — Spec Dependencies**: Create a new `pkg/skills/` package for remote skill management. Create new API handlers in `internal/api/skills.go` and `internal/api/stack.go`.

```
pkg/skills/
  config.go      — SkillSource types, skills.yaml parsing, SemVer constraint resolution
  lockfile.go    — Lock file read/write/update
  origin.go      — .origin.json sidecar management
  remote.go      — Clone, fetch, update check via Remote.List
  importer.go    — Import orchestration (discover, validate, copy to registry)
  scanner.go     — Security scanning for SKILL.md workflows (flag dangerous patterns)
  updater.go     — Background goroutine, state file, notification
```

**Frontend — Spec Visibility**: Add spec components to the existing layout structure.

```
web/src/components/spec/
  SpecTab.tsx              — Bottom panel tab: syntax-highlighted stack.yaml with validation annotations
  SpecHealthBadge.tsx      — Status bar indicator: "Spec: Valid" / "Spec: 2 warnings"
  SpecDiffModal.tsx        — Modal showing old-vs-new spec diff on reload
  DriftOverlay.tsx         — Canvas overlay: ghost nodes, warning badges for drift
```

```
web/src/stores/useSpecStore.ts  — Zustand store for spec content, validation results, drift state, health
```

**Frontend — Visual Spec Builder**: Create a `web/src/components/wizard/` directory with the wizard shell and step components. Create `web/src/lib/yaml-builder.ts` for form-to-YAML conversion.

```
web/src/components/wizard/
  CreationWizard.tsx        — Modal shell + resource type picker + step navigation
  YAMLPreview.tsx           — Live YAML preview panel with syntax highlighting + inline validation annotations
  ExpertModeToggle.tsx      — Form/YAML segmented control
  TemplateGrid.tsx          — Template card selection grid
  SecretsPopover.tsx        — Inline vault picker for env values
  DraftManager.tsx          — Save/load/delete named wizard drafts
  steps/
    MCPServerForm.tsx       — 6-variant dynamic server form
    StackForm.tsx           — Stack composition with nested resource forms
    AgentForm.tsx           — Agent creation (container/headless/A2A)
    ResourceForm.tsx        — Resource creation with presets
    SkillImportWizard.tsx   — 4-step skill import flow
    ReviewStep.tsx          — Validation + summary + generate action
```

### Key Files to Understand

| File | Why |
|------|-----|
| `pkg/config/validate.go` | All validation rules — foundation for `gridctl validate` and real-time wizard validation |
| `pkg/state/state.go` | Daemon state management — foundation for `gridctl plan` spec-vs-state comparison |
| `cmd/gridctl/deploy.go` | Deploy flow — `gridctl plan` follows this pattern but stops before applying |
| `pkg/registry/store.go` | Skill CRUD, directory walking, mutex locking, `atomicWriteBytes` |
| `pkg/registry/types.go` | AgentSkill struct, ItemState, validation |
| `pkg/registry/frontmatter.go` | SKILL.md parse/render — reuse for skill discovery |
| `pkg/builder/git.go` | `CloneOrUpdate` — extend with `Remote.List` |
| `pkg/config/types.go` | Full Stack schema with YAML tags — the source of truth for wizard forms |
| `pkg/config/validate.go` | All validation rules — replicate in wizard for real-time field validation |
| `pkg/config/loader.go` | `SetDefaults()` — replicate in wizard for auto-inference |
| `pkg/vault/store.go` | Vault CRUD — wizard secrets integration |
| `cmd/gridctl/vault.go` | Cobra subcommand tree pattern for `skill` commands |
| `internal/api/api.go` | Router setup, handler registration, middleware patterns |
| `internal/api/registry.go` | REST endpoint patterns, file write via API |
| `internal/api/vault.go` | Vault API — used by wizard SecretsPopover |
| `web/src/components/registry/SkillEditor.tsx` | Split-pane, frontmatter form, debounced validation, tab modes |
| `web/src/components/vault/VaultPanel.tsx` | Secure input, reveal/hide, vault CRUD patterns |
| `web/src/components/ui/Modal.tsx` | Modal sizes, expand/popout — wizard container |
| `web/src/lib/api.ts` | `fetchJSON`, `mutateJSON`, auth headers — API call patterns |
| `web/src/types/index.ts` | Transport, MCPServerStatus, AgentStatus — TypeScript types for forms |
| `web/src/stores/useRegistryStore.ts` | Zustand store pattern to follow |
| `web/src/index.css` | Design system tokens, animations, glass-panel styles |
| `web/tailwind.config.js` | Component sizing, border radius, custom shadows |

### Integration Points

**CLI** (`cmd/gridctl/root.go`): Add `validateCmd`, `planCmd`, `exportCmd`, and `skillCmd` following `vaultCmd` pattern.

**Deploy flow** (`cmd/gridctl/deploy.go`): Start background update checker after deploy. If stack has `remote_skills:`, ensure imported before registry loads.

**API router** (`internal/api/api.go`): Register `/api/stack/` (validate, plan, health, spec), `/api/skills/`, and `/api/wizard/` route groups.

**Bottom panel** (`web/src/components/layout/BottomPanel.tsx`): Add "Spec" tab alongside Logs and Metrics.

**Status bar** (`web/src/components/layout/StatusBar.tsx`): Add spec health badge.

**Canvas controls** (`web/src/components/graph/Canvas.tsx`): Add drift overlay toggle button.

**Registry store** (`pkg/registry/store.go`): After `Load()`, check for `.origin.json` to populate origin metadata. No Store interface changes — imported skills are regular SKILL.md files.

**Header** (`web/src/components/layout/Header.tsx`): Add "+" IconButton triggering wizard modal.

**Sidebar** (`web/src/components/layout/Sidebar.tsx`): Add quick-add ghost buttons and update badges for skills.

**Config types** (`pkg/config/types.go`): Add optional `RemoteSkills []SkillSource` to Stack struct.

### Reusable Components

**Backend — use directly**:
- `builder.CloneOrUpdate()` for clone/update operations
- `registry.ParseSkillMD()` for skill discovery in cloned repos
- `registry.ValidateSkillFull()` for imported skill validation
- `config.Validate()` for server-side config validation endpoint
- `config.SetDefaults()` logic — replicate in `yaml-builder.ts` for client-side defaults
- `vault.Store` for secrets CRUD from wizard API

**Frontend — use directly**:
- `Modal` (size="full") for wizard container
- `SkillEditor` split-pane pattern for form/preview layout
- `VaultPanel` patterns for SecretsPopover
- `MetadataEditor` pattern for all key-value inputs (env, build_args)
- `Button` variants for wizard actions
- `showToast` for success/error notifications
- `useVaultStore` for secrets state in wizard

## UX Specification

### Spec Foundation UX

#### Spec Tab (Bottom Panel)

```
User clicks "Spec" tab in bottom panel →
  Tab shows current stack.yaml with syntax highlighting (same style as code blocks in logs)
  Left margin: line numbers
  Right margin: validation annotations per line
    Green dot: valid field
    Amber dot: warning (e.g., deprecated field, missing optional)
    Red dot: error (e.g., invalid transport, missing required field)
  Hover annotation: shows error/warning message in tooltip
  Top bar: "Compare to running" toggle
    When active: lines that differ from running state highlighted with amber background
    Added lines: green left border
    Removed lines (in running but not in spec): shown as strikethrough ghost lines
```

#### Spec Health Badge (Status Bar)

```
Status bar (bottom of screen) shows:
  [green dot] "Spec: Valid" — all validations pass, no drift
  [amber dot] "Spec: 2 warnings" — warnings present, no errors
  [red dot] "Spec: 3 errors" — validation errors present
  Click badge → opens Spec tab in bottom panel
  Badge updates in real-time via polling (same interval as status refresh)
```

#### Spec Diff Modal (On Reload)

```
User clicks "Reload Config" button (or --watch triggers) →
  Modal appears: "Configuration Changed"
  Split-pane diff view: left=current (running), right=new (from disk)
  Changes highlighted: green (added), red (removed), amber (modified)
  Bottom bar: "Apply Changes" (primary button) | "Cancel" (secondary)
  If validation errors in new spec: "Apply" button disabled, errors shown below diff
```

#### Drift Overlay (Canvas)

```
User clicks drift toggle in canvas controls (new button: GitCompare icon) →
  Canvas enters "drift mode" with subtle amber tint on background
  Nodes in spec but NOT running: rendered as dashed-border ghost nodes with "Not deployed" label
  Nodes running but NOT in spec: existing node gets amber warning badge with "Not in spec" tooltip
  Connections declared in uses[] but agent not running: shown as dashed edges
  Toggle off → canvas returns to normal monitoring mode
```

### Spec Builder Discovery

- **Header "+" button**: Always visible in action group. Opens wizard at resource type picker.
- **Empty canvas CTA**: When no stack is deployed, centered glass-panel card: "Create your first stack" → opens wizard in Stack mode.
- **Sidebar quick-add**: Ghost buttons below each resource section → opens wizard pre-targeted, skipping type picker.

### Spec Builder Flow

1. **Resource Type Picker**: 6 glass-panel cards in a 3x2 grid. Icon, title, one-line description, existing count badge.
2. **Template Selection**: Template cards with 3-line YAML preview. "Blank" option always available.
3. **Form**: Single-column accordion with sections. Active section auto-scrolls.
4. **YAML Preview**: Right sidebar (45% width) with live-updating, syntax-highlighted YAML.
5. **Review**: Bottom section with validation panel and "Generate" action.

### Server Type Switching (Dynamic Form)

```
User selects "SSH" radio card →
  Fields animate out: image, source, url, openapi fields
  Fields animate in: ssh.host, ssh.user, ssh.port (default 22), ssh.identityFile, command
  Transport badge: "stdio (via SSH)"
  Port field: hidden (not applicable for SSH)
```

Transitions use `transition-all duration-200` with opacity + height animation. Previously entered data preserved in state — switching back restores values.

### Secrets Flow

```
User clicks KeyRound icon on env value input →
  Popover opens anchored to input:
    - Search bar filtering existing vault secrets
    - Secret list: key names with "Select" action
    - "Create New Secret" section at bottom:
        Key input + Value input (password type with eye toggle)
        "Create & Insert" button
  User selects or creates secret →
    ${vault:SECRET_KEY} auto-inserted into env value field
    Popover closes
```

### Expert Mode

```
User clicks "YAML" in segmented control →
  Form slides out, full-width YAML editor slides in
  Current form state serialized to YAML
User edits YAML, clicks "Form" →
  YAML parsed, form fields populated
  If parse error: inline red banner with error, stays in YAML mode
```

### Error States

| Error | Communication |
|-------|---------------|
| Invalid field value | Inline error below field (red text, `text-status-error`) |
| Missing required field | Field border turns amber, error text on "Next" attempt |
| YAML parse error (expert mode) | Red banner above editor with line number |
| Repo not found (skill import) | Red validation badge on URL input with message |
| Name conflict (skill import) | Warning badge in browse step with rename option |
| Network failure (auto-update) | Silent, logged. Status shows "last check failed" |
| Invalid SKILL.md in repo | Yellow badge, skill grayed out, valid ones still importable |

## Implementation Notes

### Conventions to Follow

- **Go packages**: `pkg/skills/` (plural, matches `pkg/metrics/`), CLI command `skill` (singular, matches `vault`)
- **Error wrapping**: `fmt.Errorf("context: %w", err)`, use `errors.Is()` for checks
- **Logging**: `slog` throughout
- **Config tags**: `yaml:"snake_case,omitempty"` and `json:"camelCase,omitempty"`
- **Mutex**: `sync.RWMutex` pattern from `Store`
- **Atomic writes**: `atomicWriteBytes` for lock/origin files
- **API handlers**: `writeJSON()`, `writeJSONError()`, path parsing from `internal/api/registry.go`
- **Frontend stores**: Zustand with `subscribeWithSelector` middleware
- **Frontend components**: TailwindCSS, `lucide-react` icons, glass-panel tokens
- **Form inputs**: `bg-background/60 border border-border/40 rounded-lg px-3 py-2 text-xs focus:outline-none focus:border-primary/50`
- **Tests**: Table-driven Go tests, `testify/assert`, Vitest for frontend

### Potential Pitfalls

1. **go-git memory on large repos**: Use `CloneOptions.Depth: 1` (shallow clone)
2. **Concurrent update checks**: `sync.WaitGroup` with rate limiting to avoid GitHub rate limits
3. **SKILL.md directory naming**: Store uses directory name as canonical skill name — imported skills must match
4. **Lock file merge conflicts**: Keep format simple (sorted keys) to minimize YAML merge conflicts
5. **Form/YAML bidirectional sync**: Full round-tripping is hard. Make YAML→Form best-effort with clear error handling. Never silently drop unknown fields.
6. **Transport conditional logic complexity**: Encode rules in a `getFieldVisibility(serverType, transport)` function, not scattered across components
7. **Config schema drift**: If `config/types.go` changes, wizard forms must be updated. Consider generating TypeScript types from Go structs (or maintain manually with test parity)
8. **Auto-update timing**: Check goroutine must start AFTER registry loads but BEFORE deploy completes
9. **Private repos**: go-git supports HTTP basic auth. Map `GITHUB_TOKEN` to basic auth (username=token, password="")
10. **Secrets in YAML preview**: The preview must show `${vault:KEY}` references, never resolved values. Lint for raw secret patterns.
11. **SemVer constraint edge cases**: Repos without tags fall back to branch-based refs. Handle repos with inconsistent tagging (mixed v-prefix, pre-release tags). `Masterminds/semver` handles most cases but test edge cases.
12. **Security scanner false positives**: Pattern matching for dangerous commands will have false positives. Keep the scanner conservative (flag, don't block) and let `--trust` override. Document the patterns checked.
13. **Real-time validation rate limiting**: Backend validate endpoint called on every form change (debounced 500ms). Ensure the endpoint is fast (<50ms) and consider request cancellation for rapid typing.
14. **Draft storage growth**: Wizard drafts in `~/.gridctl/cache/wizard-drafts/` could accumulate. Add a max draft count or TTL-based cleanup.
15. **Spec plan without Docker**: `gridctl plan` needs Docker API to compare against running containers. When Docker is unavailable, fall back to state file comparison only and show "container status unknown" for drift items.
16. **Spec tab performance**: Large stack.yaml files with many validation annotations could cause re-render jank. Use virtualized rendering or throttle annotation updates.
17. **Drift detection false positives**: Transient container restarts or image digest differences may show as drift. Use semantic comparison (name + config) not exact container state matching.

### Suggested Build Order

**Phase 1 — Spec Foundation (CLI + API)**:
1. `pkg/config/plan.go` — `SpecPlan` type: load spec, compare against state files + optional Docker query, produce structured diff (added/removed/changed)
2. `pkg/config/health.go` — `SpecHealth` type: aggregate validation result + drift status + dependency status
3. `cmd/gridctl/validate.go` — `gridctl validate` command with field-level error output, `--format json`, exit codes
4. `cmd/gridctl/plan.go` — `gridctl plan` command with structured diff display, `-y` auto-approve, deploy integration
5. `internal/api/stack.go` — `POST /api/stack/validate`, `GET /api/stack/plan`, `GET /api/stack/health`, `GET /api/stack/spec` endpoints
6. Tests for all above

**Phase 2 — Spec Visibility (Web UI)**:
7. `web/src/stores/useSpecStore.ts` — Zustand store for spec content, validation results, drift state, health status
8. `web/src/components/spec/SpecTab.tsx` — Bottom panel tab with syntax-highlighted stack.yaml + validation annotations
9. `web/src/components/spec/SpecHealthBadge.tsx` — Status bar indicator
10. Update `BottomPanel.tsx` with Spec tab, `StatusBar.tsx` with health badge
11. `web/src/components/spec/SpecDiffModal.tsx` — Old-vs-new spec diff on reload
12. Wire reload button to show diff modal before applying
13. Frontend tests for spec components

**Phase 3 — Spec Dependencies CLI (Skill Import)**:
14. `pkg/skills/config.go` — `SkillSource` type, `skills.yaml` parsing, SemVer constraint resolution via `Masterminds/semver/v3`
15. `pkg/skills/origin.go` — `.origin.json` read/write
16. `pkg/skills/lockfile.go` — Lock file struct, read/write/update (records resolved tag + commit SHA for constraint-based refs)
17. `pkg/skills/remote.go` — Clone repo, discover SKILL.md files, resolve SemVer constraints against git tags
18. `pkg/skills/scanner.go` — Security scanning for SKILL.md workflows (flag `exec`, `curl | sh`, broad filesystem writes)
19. `pkg/skills/importer.go` — Import orchestration (discover, scan, validate, copy to registry, write origin + lock). Require `--trust` for flagged skills.
20. `cmd/gridctl/skill.go` — `skill add`, `skill list`, `skill remove`, `skill update`, `skill pin`, `skill info`
21. Tests for all above

**Phase 4 — Visual Spec Builder Shell**:
22. `web/src/stores/useWizardStore.ts` — Zustand store for wizard state + named draft persistence
23. `web/src/components/wizard/CreationWizard.tsx` — Modal shell + resource type picker
24. `web/src/components/wizard/TemplateGrid.tsx` — Template card selection (recipes)
25. `web/src/lib/yaml-builder.ts` — Form state to YAML serialization
26. `web/src/components/wizard/YAMLPreview.tsx` — Live preview with syntax highlighting + inline validation annotations from backend `Validate()`
27. `web/src/components/wizard/ExpertModeToggle.tsx` — Form/YAML segmented control
28. `web/src/components/wizard/DraftManager.tsx` — Save/load/delete named drafts
29. `web/src/components/wizard/steps/ReviewStep.tsx` — Spec validation gate + summary + generate
30. Update `Header.tsx` with "+" button entry point
31. `internal/api/wizard.go` — Draft CRUD endpoints (`GET/POST/DELETE /api/wizard/drafts`)

**Phase 5 — MCP Server Spec Form**:
32. `web/src/components/wizard/steps/MCPServerForm.tsx` — 6-variant dynamic form
33. `web/src/components/wizard/SecretsPopover.tsx` — Inline vault picker
34. Wire wizard validation to `POST /api/stack/validate` (shared with spec foundation)
35. Frontend tests for dynamic field switching

**Phase 6 — Stack Spec Composition**:
36. `web/src/components/wizard/steps/StackForm.tsx` — Stack form with nested server/agent/resource sub-forms
37. File generation: download, clipboard, deploy options. Output as complete Stack Spec directory when skills are included.
38. Empty-state canvas CTA integration

**Phase 7 — Spec Dependencies UI (Skills Builder)**:
39. `internal/api/skills.go` — All `/api/skills/` endpoints
40. `web/src/components/wizard/steps/SkillImportWizard.tsx` — 4-step import flow
41. `web/src/components/wizard/steps/AddSourceStep.tsx` — URL input with validation
42. `web/src/components/wizard/steps/BrowseStep.tsx` — Two-column browse + preview
43. Update `RegistrySidebar` with import button, update badges, sources section

**Phase 8 — Agent + Resource Spec Forms**:
44. `web/src/components/wizard/steps/AgentForm.tsx` — Container/headless/A2A
45. `web/src/components/wizard/steps/ResourceForm.tsx` — Presets + custom
46. Sidebar quick-add links

**Phase 9 — Spec Monitoring (Auto-Update + Drift)**:
47. `pkg/skills/updater.go` — Background goroutine, state file, notification
48. Integration with `cmd/gridctl/deploy.go`
49. Web UI update badges and "Update All" action
50. `web/src/components/spec/DriftOverlay.tsx` — Canvas overlay with ghost nodes, warning badges
51. Add drift toggle to canvas controls

**Phase 10 — Spec-Aware Canvas + Novel UX**:
52. Canvas spec mode toggle (ghost nodes for undeployed declarations, connections from `uses[]`)
53. `cmd/gridctl/export.go` — `gridctl export` to reverse-engineer spec from running state
54. `gridctl skill try` with ephemeral timer
55. Wiring Mode on ReactFlow canvas
56. Stack Recipes with live diffing
57. Secret Heatmap Overlay
58. Transport Compatibility Advisor
59. Skill Fingerprinting with behavioral change detection

## Acceptance Criteria

### Spec Foundation
SF1. `gridctl validate stack.yaml` returns field-level errors with file/line context, exit code 0/1/2
SF2. `gridctl validate --format json` outputs machine-readable validation results for CI
SF3. `gridctl plan stack.yaml` shows structured diff (added/removed/changed) against running state
SF4. `gridctl plan -y stack.yaml` auto-approves and deploys after showing diff
SF5. `POST /api/stack/validate` returns field-level errors with severity (error/warning/info)
SF6. `GET /api/stack/health` returns aggregate spec health (validation + drift + dependencies)
SF7. Spec tab in bottom panel shows syntax-highlighted stack.yaml with live validation annotations
SF8. Spec health badge in status bar updates in real-time as spec changes
SF9. Spec diff modal appears on reload, showing old-vs-new spec before applying
SF10. Drift detection overlay on canvas shows ghost nodes for declared-but-not-running items
SF11. All spec foundation Go code has unit tests with >80% coverage
SF12. All spec foundation React components have Vitest tests

### Skill Import (Spec Dependencies)
1. `gridctl skill add <github-url>` clones, discovers, imports skills as active with `.origin.json` sidecar
2. `skills.lock.yaml` created with resolved commit SHAs and per-skill checksums
3. `gridctl skill list` shows source origin (local/remote) and update status
4. `gridctl skill update` fetches latest, shows diff, applies, rewrites lock file
5. `gridctl skill update --dry-run` shows changes without applying
6. `gridctl skill remove` cleans up skill, origin file, and lock entry
7. `gridctl skill pin <name> <ref>` updates ref and disables auto-update
8. `skills.yaml` parsed for sources with defaults and per-source overrides
8a. SemVer constraints (e.g., `^1.2.0`) in `ref` field resolve against git tags, pin exact SHA in lock file
8b. Security scanning flags dangerous patterns in SKILL.md workflows (unrestricted shell, `curl | sh`, broad fs writes). Flagged skills require `--trust` or interactive confirmation.
9. Background check runs non-blocking during deploy, results in state file
10. `GRIDCTL_NO_SKILL_UPDATE_CHECK=1` and `CI=true` disable checks
11. Name conflicts produce clear errors with `--force` and `--rename` options
12. Network failures handled gracefully (log, cache, show "last check failed")
13. Shallow clones (`Depth: 1`) used by default

### Visual Spec Builder (Universal Wizard)
14. Header "+" button opens wizard modal with resource type picker
15. Empty canvas shows "Create your first stack" CTA opening wizard
16. Template cards pre-fill forms with sensible defaults
17. MCP Server form dynamically reconfigures on type selection (6 variants)
18. Transport selection shows/hides port field with correct validation
19. Data preserved when switching server types (no loss on accidental click)
20. YAML preview updates live (debounced 150ms) as form values change, with real-time backend validation annotations (debounced 500ms)
21. Form/YAML toggle enables bidirectional editing with parse error handling
22. Stack form supports nested MCP server, agent, and resource sub-forms
23. "Generate stack.yaml" produces valid YAML passing `config.Validate()`
24. Output options work: download file, copy to clipboard
25. Secrets popover shows existing vault secrets and supports inline creation
26. Every `${vault:KEY}` reference in generated YAML corresponds to a real vault secret
27. Resource presets (PostgreSQL, Redis, MySQL) pre-fill correct images and env vars
28. Review section shows validation results (green/amber/red) with field-level errors
29. Wizard state persists across modal close/reopen within session
29a. Named drafts can be saved, listed, and resumed across browser sessions via `/api/wizard/drafts` endpoints
30. All new Go code has unit tests with >80% coverage
31. All new React components have Vitest tests

### Skills Builder (Spec Dependencies UI)
32. Skills Builder accessible from wizard type picker and RegistrySidebar
33. Step 1 validates GitHub URL and shows repo metadata
34. Step 2 displays skills with markdown preview and batch selection
35. Step 4 shows install progress and success confirmation
36. Update badges appear on skills with available updates

### API
37. All `/api/skills/` endpoints functional and returning proper JSON
38. `POST /api/stack/validate` validates config and returns field-level errors (used by spec tab, review step, and real-time YAML preview)
39. `GET/POST/DELETE /api/wizard/drafts` endpoints for named draft persistence
40. `GET /api/stack/plan` returns structured diff comparing spec to running state
41. `GET /api/stack/health` returns aggregate spec health status
42. `GET /api/stack/spec` returns current stack.yaml content for Spec tab display

## References

### Spec-Driven Development
- Thoughtworks SDD analysis: https://www.thoughtworks.com/en-us/insights/blog/agile-engineering-practices/spec-driven-development-unpacking-2025-new-engineering-practices
- Martin Fowler — SDD tools comparison: https://martinfowler.com/articles/exploring-gen-ai/sdd-3-tools.html
- GitHub Spec Kit: https://github.com/github/spec-kit
- Amazon Kiro specs: https://kiro.dev/docs/specs/
- Addy Osmani — Writing good specs: https://addyosmani.com/blog/good-spec/
- Terraform plan/apply pattern: https://developer.hashicorp.com/terraform/cli/commands/plan

### Skills & Distribution
- agentskills.io specification: https://agentskills.io/specification
- go-git v5: https://pkg.go.dev/github.com/go-git/go-git/v5
- go-git Remote.List: https://pkg.go.dev/github.com/go-git/go-git/v5#Remote.List
- Masterminds/semver: https://github.com/Masterminds/semver
- FluxCD source-controller: https://github.com/fluxcd/source-controller
- Terraform lock file: https://developer.hashicorp.com/terraform/language/files/dependency-lock
- lazy.nvim lock file: https://github.com/folke/lazy.nvim
- gh CLI update checker: https://github.com/cli/cli
- Backstage Scaffolder: https://backstage.spotify.com/docs/portal/core-features-and-plugins/scaffolder
- Rancher Form/YAML toggle: gold standard for config builder UX
- react-hook-form: https://react-hook-form.com/
- @monaco-editor/react: https://www.npmjs.com/package/@monaco-editor/react
- monaco-yaml: https://github.com/remcohaszing/monaco-yaml
- NNG Wizard UX: https://www.nngroup.com/articles/wizards/
- Existing gridctl patterns: `pkg/builder/git.go`, `pkg/registry/store.go`, `pkg/config/types.go`, `pkg/config/validate.go`
