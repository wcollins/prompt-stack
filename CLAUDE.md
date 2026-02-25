# CLAUDE.md

Global Claude Code configuration for all projects.

## Available Skills

### Git Workflow

Two workflow patterns are available. Choose based on your repository setup:

#### Fork-and-Pull Workflow

For contributing to repositories you've forked (upstream/origin model):

| Skill | Description |
|-------|-------------|
| `/branch-fork <task>` | Sync with upstream, create feature branch, make changes |
| `/pr-fork` | Commit changes, push to origin, create PR to upstream |
| `/reset-fork` | Sync with upstream, delete feature branch |

#### Trunk-Based Workflow

For repositories where you have direct push access (single main branch):

| Skill | Description |
|-------|-------------|
| `/branch-trunk <task>` | Sync with origin, create feature branch, make changes |
| `/pr-trunk` | Commit changes, push to origin, create PR to main |
| `/reset-trunk` | Sync with origin, delete feature branch |

### Onboarding

| Skill | Description |
|-------|-------------|
| `/onboard-trunk` | Onboard codebase using trunk workflow |
| `/onboard-fork` | Onboard codebase using fork workflow |

### Gridctl

| Skill | Description |
|-------|-------------|
| `/release-gridctl [VERSION]` | Phase A: Create release PR with changelog update |
| `/release-gridctl --tag` | Phase B: After PR merge, create and push the release tag |
| `/release-gridctl --redo VERSION` | Tear down existing release and redo it |
| `/sync-gridctl` | Validate project state and sync AGENTS.md with codebase |

**Release Workflow:**
1. `/release-gridctl` - Run checks, update CHANGELOG.md, create release PR
2. Review and merge the PR
3. `/release-gridctl --tag` - Create tag to trigger GitHub Actions release

**Pre-release checks:**
- Lint (golangci-lint)
- Tests (go test -race)
- Build (go build)
- Web build (npm run build)

**Version types supported:**
- Alpha (`v0.1.0-alpha.N`) - Active development
- Beta (`v0.1.0-beta.N`) - Feature complete, testing
- RC (`v0.1.0-rc.N`) - Release candidate
- Stable (`v0.1.0`) - Production ready

### Content

| Skill | Description |
|-------|-------------|
| `/blog [blog \| talk \| project \| link]` | Add new content to the wcollins.io blog |

### Utilities

| Skill | Description |
|-------|-------------|
| `/gif-create` | Create terminal GIFs with VHS |

### Documentation

| Skill | Description |
|-------|-------------|
| `/docs [audit \| improve \| sync]` | Audit, improve, and sync project documentation |

### Skill Management

| Skill | Description |
|-------|-------------|
| `/skill-creator create` | Scaffold a new skill or plugin with templates |
| `/skill-creator list` | List all skills and plugins in the project |
| `/skill-creator validate [name]` | Validate a skill for correctness and quality |

### Development

| Skill | Description |
|-------|-------------|
| `/feature-scout` | Pre-development feature exploration and evaluation |
| `/feature-dev` | Guided 7-phase feature development workflow |
| `/frontend-design` | Create distinctive, production-grade frontend interfaces |

### Loop

| Skill | Description |
|-------|-------------|
| `/ralph-loop` | Start Ralph Wiggum iterative development loop |
| `/cancel-ralph` | Cancel active Ralph loop |
| `/help` | Show Ralph Wiggum help and available commands |

### Workflow Selection Guide

**Use Fork Workflow (`*-fork`) when:**
- You forked someone else's repository
- Contributing to open source projects
- You don't have direct push access to the main repository
- PRs go to an "upstream" remote

**Use Trunk Workflow (`*-trunk`) when:**
- You own the repository
- You have direct push/merge access
- Single main branch with short-lived feature branches
- No upstream remote needed

## Commit Conventions

All skills enforce these conventions:

### Commit Format
```
<type>: <subject>
```

**Types:** `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`, `perf`

**Subject rules:**
- Imperative mood ("add feature" not "added feature")
- Max 50 characters
- No period at end

### Branch Naming

Auto-generated from task description:

| Prefix | When to use |
|--------|-------------|
| `feature/` | New functionality (default) |
| `fix/` | Bug fixes |
| `refactor/` | Code restructuring |
| `docs/` | Documentation changes |
| `chore/` | Maintenance, CI, dependencies |

### Critical Rules

- **Sign all commits** with `-S` flag
- **No Co-authored-by trailers** in commits
- **No mention of Claude** in version control (commits, PRs, branches)
- Keep PR descriptions concise and practical

## Coding Guidelines

### Code Comments

- Concise and meaningful while being as brief as possible
- Use inline comments when appropriate to avoid cluttering code
- Don't over-explain simple concepts

### Error Handling

- Fail fast with clear error messages
- Provide actionable next steps when possible
- Log errors appropriately without exposing internals

### Security

- Never expose API keys, passwords, or sensitive data
- Validate inputs before processing
- Sanitize outputs when displaying user data

## Working Style

### Assumptions

- When ambiguous, state reasonable assumptions and proceed
- Ask only if execution would otherwise fail
- Use verifiable facts; write "Unknown" rather than guess

### Scope Management

- Break down overly broad requests into manageable parts
- Suggest prioritization when everything can't be done at once
- Clarify requirements when requests are too vague to execute

### Iteration & Feedback

- When initial approach fails, try alternative methods
- Learn from corrections and adjust approach accordingly
- Ask clarifying questions only when essential for success

## Tool Preferences

- Prefer `rg` over `grep`
- Prefer `fd` over `find`
- `tree` is available for directory structure

## Response Guidelines

- Structure responses clearly with appropriate headings when helpful
- Match verbosity to request complexity
- Provide examples when explaining abstract concepts
- Use formatting (code blocks, lists) judiciously to enhance readability
