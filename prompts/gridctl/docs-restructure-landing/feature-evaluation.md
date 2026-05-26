# Feature Evaluation: Docs Restructure & Messaging Refresh

**Date**: 2026-05-16
**Project**: gridctl
**Recommendation**: **Build with caveats**
**Value**: High (newcomer conversion + positioning)
**Effort**: Small–Medium (½ day to 1 day)

## Summary

The 667-line README is in lazygit territory while six of eight peer Go-CLIs (gh, devbox, flox, k3d, trivy, mkcert) sit at 100–210 lines. The proposed structural split into a landing-page README + new `docs/installation.md`, `docs/cli-reference.md`, and `docs/project-status.md` is sound, low-risk, and matches universal peer practice. The proposed messaging pivot to *"Operating System for MCP Grids"* should be rejected — the OS metaphor is over-used in the MCP gateway space and "Grid" is a noun the market has not adopted. A verb-based, local-first positioning ("The developer cockpit for MCP servers and Agent Skills") is more defensible and reflects what the code actually does.

## The Idea

Refactor gridctl's documentation surface in three coordinated moves:

1. **Structural**: Shrink the 667-line README into a ~200-line landing page. Move installation detail, CLI reference tables, and stability/limitations into dedicated files in `docs/`.
2. **Messaging**: Reposition gridctl from "MCP proxy/gateway" to a sharper pitch that reflects current investment in agents, skills, and cost observability.
3. **Visual**: Elevate the hero GIF and add a dedicated visual showcase for `gridctl agent dev`.

**Problem solved**: New visitors bounce off the wall of text before reaching Quick Start. The product's strongest current differentiators (skills runtime, optimize, format conversion) are buried under flag tables. Returning users have no clean reference structure.

**Beneficiaries**: First-time visitors (the dominant audience for a pre-1.0 OSS project); returning power users (faster reference lookup); maintainer (positioning that matches code investment).

## Project Context

### Current State

gridctl is at **v0.1.0-beta.9 (unreleased)** with a massive pending changelog — Phase F agent IDE (PR #599), `gridctl run`/`runs` ledger, Go-plugin skills, multi-agent orchestrator, optimize CLI + five heuristics, cost layer. Active investment over the last 6 weeks has been in the **agent + skills + cost stack**, not in the core MCP gateway (which is stable).

Maturity signals: CI gatekeeper (lint, race tests, vuln scan, Podman parity), OpenSSF Best Practices badge, dedicated `docs/` directory at 3,286 lines across 6 files, Apache 2.0, hero GIF assets in `assets/`.

### Integration Surface

| File | Action |
|---|---|
| `README.md` | Trim from 667 → ~200 lines |
| `docs/README.md` | Upgrade from 25-line stub to real index |
| `docs/installation.md` | NEW — extracted from README lines 71–193 |
| `docs/cli-reference.md` | NEW — extracted from README lines 416–531 |
| `docs/project-status.md` | NEW — extracted from README lines 605–645 |
| `assets/agent-ide.gif` | NEW (optional, gated on quality) — recorded via `/gif-create` |

**Risk surface is unusually low**: only ONE inbound anchor link to README exists in the entire repo (`docs/README.md` → `../README.md#-quick-start`). No external website, no gh-pages, no `gridctl.io` domain, no package-manager formulas in this repo, no CLI help text or test fixtures that reference README anchors.

### Reusable Components

- Existing hero GIFs (`assets/gridctl.gif`, `assets/gridctl-ui.gif`, `assets/install.gif`) — already production quality
- `assets/*.tape` files for VHS reproduction
- Existing `docs/` content (api-reference, config-schema, cost-observability, scaling, skills, troubleshooting) — keep as-is, just integrate into the new index
- `/gif-create` skill for the optional new agent IDE GIF
- README's existing `<details>` collapsible sections — port pattern into `docs/installation.md`

## Market Analysis

### Competitive Landscape

**Direct MCP gateway peers (May 2026)**:

| Tool | Self-description | Differentiator |
|---|---|---|
| IBM ContextForge | "AI Gateway, registry, proxy... centralized discovery, guardrails, management" | Enterprise A2A, RBAC, plugins |
| ToolHive (Stacklok) | "Enterprise-grade platform for running and managing MCP servers" | Container isolation, K8s operator, agent skills bundled |
| Pluggedin MCP | "The Crossroads for AI Data Exchanges" | Self-hosted web UI, trending analytics |
| Smithery | "Largest open registry for connecting AI agents" | 7,000+ server registry, hosted runtime |
| MCPJungle | "One place to manage & connect to all your MCP servers" | Self-hosted registry, RBAC enterprise |
| mcp-router | "Unified MCP Server Management App" | Local-first desktop manager |
| sparfenyuk/mcp-proxy | "A bridge between Streamable HTTP and stdio" | Pure transport bridge |

**Comparable Go-CLI README structures**:

| Project | README lines | Install in README | CLI reference location |
|---|---|---|---|
| gh (cli/cli) | 105 | Per-OS file links | cli.github.com/manual |
| flox | 145 | One-liner + link | flox.dev/docs |
| trivy | 147 | One-liner + link | trivy.dev (MkDocs) |
| mkcert | 197 | Per-OS in README | In-README |
| devbox | 194 | One-liner + link | jetify.com/devbox/docs |
| k3d | 201 | Brief + link | k3d.io (MkDocs) |
| lazygit | 637 | All package managers | docs/keybindings/ |
| k9s | 1,401 | Full | In-README |

### Market Positioning

The structural change is **catch-up to peer convention** — 6 of 8 peers ship at 100–210 lines. Long-form READMEs (lazygit, k9s) are legacy that grew organically; new launches (devbox, flox in 2024–25) ship landing-page-style from day one.

The proposed messaging change is more contested:

- **"Operating System for MCP Grids"** suffers from three problems: (1) OS-metaphor inflation — ContextForge, ToolHive, and literal "Control Plane" Inc. already use control-plane/OS language; (2) "Grid" is an unfamiliar product noun (and the README's *own* current vocabulary is "stack," not "grid"); (3) "Agent IDE" and "cost optimize" are increasingly table-stakes — ToolHive, Pluggedin, and Smithery all ship comparable surfaces.

- **What gridctl actually owns** (per code investment and peer gap): a **local-first developer cockpit** for MCP servers + Anthropic Agent Skills with run inspection. mcp-router is local-first but has no agent layer. ToolHive has agents but ships enterprise/server-deployed. ContextForge is server-side. Smithery is hosted. None of them combine local-first + skills runtime + run inspector + cost observability in one developer-facing workspace.

### Ecosystem Support

- **Plain markdown in `docs/`** is the dominant pattern in this peer set (lazygit, gh ship substantial docs as plain markdown with a `docs/README.md` index).
- **MkDocs Material** is the standard upgrade path for Go CLIs when plain markdown becomes painful (trivy, k3d, flox all use it).
- **Docusaurus / starlight / just-the-docs** are uncommon in this peer set — typically appear with company-backed docs or framework-scope projects.

The recommended move is to **stay in plain markdown** for this refactor. Revisit a hosted site only when search, versioning, or page count force the change.

### Demand Signals

- The 667-line README is significantly above the median peer length, which is direct evidence of structural debt.
- Anthropic's Agent Skills standard (agentskills.io, Dec 2025) is in 26+ tools — vocabulary alignment with "Skills" is increasingly valuable.
- gridctl's recent commits (WorkspaceShell, skills inspector, runs workspace, Phase F IDE) signal the product is becoming a workspace, not just a proxy. Messaging should catch up.

## User Experience

### Interaction Model

**New-visitor journey (target: 30-second decision)**:
- Today: Hero GIF → install wall → container runtime wall → Quick Start at line 194. Most visitors bounce.
- Proposed: Hero GIF → "Why" → YAML example → 1-line install + link → 3-command Quick Start. Fits in 1–2 scrolls. Major win.

**Returning-user journey (reference lookup)**:
- Today: 116 lines of CLI tables in README. Find-in-page works.
- Proposed: dedicated `docs/cli-reference.md` with per-command-group ToC. One extra click; better organization; better SEO (each docs page gets its own search-engine URL).

### Workflow Impact

- *Reduces friction* for newcomers (dominant audience).
- *Adds one click* for returning power users (mitigate with a prominent "📚 [CLI Reference](docs/cli-reference.md)" link).
- *Improves Google discoverability* — each docs page becomes its own SEO entry.
- *Improves maintenance ergonomics* — focused files are easier to keep current than a mega-README.

### UX Recommendations

1. **Keep a 1-line install snippet in the landing README** — mirror gh/devbox/flox. Don't fully exile install.
2. **Upgrade `docs/README.md` from 25-line stub to a real index** with grouped links (References / Guides / Operations / Quick Links). This becomes the docs nav since GitHub has no built-in left rail.
3. **Use collapsible `<details>` sections** in `docs/installation.md` for per-method install steps — port the pattern that already works in the current README.
4. **Don't elevate `gridctl agent dev` to the hero spot yet.** The stability table currently marks it Experimental; the feature landed days ago; there's no demo GIF. Feature it as "Early Access" — lead with `optimize` + skills + format conversion as the *currently-shipped* differentiators.
5. **Add an agent IDE GIF** as part of the change OR hold the IDE feature block until one exists. `/gif-create` is the tool.
6. **Anchor stability** — update `docs/README.md`'s only inbound link to either keep pointing at `../README.md#quick-start` (if Quick Start stays on the landing) or repoint to a new `docs/getting-started.md`.

## Feasibility

### Value Breakdown
| Dimension | Rating | Notes |
|---|---|---|
| Problem significance | Significant | 667-line README is measurable bounce risk; competitive set sits at 100–210 lines |
| User impact | Broad+Shallow (newcomers), Narrow+Deep (maintainer) | Wide first-impression surface |
| Strategic alignment | Core mission | Pre-1.0 project in a crowded space; positioning IS the strategy |
| Market positioning | Catch up (structure) + Differentiate (messaging if reframed) | OS-for-Grids loses; local-first cockpit wins |

### Cost Breakdown
| Dimension | Rating | Notes |
|---|---|---|
| Integration complexity | Minimal | One inbound link, no external surface, pure markdown moves |
| Effort estimate | Small–Medium | ~½ day structural + ~2–3 hours messaging + 30–60 min GIF |
| Risk level | Low (structure), Medium (messaging) | Messaging is harder to walk back once cited externally |
| Maintenance burden | Reduced | Focused files easier to maintain than one mega-README |

## Recommendation

**Build with caveats.**

The structural split is well-aligned with peer practice, addresses a real friction point, is low-risk, and is low-effort. Do it.

Five caveats scope the work:

1. **Replace "OS for MCP Grids" with a verb-based, local-first pitch.** Recommended primary: *"The developer cockpit for MCP servers and Agent Skills."* Recommended sub-tagline (stays close to current): *"One YAML. One endpoint. Every MCP server and Agent Skill."*

2. **Don't elevate `gridctl agent dev` to the hero spot yet.** Mark it "Early Access." Lead with the three currently-stable + differentiated features: declarative stack management ("Stack as Code"), `gridctl optimize` + cost observability, and `toon`/`csv` output format conversion.

3. **Upgrade `docs/README.md` into a real index** as part of the same change.

4. **Stay in plain markdown.** Do NOT introduce MkDocs/Docusaurus/a hosted site as part of this refactor. Revisit when the docs catalog or skills registry forces it.

5. **Keep a 1-line install in the landing README.** Mirror gh/devbox/flox.

If `gridctl agent dev` matures (gets a GIF, gets 2–3 weeks of field use, gets promoted out of Experimental in the stability table), revisit the hero positioning in a subsequent docs PR — it becomes the natural lead the moment those gates clear.

## References

- gridctl current README: `/Users/william/code/gridctl/README.md`
- gridctl stability table: README.md lines 605–637 (truth source for what's Experimental vs Stable)
- gridctl docs index: `/Users/william/code/gridctl/docs/README.md`
- cli/cli README: https://github.com/cli/cli (105 lines, gold-standard split)
- flox README: https://github.com/flox/flox (145 lines)
- trivy README: https://github.com/aquasecurity/trivy (147 lines, MkDocs site)
- k3d README: https://github.com/k3d-io/k3d (201 lines, MkDocs site)
- lazygit README: https://github.com/jesseduffield/lazygit (637 lines, plain markdown docs/)
- IBM mcp-context-forge: https://github.com/IBM/mcp-context-forge
- ToolHive: https://github.com/stacklok/toolhive
- Pluggedin MCP: https://github.com/VeriTeknik/pluggedin-mcp-proxy
- Smithery: https://smithery.ai
- mcp-router: https://github.com/mcp-router/mcp-router
- agentskills.io: https://agentskills.io/home
- Anthropic Agent Skills engineering post: https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills
- Backstage (avoids "OS" framing): https://backstage.spotify.com/
- MkDocs Material: https://squidfunk.github.io/mkdocs-material/
