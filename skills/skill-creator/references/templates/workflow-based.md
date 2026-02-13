# Workflow-Based Template

For skills that follow a sequential multi-step process (build, deploy, release, onboard).

```markdown
---
description: >
  {Detailed description of what this skill does and when to trigger it.
  List specific phrases: "do X", "run Y", "start Z".}
argument-hint: "{argument format}"
---

# {Skill Title}

{One sentence: what this skill does and when to use it.}

## Phase 1: {Phase Name}

**Goal**: {What this phase achieves}

### 1.1 {Step Name}

{Instructions Claude follows directly. Use imperative form.}

### 1.2 {Step Name}

{More instructions. Include code blocks for commands:}

```bash
{command}
```

---

## Phase 2: {Phase Name}

**Goal**: {What this phase achieves}

### 2.1 {Step Name}

{Instructions.}

---

## Phase 3: {Phase Name}

**Goal**: {What this phase achieves}

### 3.1 {Step Name}

{Instructions.}

---

## Important Rules

- {Rule 1: what to always do or never do}
- {Rule 2}
- {Rule 3}
```

**When to use:** The skill walks through phases in order. Each phase has a clear goal and specific steps. Examples: release workflows, onboarding sequences, migration procedures.
