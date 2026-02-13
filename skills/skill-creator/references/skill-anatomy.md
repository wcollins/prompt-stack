# Skill Anatomy

What a skill is, how it's structured, and how it fits into the prompt-stack project.

## What is a Skill?

A skill is a SKILL.md file that Claude Code loads as a slash command. When a user types `/skill-name`, Claude reads the SKILL.md and follows its instructions. There is no runtime, no interpreter, no middleware — Claude IS the execution engine.

## Directory Patterns

### Categorized Skill

Most skills live under a category namespace:

```
skills/<category>/<skill-name>/
├── SKILL.md              # The skill — all core logic lives here
└── references/           # Optional: overflow documentation loaded on demand
    ├── topic-a.md
    └── topic-b.md
```

The category is a namespace for organization. Examples: `git-workflow/`, `gridctl/`, `utilities/`.

### Standalone Skill

Skills that don't fit a category sit directly under `skills/`:

```
skills/<skill-name>/
├── SKILL.md
└── references/
```

### Key Rules

- The skill name comes from the directory name, not the filename
- `setup.sh` finds all `SKILL.md` files and symlinks their parent directories to `~/.claude/skills/<name>/`
- Only create `references/` if the skill actually needs overflow docs
- Never create empty directories

## What is a Plugin?

A plugin is a full package for skills that need more than just a SKILL.md — agents, hooks, scripts, or other bundled resources.

```
plugins/<plugin-name>/
├── .claude-plugin/
│   └── plugin.json       # Manifest: name, description
├── skills/               # Skill files (slash commands)
│   ├── command-a.md      # Flat pattern (e.g., ralph-wiggum/skills/ralph-loop.md)
│   └── command-b.md
├── agents/               # Optional: agent definitions
│   └── agent-name.md
├── hooks/                # Optional: lifecycle hooks
│   ├── hooks.json
│   └── hook-script.sh
├── scripts/              # Optional: helper scripts
│   └── setup.sh
└── README.md             # Plugin documentation
```

Plugin skills can also use the nested SKILL.md pattern:

```
plugins/<plugin-name>/
├── skills/
│   └── command-name/
│       └── SKILL.md      # Nested pattern (e.g., frontend-design/skills/frontend-design/SKILL.md)
```

Pick one pattern per plugin — don't mix flat and nested within the same `skills/` directory.

### When to Use a Plugin vs a Skill

| Use a Skill when... | Use a Plugin when... |
|---------------------|---------------------|
| Just need a SKILL.md | Need agents for parallel exploration |
| Self-contained instructions | Need hooks for lifecycle events |
| No external scripts | Need helper scripts |
| Simple slash command | Multiple related commands |

## Progressive Disclosure

Claude Code loads content in layers:

1. **Frontmatter** (~100 words) — Always in context. The `description` field determines when the skill triggers. This is the most important part.

2. **SKILL.md body** (<500 lines) — Loaded when the skill is triggered. Contains all core logic and instructions.

3. **References** (unlimited) — Loaded on demand when the SKILL.md explicitly reads them. Used for detailed specs, templates, and overflow content that isn't needed every time.

This means:
- Put trigger logic in the description (always visible)
- Put core instructions in the body (loaded on trigger)
- Put reference material in references/ (loaded on demand)

## Resource Types

### References (loaded into context)

Files that Claude reads for additional instructions or information. Used when the SKILL.md body would exceed 500 lines, or when certain content is only needed for specific modes.

Examples: writing guides, templates, API specs, domain-specific rules.

### Assets (used in output)

Files bundled with a plugin that Claude uses to produce output — fonts, images, configuration templates. These are rare for skills.

## Domain Organization

For skills with extensive reference material, organize by domain:

```
skills/network-automation/
├── deploy-stack/
│   ├── SKILL.md
│   └── references/
│       ├── aws.md
│       ├── gcp.md
│       └── azure.md
```

Each reference covers a specific domain, loaded only when relevant.
