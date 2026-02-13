---
description: >
  Audit and improve project documentation. Use when the user says: "update docs",
  "improve readme", "sync documentation", "audit docs", "refresh docs",
  "update examples", "improve documentation", "docs are outdated",
  "make the README better", "documentation review", "clean up docs",
  "keep docs up to date", or "doc refresh". Works on any Git project.
argument-hint: "[audit | improve | sync]"
---

# Docs

Audit, improve, and synchronize project documentation with the codebase. Works on any Git project.

## Detect Mode

Parse `$ARGUMENTS` to determine mode:

- Starts with `audit` or `review` or is empty → **Audit Mode**
- Starts with `improve` or `refresh` or `update` → **Improve Mode**
- Starts with `sync` → **Sync Mode**

---

## Audit Mode

Scan the project and evaluate documentation against best practices. Produce an actionable report.

### 1. Understand the Project

Before evaluating docs, understand what the project actually does:

1. Read `README.md`, `CONTRIBUTING.md`, `CHANGELOG.md`, `AGENTS.md`, `CLAUDE.md` if they exist
2. Read `go.mod`, `package.json`, `Cargo.toml`, `pyproject.toml`, or equivalent for tech stack
3. Scan the directory tree to understand project structure
4. Read key source files to understand core functionality
5. Check `examples/` or `docs/` directories
6. Check `.github/` for templates and workflows

### 2. Evaluate README

Read `references/readme-best-practices.md` for detailed scoring criteria.

Score each dimension (Pass / Needs Work / Missing):

| Dimension | What to Check |
|-----------|---------------|
| **Hero Section** | Logo/banner, badges (3-7), one-liner value prop, visual demo |
| **10-Second Value** | Can a developer understand what this does and why immediately? |
| **Voice** | Authentic tone? No generic filler ("powerful", "flexible", "scalable")? |
| **Quick Start** | Try the tool in under 5 minutes? One-liner install? |
| **Visual Demos** | GIFs or screenshots showing it in action? |
| **Scannability** | Clear headings, tables, collapsible sections, no walls of text? |
| **Examples** | Code examples that work? Representative use cases? |
| **Installation** | Multiple methods? Collapsible details for alternatives? |
| **Architecture** | Entry point, not encyclopedia? Links to deeper docs? |
| **Contributing** | Welcoming tone? Clear process? |
| **Freshness** | Examples match current CLI? Badges current? Links work? |

### 3. Evaluate Supporting Docs

Check existence and adequacy:

| Document | Purpose | Open Source? |
|----------|---------|:------------:|
| `CONTRIBUTING.md` | Dev setup, conventions, PR process | Required |
| `CHANGELOG.md` | Version history | If releasing |
| `CODE_OF_CONDUCT.md` | Community standards | Recommended |
| `SECURITY.md` | Vulnerability reporting | Recommended |
| `.github/ISSUE_TEMPLATE/` | Bug report, feature request | Recommended |
| `.github/pull_request_template.md` | PR checklist | Recommended |

### 4. Present Report

Format findings as an actionable report:

```
## Documentation Audit: {project-name}

### README.md
| Dimension | Status | Notes |
|-----------|--------|-------|
| Hero Section | ✅ Pass | ... |
| 10-Second Value | ⚠️ Needs Work | ... |
| ... | ... | ... |

### Supporting Docs
| Document | Status |
|----------|--------|
| CONTRIBUTING.md | ✅ Present |
| CHANGELOG.md | ❌ Missing |

### Top 3 Recommendations
1. {Most impactful improvement}
2. {Second most impactful}
3. {Third most impactful}
```

Use `AskUserQuestion` to ask if the user wants to proceed to **Improve Mode** for any findings.

---

## Improve Mode

Make targeted documentation improvements based on best practices.

### 1. Scope the Work

If `$ARGUMENTS` specifies a focus (e.g., "improve readme hero section"), scope to that.

Otherwise:
1. Run the Audit Mode checks mentally
2. Identify the 3-5 highest-impact improvements
3. Use `AskUserQuestion` to confirm scope with user

### 2. Apply README Best Practices

Read `references/readme-best-practices.md` for the complete guide. Core principles:

**Hero Section** — First thing visitors see:
- Logo or banner image
- 3-7 shields.io badges (build status, version, license minimum)
- Single-sentence value prop under 10 words
- GIF or screenshot demonstrating the tool immediately after

**Value Proposition** — Why this exists:
- Use comparison-based ("like X but for Y"), problem-first ("tired of X?"), or philosophy-driven
- Be specific. Concrete descriptions beat abstract superlatives
- Sound human. Personal motivation or problem statements build trust

**Information Architecture** — Respect scanning:
1. Hero (logo, badges, one-liner)
2. Visual demo
3. Why this exists (2-3 sentences max)
4. Quick start (install + first command)
5. Key features (scannable — tables, short descriptions)
6. Examples (linked, not inline novels)
7. CLI reference (if applicable)
8. Contributing link
9. License

**Scannability**:
- Tables for structured comparisons
- `<details>` for secondary info (alt install methods, advanced config)
- One concept per heading
- GitHub alert syntax (`> [!NOTE]`, `> [!TIP]`) for callouts
- No implementation details in README — move to AGENTS.md or docs/

**Voice**:
- Kill empty words: "powerful", "flexible", "scalable", "comprehensive", "enterprise-grade"
- Replace with specifics: what it does, how fast, how many
- Don't overdo emojis — one per section heading max
- Explain the "why" through personal motivation or problem statement

**Anti-Patterns to Fix**:
- Walls of text without visual breaks
- Source code / implementation details in README (move to AGENTS.md or docs/)
- Features described in paragraphs instead of scannable format
- Missing one-liner install option
- Missing "why" section
- Outdated examples or broken links

### 3. Edit Surgically

For each change:
- Read the file first
- Make targeted edits — don't rewrite entire files unless asked
- Preserve existing structure and voice where it works
- Move content rather than delete (e.g., implementation details → AGENTS.md)
- Tighten prose: cut words that don't earn their place

### 4. Verify Changes

After edits:
1. Check all internal links still resolve
2. Verify code examples are syntactically valid
3. Confirm referenced files exist
4. Show the user a summary of what changed and why

---

## Sync Mode

Update documentation to match current codebase state. Focus on accuracy, not style.

### 1. Inventory What Could Drift

Scan docs for anything that references code, CLI, or configuration:
- CLI commands and flags
- Code examples (YAML, JSON, config files)
- Installation instructions (versions, package names, build commands)
- Configuration schemas and field names
- Example files referenced by path
- Badge URLs and external links
- Import paths and module names

### 2. Verify Against Source

For each item:

**CLI references** — Read CLI source code (cobra commands, argparse, click, etc.) and compare documented flags, subcommands, and usage strings.

**Code examples** — Check that example YAML/JSON/code uses current field names, valid syntax, and reflects actual behavior.

**Example files** — Verify files in `examples/` still exist and match their descriptions.

**Installation** — Confirm:
- Package names and tap/repo URLs are correct
- Version numbers aren't stale (if pinned)
- Build commands still work

**Links** — Verify internal file references resolve. Flag potentially stale external links.

**Badges** — Confirm badge URLs reference correct org/repo/branch.

### 3. Fix Drift

For each discrepancy:
1. Update documentation to match the code (code is source of truth)
2. If the discrepancy suggests a code bug, flag it to the user instead

### 4. Report Changes

```
## Sync Report

### Updated
- README.md: Updated CLI reference (added --verbose flag)
- README.md: Fixed example config field name (topology → stack)

### Flagged
- examples/ssh-mcp.yaml: Referenced in README but file doesn't exist

### No Changes Needed
- Installation instructions: current
- Badges: correct
```

---

## Important Rules

- **Code is source of truth** — When docs and code disagree, update docs unless it's a code bug
- **README is an entry point** — Move implementation details to AGENTS.md, docs/, or wiki
- **Preserve existing voice** — Match the project's established tone, don't impose a different one
- **Edit surgically** — Targeted improvements, not wholesale rewrites (unless user asks)
- **Show, don't tell** — GIFs, code examples, and tables over prose paragraphs
- **No generic filler** — Every sentence earns its place or gets cut
- **Don't create docs the project doesn't need** — Not every project needs a SECURITY.md
