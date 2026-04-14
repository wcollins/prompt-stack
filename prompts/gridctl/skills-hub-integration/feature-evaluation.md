# Feature Evaluation: Skills Hub Integration (gridctl.dev Registry)

**Date**: 2026-04-09
**Project**: gridctl
**Recommendation**: Build
**Value**: High
**Effort**: Medium (three phased deliverables)

## Summary

gridctl's skills system has solid import plumbing (git clone, lock files, fingerprinting, security scanning) but zero discoverability — users must already know a skill's git repo URL to install it. Pairing `gridctl skill search` with a curated public registry at gridctl.dev closes the ecosystem loop and is the single highest-leverage improvement to the skills system. With gridctl.dev owned and controlled, the registry authority question is resolved: gridctl.dev is the canonical home for both the tool and its ecosystem. The work breaks naturally into three phases: search, aggregation from upstream registries, and publishing from the CLI.

## The Idea

A curated public registry hosted at `gridctl.dev/api/v1/skills` backed by a YAML/JSON manifest in a public git repo (`gridctl/skills-hub`), with a Cloudflare Worker handling query filtering. Think Homebrew formulae or the Terraform Registry — but owned by the same team that ships the CLI. Users run `gridctl skill search github` to discover skills, `gridctl skill add <name>` to install, and eventually `gridctl skill publish` to contribute back.

**Three phases:**
1. **Search** — `gridctl skill search` queries gridctl.dev; static index served from GitHub Pages via Cloudflare Worker
2. **Aggregation** — CI job pulls from compatible upstream registries (tech-leads-club, skilldock.io), normalizes into a tiered index
3. **Publishing** — `gridctl skill publish` validates locally and opens a PR to `gridctl/skills-hub`

**Who benefits**: All gridctl users who want to find skills beyond what they already know. Aggregation means hundreds of community skills on day one. Publishing creates the contribution flywheel.

## Project Context

### Current State

- gridctl is a stack-as-code MCP gateway platform (v0.x, stable core, experimental skills)
- Skills are SKILL.md files (agentskills.io spec) with YAML frontmatter defining prompts, workflows, inputs
- `skill add <repo-url>` handles git clone → discover → validate → security scan → import → lock
- Lock file (`~/.gridctl/skills.lock.yaml`) records commit SHA, content hash, and behavioral fingerprint per skill
- `skill search` does not exist at all today
- README explicitly notes: "Skills registry is local-only with no remote discovery"
- agentskills.io is referenced as the specification authority in README and `pkg/registry/types.go`
- gridctl.dev is now owned — the registry authority and the tool brand are unified

### Integration Surface

| File | Role |
|------|------|
| `cmd/gridctl/skill.go` | Add `skillSearchCmd` and `skillPublishCmd` subcommands |
| `pkg/skills/importer.go` | `ImportOptions` gains optional `HubSkill` resolved metadata (Phase 2) |
| `pkg/skills/` (new: `hub.go`) | HTTP client for gridctl.dev search API |
| `pkg/skills/` (new: `publisher.go`) | PR creation logic for `skill publish` (Phase 3) |
| `internal/api/skills.go` | Add `GET /api/skills/hub/search` REST proxy endpoint |

### Reusable Components

- `http.Client` pattern from `cmd/gridctl/pins.go` — simple stdlib, 10s timeout
- Table output from `runSkillList()` — `table.StyleRounded`, conditional columns, `--format json`
- `pkg/output` Printer for status messages (`printer.Info()`, `printer.Warn()`)
- `skills.LockFile` schema is extensible (can add `hub_id`, `hub_version`, `tier` fields)
- `GITHUB_TOKEN` already supported in `pkg/skills/remote.go` for git auth — reusable for publish PR creation

## Market Analysis

### Competitive Landscape

| Registry | Backend | Key Design Decision |
|----------|---------|---------------------|
| Homebrew | Static generated JSON from git monorepo | CLI caches JSON locally; search is substring match against cache |
| Terraform Registry | Dynamic DB + REST API, tiers, download counts | Registry Protocol v1 is open; private mirrors can implement |
| npm | ElasticSearch + CouchDB, `/-/v1/search`, 3D scoring | `keywords` field in package.json drives discoverability |
| `gh extension` | GitHub Search API (`topic:gh-extension`) — no curated index | Zero infra, zero quality control — breaks at scale |
| Raycast Store | Monorepo (`raycast/extensions`) — PRs = submissions | Curation built into git workflow; zero DB infrastructure |
| `tech-leads-club/agent-skills` (2K ★) | Git monorepo + generated `skills-registry.json` | 77 skills, 15 categories; uses agentskills.io format — top aggregation target |

### Aggregation Compatibility

| Upstream Registry | Stars | Format Compat | Aggregation Viability |
|-------------------|-------|--------------|----------------------|
| `tech-leads-club/agent-skills` | 2,030 | High — agentskills.io SKILL.md + generated JSON index | **Day-one target** — 77 skills on launch |
| `chigwell/skilldock.io` | 52 | High — agentskills.io spec, versioned | Worth including |
| `majiayu000/claude-skill-registry` | 183 | Medium — JSON index, close but non-identical format | Needs adapter |
| `Kamalnrf/claude-plugins` | 494 | Low — TypeScript monorepo, different format | Skip for now |

### Market Positioning

First-mover in a forming space. No AI coding assistant skill ecosystem has a polished, curated registry with CLI integration. gridctl.dev as the authority is a stronger position than agentskills.io (a spec doc site) — it is the tool and the registry under one brand. Aggregating upstream registries means launching with a meaningful catalog rather than an empty index.

### Demand Signals

- `tech-leads-club/agent-skills`: 2,030 stars — organic community already curating skills in the exact format
- Multiple competing registries emerging (`skilldock.io`, `skillnote`, `claude-plugins`) — active but uncoordinated
- gridctl README explicitly acknowledges "local-only with no remote discovery" as a limitation

## User Experience

### Phase 1 — Search

```
$ gridctl skill search github
┌──────────────────────────┬────────────┬───────────────────────────────────────────────┬───────────┐
│ Name                     │ Category   │ Description                                   │ Tier      │
├──────────────────────────┼────────────┼───────────────────────────────────────────────┼───────────┤
│ pr-review                │ git        │ Review pull requests with structured AI output │ curated   │
│ github-actions-debug     │ ci         │ Debug failing GitHub Actions workflows         │ community │
│ branch-strategy          │ git        │ Suggest branching and PR strategy              │ curated   │
└──────────────────────────┴────────────┴───────────────────────────────────────────────┴───────────┘

Use `gridctl skill add <repo-url>` to install a skill.
```

### Phase 2 — Install by Hub Name

```
$ gridctl skill add pr-review
Resolving pr-review from gridctl.dev...
Importing from https://github.com/gridctl/skills-hub, path: git/pr-review
✓ Imported pr-review (active)
```

### Phase 3 — Publish

```
$ gridctl skill publish
Validating skill branch-trunk... ✓
Opening PR to gridctl/skills-hub...
✓ PR opened: https://github.com/gridctl/skills-hub/pull/42
```

### Workflow Impact

Transforms skills from a power-user feature into a discoverable ecosystem. Current flow: find a URL somewhere, `skill add <url>`. Proposed flow: `skill search <topic>` → `skill add <name>` → `skill publish` to give back. The contribution loop is closed entirely within the CLI.

### UX Recommendations

1. Show `Tier` as a column (`curated` / `community`) — trust signal that costs nothing
2. After zero results: "No skills found. Browse all at gridctl.dev/skills"
3. Network error: "Could not reach gridctl.dev — use `gridctl skill add <repo-url>` directly"
4. `skill publish` should do a full `skill validate` before attempting to open a PR — fail fast locally

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Significant | Discoverability is an explicit adoption blocker called out in README |
| User impact | Broad + Deep | Every gridctl user wanting skills benefits; aggregation means immediate catalog depth |
| Strategic alignment | Core mission | gridctl.dev owned — tool and registry are one brand; natural ecosystem flywheel |
| Market positioning | Leap ahead | No comparable ecosystem exists; aggregation creates catalog depth on day one |

### Cost Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Minimal–Moderate | Phase 1 minimal; Phase 3 publish needs GitHub API for PR creation |
| Effort estimate | Medium | P1 ~1 week (client + infra); P2 ~1 week (aggregator CI); P3 ~1 week (publish command) |
| Risk level | Low | Additive; skills are experimental; hub failure never breaks existing commands |
| Maintenance burden | Moderate | Index curation is ongoing; aggregator needs maintenance when upstreams change format |

## Recommendation

**Build — all three phases.** This is the ecosystem flywheel for gridctl's skills system, and gridctl.dev ownership removes the only real blocker (authority + hosting). The phased approach means Phase 1 ships fast and independently; aggregation and publishing follow without blocking each other.

**Infrastructure summary** (what's needed outside the gridctl repo):
1. `gridctl/skills-hub` repo — SKILL.md files, `sources.yaml` for aggregation, CI-generated `index.json`
2. GitHub Pages on that repo — serves `index.json` at `gridctl.github.io/skills-hub/`
3. Cloudflare Worker at `gridctl.dev/api/v1/skills` — fetches `index.json`, filters by `?query=`, returns subset. Free tier: 100K req/day. ~30 lines of JS.
4. DNS for `gridctl.dev` pointing at Cloudflare — one record
5. Optional: `gridctl.dev/skills` web UI (static Next.js or plain HTML) — browsable skills catalog

**Aggregation approach**: A GitHub Action in `skills-hub` runs nightly, fetches upstream `skills-registry.json` files from compatible registries, normalizes to the `HubSkill` schema, stamps tier as `community`, deduplicates (curated wins), and regenerates `index.json`. Taxonomy mapping (their categories → gridctl.dev canonical categories) is a YAML file in the repo.

**Publishing approach**: PR-based (Raycast model). `gridctl skill publish` validates locally, uses `GITHUB_TOKEN` (already supported) to fork `gridctl/skills-hub` and open a PR. No server auth required. Maintainers review and merge.

**Specific caveats:**
- Lock the `gridctl.dev/api/v1/skills` API shape before Phase 1 ships — the client hard-codes the path structure
- `GRIDCTL_SKILLS_HUB_URL` env var makes the URL overridable for private registries
- Aggregated `community` skills still run through gridctl's security scanner on install — tier is editorial trust, not a security bypass
- Taxonomy mapping file needs an initial design decision: how many top-level categories? Suggest starting with the 15 from `tech-leads-club/agent-skills` and refining

## References

- gridctl.dev: owned domain — canonical registry authority
- agentskills.io specification: `https://agentskills.io/specification` (still the spec reference)
- `tech-leads-club/agent-skills` (best prior art, 2K★): `https://github.com/tech-leads-club/agent-skills`
- `chigwell/skilldock.io` (52★): `https://github.com/chigwell/skilldock.io`
- Homebrew Formulae API: `https://formulae.brew.sh/api/formula.json`
- Terraform Registry Protocol v1: `https://developer.hashicorp.com/terraform/internals/provider-registry-protocol`
- Raycast extensions monorepo (curation model): `https://github.com/raycast/extensions`
- Cloudflare Workers docs: `https://developers.cloudflare.com/workers/`
