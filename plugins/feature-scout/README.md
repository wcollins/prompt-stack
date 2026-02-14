# Feature Scout Plugin

Pre-development feature exploration and evaluation. Researches whether a feature idea is worth building before committing development time.

## Overview

Feature Scout is the "think before you build" step. Before jumping into `/feature-dev`, use `/feature-scout` to assess whether a feature idea is valuable, feasible, and well-timed. It researches the project state, competitive landscape, user experience implications, and technical feasibility — then produces a clear recommendation and an implementation-ready prompt.

## Philosophy

Not every feature idea deserves development time. Feature Scout helps you:
- **Validate before building** — research the market and codebase before writing code
- **Make evidence-based decisions** — gather real data on competitors, standards, and user demand
- **Reduce wasted effort** — a "skip" recommendation saves hours of development time
- **Build better features** — when you do build, you start with deep context and a well-crafted prompt

## Skill: `/feature-scout`

Launches a guided 7-phase evaluation workflow.

**Usage:**
```bash
/feature-scout Add real-time collaboration to the editor
```

Or simply:
```bash
/feature-scout
```

The command will guide you through the evaluation interactively.

## The 7-Phase Workflow

### Phase 1: Feature Intake

**Goal**: Understand the feature idea

**What happens:**
- Clarifies the feature idea if unclear
- Identifies the problem, beneficiaries, and motivation
- Confirms understanding before proceeding

### Phase 2: Project State Analysis

**Goal**: Understand the current project deeply

**What happens:**
- Launches 2-3 `project-analyst` agents in parallel
- Each explores a different aspect: scope/architecture, related features, project health
- Maps extension points and reusable components
- Presents comprehensive project context

### Phase 3: Market & Landscape Research

**Goal**: Assess the competitive and ecosystem landscape

**What happens:**
- Launches 2-3 `market-researcher` agents in parallel
- Each researches a different angle: competitors, standards, ecosystem support
- Evaluates whether the feature is table-stakes, a differentiator, or nice-to-have
- Reports on timing and demand signals

### Phase 4: User Experience Analysis

**Goal**: Evaluate UX implications

**What happens:**
- Launches 1-2 `ux-evaluator` agents
- Maps how users would discover, activate, and use the feature
- Assesses workflow impact and complexity
- Researches UX patterns from comparable tools

### Phase 5: Feasibility & Impact Assessment

**Goal**: Synthesize everything into a clear recommendation

**What happens:**
- Evaluates value (problem significance, user impact, strategic alignment, market positioning)
- Evaluates cost (integration complexity, effort, risk, maintenance burden)
- Delivers a clear recommendation: Build, Build with caveats, Defer, or Skip

### Phase 6: Feature Evaluation Report

**Goal**: Create a comprehensive evaluation document

**What happens:**
- Creates `plan/<feature-name>/feature-evaluation.md`
- Documents all findings, analysis, and recommendation
- Provides structured value and cost breakdowns

### Phase 7: Implementation Prompt

**Goal**: Create an implementation-ready prompt (only if recommendation is Build)

**What happens:**
- Creates `plan/<feature-name>/feature-prompt.md`
- Self-contained prompt usable with `/feature-dev` or any coding assistant
- Includes architecture guidance, UX specification, acceptance criteria

## Agents

### `project-analyst`

**Purpose**: Analyzes project state, architecture, scope, and feature readiness

**Focus areas:**
- Project scope and maturity
- Architecture and extension points
- Related features and reusable components
- Project health signals
- Integration surface for the proposed feature

### `market-researcher`

**Purpose**: Researches competitive landscape, standards, and ecosystem

**Focus areas:**
- Competitive analysis
- Industry standards and best practices
- Open source ecosystem support
- User demand signals
- Timing and trend analysis

### `ux-evaluator`

**Purpose**: Evaluates user experience implications

**Focus areas:**
- Current UX model audit
- Feature interaction design
- Workflow integration
- UX patterns from comparable tools
- Complexity and cognitive load assessment

## Outputs

All outputs go to `plan/` (gitignored — local thinking space):

```
plan/<feature-name>/
├── feature-evaluation.md   # Full analysis and recommendation
└── feature-prompt.md       # Implementation-ready prompt (if recommended)
```

## When to Use This Plugin

**Use for:**
- New feature ideas you're considering adding to a project
- Evaluating whether to contribute a feature to an open source project
- Comparing feature approaches before committing to one
- Building a case for or against a feature with evidence

**Don't use for:**
- Features you've already decided to build (use `/feature-dev` instead)
- Bug fixes or minor improvements
- Features with clear, well-defined requirements that don't need validation

## Typical Flow

```
/feature-scout Add plugin system for custom themes
  ↓ (evaluation complete, recommendation: Build)
/feature-dev   (use the generated prompt as input)
```

## Requirements

- Claude Code installed
- Git repository with existing codebase
- `plan/` directory exists and is in `.gitignore`
