---
description: >
  Create, list, and validate Claude Code skills and plugins.
  Trigger when the user mentions: creating a skill, new skill, add a skill,
  scaffold a skill, skill template, list skills, validate a skill,
  turn this into a skill, capture a workflow as reusable instructions,
  make a plugin, new plugin, or any variation.
argument-hint: "create | list | validate [skill-name]"
---

# Skill Creator

Create, list, and validate skills and plugins for this prompt-stack project. You read the instructions below and carry them out directly — the SKILL.md files ARE the logic.

## Project Context

This project uses two patterns:

**Skills** — Markdown files that Claude Code loads as slash commands.
- Live under `skills/<category>/<skill-name>/SKILL.md`
- Categories are namespaces: `git-workflow/`, `gridctl/`, `utilities/`, etc.
- Standalone skills sit directly under `skills/<skill-name>/SKILL.md`
- Can have `references/` subdirectory for overflow documentation
- Installed via `setup.sh` which symlinks skill directories to `~/.claude/skills/`

**Plugins** — Full packages for skills that need agents, hooks, or scripts.
- Live under `plugins/<plugin-name>/`
- Require `.claude-plugin/plugin.json` manifest
- Have `skills/` directory containing command files
- Optional: `agents/`, `hooks/`, `scripts/` directories
- Have a `README.md` documenting the plugin

## Detect Mode

Parse `$ARGUMENTS` to determine mode:

- Starts with `create` or is empty → **Create Mode**
- Starts with `list` → **List Mode**
- Starts with `validate` → **Validate Mode**

---

## Create Mode

When the user wants a new skill or plugin.

### Step 1: Capture Intent

Ask the user:
1. **What should this do?** — Core purpose and behavior
2. **When should it trigger?** — What phrases or contexts activate it
3. **Skill or plugin?** — Simple skill (just a SKILL.md) or full plugin (needs agents/hooks/scripts)
4. **Category** — Which namespace? Existing category, new category, or standalone?

If the user already described the skill clearly in their request, extract answers from context instead of asking again.

### Step 2: Determine Template

Read the templates in `references/templates/` to understand the patterns:
- **Workflow-based** — Sequential multi-step processes (build, deploy, release)
- **Task-based** — Collection of operations triggered by arguments (CRUD, mode switching)
- **Reference-based** — Standards, guidelines, conventions

Ask the user which fits, or recommend based on their description.

### Step 3: Scaffold

**For a skill:**

1. Create directory: `skills/<category>/<skill-name>/`
   - Or `skills/<skill-name>/` if standalone
2. Create `SKILL.md` from chosen template:
   - Fill in frontmatter (`description`, `argument-hint`)
   - Write the body based on the interview
3. Create `references/` only if the skill needs overflow documentation
4. Do NOT create empty subdirectories

**For a plugin:**

1. Create directory: `plugins/<plugin-name>/`
2. Create `.claude-plugin/plugin.json`:
   ```json
   {
     "name": "<plugin-name>",
     "description": "<description>"
   }
   ```
3. Create `skills/` directory with command files
4. Create `README.md` with: what it does, usage, skill descriptions
5. Create `agents/`, `hooks/`, `scripts/` only if actually needed
6. If bundled with prompt-stack, add to `BUNDLED_PLUGINS` array in `setup.sh`

### Step 4: Writing the SKILL.md

Read `references/writing-guide.md` for detailed guidance. Key principles:

- **Descriptions should be pushy**: Over-trigger rather than under-trigger. List specific phrases and contexts that activate the skill.
- **Progressive disclosure**: Frontmatter is always in context (~100 words). SKILL.md body loads when triggered (keep under 500 lines). References load on demand.
- **Imperative form**: Write instructions as directives Claude follows directly.
- **Concrete examples**: Include realistic user requests and expected behavior.
- **Keep it lean**: If an instruction doesn't earn its place, cut it.

### Step 5: Verify

After scaffolding:
1. Run validate mode on the new skill
2. Show the user what was created
3. Offer 2-3 realistic test prompts they can try

---

## List Mode

Walk the project and present all skills and plugins.

### Step 1: Scan Skills

Find all `SKILL.md` files under `skills/`:
```bash
find skills/ -name "SKILL.md" -type f
```

For each, read the frontmatter to extract `description`.

### Step 2: Scan Plugins

Find all `plugin.json` files under `plugins/`:
```bash
find plugins/ -name "plugin.json" -path "*/.claude-plugin/*" -type f
```

For each, read the JSON to extract `name` and `description`. Also find skill files within each plugin.

### Step 3: Present

Display a clean table:

**Skills:**
| Name | Category | Description |
|------|----------|-------------|
| branch-trunk | git-workflow | Create feature branch synced with origin |
| ... | ... | ... |

**Plugins:**
| Name | Skills | Description |
|------|--------|-------------|
| feature-dev | /feature-dev | Guided 7-phase feature development |
| ... | ... | ... |

---

## Validate Mode

Check a skill for correctness and quality.

### Step 1: Locate Skill

If `$ARGUMENTS` includes a skill name after `validate`:
- Search for it in `skills/` and `plugins/`

If no name given:
- Ask the user which skill to validate

### Step 2: Run Checks

| Check | Pass Criteria |
|-------|---------------|
| SKILL.md exists | File present in skill directory |
| Valid frontmatter | Has `description` field (not empty/placeholder) |
| Description quality | Description is specific enough to trigger correctly (not generic like "A useful skill") |
| Line count | SKILL.md body under 500 lines |
| File references | Any files referenced in SKILL.md actually exist |

### Step 3: Report

Present pass/fail for each check with actionable suggestions for failures:

```
Validating: skill-creator

  [PASS] SKILL.md exists
  [PASS] Valid frontmatter
  [PASS] Description quality
  [PASS] Line count (142/500)
  [PASS] File references
  [PASS] Copyright header

Result: 6/6 checks passed
```

---

## Important Rules

- No README.md, CHANGELOG.md, or INSTALLATION_GUIDE.md inside skills — skills are for AI agents, not human onboarding
- Only create subdirectories that the skill actually needs
- Keep SKILL.md under 500 lines — overflow goes to `references/`
- Plugins get a README.md (they're packages meant for distribution)
- Skills do not get a README.md
