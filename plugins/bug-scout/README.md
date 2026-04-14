# Bug Scout Plugin

Pre-fix bug investigation and triage. Researches root cause, impact, and reproduction conditions before committing fix time.

## Overview

Bug Scout is the "understand before you fix" step. Before jumping into a fix, use `/bug-scout` to investigate root cause, assess severity and impact, and map reproduction conditions — then produce a clear recommendation and an implementation-ready fix prompt.

## Philosophy

Not every bug report warrants immediate development time. Bug Scout helps you:
- **Investigate before fixing** — locate root cause and understand scope before writing code
- **Make evidence-based decisions** — gather real data on severity, user impact, and fix risk
- **Avoid regressions** — understand side effects before touching the code
- **Fix bugs right** — when you do fix, you start with deep context and a well-crafted prompt

## Skill: `/bug-scout`

Launches a guided 7-phase investigation workflow.

**Usage:**
```bash
/bug-scout Users see a 500 error when paginating past 100 items
```

Or simply:
```bash
/bug-scout
```

The command will guide you through the investigation interactively.

## The 7-Phase Workflow

### Phase 1: Bug Intake

**Goal**: Understand the defect

**What happens:**
- Clarifies the bug if unclear
- Identifies expected vs actual behavior, how it was discovered, and any known reproduction steps
- Confirms understanding before proceeding

### Phase 2: Root Cause Analysis

**Goal**: Locate the bug in the codebase

**What happens:**
- Launches 2-3 `bug-analyzer` agents in parallel
- Each explores a different aspect: root cause location, affected code paths, test coverage gaps
- Maps extension points and reusable components
- Presents the defect with specific file:line references

### Phase 3: Impact & Severity Assessment

**Goal**: Assess the real-world impact

**What happens:**
- Launches 2-3 `impact-assessor` agents in parallel
- Each researches a different angle: bug classification, user reach, downstream effects
- Evaluates whether the bug is a critical blocker, common path issue, or edge case
- Reports on urgency signals and known workarounds

### Phase 4: Reproduction Investigation

**Goal**: Map the full reproduction surface

**What happens:**
- Launches 1-2 `repro-investigator` agents
- Maps minimum reproduction steps and affected environments
- Characterizes the failure mode
- Outlines a regression test to prevent recurrence

### Phase 5: Fix Feasibility Assessment

**Goal**: Synthesize everything into a clear recommendation

**What happens:**
- Evaluates severity (bug class, user impact, urgency)
- Evaluates fix cost (complexity, risk, confidence, test requirements)
- Delivers a clear recommendation: Fix immediately, Fix with caveats, Defer, or Won't fix

### Phase 6: Bug Investigation Report

**Goal**: Create a comprehensive investigation document

**What happens:**
- Creates `prompts/<project>/<bug-name>/bug-evaluation.md`
- Documents root cause, impact, reproduction conditions, and recommendation
- Provides structured severity and fix-cost breakdowns

### Phase 7: Fix Prompt

**Goal**: Create an implementation-ready fix prompt (only if recommendation is Fix)

**What happens:**
- Creates `prompts/<project>/<bug-name>/bug-prompt.md`
- Self-contained prompt usable with `/bug-build` or any coding assistant
- Includes root cause, fix requirements, regression test, and acceptance criteria

## Agents

### `bug-analyzer`

**Purpose**: Analyzes the codebase to locate root cause, trace code paths, and assess fix surface

**Focus areas:**
- Bug localization with file:line references
- Code path tracing from trigger to failure
- Related code and side effects
- Test coverage for the affected path
- Fix surface assessment

### `impact-assessor`

**Purpose**: Assesses real-world impact, severity, and urgency

**Focus areas:**
- Severity classification
- User reach and workflow impact
- Known workarounds
- Ecosystem and upstream context
- Urgency signals

### `repro-investigator`

**Purpose**: Maps reproduction conditions, affected environments, and failure modes

**Focus areas:**
- Minimum reproduction steps
- Environment and configuration dependencies
- Input and state analysis
- Failure mode characterization
- Regression test outline

## Outputs

All outputs go to `prompts/<project>/<bug-name>/` in the prompt-stack root:

```
prompts/<project>/<bug-name>/
├── bug-evaluation.md   # Full investigation and recommendation
└── bug-prompt.md       # Implementation-ready fix prompt (if recommended)
```

## What to Expect

A typical investigation takes 5-10 minutes depending on codebase size and bug complexity. The investigation report (`bug-evaluation.md`) covers root cause analysis, impact assessment, reproduction conditions, and a structured fix recommendation. The fix prompt (`bug-prompt.md`) is designed to be fully self-contained — usable by any coding assistant without additional context.

## When to Use This Plugin

**Use for:**
- Bug reports where the root cause is unclear
- Bugs that might be high-risk to fix (broad side effects, architectural issues)
- Triaging a backlog of bug reports to prioritize
- Bugs involving security or data integrity concerns

**Don't use for:**
- Obvious one-line typos or trivial fixes you've already understood
- Features you've already decided to build (use `/feature-scout` instead)
- Bugs with complete reproduction steps and a clear, isolated fix

## Typical Flow

```
/bug-scout Users see 500 error past page 100
  ↓ (investigation complete, recommendation: Fix immediately)
/bug-build  (use the generated prompt as input)
```

## Requirements

- Claude Code installed
- Git repository with existing codebase
- prompt-stack `setup.sh` run at least once (sets `~/.claude/.prompt-stack-root`)
