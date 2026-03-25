---
description: >
  Build features from validated feature-scout prompts. Orchestrates branch creation,
  GitHub issues, feature implementation, and PR creation — one phase per invocation.
  Trigger when user mentions: build feature, feature build, build from prompt,
  implement feature, execute feature prompt, start building, build phase,
  continue build, next phase, feature-build.
argument-hint: "<prompt-path> | continue"
---

# Feature Build

Orchestrate feature implementation from a validated feature-scout prompt. Creates branches, GitHub issues, builds each phase, and creates PRs. One phase per invocation — user merges and resets between phases.

## Resolve Prompts Directory

Before any mode, resolve the centralized prompts directory:

```bash
PROMPT_STACK_ROOT=$(cat ~/.claude/.prompt-stack-root 2>/dev/null)
PROJECT_NAME=$(basename "$PWD")
PROMPTS_DIR="${PROMPT_STACK_ROOT}/prompts/${PROJECT_NAME}"
```

If `~/.claude/.prompt-stack-root` doesn't exist, fall back to `plan/` in the current directory and warn the user to run prompt-stack's `setup.sh`.

## Detect Mode

Parse `$ARGUMENTS`:
- `continue` or `next` → **Continue Mode**
- Path to a `.md` file → **Start Mode** (accept both absolute paths and paths relative to prompts dir)
- Feature name (matches a directory in `${PROMPTS_DIR}/`) → **Start Mode** (resolve to `${PROMPTS_DIR}/<name>/feature-prompt.md`)
- Empty → **Select Mode**: list available prompts in `${PROMPTS_DIR}/` and ask user which to build

---

## Select Mode

Scan the prompts directory for available feature prompts, excluding completed ones:

```bash
find "${PROMPTS_DIR}" -name "feature-prompt.md" -type f -not -path "*/completed/*" 2>/dev/null
```

Present them as a numbered list:

```
Available prompts for <project>:
1. oauth-integration
2. cli-plugin-system
3. real-time-notifications
```

Ask the user which to build. Once selected, proceed to **Start Mode** with that prompt file.

If no prompts found, inform the user to run `/feature-scout` first.

---

## Start Mode

### Step 1: Read & Parse Prompt

1. Read the prompt file
2. Extract the feature name from the `# Feature Implementation:` heading (use for branch naming and state)
3. Parse phases from the `## Suggested Build Order` section:
   - Each numbered item becomes a phase
   - If no numbered items or no such section, treat the entire prompt as a single phase
4. For each phase, detect which build skill to use:
   - If description contains "UI", "frontend", "interface", "component", "page", "dashboard", "design", "styling" → `frontend-design`
   - Otherwise → `feature-dev`

### Step 2: Detect Workflow

```bash
git remote get-url upstream 2>/dev/null
```

- Upstream exists → **Fork workflow** (`branch-fork`, `pr-fork`, `reset-fork`)
- No upstream → **Trunk workflow** (`branch-trunk`, `pr-trunk`, `reset-trunk`)

### Step 3: Create GitHub Issue

Check for a feature-request issue template:

```bash
find .github/ISSUE_TEMPLATE -iname "*feature*" -type f 2>/dev/null
```

If a template exists, read it to understand its field structure (problem, solution, alternatives, context). Create the issue with a body that mirrors those fields, populated from the prompt file:

```bash
gh issue create \
  --title "feat: <feature name>" \
  --assignee wcollins \
  --label enhancement \
  --body "<body>"
```

Body structure (map to template fields):
- **Problem Statement**: extract from the prompt's "Feature Description" section — what problem it solves
- **Proposed Solution**: extract from "Requirements" section — what to build
- **Alternatives Considered**: extract from "Evaluation Context" if available
- **Additional Context**: architecture guidance, UX spec highlights

If no template exists, create a standard issue with the same content.

**CRITICAL**: Exclude ALL references to `prompts/` and `plan/` directory paths. Strip any mentions of prompt-stack paths, `prompts/<project>/<name>/`, `plan/<name>/`, or any internal working file paths. These must never appear in GitHub issues, PRs, or commits.

Store the issue number for PR linking.

### Step 4: Save State (multi-phase only)

If multiple phases were detected, save state to `${PROMPTS_DIR}/<feature-name>/.build-state.json`:

```json
{
  "prompt_file": "<path>",
  "feature_name": "<name>",
  "workflow": "trunk|fork",
  "issue_number": 123,
  "total_phases": 3,
  "current_phase": 0,
  "phases": [
    {
      "index": 0,
      "description": "<phase description>",
      "build_skill": "feature-dev|frontend-design",
      "status": "pending",
      "branch": null,
      "pr_url": null
    }
  ]
}
```

### Step 5: Build Current Phase

Proceed to the **Build Phase** section below.

---

## Continue Mode

1. Find state files in the prompts directory (excluding completed features):
   ```bash
   find "${PROMPTS_DIR}" -name ".build-state.json" -type f -not -path "*/completed/*" 2>/dev/null
   ```
   - If multiple found, ask user which to continue
   - If none found, inform user to start with a prompt file path or run `/feature-build` to select one

2. Read the state file
3. Find the next phase with status `pending`
4. If all phases are complete, inform the user and delete the state file
5. Otherwise, proceed to the **Build Phase** section below

---

## Build Phase

This section runs for each phase in both Start and Continue modes.

### Step 1: Create Branch

Use the Skill tool to invoke the branch skill based on detected workflow:
- Trunk → invoke `branch-trunk` with the phase description as argument
- Fork → invoke `branch-fork` with the phase description as argument

The branch skill will sync, generate a branch name, and create the branch. It will not implement changes — that is handled by the build skill in Step 2.

After the branch is created, record the branch name in state (if multi-phase).

### Step 2: Build

Read the full prompt file to get complete context. Extract the relevant phase details if multi-phase.

Use the Skill tool to invoke the detected build skill:

**For `feature-dev`**, pass arguments in this format:

```
PRE-VALIDATED PROMPT — This prompt was validated through feature-scout.
Skip Phase 1 (Discovery), Phase 3 (Clarifying Questions), and Phase 4 approval gate entirely.
The architecture guidance is already specified in the prompt — follow it directly.
Proceed: Phase 2 (Codebase Exploration) → Phase 5 (Implementation) → Phase 6 (Review) → Phase 7 (Summary).

<full prompt content, with phase-specific focus if multi-phase>
```

**For `frontend-design`**, pass the relevant context directly as the argument.

### Step 3: Create PR

Use the Skill tool to invoke the PR skill based on workflow:
- Trunk → invoke `pr-trunk`
- Fork → invoke `pr-fork`

After the PR is created, apply these modifications:

```bash
# Assign to user
gh pr edit --add-assignee wcollins
```

Link the GitHub issue in the PR body. For multi-phase builds:
- Last phase or single phase: add `Closes #<issue_number>` to PR body
- Earlier phases: add `Part of #<issue_number>` to PR body

```bash
# Append issue reference to PR body
CURRENT_BODY=$(gh pr view --json body -q .body)
gh pr edit --body "${CURRENT_BODY}

<Closes|Part of> #<issue_number>"
```

### Step 4: Report

**If multi-phase and more phases remain:**

Update state file: set current phase status to `completed`, record branch and PR URL, advance `current_phase`.

Report to user:

> Phase N/total complete.
> PR: <PR_URL>
> Issue: #<issue_number>
>
> Next steps:
> 1. Review and merge the PR in GitHub
> 2. Run `/<reset-skill>` to clean up the branch
> 3. Run `/feature-build continue` for the next phase

**If single-phase or last phase:**

If state file exists, delete it.

Move the feature folder to the `completed/` directory:

```bash
FEATURE_DIR="${PROMPTS_DIR}/<feature-name>"
COMPLETED_DIR="${PROMPTS_DIR}/completed"
mkdir -p "${COMPLETED_DIR}"
mv "${FEATURE_DIR}" "${COMPLETED_DIR}/"
```

> Build complete.
> PR: <PR_URL>
> Issue: #<issue_number>
>
> Next steps:
> 1. Review and merge the PR in GitHub
> 2. Run `/<reset-skill>` to clean up

---

## Important Rules

- **gh CLI only**: Use `gh` for ALL GitHub operations. Do not use GitHub MCP servers even if available.
- **No internal path references**: Never include `prompts/`, `plan/`, or prompt-stack paths in issues, PRs, commits, or any GitHub-facing content. These are internal working files.
- **Assign to wcollins**: Both issues and PRs get `--assignee wcollins`.
- **One phase per invocation**: Build one phase, create its PR, then stop. User merges and resets before the next phase.
- **Sign all commits**: Sub-skills handle this — verify they do.
- **No Co-authored-by trailers**: Sub-skills handle this.
- **No mention of Claude**: Nothing in commits, PRs, issues, or branches.
- **Skip clarifying questions**: When invoking feature-dev, always instruct it to skip Phase 3 unless the user explicitly included `--clarify` in their original arguments.
