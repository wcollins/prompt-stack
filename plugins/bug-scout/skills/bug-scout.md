---
description: >
  Pre-fix bug investigation and triage. Researches root cause, impact, and
  reproduction conditions before committing fix time. Produces a clear severity
  recommendation and an implementation-ready fix prompt.
  Trigger when user mentions: investigate a bug, triage a bug, is this bug worth
  fixing, should I fix this bug, bug analysis, bug evaluation, bug research,
  assess this defect, scout a bug, pre-fix investigation, bug severity, bug
  triage, bug investigation, root cause analysis, defect triage, reproduce a bug,
  bug-scout.
argument-hint: "Bug description or issue reference to investigate"
---

# Bug Scout

You are helping a developer investigate a bug before committing fix time. Follow a systematic approach: understand the defect, analyze root cause in the codebase, assess impact and severity, investigate reproduction conditions, then produce a clear recommendation with an actionable fix prompt.

## Core Principles

- **Investigate before fixing**: Gather real evidence from the codebase before forming opinions
- **Be honest about severity**: A "won't fix" or "defer" recommendation saves more time than a weak "maybe"
- **Read files identified by agents**: When launching agents, ask them to return lists of important files. After agents complete, read those files to build context before proceeding.
- **Use TodoWrite**: Track all progress throughout
- **Outputs go to prompt-stack**: All deliverables go to `<prompt-stack>/prompts/<project>/` so they are version-controlled alongside your skills. Resolve the prompt-stack root by reading `~/.claude/.prompt-stack-root`. Derive the project name from the current working directory basename (e.g., if working in `~/code/gridctl`, project is `gridctl`).

---

## Phase 1: Bug Intake

**Goal**: Understand the defect and establish investigation context

Initial request: $ARGUMENTS

**Actions**:
1. Create todo list with all 7 phases
2. If the bug is clear from $ARGUMENTS, summarize your understanding
3. If unclear, ask the user:
   - What is the bug? (one-sentence description of the wrong behavior)
   - What is the expected behavior?
   - How was it discovered? (user report, test failure, monitoring alert, code review)
   - Which project is this for? (if not obvious from working directory)
   - Any known reproduction steps, error messages, or stack traces?
4. Confirm understanding with the user before proceeding

Capture these details — they inform every subsequent phase.

---

## Phase 2: Root Cause Analysis

**Goal**: Locate the bug in the codebase and understand what is causing it

**Actions**:

**CRITICAL**: When launching agents, always include the full bug description, expected vs actual behavior, and any error messages or stack traces from Phase 1. Do not send agents with only a label — they need specific context to focus their analysis.

1. Launch 2-3 bug-analyzer agents in parallel. Each agent should focus on a different aspect:
   - "The reported bug is: [full bug description from Phase 1]. Expected behavior: [expected]. Actual behavior: [actual]. Search the codebase to locate the root cause. Trace the execution path from the trigger to the failure point and identify the specific file:line where the defect originates."
   - "The reported bug is: [full bug description from Phase 1]. Find all code related to this bug: affected modules, call chains, data flow. Identify related features or code paths that could be affected by a fix and flag any similar defects elsewhere in the codebase."
   - "The reported bug is: [full bug description from Phase 1]. Assess project health in areas relevant to this bug: test coverage for the affected code path, documentation of expected behavior, and technical debt near the defect that could complicate a fix."

   Each agent should return a list of 5-10 essential files.

2. Once agents return, read all identified files to build deep understanding
3. Present a concise summary:
   - Root cause: the specific defect and why it causes the observed behavior
   - Code path: execution trace from trigger to failure
   - Affected files: files that need modification
   - Similar instances: same defect pattern elsewhere in the codebase
   - Test coverage gaps
4. **Existence check**: If the analysis reveals the "bug" is actually intended behavior or a misunderstanding of the expected behavior, present this finding to the user before proceeding. Options:
   - Continue with investigation if there's genuine disagreement about intended behavior
   - Exit with a "not a bug" recommendation and document the intended behavior
   - Pivot to evaluating a feature change to alter the current behavior

   If it is a genuine defect, proceed to Phase 3.

---

## Phase 3: Impact & Severity Assessment

**Goal**: Understand the real-world impact and determine urgency

**Actions**:
1. Launch 2-3 impact-assessor agents in parallel. Each agent should focus on a different aspect:
   - "Research how this class of bug — [bug description] — is typically classified in projects like this. Is it a crash, data corruption, security issue, regression, or cosmetic defect? What is standard industry practice for prioritizing this type of defect?"
   - "Investigate user impact for this bug: [bug description]. Are there workarounds? How many users would encounter this? Is there any public discussion or issue tracking for this bug or similar bugs?"
   - "Assess downstream effects of this bug: [bug description]. Does it block other features or integrations? Could a fix also resolve related issues? Are there upstream library or platform factors at play?"

2. Once agents return, synthesize findings
3. Present a concise summary:
   - Severity classification: Critical / High / Medium / Low with reasoning
   - User reach and which workflows are blocked
   - Known workarounds and their adequacy
   - Upstream factors (dependency bugs, platform limitations)
   - Urgency signals (active user complaints, release pressure, security risk)
4. **Checkpoint**: Present impact findings to the user before proceeding. If findings change the investigation direction (e.g., this is a dependency bug that can't be fixed locally, or the impact is far lower than expected), confirm with the user whether to:
   - Continue with reproduction analysis as planned
   - Pivot to documenting a workaround instead of a full fix
   - Exit early with a preliminary recommendation

   If no pivotal findings, briefly confirm with the user and proceed to Phase 4.

---

## Phase 4: Reproduction Investigation

**Goal**: Map the exact conditions required to reproduce the bug

**Actions**:
1. Launch 1-2 repro-investigator agents:
   - "Investigate the reproduction conditions for this bug: [bug description]. Map the minimum steps to reproduce, affected environments, and any preconditions. Identify whether this is deterministic or intermittent."
   - "Analyze what test coverage exists for the affected code path in this project. Identify the gaps and outline a test case that would catch this bug."

2. Once agents return, synthesize findings
3. Present a concise summary:
   - Minimum reproduction steps (precise and ordered)
   - Affected vs non-affected environments
   - Failure mode: what exactly goes wrong and how it manifests
   - Whether the bug leaves the system in a corrupted or recoverable state
   - Outline of a regression test to prevent recurrence

---

## Phase 5: Fix Feasibility Assessment

**Goal**: Synthesize all investigation into a clear feasibility and priority assessment

This phase does NOT launch agents — it synthesizes findings from Phases 2-4.

**Actions**:
1. Review all findings from previous phases
2. Assess along these dimensions:

   **Severity Assessment**:
   - Bug class: Crash / Data loss / Security / Regression / Incorrect behavior / Performance / Cosmetic
   - User impact: Critical path blocker / Common path / Edge case / Cosmetic
   - Urgency: Immediate (ship hotfix) / Next release / Backlog / Won't fix

   **Fix Assessment**:
   - Fix complexity: Trivial (1-5 lines) / Small / Medium / Large / Architectural
   - Risk level: Low (isolated) / Medium (side effects possible) / High (broad impact)
   - Confidence: High (clear root cause) / Medium (likely root cause) / Low (uncertain)
   - Test requirement: Regression test needed / Existing tests sufficient / No test needed

   **Weighting Guidance**:
   - **Primary severity driver**: Bug class. Data loss and security bugs escalate to Immediate regardless of fix complexity.
   - **Primary fix driver**: Risk level. A high-risk fix for a cosmetic bug should be deferred in favor of a safer approach.
   - **Tiebreaker**: User impact. Critical path blockers warrant more fix effort than edge cases.
   - A high-severity, high-risk bug should be "Fix with caveats" (staged rollout, feature flag, minimal change) rather than "Skip."
   - A low-severity, low-risk bug should be "Defer" rather than immediately fixed — low effort does not justify low value.

   **Overall Recommendation**:
   - **Fix immediately** — Severe bug with clear root cause. Hotfix or next-sprint priority.
   - **Fix with caveats** — Real bug, but approach should be scoped or staged to manage risk.
   - **Defer** — Valid bug but low impact or high uncertainty. Fix in future sprint when [specific condition].
   - **Won't fix** — Cost or risk outweighs value. Document why and close.

3. Present the assessment to the user with clear reasoning
4. **Wait for user acknowledgment before proceeding to deliverables**

---

## Phase 6: Bug Investigation Report

**Goal**: Create a comprehensive investigation document

**Actions**:
1. Resolve the prompts directory:
   ```bash
   PROMPT_STACK_ROOT=$(cat ~/.claude/.prompt-stack-root)
   PROJECT_NAME=$(basename "$PWD")
   PROMPTS_DIR="${PROMPT_STACK_ROOT}/prompts/${PROJECT_NAME}"
   ```
   Create the directory if it doesn't exist.
2. Generate a short, descriptive folder name for the bug (kebab-case, 3-5 words)
   - Examples: `null-pointer-auth-flow`, `race-condition-cache-write`, `off-by-one-pagination`
3. Create the directory: `${PROMPTS_DIR}/<bug-name>/`
4. Write `${PROMPTS_DIR}/<bug-name>/bug-evaluation.md` with this structure:

```markdown
# Bug Investigation: [Bug Name]

**Date**: [current date]
**Project**: [project name]
**Recommendation**: [Fix immediately / Fix with caveats / Defer / Won't fix]
**Severity**: [Critical / High / Medium / Low]
**Fix Complexity**: [Trivial / Small / Medium / Large / Architectural]

## Summary

[2-3 sentence executive summary of the bug and recommendation]

## The Bug

[Clear description of the defect, the expected behavior, the actual behavior, and how it was discovered]

## Root Cause

### Defect Location
[Specific file:line references where the bug originates]

### Code Path
[Execution trace from trigger to failure]

### Why It Happens
[Explanation of the underlying logic error, missing guard, race condition, etc.]

### Similar Instances
[Any other places in the codebase with the same defect pattern]

## Impact

### Severity Classification
[Bug class and reasoning]

### User Reach
[How many and which users are affected]

### Workflow Impact
[Core path blocker vs edge case vs cosmetic]

### Workarounds
[Known workarounds and their adequacy]

### Urgency Signals
[Evidence of active user pain, security risk, or time sensitivity]

## Reproduction

### Minimum Reproduction Steps
[Precise, ordered steps that reliably trigger the bug]

### Affected Environments
[OS, runtime, versions, configurations where the bug occurs]

### Non-Affected Environments
[Where the bug does NOT occur — helps with root cause validation]

### Failure Mode
[Exactly what goes wrong and how it manifests]

## Fix Assessment

### Fix Surface
[Files and interfaces that need modification]

### Risk Factors
[What could go wrong with a fix]

### Regression Test Outline
[Outline of a test that would catch this bug and prevent recurrence]

## Recommendation

[Detailed recommendation with reasoning. If "Fix with caveats", explain the
specific scope limitations or staging approach. If "Defer", explain the
conditions under which this should be revisited. If "Won't fix", explain
what would need to change for this to become worth addressing.]

## References

[URLs and sources from impact research, related issues, or comparable defect reports]
```

5. Inform the user that the investigation report has been written and where to find it

---

## Phase 7: Fix Prompt

**Goal**: If the bug is worth fixing, create a comprehensive prompt that any coding assistant could use to implement the fix

Only proceed with this phase if the recommendation is **Fix immediately** or **Fix with caveats**. If the recommendation is Defer or Won't fix, inform the user the investigation is complete and skip this phase.

**Actions**:
1. Write `${PROMPTS_DIR}/<bug-name>/bug-prompt.md` (using the same prompts directory resolved in Phase 6) with this structure:

```markdown
# Bug Fix: [Bug Name]

## Context

[Project description, tech stack, and relevant architecture — enough context for a
coding assistant unfamiliar with the project to orient themselves]

## Investigation Context

[Brief summary of key investigation findings that shaped this prompt:
- Root cause confirmed (e.g., "Off-by-one in pagination cursor calculation at lib/cursor.go:47")
- Risk mitigations baked into the fix requirements (e.g., "High side-effect risk — fix must be scoped to X, not Y")
- Reproduction confirmed via (e.g., "Reproduces deterministically with inputs >1000 items on all platforms")
- Link to the full investigation: `<prompts-dir>/<bug-name>/bug-evaluation.md`]

## Bug Description

[Clear, complete description of the defect:
- What is wrong
- What the expected behavior is
- How it manifests
- Who is affected]

## Root Cause

[Precise explanation of the defect's origin:
- Specific file:line where the bug is
- Why the current code produces the wrong behavior
- The correct logic that should replace it]

## Fix Requirements

### Required Changes
[Numbered list of specific, testable changes that fix the bug]

### Constraints
[What the fix must NOT do — side effects to avoid, behavior to preserve]

### Out of Scope
[Explicitly state what this fix does NOT address — related issues, refactors, improvements]

## Implementation Guidance

### Key Files to Read
[List of files the implementer should read first, with brief descriptions of why each matters]

### Files to Modify
[Specific files and the changes needed in each, with line references where available]

### Reusable Components
[Existing utilities, patterns, or helpers to use rather than writing new code]

### Conventions to Follow
[Project-specific conventions the implementer must follow — naming, error handling, testing patterns]

## Regression Test

### Test Outline
[Specific test case(s) that verify the fix and prevent regression:
- Test inputs (the values that trigger the bug)
- Expected output after the fix
- Where the test should live in the project]

### Existing Test Patterns
[How tests are structured in this project — file naming, assertion style, fixtures used]

## Potential Pitfalls

[Known risks, tricky integration points, or common mistakes to avoid when implementing this fix]

## Acceptance Criteria

[Numbered list of criteria that determine when the fix is complete. Each should be specific and verifiable.]

## References

[Links to related issues, comparable fixes, library documentation, or standards]
```

2. Present a summary of what was created and where to find both files
3. Suggest next steps:
   - Review the investigation in `${PROMPTS_DIR}/<bug-name>/bug-evaluation.md`
   - If ready to fix, run `/bug-build` — it will find the prompt and let you select it
   - If adjustments needed, iterate on the prompt before building

---

## Important Notes

- Prompts are stored in prompt-stack at `prompts/<project>/<bug>/`. If `~/.claude/.prompt-stack-root` doesn't exist, fall back to `plan/` in the current directory and warn the user to run prompt-stack's `setup.sh`.
- Be direct in recommendations. "Fix with caveats" is better than a wishy-washy "maybe".
- If impact research turns up limited results, say so. Absence of data is itself a signal.
- The fix prompt should be self-contained — someone with no prior context should be able to use it effectively.
