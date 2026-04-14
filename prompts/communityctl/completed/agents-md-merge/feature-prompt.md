# Feature Implementation: Merge DCOMM AGENTS.md into communityctl AGENTS.md

## Context

**communityctl** is a Claude Code skills toolkit for managing Itential community repositories on GitHub. It lives at `github.com/itential/communityctl` and provides two skills:
- `/onboarding` — bootstraps new repos from `skeleton/` templates, configures GitHub teams + branch protection
- `/audit` — runs compliance checks against the skeleton standard, publishes graded reports to Atlassian Confluence

The project uses a `CLAUDE.md` → `@AGENTS.md` indirection pattern: `CLAUDE.md` is a one-liner that imports `AGENTS.md` via `@AGENTS.md`. `AGENTS.md` is the actual guidance document.

The Atlassian MCP server (`getConfluencePage`, `createConfluencePage`, `getConfluencePageDescendants`, etc.) provides Confluence read/write access. These tools are referenced in skill files but the infrastructure constants (Cloud ID, Space IDs, page IDs) are currently hardcoded in the audit skill rather than centralized in AGENTS.md.

## Evaluation Context

- The current AGENTS.md covers only GitHub operations; the DCOMM AGENTS.md is a superset covering the full Itential community operational surface
- The audit skill already writes to Confluence but AGENTS.md documents none of the Confluence access rules — an active guardrail gap
- Future skills (Jira integration, marketplace management) require Atlassian context that doesn't exist anywhere in communityctl
- The Atlassian MCP server may not always be active in a session; AGENTS.md should document it as expected infrastructure so agents know when it's available
- Full evaluation: `/Users/william/code/prompt-stack/prompts/communityctl/agents-md-merge/feature-evaluation.md`

## Feature Description

Rewrite `AGENTS.md` to be a unified, comprehensive guide for AI agents executing all Itential community work from communityctl — both GitHub repository lifecycle operations AND Atlassian/Jira operations. The result should be the single document an agent needs to operate correctly, safely, and with full context.

## Requirements

### Functional Requirements

1. Preserve all existing AGENTS.md content (project overview, available commands, project structure, skeleton template tables, placeholder reference, template conventions)
2. Add the DCOMM project overview section describing the broader community ecosystem (platform/OSS analogy, primary owner, co-owner, senior stakeholder)
3. Add a Repository Topology section covering both GitHub (`github.com/itential`) and GitLab (`gitlab.com/itentialopensource`)
4. Add a Key Infrastructure section with Atlassian reference tables: Confluence space IDs, Jira project key/ID/board URL, William's personal space ID, Cloud ID
5. Add Confluence operational rules as a subsection: restricted page creation, no partial patch updates, no MCP page deletion, Planning & Development folder protection (parentId `5890539521`)
6. Add a Community Marketplace section: registry model, `active`/`status` field semantics, project types, certification tiers
7. Add Active Workstreams section (itential-skills, job-and-task-archiver, Project Intake Pipeline, .github org repo)
8. Add Naming Conventions section
9. Add Governance Principles section (the four principles)
10. Add Document & Code Style section (Confluence fonts, presentation palette, communication style, iteration velocity)
11. Add a Tooling Reference table (Claude Code + itential-skills, Grafana, Shields.io, SVG badges, portal options)
12. Add a prominent "What Agents Should NOT Do" section with all constraints from the DCOMM document
13. Add a Useful Links reference table at the end
14. Move the Confluence Cloud ID and Space ID constants from `audit/SKILL.md` into AGENTS.md as canonical infrastructure references (the skill can reference them from context rather than hardcoding)

### Non-Functional Requirements

- The document must remain clean, readable markdown — no raw HTML, no broken tables
- Section order should follow a natural reading progression: Who we are → What we work with → Infrastructure → Commands → Standards → Governance → Safety rules
- The file should be self-contained: an agent with no prior context should be able to read it and operate correctly
- Keep the `CLAUDE.md` → `@AGENTS.md` pattern intact — do not modify `CLAUDE.md`

### Out of Scope

- Do not modify any skill files (SKILL.md files) beyond removing constants that move to AGENTS.md
- Do not add new skills or commands
- Do not create any new files other than the updated AGENTS.md

## Architecture Guidance

### Recommended Approach

This is a documentation merge, not a code change. The recommended approach:

1. Read both source documents in full
2. Draft the merged structure section by section, resolving conflicts by preferring specificity (keep communityctl-specific detail, don't overwrite with generic DCOMM language)
3. The existing "Available Commands" and "Project Structure" sections are well-formatted — preserve them verbatim
4. The DCOMM sections (Governance Principles, What NOT To Do, etc.) can be incorporated largely as-is

### Key Files to Understand

| File | Why it matters |
|------|----------------|
| `/Users/william/code/itential/communityctl/AGENTS.md` | Source document #1 — primary structure to preserve |
| `/Users/william/code/itential/communityctl/CLAUDE.md` | One-liner importing AGENTS.md — do not modify |
| `/Users/william/code/itential/communityctl/.claude/skills/audit/SKILL.md` | Contains hardcoded Confluence IDs to reference from AGENTS.md |
| `/Users/william/code/itential/communityctl/.claude/skills/onboarding/SKILL.md` | Full onboarding workflow — understand what context it needs |

### Integration Points

- `AGENTS.md` is loaded into every Claude Code session via `CLAUDE.md` → `@AGENTS.md`
- The audit skill references `Cloud ID: 2ece816a-62e4-4222-8518-b5507d198470` and `Space ID: 5487231058` — these should be documented in AGENTS.md's infrastructure table (the skill file can keep its own local reference for execution, but AGENTS.md becomes the source of truth)

### Reusable Components

Both source documents. The merge is additive — almost nothing conflicts.

## UX Specification

**Discovery**: The document is auto-loaded via `CLAUDE.md`; no agent action needed.

**Section ordering** (recommended):

```
# AGENTS.md
1. Project Overview (DCOMM ecosystem context + communityctl role)
2. Repository Topology (GitHub + GitLab)
3. Key Infrastructure (Atlassian tables + Confluence rules)
4. Available Commands (/onboarding, /audit — preserve existing)
5. Project Structure (directory tree — preserve existing)
6. Template Files (skeleton/ table — preserve existing)
7. Placeholder Reference (preserve existing)
8. Template Conventions (preserve existing)
9. Community Marketplace (registry, schema, types, tiers)
10. Active Workstreams
11. Naming Conventions
12. Governance Principles
13. Document & Code Style
14. Tooling Reference
15. What Agents Should NOT Do  ← prominent, near end
16. Useful Links
```

**Tone**: The document is written for AI agents, not humans. Be precise and explicit. Prefer tables and lists over prose. Safety constraints (section 15) should be written as direct imperatives.

## Implementation Notes

### Conventions to Follow

- File header: `# CLAUDE.md` is the current header — preserve it (it's the conventional name even though the file is AGENTS.md; the CLAUDE.md indirection is intentional)
- Table formatting: use standard GFM pipe tables, consistent column spacing
- All IDs that appear in the DCOMM AGENTS.md should be treated as authoritative — do not invent or modify them
- The Confluence `isPrivate: true` restriction rule is critical safety context — make it visually prominent in the Confluence rules subsection

### Potential Pitfalls

- The current AGENTS.md header says `# CLAUDE.md` — this is intentional (the file is named AGENTS.md but the header reflects its role as Claude's instruction file). Keep this header.
- Do not accidentally drop the "Template Conventions" section — it contains important rules (sign all commits, squash merging only) that skills rely on
- The DCOMM AGENTS.md uses `isPrivate: true` language for Confluence page creation; the audit skill uses `createConfluencePage` — make sure the documented rule matches the skill's actual behavior

### Suggested Build Order

1. Read both source documents in full
2. Draft the merged outline (section headers only) and verify nothing is missed
3. Write section by section, top to bottom
4. Final pass: verify all Confluence/Jira IDs match the DCOMM source exactly
5. Verify no placeholders or template text remains

## Acceptance Criteria

1. The merged AGENTS.md contains all content from both source documents with no information lost
2. Confluence Cloud ID, Space ID, DCOMM Homepage Page ID, Compliance Folder ID, and Planning & Development folder parentId are all present in infrastructure reference tables
3. Jira project key (`COMM`), project ID (`16322`), and board URL are present
4. "What Agents Should NOT Do" section is present with all 7 constraints from the DCOMM document
5. All four Governance Principles are present
6. The existing "Available Commands" section is unchanged
7. The existing "Project Structure" directory tree is unchanged
8. The file passes a markdown lint check (no broken tables, consistent heading hierarchy)
9. `CLAUDE.md` is unchanged

## References

- DCOMM AGENTS.md content: provided inline in the original feature request
- Confluence Compliance Folder ID: `5968953424` (from audit/SKILL.md)
- Confluence Cloud ID: `2ece816a-62e4-4222-8518-b5507d198470` (from audit/SKILL.md)
- DCOMM Space ID: `5487231058`
- DCOMM Homepage Page ID: `5487231212`
- Planning & Development folder parentId: `5890539521`
- Jira Project Key: `COMM`, Project ID: `16322`
- William's Personal Space ID: `4947804203`
