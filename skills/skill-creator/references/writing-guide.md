# Writing Guide

How to write effective SKILL.md files that work well with Claude Code.

## Frontmatter

Frontmatter is optional but strongly recommended for new skills. It determines when Claude triggers the skill and what arguments it accepts. Skills without frontmatter still work — Claude uses the skill name and content to match intent — but a good `description` field significantly improves trigger accuracy.

### The `description` Field

This is always in context — Claude sees it before the skill is triggered. Make it count.

**Good description:**
```yaml
description: >
  Create, list, and validate Claude Code skills and plugins.
  Trigger when the user mentions: creating a skill, new skill, add a skill,
  scaffold a skill, skill template, list skills, validate a skill,
  turn this into a skill, capture a workflow as reusable instructions.
```

**Bad description:**
```yaml
description: A skill for managing skills
```

**Why the good one works:** It lists specific trigger phrases. Claude can match user intent against concrete examples rather than guessing from a vague summary.

**Rules for descriptions:**
- Be pushy — over-trigger rather than under-trigger
- List specific phrases and contexts that should activate the skill
- Include variations of how users might ask for the same thing
- Keep it under ~100 words (it's always loaded into context)

### The `argument-hint` Field

Shows users what arguments the skill accepts:

```yaml
argument-hint: "create | list | validate [skill-name]"
```

Keep it short. It appears in autocomplete.

### Other Frontmatter Fields

| Field | Purpose | Example |
|-------|---------|---------|
| `description` | When to trigger (required) | See above |
| `argument-hint` | Argument format hint | `"<task description>"` |
| `allowed-tools` | Restrict available tools | `["Bash(script.sh:*)"]` |
| `hide-from-slash-command-tool` | Hide from tool listing | `"true"` |

## Body Structure

### Workflow-Based Skills

For sequential processes (build, deploy, release):

```markdown
# Skill Title

Brief context sentence.

## Phase 1: Name
**Goal**: What this phase achieves
**Actions**: Numbered steps

## Phase 2: Name
...
```

### Task-Based Skills

For operation collections with modes:

```markdown
# Skill Title

Brief context sentence.

## Detect Mode
Parse $ARGUMENTS to determine mode.

## Mode A
Steps for mode A.

## Mode B
Steps for mode B.
```

### Reference-Based Skills

For standards and guidelines:

```markdown
# Skill Title

Brief context sentence.

## Guidelines
The rules to follow.

## Specifications
Technical details.

## Examples
Concrete usage examples.
```

## Writing Principles

### Imperative Form

Write instructions as directives Claude follows directly:

**Good:** "Create the directory. Write the file. Run the validation."
**Bad:** "You should consider creating the directory and then maybe writing the file."

### Explain the Why

Don't use heavy-handed MUSTs without reasoning. Explain intent so Claude can generalize:

**Good:** "Keep SKILL.md under 500 lines — beyond this, Claude's instruction-following degrades. Move overflow to references/."
**Bad:** "MUST keep SKILL.md under 500 lines."

Both work, but the first produces better results because Claude understands the constraint and can make judgment calls.

### Concrete Examples

Include realistic examples of user requests and expected behavior:

```markdown
**Examples:**
| User says | Skill does |
|-----------|-----------|
| "add tmux configuration" | Creates feature/add-tmux-configuration branch |
| "fix shell sourcing" | Creates fix/shell-sourcing branch |
```

### Progressive Disclosure in Practice

Put everything Claude needs for the common case in the SKILL.md body. Put edge cases, detailed specs, and reference material in `references/`.

```markdown
## Handle Special Cases

For cloud-specific configuration, read the relevant reference:
- AWS: Read `references/aws.md`
- GCP: Read `references/gcp.md`
```

### Keep It Lean

Remove instructions that aren't pulling their weight:
- If Claude consistently gets something right without being told, remove the instruction
- If Claude wastes time on a step, cut or simplify it
- If an instruction is just restating what's obvious from context, remove it

The best SKILL.md files are shorter than you'd expect.

## Common Mistakes

### Too Verbose

```markdown
## Step 1: Initialize the Project

First, you need to make sure that the project directory exists. If it doesn't
exist yet, you should create it. Make sure to use the appropriate permissions
and ensure the parent directory is writable...
```

Fix: "Create the project directory if it doesn't exist."

### Too Abstract

```markdown
## Handle Errors

Implement appropriate error handling for all operations.
```

Fix: Specify what errors to handle and how:
```markdown
If git push fails, check if the remote branch exists and suggest `git push -u origin <branch>`.
```

### Missing Trigger Context

```markdown
---
description: Manages deployments
---
```

Fix: List when the skill should activate:
```markdown
---
description: >
  Deploy applications to staging and production environments.
  Trigger when user mentions: deploy, push to prod, release to staging,
  ship it, deploy to environment, rollout, promote build.
---
```

### Over-Scaffolding

Creating empty directories, placeholder files, or documentation nobody reads.

Fix: Only create what the skill actually needs. `references/` is optional. `assets/` is rare. If a skill is just a SKILL.md, that's fine.

## Formatting Conventions

- Use `$ARGUMENTS` to reference user input passed to the skill
- Use `AskUserQuestion` when user confirmation is needed
- Use markdown tables for structured data
- Use code blocks for commands and examples
- Keep headings hierarchical (## for sections, ### for subsections)
