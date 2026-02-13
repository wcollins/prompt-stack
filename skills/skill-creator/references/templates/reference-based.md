# Reference-Based Template

For skills that define standards, guidelines, or conventions that Claude should follow.

```markdown
---
description: >
  {Detailed description of what standards/guidelines this skill defines.
  List specific contexts: "when doing X", "for Y projects", "during Z".}
argument-hint: "{optional scope or topic}"
---

# {Skill Title}

{One sentence: what guidelines this skill provides and when they apply.}

## Overview

{Brief context on why these guidelines exist and what they achieve.}

## Guidelines

### {Guideline Category 1}

- {Specific, actionable guideline}
- {Another guideline with rationale}

### {Guideline Category 2}

- {Guideline}
- {Guideline}

## Specifications

### {Spec Area}

| Setting | Value | Rationale |
|---------|-------|-----------|
| {setting} | {value} | {why} |

## Examples

### {Good Example}

```
{Example showing correct usage}
```

### {Anti-Pattern}

```
{Example showing what to avoid}
```

**Why this is wrong:** {Explanation}
```

**When to use:** The skill doesn't perform actions — it defines standards that Claude follows when doing other work. Examples: coding conventions, naming standards, review criteria, design guidelines.
