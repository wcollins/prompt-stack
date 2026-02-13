# Task-Based Template

For skills that offer a collection of operations, switching behavior based on arguments or context.

```markdown
---
description: >
  {Detailed description of what this skill does and when to trigger it.
  List specific phrases: "do X", "run Y", "start Z".}
argument-hint: "{mode1 | mode2 | mode3} [options]"
---

# {Skill Title}

{One sentence: what this skill does.}

## Detect Mode

Parse `$ARGUMENTS` to determine which operation to run:

- Starts with `{mode1}` → **{Mode 1 Name}**
- Starts with `{mode2}` → **{Mode 2 Name}**
- Default → **{Default Mode Name}**

---

## {Mode 1 Name}

{When this mode is used.}

### Step 1: {Action}

{Instructions.}

### Step 2: {Action}

{Instructions.}

---

## {Mode 2 Name}

{When this mode is used.}

### Step 1: {Action}

{Instructions.}

---

## {Mode 3 Name}

{When this mode is used.}

### Step 1: {Action}

{Instructions.}

---

## Important Rules

- {Rule 1}
- {Rule 2}
```

**When to use:** The skill does different things depending on what the user asks for. Examples: CRUD operations, create/list/validate modes, tools with subcommands.
