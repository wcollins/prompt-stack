# Feature Implementation: Docs Restructure & Messaging Refresh

## Context

gridctl is a Go (1.26+) + React MCP control plane at v0.1.0-beta.9 (unreleased). The CLI is in `cmd/gridctl/`, internal services in `internal/`, the gateway/skills/agent runtime in `pkg/`, and the web UI in `web/`. Project docs live in `README.md` (currently 667 lines) and a `docs/` directory (6 files, 3,286 lines: api-reference, config-schema, cost-observability, scaling, skills, troubleshooting + a 25-line `docs/README.md` index).

**Project posture**: pre-1.0, single maintainer, OSS (Apache 2.0), positioning is actively contested in a crowded MCP gateway space (ContextForge, ToolHive, Pluggedin, Smithery, MCPJungle, mcp-router are all peers). The product has been investing heavily over the last 6 weeks in agents, skills, runs ledger, and cost observability — but the README does not reflect that.

**This task is documentation + messaging. No code changes.**

## Evaluation Context

This work was scoped from `/feature-scout` research. Key findings that shaped the requirements below:

- **Peer-set research**: 6 of 8 comparable Go CLIs (gh, devbox, flox, k3d, trivy, mkcert) ship READMEs at 100–210 lines. The 667-line README is in lazygit/k9s territory and above peer median. The structural trim is **catching up to convention**, not breaking new ground.
- **Messaging research**: The originally-proposed *"Operating System for MCP Grids"* pitch was rejected as weak — the OS metaphor is over-used in the MCP gateway space (ContextForge, ToolHive, Control Plane Inc. already use it), "Grid" is a noun the market hasn't accepted, and the README's own internal vocabulary is "stack" not "grid." Replace with the verb-based local-first pitch specified below.
- **Honesty audit against the Stability table at README.md:605–637**: `gridctl agent dev` is currently marked **Experimental**, landed days ago (PR #599, Phase F), and has no demo GIF. Do NOT elevate it to the hero spot. Lead with currently-stable + currently-differentiated features. Mark agent IDE as "Early Access."
- **Risk surface is unusually low**: only one inbound README anchor link exists in the repo (`docs/README.md` line 22 → `../README.md#-quick-start`). No external website, no gh-pages, no package-manager formulas in this repo.
- **Toon/CSV format conversion IS shipped and Stable** (see `pkg/format/toon.go`, README.md line 616). Safe to feature.

Full evaluation: `/Users/william/code/prompt-stack/prompts/gridctl/docs-restructure-landing/feature-evaluation.md`

## Feature Description

Refactor gridctl's documentation in three coordinated moves:

1. **Structural** — shrink `README.md` from 667 → ~200 lines by extracting installation, CLI reference, and stability/limitations into dedicated `docs/` files.
2. **Messaging** — replace the current "MCP gateway" tagline with a verb-based, local-first pitch that reflects current product investment in skills, runs, and cost optimization.
3. **Navigation** — upgrade `docs/README.md` from a 25-line stub into a real docs index.

## Requirements

### Functional Requirements

1. **README.md** is reduced to 180–230 lines following the outline in "Implementation Notes → Landing README outline" below.
2. **New file `docs/installation.md`** contains the content currently at README.md:71–193 (Quick install, package managers, pre-built binaries, build from source, updating, uninstalling, container runtime detection, Podman setup). Preserve all `<details>` collapsibles. Add an H1 (`# Installation`) and a top-of-page link back to the README.
3. **New file `docs/cli-reference.md`** contains the content currently at README.md:416–531 (all command tables — stack lifecycle, LLM clients, skills remote/authoring, runs, vault, pins, traces, optimize, upgrade). Add an H1 (`# CLI Reference`), a brief intro about `--help`, and a ToC linking each command group.
4. **New file `docs/project-status.md`** contains the content currently at README.md:605–645 (Stability table + Known Limitations). Add an H1 (`# Project Status`), a brief intro explaining the stability tiers, and a "Last updated" line that mirrors the current CHANGELOG version.
5. **`docs/README.md`** is upgraded into a real index with grouped sections: **Getting Started** (links to installation + quick-start), **References** (config-schema, cli-reference, api-reference), **Guides** (skills, scaling, cost-observability), **Operations** (project-status, troubleshooting), **Quick Links** (existing). The existing inbound link at line 22 (`../README.md#-quick-start`) must remain valid (Quick Start stays on the landing README).
6. **README.md** retains: hero logo + tagline, badges, hero GIF, "Why gridctl" with YAML example, hero UI GIF, **one-line install + link to docs/installation.md**, Quick Start (3-command), Features (3–4 short feature blocks per Implementation Notes), Connect LLM Application, Examples table, Documentation index, Contributing, License.
7. **README.md** removes (now lives in docs/): full installation matrix, container runtime setup, full CLI reference tables, stability table, known limitations.
8. **Tagline replacement**: the current bold line at README.md:6 (`One endpoint. Dozens of AI tools. Zero configuration drift.`) is replaced with a new primary tagline and a sub-tagline:
   - Primary: **"The developer cockpit for MCP servers and Agent Skills."**
   - Sub-tagline (smaller): *"One YAML. One endpoint. Every MCP server and Agent Skill."*
9. **Feature blocks on the landing README** lead with currently-stable + differentiated features in this order: **Stack as Code**, **`gridctl optimize` + Cost Observability**, **Output Format Conversion (toon/csv)**, then **Skills (Early Access)** and **Visual Agent IDE (Early Access)** as the forward-looking pair. Each feature block is 2–4 sentences and ends with a "Learn more →" link to the appropriate `docs/` file.
10. The single inbound link from `docs/README.md` to README anchor `#-quick-start` continues to resolve after the refactor.

### Non-Functional Requirements

- Total README length between 180 and 230 lines.
- No new tooling dependencies (no MkDocs, no Docusaurus, no Node-based docs build). Plain markdown only.
- All existing `assets/*.gif` and `assets/*.png` references continue to resolve.
- Every Markdown link in moved content must continue to resolve (relative paths shift from `examples/...` to `../examples/...` when content moves into `docs/`).
- Consistent emoji-prefixed H2 headings on the landing README (matches the existing house style: 🪛 ⚡️ 🚦 🎬 📚 🖥️ 📙 📐 ⚠️ 📖 🤝 🪪).
- Each new `docs/*.md` file opens with an H1 and (when long) a short ToC.

### Out of Scope

- **No code changes.** This is doc-only.
- **No new docs site, no mkdocs.yml, no GitHub Pages setup.** Plain markdown in the repo is the deliberate choice.
- **No new agent-IDE GIF recording.** If `assets/agent-ide.gif` does not exist when this work starts, the Visual Agent IDE feature block on the landing README links to docs/skills.md and uses a still or no media — do not block the refactor on recording new media. (If the user runs `/gif-create` before this work, link it.)
- **No changes to existing `docs/` content** (api-reference, config-schema, cost-observability, scaling, skills, troubleshooting). Only the index (`docs/README.md`) is updated.
- **No changes to CHANGELOG, AGENTS.md, CONTRIBUTING.md, SECURITY.md, install.sh**, or any code-adjacent docs.
- **No changes to web/ frontend**. The "Connect LLM Application" section stays in the README with the same content.
- **Do not adopt "Operating System for MCP Grids"** — this framing was explicitly rejected. Use the tagline in requirement #8.
- **Do not elevate `gridctl agent dev` to the hero spot.** Feature it as Early Access among the feature blocks.

## Architecture Guidance

### Recommended Approach

This is a content move, not a code change. The right approach is:

1. Read the current `README.md` and existing `docs/` files end-to-end first.
2. Draft the new landing `README.md` in full before extracting anything — so the new outline is the source of truth for what stays vs. moves.
3. Extract content into the three new `docs/` files in order: installation → cli-reference → project-status.
4. Update `docs/README.md` to index the new files.
5. Verify all internal links resolve (`grep -nE '\]\([^)]+\)' README.md docs/*.md`).

Do **not** try to write each new file independently. Each move shifts what the landing README needs to say, so iterate on the landing README throughout.

### Key Files to Understand

| File | Why it matters |
|---|---|
| `/Users/william/code/gridctl/README.md` | Source content. Section-by-section breakdown in "Implementation Notes" below. |
| `/Users/william/code/gridctl/docs/README.md` | Current 25-line stub. Must become a real index. Contains the one inbound link to update/preserve. |
| `/Users/william/code/gridctl/docs/skills.md` | Sets the tone for prose-heavy gridctl docs files. Match its voice. |
| `/Users/william/code/gridctl/docs/cost-observability.md` | The model for a focused single-topic docs file (~80 lines, very tight). The landing README's Cost Observability feature block should link here. |
| `/Users/william/code/gridctl/CHANGELOG.md` | Source for the "Last updated" line on `docs/project-status.md`. Use the most recent released version (currently v0.1.0-beta.9). |
| `/Users/william/code/gridctl/assets/` | Existing GIFs (`gridctl.gif`, `gridctl-ui.gif`, `install.gif`). All three are kept on the landing README. |

### Integration Points

- **One inbound link to maintain**: `docs/README.md` line 22 currently reads `[Getting Started](../README.md#-quick-start)`. The Quick Start section stays on the landing README under the heading `## 🚦 Quick Start`, so the GitHub anchor `#-quick-start` continues to resolve. Verify after the refactor.
- **No CLI help text, test fixture, or web-frontend file references README anchors.** Confirmed via grep during evaluation; re-verify if any code-adjacent change has landed since.

### Reusable Components

- The existing README's `<details><summary>` collapsibles for installation methods — port the pattern verbatim into `docs/installation.md`.
- The existing README's emoji-prefixed H2 heading style (e.g. `## 🪛 Installation`) — use across new docs files where natural.
- The existing `docs/cost-observability.md` voice (concrete, code-block-rich, technical-but-tight) — mirror in the new docs files.

## UX Specification

### Discovery (landing README, first screen)

1. Logo (centered, 420px).
2. Primary tagline (bold, centered): **"The developer cockpit for MCP servers and Agent Skills."**
3. Sub-tagline (smaller, centered): *"One YAML. One endpoint. Every MCP server and Agent Skill."*
4. Badges row (unchanged).
5. `---` rule.
6. Hero GIF (`assets/gridctl.gif`).
7. Two-paragraph "Why gridctl" — keep close to current README's opening (lines 22–39, condensed). Open with the one-sentence value prop, then drop into the existing YAML stack example. Close with "Three servers. Three different transports. One endpoint." sentence, followed by `assets/gridctl-ui.gif`.

### Activation (landing README, second screen)

8. `## 🪛 Install` — one-liner curl install + a "📖 [Full installation guide](docs/installation.md)" link. 4–6 lines total.
9. `## 🚦 Quick Start` — exactly the 3-command block at current README.md:194–209. Unchanged.
10. `## 🎬 Features` — five tight feature blocks (2–4 sentences each), each ending with `Learn more → [docs path]`:
    - **Stack as Code** → `docs/config-schema.md`
    - **`gridctl optimize` & Cost Observability** → `docs/cost-observability.md`
    - **Output Format Conversion (toon, csv)** → docs/config-schema.md (anchor to output_format section if one exists, else top of file)
    - **Skills _(Early Access)_** → `docs/skills.md`
    - **Visual Agent IDE _(Early Access)_** → `docs/skills.md`

### Interaction (landing README, third screen and below)

11. `## 🖥️ Connect LLM Application` — unchanged from current README.md:532–573.
12. `## 📙 Examples` — unchanged table from current README.md:574–604.
13. `## 📖 Documentation` — bulleted list of docs/ files, grouped by Getting Started / References / Guides / Operations to mirror `docs/README.md`.
14. `## 🤝 Contributing` — unchanged.
15. `## 🪪 License` — unchanged.
16. Centered closing line — unchanged.

### Error / Edge States

- If an internal link breaks during the refactor, fix it before completing. Do not ship dangling links.
- If `assets/agent-ide.gif` does not exist, the Visual Agent IDE block uses no media and links to docs/skills.md.

## Implementation Notes

### Landing README outline (target ~200 lines)

```
1.  <p align="center"> logo <img>                                                              [1 line block]
2.  <p align="center"> primary tagline (bold)                                                  [1 line block]
3.  <p align="center"> sub-tagline (italic)                                                    [1 line block]
4.  <p align="center"> badges                                                                  [1 line block]
5.  ---
6.  ![hero gif](assets/gridctl.gif)
7.  Why gridctl (2 paragraphs + YAML example + closing sentence + UI gif)                      [~40 lines]
8.  ## 🪛 Install (one-liner + link)                                                           [~10 lines]
9.  ## 🚦 Quick Start (3-command block)                                                        [~15 lines]
10. ## 🎬 Features
    ### Stack as Code (2-4 sentences + Learn more link)                                        [~6 lines]
    ### `gridctl optimize` & Cost Observability                                                [~6 lines]
    ### Output Format Conversion                                                               [~6 lines]
    ### Skills _(Early Access)_                                                                [~6 lines]
    ### Visual Agent IDE _(Early Access)_                                                      [~6 lines]
11. ## 🖥️ Connect LLM Application (gridctl link explanation + manual config)                  [~45 lines]
12. ## 📙 Examples (table — current content unchanged)                                         [~30 lines]
13. ## 📖 Documentation (grouped bulleted index)                                               [~15 lines]
14. ## 🤝 Contributing                                                                         [~3 lines]
15. ## 🪪 License                                                                              [~3 lines]
16. <p align="center"> closing                                                                 [~3 lines]
```

### Conventions to Follow

- Bullets and tables match existing README style (no over-formatting).
- Code fences use the same language tags as today (`bash`, `yaml`, `json`).
- Internal links use relative paths (`docs/installation.md`, `../examples/foo.yaml`).
- Emoji-prefixed H2s on landing README match house style.
- New `docs/*.md` files open with `# Title` H1 (no emoji on docs H1s — keep emojis to the landing README).
- Preserve all `<details>` collapsibles.

### Potential Pitfalls

- **Don't lose the "Inspiration / Containerlab" callout** (current README.md:30–31) — port into the Why section, condensed.
- **Don't accidentally feature `gridctl agent dev` as the lead.** The Stability table marks it Experimental. Mark it Early Access in the feature block.
- **Don't claim "Operating System for MCP Grids" anywhere.** This framing was explicitly rejected during evaluation.
- **Don't over-condense the YAML example.** The current 3-server YAML at README.md:41–64 is one of the strongest hooks — keep it intact.
- **Don't introduce hosted-docs tooling.** No MkDocs, no Docusaurus.
- **Don't break the one inbound link.** `docs/README.md` line 22 must keep working.
- **Don't move existing docs/ content.** Only NEW docs files are created; the existing six stay where they are.
- **Don't strip the Examples table.** It's an underrated landing-page asset and only 31 lines.
- **Don't add a hosted-domain CTA** ("Visit gridctl.io") — no such domain exists.

### Suggested Build Order

1. Draft the new `README.md` end-to-end in full (this is the source of truth for what moves).
2. Create `docs/installation.md` by extracting README.md:71–193 content, adjusting headings/links.
3. Create `docs/cli-reference.md` by extracting README.md:416–531 content, adding intro + ToC.
4. Create `docs/project-status.md` by extracting README.md:605–645 content, adding intro about stability tiers.
5. Update `docs/README.md` into the real index.
6. Delete moved content from the landing `README.md`.
7. Verify line count is 180–230.
8. Grep for broken internal links: `grep -rnE '\]\([^)h][^)]*\)' README.md docs/*.md` then manually check each.
9. Open the rendered README in GitHub preview locally (`gh markdown-preview` or push to a branch and view on GitHub) to spot any rendering issues.
10. Run `make build` to confirm no Go test or generated file references a moved README anchor (low risk per evaluation but cheap to verify).

## Acceptance Criteria

1. `README.md` line count is between 180 and 230.
2. New files exist: `docs/installation.md`, `docs/cli-reference.md`, `docs/project-status.md`. Each opens with an H1.
3. `docs/README.md` is a real index (grouped sections, all new docs files linked, existing inbound link to `../README.md#-quick-start` preserved).
4. Primary tagline at top of README is exactly: **"The developer cockpit for MCP servers and Agent Skills."**
5. Sub-tagline is exactly: *"One YAML. One endpoint. Every MCP server and Agent Skill."*
6. The string "Operating System for MCP Grids" does NOT appear anywhere in the repo (grep -r confirms zero matches).
7. The string "MCP proxy" does not appear as gridctl's self-description (other contexts OK — e.g. naming a peer tool).
8. `gridctl agent dev` is labeled "Early Access" or equivalent in any landing-README feature block where it appears.
9. All internal markdown links in `README.md` and `docs/*.md` resolve to existing files/anchors (verified via grep + manual check).
10. The hero GIF `assets/gridctl.gif`, UI GIF `assets/gridctl-ui.gif`, and `assets/install.gif` all continue to be referenced from their appropriate locations (gridctl.gif on landing README, install.gif now lives on `docs/installation.md`).
11. No code files (`*.go`, `*.ts`, `*.tsx`, `*.json`, `*.yaml`) have been modified.
12. No new build tooling has been added (no `mkdocs.yml`, no `docusaurus.config.js`, no new package.json entries).
13. `make build` succeeds.
14. `go test ./...` succeeds.

## References

- Full evaluation: `/Users/william/code/prompt-stack/prompts/gridctl/docs-restructure-landing/feature-evaluation.md`
- Current README: `/Users/william/code/gridctl/README.md`
- Current docs index: `/Users/william/code/gridctl/docs/README.md`
- Stability table (source of truth for Stable vs Experimental labeling): README.md:605–637
- Peer-set comparators:
  - https://github.com/cli/cli/blob/trunk/README.md (105 lines — gold standard)
  - https://github.com/flox/flox/blob/main/README.md (145 lines)
  - https://github.com/k3d-io/k3d/blob/main/README.md (201 lines)
  - https://github.com/aquasecurity/trivy/blob/main/README.md (147 lines)
- MCP competitor pitches (do NOT mimic, but useful for tonal triangulation):
  - https://github.com/IBM/mcp-context-forge — enterprise gateway framing
  - https://github.com/stacklok/toolhive — enterprise platform framing
  - https://github.com/mcp-router/mcp-router — local-first desktop framing
- Anthropic Agent Skills (the standard "Agent Skills" naming aligns with): https://agentskills.io/home
