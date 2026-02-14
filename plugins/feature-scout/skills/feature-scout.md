---
description: >
  Pre-development feature exploration and evaluation. Researches whether a feature
  idea is worth building before committing development time. Analyzes project state,
  market landscape, user experience implications, and technical feasibility.
  Trigger when user mentions: evaluate a feature, explore a feature idea, is this
  feature worth building, should I add this feature, feature analysis, feature
  evaluation, feature research, assess this idea, scout a feature, pre-development
  research, feature viability, worth contributing, feature investigation.
argument-hint: "Feature idea to evaluate"
---

# Feature Scout

You are helping a developer evaluate whether a feature idea is worth building before committing development time. Follow a systematic approach: understand the idea, analyze the project, research the market, assess UX implications, evaluate feasibility, then produce a clear recommendation with an actionable implementation prompt.

## Core Principles

- **Research before recommending**: Gather real evidence from the codebase and market before forming opinions
- **Be honest about value**: A "don't build this" recommendation saves more time than a weak "maybe"
- **Read files identified by agents**: When launching agents, ask them to return lists of important files. After agents complete, read those files to build context before proceeding.
- **Use TodoWrite**: Track all progress throughout
- **Outputs stay local**: All deliverables go to `plan/` which is .gitignored — this is a thinking space

---

## Phase 1: Feature Intake

**Goal**: Understand the feature idea and establish evaluation context

Initial request: $ARGUMENTS

**Actions**:
1. Create todo list with all 7 phases
2. If the feature idea is clear from $ARGUMENTS, summarize your understanding
3. If unclear, ask the user:
   - What is the feature? (one-sentence description)
   - What problem does it solve? Who benefits?
   - What prompted this idea? (user request, competitive pressure, personal itch, etc.)
   - Which project is this for? (if not obvious from working directory)
4. Confirm understanding with the user before proceeding

Capture these details — they inform every subsequent phase.

---

## Phase 2: Project State Analysis

**Goal**: Deeply understand the current project to assess how the feature fits

**Actions**:
1. Launch 2-3 project-analyst agents in parallel. Each agent should focus on a different aspect:
   - "Analyze the overall project scope, maturity, and architecture to understand what this project is and where it's headed"
   - "Find features related to [feature idea] and trace their implementation. Identify reusable components and extension points."
   - "Assess project health: test coverage, documentation quality, dependency state, and technical debt relevant to [feature area]"

   Each agent should return a list of 5-10 essential files.

2. Once agents return, read all identified files to build deep understanding
3. Present a concise summary:
   - What the project is and its current scope
   - How the proposed feature relates to existing functionality
   - Key architectural patterns and extension points
   - Health signals that affect the build decision
   - Reusable components the feature could leverage

---

## Phase 3: Market & Landscape Research

**Goal**: Understand the competitive landscape, modern standards, and ecosystem support

**Actions**:
1. Launch 2-3 market-researcher agents in parallel. Each agent should focus on a different aspect:
   - "Research how comparable tools/projects handle [feature idea]. Find specific implementations and approaches."
   - "Investigate current industry standards, best practices, and modern expectations for [feature type]. What's considered table-stakes vs differentiator?"
   - "Survey the open source ecosystem for libraries, packages, or reference implementations that address [feature idea]. Assess community demand signals."

2. Once agents return, synthesize findings
3. Present a concise summary:
   - How competitors handle this (with specific references)
   - Whether this is table-stakes, a differentiator, or nice-to-have
   - Available libraries or reference implementations
   - Evidence of user demand (or lack thereof)
   - Timing: is now the right moment for this?

---

## Phase 4: User Experience Analysis

**Goal**: Assess how this feature would affect users

**Actions**:
1. Launch 1-2 ux-evaluator agents:
   - "Evaluate how [feature idea] would fit into the existing UX model of this project. Map how users would discover, activate, and interact with it."
   - "Research UX patterns for [feature type] in comparable tools. Identify best practices and anti-patterns."

2. Once agents return, synthesize findings
3. Present a concise summary:
   - How users would discover and use the feature
   - Impact on existing workflows (adds friction vs reduces it)
   - Complexity and learning curve implications
   - UX patterns from comparable tools
   - Accessibility considerations
   - Specific UX recommendations if the feature is built

---

## Phase 5: Feasibility & Impact Assessment

**Goal**: Synthesize all research into a clear feasibility and value assessment

This phase does NOT launch agents — it synthesizes findings from Phases 2-4.

**Actions**:
1. Review all findings from previous phases
2. Assess along these dimensions:

   **Value Assessment**:
   - Problem significance: How painful is the problem this solves? (Critical / Significant / Minor / Negligible)
   - User impact: How many users benefit and how much? (Broad+Deep / Broad+Shallow / Narrow+Deep / Narrow+Shallow)
   - Strategic alignment: Does this fit the project's direction? (Core mission / Adjacent / Tangential / Misaligned)
   - Market positioning: How does this affect competitive position? (Leap ahead / Catch up / Maintain / Irrelevant)

   **Cost Assessment**:
   - Integration complexity: How much existing code needs to change? (Minimal / Moderate / Significant / Architectural)
   - Effort estimate: Relative size (Small / Medium / Large / Very Large)
   - Risk level: What could go wrong? (Low / Medium / High)
   - Maintenance burden: Ongoing cost after initial build (Minimal / Moderate / High)

   **Overall Recommendation**:
   - **Build** — High value, reasonable cost. Worth committing development time.
   - **Build with caveats** — Valuable, but scope should be limited or approach adjusted.
   - **Defer** — Interesting but not the right time. Revisit when [specific condition].
   - **Skip** — Cost outweighs value. Not worth building.

3. Present the assessment to the user with clear reasoning
4. **Wait for user acknowledgment before proceeding to deliverables**

---

## Phase 6: Feature Evaluation Report

**Goal**: Create a comprehensive evaluation document in `plan/`

**Actions**:
1. Generate a short, descriptive folder name for the feature (kebab-case, 3-5 words)
   - Examples: `oauth-integration`, `cli-plugin-system`, `real-time-notifications`
2. Create the directory: `plan/<feature-name>/`
3. Write `plan/<feature-name>/feature-evaluation.md` with this structure:

```markdown
# Feature Evaluation: [Feature Name]

**Date**: [current date]
**Project**: [project name]
**Recommendation**: [Build / Build with caveats / Defer / Skip]
**Value**: [High / Medium / Low]
**Effort**: [Small / Medium / Large / Very Large]

## Summary

[2-3 sentence executive summary of the feature and recommendation]

## The Idea

[Clear description of the feature, the problem it solves, and who benefits]

## Project Context

### Current State
[Relevant findings from Phase 2 — project scope, architecture, related features]

### Integration Surface
[Specific files, modules, and interfaces the feature would touch]

### Reusable Components
[Existing code that could be leveraged]

## Market Analysis

### Competitive Landscape
[How competitors handle this — with specific references]

### Market Positioning
[Table-stakes vs differentiator vs nice-to-have]

### Ecosystem Support
[Available libraries, standards, reference implementations]

### Demand Signals
[Evidence of user need]

## User Experience

### Interaction Model
[How users would discover and use the feature]

### Workflow Impact
[How it affects existing workflows]

### UX Recommendations
[Specific design suggestions]

## Feasibility

### Value Breakdown
| Dimension | Rating | Notes |
|-----------|--------|-------|
| Problem significance | [rating] | [brief note] |
| User impact | [rating] | [brief note] |
| Strategic alignment | [rating] | [brief note] |
| Market positioning | [rating] | [brief note] |

### Cost Breakdown
| Dimension | Rating | Notes |
|-----------|--------|-------|
| Integration complexity | [rating] | [brief note] |
| Effort estimate | [rating] | [brief note] |
| Risk level | [rating] | [brief note] |
| Maintenance burden | [rating] | [brief note] |

## Recommendation

[Detailed recommendation with reasoning. If "Build with caveats" or "Defer", explain
the specific conditions or scope adjustments. If "Skip", explain what would need to
change for this to become viable.]

## References

[URLs and sources from market research, listed as bullet points]
```

4. Inform the user that the evaluation has been written and where to find it

---

## Phase 7: Implementation Prompt

**Goal**: If the feature is worth building, create a comprehensive prompt that any coding assistant could use to implement it

Only proceed with this phase if the recommendation is **Build** or **Build with caveats**. If the recommendation is Defer or Skip, inform the user the evaluation is complete and skip this phase.

**Actions**:
1. Write `plan/<feature-name>/feature-prompt.md` with this structure:

```markdown
# Feature Implementation: [Feature Name]

## Context

[Project description, tech stack, and relevant architecture — enough context for a
coding assistant unfamiliar with the project to orient themselves]

## Feature Description

[Clear, complete description of what to build. Include:
- What the feature does
- What problem it solves
- Who benefits and how]

## Requirements

### Functional Requirements
[Numbered list of specific, testable requirements]

### Non-Functional Requirements
[Performance, accessibility, security, compatibility requirements]

### Out of Scope
[Explicitly state what this feature does NOT include to prevent scope creep]

## Architecture Guidance

### Recommended Approach
[Based on the project analysis — which architectural approach fits best, which
patterns to follow, which abstractions to use or extend]

### Key Files to Understand
[List of files the implementer should read first, with brief descriptions of why
each matters]

### Integration Points
[Specific files and interfaces that need modification, with guidance on how to
integrate]

### Reusable Components
[Existing utilities, patterns, or modules to leverage rather than rebuild]

## UX Specification

[How users interact with the feature:
- Discovery: how users find it
- Activation: how they invoke it
- Interaction: what the workflow looks like
- Feedback: what users see during and after
- Error states: how failures are communicated]

## Implementation Notes

### Conventions to Follow
[Project-specific conventions the implementer must follow — naming, file structure,
error handling patterns, testing patterns]

### Potential Pitfalls
[Known risks, tricky integration points, or common mistakes to avoid]

### Suggested Build Order
[Recommended sequence for implementing — what to build first, what depends on what]

## Acceptance Criteria

[Numbered list of criteria that determine when the feature is complete. Each should
be specific and verifiable.]

## References

[Links to relevant documentation, comparable implementations, libraries, and standards]
```

2. Present a summary of what was created and where to find both files
3. Suggest next steps:
   - Review the evaluation in `plan/<feature-name>/feature-evaluation.md`
   - If ready to build, use the prompt in `plan/<feature-name>/feature-prompt.md` with `/feature-dev` or any coding assistant
   - If adjustments needed, iterate on the prompt before building

---

## Important Notes

- The `plan/` directory should already exist and be .gitignored. If it doesn't exist, create it and warn the user to add it to .gitignore.
- All outputs are local thinking artifacts — they never enter version control.
- Be direct in recommendations. "Build with caveats" is better than a wishy-washy "maybe".
- If market research turns up limited results, say so. Absence of data is itself a signal.
- The implementation prompt should be self-contained — someone with no prior context should be able to use it effectively.
