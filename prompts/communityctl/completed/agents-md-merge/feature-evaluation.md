# Feature Evaluation: Merge DCOMM AGENTS.md into communityctl AGENTS.md

**Date**: 2026-04-02
**Project**: communityctl
**Recommendation**: Build
**Value**: High
**Effort**: Small

## Summary

The existing communityctl `AGENTS.md` covers only GitHub repository management (skeleton templates, onboarding, compliance audits). The DCOMM `AGENTS.md` is a broader operational framework for all AI agents working on Itential community work — including Atlassian infrastructure, Jira, marketplace governance, and agent safety constraints. Merging them makes communityctl the single authoritative execution engine for all Itential community operations, and closes active guardrail gaps that currently leave agents operating without Confluence safety rules.

## The Idea

Blend the current communityctl `AGENTS.md` (GitHub-focused) with the provided DCOMM `AGENTS.md` (full community framework) into a single unified document. The result should make communityctl the definitive source of truth and execution engine for both GitHub repo lifecycle work AND Atlassian/Jira operations.

**Problem it solves**: Agents operating from communityctl today have no Confluence access rules, no Jira context, no marketplace schema knowledge, and no governance guardrails. The audit skill already writes to Confluence — but AGENTS.md doesn't document the constraints that govern those writes, leaving agents to guess.

**Who benefits**: Every agent session that invokes a communityctl skill. Also William, who no longer needs to paste DCOMM context manually.

## Project Context

### Current State

communityctl has two Claude Code skills:
- `/onboarding` — bootstraps a new GitHub repo from `skeleton/` templates, configures teams and branch protection
- `/audit` — clones a repo, runs a 7-category compliance check, publishes a graded report to Confluence

The `AGENTS.md` (aliased as `CLAUDE.md`) documents only GitHub operations. The Confluence interactions in the audit skill are self-contained within `audit/SKILL.md` — including hardcoded Confluence IDs that belong in AGENTS.md as shared infrastructure references.

### Integration Surface

- `/AGENTS.md` (primary change target)
- `CLAUDE.md` (references AGENTS.md via `@AGENTS.md`)
- `.claude/skills/audit/SKILL.md` — references Confluence IDs that should move to AGENTS.md as canonical source

### Reusable Components

The DCOMM AGENTS.md was written for the same operational domain. It can be merged largely as-is, with structural adaptation to fit communityctl's existing section format.

## Market Analysis

### Competitive Landscape

Not applicable — this is internal operational documentation for a proprietary community platform.

### Market Positioning

N/A — internal tooling.

### Ecosystem Support

- The pattern of centralizing agent context in a single `AGENTS.md`/`CLAUDE.md` is standard practice for Claude Code projects.
- Skills referencing shared infrastructure constants (Confluence IDs, Jira project keys) without a central reference is a known anti-pattern that causes drift.

### Demand Signals

- William explicitly requested this merge.
- The audit skill already assumes Confluence infrastructure — without AGENTS.md documenting it, agents must read skill files to discover constraints that should be first-class context.
- Future skills (Jira ticket creation, marketplace management) will need Atlassian context that doesn't currently exist anywhere in communityctl.

## User Experience

### Interaction Model

The "user" here is an AI agent loading context from AGENTS.md at the start of a session. The merged document is read once and provides complete operational context for all subsequent skill invocations.

### Workflow Impact

**Reduces friction**: Agents no longer need to infer Confluence rules from skill internals. The "What Agents Should NOT Do" section provides explicit negative-space guardrails that prevent common errors (modifying the Planning & Development folder, creating unrestricted Confluence pages, conflating `active` vs `status` fields).

**No new complexity**: This is additive documentation — no UX surface changes for William.

### UX Recommendations

1. Organize the merged AGENTS.md with clear top-level sections: Project Overview → Repository Topology → Infrastructure → Skills/Commands → Template Conventions → Governance → Style → What NOT to Do
2. Keep the infrastructure reference tables (Confluence IDs, Jira IDs) visually distinct and easy to scan
3. Preserve the existing "Available Commands" section verbatim — it's already well-structured
4. The "What Agents Should NOT Do" section should be prominent and near the end (read last, remembered longest)

## Feasibility

### Value Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | Critical | Missing guardrails are an active risk; Jira context is required for future skills |
| User impact | Broad+Deep | Every agent session benefits; prevents real Confluence errors |
| Strategic alignment | Core mission | communityctl is the execution engine — AGENTS.md must reflect full scope |
| Market positioning | N/A | Internal tooling |

### Cost Breakdown

| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | Minimal | Pure markdown merge; no code changes |
| Effort estimate | Small | ~200–300 lines of carefully structured markdown |
| Risk level | Low | Documentation only; fully reversible via git |
| Maintenance burden | Minimal | AGENTS.md is the natural single home for this info |

## Recommendation

**Build.** The case is unambiguous: high value, minimal cost, low risk, directly requested. The only judgment call is structural — how to organize the merged document so it reads naturally and gives agents the right context in the right order. The implementation prompt addresses this in detail.

The one nuance: the Atlassian MCP server is not currently configured in `~/.claude.json` (only `gridctl` is active). The merged AGENTS.md should document the expected MCP tooling so that sessions with the Atlassian MCP server configured can take full advantage of the Confluence/Jira context.

## References

- Current communityctl AGENTS.md: `/Users/william/code/itential/communityctl/AGENTS.md`
- Audit skill (Confluence IDs): `/Users/william/code/itential/communityctl/.claude/skills/audit/SKILL.md`
- DCOMM AGENTS.md: provided inline in feature request
