# prompt-stack

A collection of Claude Code skills and plugins for development workflows, automation, and iterative AI-driven development.

Skills are slash commands (`/branch-trunk`, `/feature-dev`, `/ralph-loop`, etc.) that extend Claude Code with structured workflows — from git branching to full feature development with architectural design phases.

## Quick Start

```bash
git clone <repo-url> ~/code/prompt-stack
cd ~/code/prompt-stack
./setup.sh
```

Restart Claude Code. All skills are now available as `/commands`.

> [!NOTE]
> `setup.sh` symlinks skill directories to `~/.claude/skills/` and is safe to re-run. It also links `CLAUDE.md` to `~/.claude/CLAUDE.md` for global configuration.

## Skills

### Git Workflow

Two workflow patterns. Choose based on your repository access model.

#### Fork-and-Pull (upstream/origin)

For repositories you've forked — PRs go to upstream.

| Command | What it does |
|---------|-------------|
| `/branch-fork <task>` | Sync with upstream, create feature branch with smart naming |
| `/pr-fork` | One-file-per-commit strategy, push to origin, PR to upstream |
| `/reset-fork` | After PR merge: sync main with upstream, delete feature branch |

#### Trunk-Based (origin only)

For repositories you own with direct push access.

| Command | What it does |
|---------|-------------|
| `/branch-trunk <task>` | Sync with origin, create feature branch with smart naming |
| `/pr-trunk` | One-file-per-commit strategy, push to origin, PR to main |
| `/reset-trunk` | After PR merge: sync main with origin, delete feature branch |

**Branch naming** is auto-generated from the task description with smart prefixes: `feature/`, `fix/`, `docs/`, `refactor/`, `chore/`.

**When to use fork vs trunk:**
- Fork: you don't own the repo, contributing to someone else's project, have an `upstream` remote
- Trunk: you own the repo, have direct push/merge access, no upstream needed

---

### Onboarding

Stage and commit an uncommitted codebase in logical chunks via separate PRs.

| Command | What it does |
|---------|-------------|
| `/onboard-trunk` | Chunk uncommitted code into 2-7 PRs to origin/main |
| `/onboard-fork` | Same, but PRs target upstream |

Pass `continue` after each PR merges to proceed to the next chunk.

**When to use:** You have a new codebase with no git history and want to break it into reviewable, logical PRs instead of one massive initial commit. Chunks are tiered: foundation → types → core → features → tests → docs.

---

### Feature Development

| Command | What it does |
|---------|-------------|
| `/feature-dev [description]` | Guided 7-phase feature development workflow |

Phases:

1. **Discovery** — Clarify requirements, constraints, and success criteria
2. **Codebase Exploration** — Launch parallel `code-explorer` agents to trace existing patterns, architecture, and similar features
3. **Clarifying Questions** — Surface all ambiguities (edge cases, integration points, backward compatibility) before design
4. **Architecture Design** — Launch `code-architect` agents to propose multiple approaches with trade-offs; presents a recommendation
5. **Implementation** — Build the feature following chosen architecture (requires explicit approval)
6. **Quality Review** — Launch `code-reviewer` agents checking for bugs, DRY violations, and convention compliance
7. **Summary** — Document what was built, key decisions, files modified, and next steps

**When to use:** New features touching multiple files, features requiring architectural decisions, complex integrations where understanding existing code matters.

**Skip it for:** Single-line bug fixes, trivial changes, well-defined simple tasks, urgent hotfixes.

---

### Ralph Wiggum Loop

| Command | What it does |
|---------|-------------|
| `/ralph-loop "<prompt>" [options]` | Start an iterative development loop |
| `/cancel-ralph` | Stop the active loop |
| `/help` | Show Ralph reference and examples |

Options:
- `--max-iterations N` — Safety limit (always recommended)
- `--completion-promise "TEXT"` — Phrase that signals task completion

Ralph creates a self-referential feedback loop: Claude works on the task, tries to exit, the stop hook blocks exit and re-feeds the same prompt. Each iteration sees its own previous work in files and git history, enabling autonomous self-correction.

**Example:**
```bash
/ralph-loop "Build a REST API for todos with CRUD, validation, and tests. Output <promise>COMPLETE</promise> when all tests pass." --completion-promise "COMPLETE" --max-iterations 50
```

**When to use:** Well-defined tasks with clear success criteria and automatic verification (tests, linters). Tasks where iteration and self-correction are valuable — getting tests to pass, building greenfield projects, TDD workflows.

**Skip it for:** Tasks requiring human judgment or design decisions, unclear success criteria, one-shot operations.

**Prompt tips:**
- Define explicit completion criteria (what "done" looks like)
- Break large tasks into incremental phases
- Include self-correction instructions ("run tests, if any fail, debug and fix")
- Always set `--max-iterations` as a safety net

---

### Frontend Design

| Command | What it does |
|---------|-------------|
| `/frontend-design [requirements]` | Generate distinctive, production-grade frontend interfaces |

Creates web components, pages, or applications with bold aesthetic choices — distinctive typography, cohesive color palettes, high-impact animations, and attention to spatial composition. Actively avoids generic AI aesthetics.

**Example:**
```
/frontend-design Create a dashboard for a music streaming app
/frontend-design Build a landing page for a developer tool
```

**When to use:** Building any frontend where design quality matters and you want polished, memorable output rather than Bootstrap defaults.

---

### Documentation

| Command | What it does |
|---------|-------------|
| `/docs` or `/docs audit` | Score README against best practices, report findings |
| `/docs improve` | Make targeted documentation improvements |
| `/docs sync` | Verify docs match code (CLI flags, examples, links, badges) |

**When to use:**
- **Audit** when you want to know where docs stand
- **Improve** when you want to make them better
- **Sync** when docs may have drifted from code (renamed flags, changed defaults, moved files)

---

### Terminal GIF Creation

| Command | What it does |
|---------|-------------|
| `/gif-create [command]` | Create polished terminal GIFs with VHS |

Analyzes your command's output to calculate optimal dimensions, timing, and pauses — then iteratively records and refines until it meets your criteria. Supports per-project brand configuration via `.gif-create.yml` so every GIF in a project stays consistent. All artifacts (`.tape` files and GIFs) persist in the consuming repository under `assets/gifs/` by default.

Requires: [VHS](https://github.com/charmbracelet/vhs) and ffmpeg.

**When to use:** Documentation demos, README walkthroughs, social media content, anything that needs a visual of terminal output.

---

### Skill Management

| Command | What it does |
|---------|-------------|
| `/skill-creator create` | Scaffold a new skill or plugin with templates |
| `/skill-creator list` | Inventory all installed skills and plugins |
| `/skill-creator validate [name]` | Check a skill for correctness (frontmatter, line count, file refs) |

**When to use:** Building new skills for prompt-stack, checking what's installed, or validating a skill before use.

---

### Release Management (gridctl-specific)

| Command | What it does |
|---------|-------------|
| `/release-gridctl [VERSION]` | Phase A: Run checks, update changelog, create release PR |
| `/release-gridctl --tag` | Phase B: After PR merge, create and push release tag |
| `/sync-gridctl` | Fix inaccurate claims in AGENTS.md against actual code |

Two-phase release: first creates a PR with changelog, then (after merge) tags the release to trigger CI/CD. Supports alpha, beta, RC, and stable versioning.

## Terminal GIF Creation Guide

`/gif-create` is designed to work across any project. Brand guidelines, output paths, and defaults are configured per-project so GIFs stay consistent without repeating yourself.

### Prerequisites

```bash
# macOS
brew install vhs ffmpeg

# Or via Go
go install github.com/charmbracelet/vhs@latest
```

### Quick Start

```
/gif-create kubectl get pods
```

The skill will:
1. Run the command and measure its output (lines, width, execution time)
2. Calculate optimal GIF dimensions, typing speed, and pause durations
3. Show you the analysis and let you override any values
4. Generate a `.tape` file and record the GIF
5. Present the result for review — iterate until you're happy

### Setting Up Brand Guidelines

Create a `.gif-create.yml` in your project root to define brand settings once:

```yaml
# .gif-create.yml

brand:
  # Use a built-in theme...
  theme: "Tokyo Night"

  # ...or define custom colors
  colors:
    background: "#0d1117"
    foreground: "#c9d1d9"
    border: "#7C3AED"

  font_family: "JetBrains Mono"
  font_size: 14
  padding: 20

defaults:
  # github-readme (800x500) | documentation (1200x600) | social-media (1280x720)
  preset: "github-readme"
  typing_speed: "50ms"

paths:
  tapes: "assets/gifs/tapes"
  output: "assets/gifs"
```

> [!TIP]
> If you run `/gif-create` without a config file, the skill will prompt you interactively and then offer to save your choices to `.gif-create.yml` for next time.

**Brand color sources:**
- **Custom hex colors** — Set `brand.colors` with your exact brand palette
- **VHS themes** — Set `brand.theme` to one of: Dracula, Tokyo Night, Catppuccin Mocha, Nord, Gruvbox, One Dark, Solarized Dark
- **Project docs** — The skill can also extract colors from your AGENTS.md or README if you choose the interactive path

### How Command Analysis Works

Before designing the tape, the skill runs your command and measures the output:

| Metric | What it determines |
|--------|--------------------|
| Line count | GIF height — sized to fit all output without scrolling |
| Max line width | GIF width — wide enough for the longest line |
| Execution time | Post-command sleep — enough time for output to render |
| Command length | Typing speed — shorter commands type naturally, longer ones type faster |

You always see the calculated values and can override anything before recording.

### Output Structure

By default, artifacts live under `assets/gifs/`:

```
your-project/
├── .gif-create.yml            # brand config (project root)
└── assets/
    └── gifs/
        ├── tapes/             # .tape source files (versionable)
        │   ├── deploy-demo.tape
        │   └── help-output.tape
        ├── deploy-demo.gif    # generated GIFs
        └── help-output.gif
```

Tape files persist so you can re-record without the skill:

```bash
# Edit the tape directly, then regenerate
vhs assets/gifs/tapes/deploy-demo.tape
```

Override paths in `.gif-create.yml` if your project uses a different convention:

```yaml
paths:
  tapes: "docs/recordings/tapes"
  output: "docs/recordings"
```

### Step-by-Step Walkthrough

**1. Start the skill**

```
/gif-create myapp deploy --env staging
```

**2. Brand context** — If no `.gif-create.yml` exists, the skill asks how to style the GIF (theme, hex color, extract from docs, or defaults). If the config file exists, this step is skipped.

**3. Output preset** — Choose dimensions if not set in config: GitHub README (800x500), Documentation (1200x600), Social media (1280x720), or custom.

**4. Command analysis** — The skill runs the command, measures output, and presents calculated settings:

```
Command analysis:
- Output: 24 lines, max 72 chars wide
- Execution time: 1.2s
- Calculated dimensions: 800x500
- Post-command sleep: 2s
- Typing speed: 40ms
```

Override any value or accept and continue.

**5. Record** — VHS generates the GIF. Review the result and choose: accept, adjust timing, adjust colors, adjust dimensions, or re-record. Up to 5 iterations.

**6. Finalize** — GIF is saved to the output directory. If over 5MB, the skill offers optimization via `gifsicle`. You get embed snippets for markdown and HTML.

### Examples

**Minimal — just record a command:**
```
/gif-create terraform plan
```

**With a config file already set up:**
```
/gif-create cargo test -- --nocapture
```
The skill reads `.gif-create.yml`, analyzes the command, and generates a brand-consistent GIF with no prompts.

**Multi-step demo:**
```
/gif-create
```
Choose "Demo workflow" and describe the sequence. The skill builds a tape with multiple commands, appropriate pauses between steps, and `Hide`/`Show` to skip boring parts.

---

## Project Structure

```
prompt-stack/
├── setup.sh                      # Installation script
├── CLAUDE.md                     # Global Claude Code configuration
├── skills/                       # Standalone skills
│   ├── git-workflow/             # branch, pr, reset, onboard (fork + trunk)
│   ├── gridctl/                  # Release and sync management
│   ├── docs/                     # Documentation audit/improve/sync
│   ├── utilities/                # GIF creation
│   └── skill-creator/            # Skill scaffolding and validation
└── plugins/                      # Full-featured plugins (skills + agents + hooks)
    ├── feature-dev/              # 7-phase feature development
    ├── ralph-wiggum/             # Iterative development loops
    └── frontend-design/          # Production-grade frontend generation
```

**Skills** are single SKILL.md files with instructions for Claude Code. **Plugins** are full packages that can include skills, agents, hooks, and scripts.

## Choosing the Right Tool

| Situation | Reach for |
|-----------|-----------|
| Starting work on a feature branch | `/branch-trunk` or `/branch-fork` |
| Complex feature, need to think through architecture | `/feature-dev` |
| Well-defined task, want autonomous iteration | `/ralph-loop` |
| Building a UI component or page | `/frontend-design` |
| Done with changes, ready to PR | `/pr-trunk` or `/pr-fork` |
| PR merged, cleaning up | `/reset-trunk` or `/reset-fork` |
| New codebase, need to break into PRs | `/onboard-trunk` or `/onboard-fork` |
| Docs might be stale | `/docs sync` |
| Want better docs | `/docs improve` |
| Need a terminal demo GIF | `/gif-create` |
| Building a new skill | `/skill-creator create` |

## License

MIT
