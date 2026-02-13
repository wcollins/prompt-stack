# README Best Practices Reference

Condensed from analysis of 30+ high-star repositories (fzf, lazygit, Supabase, Charmbracelet, K9s, Caddy, etc.). Use this as scoring criteria during audits and as a guide during improvements.

## Hero Section Formula

The sequence that works across 50k+ star repos:

1. **Logo or banner** — Establishes visual identity
2. **Badge row (3-7 badges)** — Build status, version, license minimum. Go projects add Go Report Card
3. **One-liner value prop** — Communicates purpose in under 10 words
4. **Visual demo** — GIF or screenshot immediately showing the tool in action

**Good examples:**
- fzf: "A general-purpose command-line fuzzy finder" + screenshot
- Gum: "A tool for glamorous shell scripts" + animated GIF
- Caddy: "Fast and extensible multi-platform HTTP/1-2-3 web server with automatic HTTPS"

**What kills it:**
- No visual demo (text-only hero)
- More than 7 badges (visual clutter)
- Generic tagline that could describe any project in the category

## 10-Second Value Communication

Three techniques that work for technical audiences:

**Comparison-based** — Orient via familiar tools:
- mise: "Like asdf, Like direnv, Like make"
- Helm: "apt/yum/homebrew for Kubernetes"
- Supabase: "Firebase-like developer experience using open source tools"

**Problem-first** — Create emotional resonance:
- lazygit: "You've heard it before, git is *powerful*, but what good is that power when everything is so damn hard to do?"
- tRPC: "Move Fast and Break Nothing"
- Drizzle: "No bells and whistles, no Rust binaries, no serverless adapters, everything just works"

**Philosophy-driven** — Signal intentional design:
- Remix: Model-First Development, Build on Web APIs, Religiously Runtime
- Hono: Name means "flame" in Japanese — cultural identity creates memorability

## Voice & Personality

**Do:**
- Write like a human with opinions: "I built this because..." rather than "This solution provides..."
- Use concrete specifics: "aggregates 20 MCP servers into one endpoint" not "powerful MCP management"
- One personality touch per section is enough
- Personal motivation sections build trust (K9s maintainer asking for sponsorship, lazygit's frustration-based elevator pitch)

**Don't:**
- Generic superlatives without proof: "powerful", "flexible", "scalable", "enterprise-grade", "blazing fast"
- More than 2-3 emojis per section
- Formal language no developer uses: "This repository contains a comprehensive solution for..."
- Descriptions that could apply to any project in the same category

## Information Architecture

The optimal order (proven across high-star repos):

1. Hero section (logo, badges, one-liner)
2. Visual demo (GIF or screenshot)
3. Why this exists (2-3 sentences, personal voice)
4. Quick start (install + first command, under 5 lines total)
5. Key features (scannable format)
6. Examples (linked or brief inline)
7. CLI reference (if applicable)
8. Contributing link
9. License

**Critical rule:** README is an entry point, not an encyclopedia. Link to deeper docs for everything else.

## Scannability Techniques

| Technique | When to Use |
|-----------|-------------|
| Tables | Comparing features, listing options, showing transport types |
| `<details>` sections | Alternative install methods, advanced config, platform-specific info |
| GitHub alerts | `> [!NOTE]`, `> [!TIP]`, `> [!WARNING]` for important callouts |
| Short headings | One concept per heading, scan-friendly |
| Code blocks | Every command, config snippet, or example |
| `<picture>` tags | Theme-aware images (light/dark mode) |

**Anti-patterns:**
- Walls of text (3+ paragraphs without a heading, code block, or visual break)
- Implementation details in README (Go code, internal architecture — move to AGENTS.md)
- Features described in paragraphs instead of tables or bullet lists
- Inline navigation TOC for short READMEs (GitHub auto-generates one)

## Quick Start Standards

Must be achievable in under 5 minutes:

```bash
# Install (one-liner)
brew install tool/tap/tool

# Try it
tool deploy examples/hello-world.yaml

# See it working
open http://localhost:8080

# Clean up
tool destroy
```

**Multiple install methods** — Use `<details>` for alternatives:
```html
<details>
<summary>Other installation methods</summary>

... alternative methods here ...

</details>
```

## Examples Section

- Link to example files rather than inlining long configs
- Table format works well: Example name | What it demonstrates
- Keep inline examples short (under 20 lines)
- Every example should be copy-pasteable and runnable

## Contributing Section

- Welcoming tone: "Contributions welcome!" (many projects omit this)
- Link to `CONTRIBUTING.md` for details — don't put dev setup in README
- Mention non-code contribution types (docs, design, testing, triage)
- Keep it to 2-3 lines in README

## Supporting Documents Checklist

| Document | What It Contains | Priority |
|----------|-----------------|----------|
| `CONTRIBUTING.md` | Dev setup, conventions, PR process | High |
| `CHANGELOG.md` | Version history (conventional changelog format) | High if releasing |
| `CODE_OF_CONDUCT.md` | Community standards (Contributor Covenant) | Medium |
| `SECURITY.md` | Vulnerability reporting process | Medium |
| `.github/ISSUE_TEMPLATE/bug_report.md` | Structured bug reports | Medium |
| `.github/ISSUE_TEMPLATE/feature_request.md` | Structured feature requests | Medium |
| `.github/pull_request_template.md` | PR checklist | Medium |

## Scoring Guide for Audits

**Pass** — The dimension is handled well. Follows best practices. No action needed.

**Needs Work** — Present but could be meaningfully improved. Specific suggestion available.

**Missing** — Not present at all, and the project would benefit from adding it.

When scoring, weight impact over completeness. A README with a great hero section and working quick start but no SECURITY.md is in better shape than one with every supporting doc but a forgettable first impression.
