# CLAUDE.md

Global Claude Code configuration for all projects.

## Workflows

Skill descriptions load automatically each session, so they aren't listed here. What isn't auto-loaded is when to reach for each workflow:

- **Fork (`*-fork`):** forked repos and open-source contributions where you lack direct push access; PRs target the `upstream` remote.
- **Trunk (`*-trunk`):** repos you own with direct push access; single main branch with short-lived feature branches.

**gridctl release** is two-phase: run `/release-gridctl` to run checks and open the release PR, merge it, then run `/release-gridctl --tag` to tag the release and trigger GitHub Actions.

## Commit Conventions

Format: `<type>: <subject>`, where type is one of `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`, or `perf`.

- Subject in imperative mood, max 50 characters, no trailing period.
- Branch prefixes: `feature/`, `fix/`, `refactor/`, `docs/`, `chore/`.
- Sign all commits with `-S`.
- No `Co-authored-by` trailers, and no mention of Claude in commits, PRs, or branch names.
- Keep PR descriptions concise and practical.

## Writing Style

Applies to all prose: chat responses, documentation, commit messages, code comments, and generated content.

- No em dashes (—). Use en dashes (–) for ranges; use parentheses or rephrase for asides and interruptions.
- Use the Oxford comma consistently in all lists.
- Spell out numbers one through nine; use numerals for 10 and above. Exceptions: dates, percentages, and measurements.
- Use American English spelling and grammar unless the user specifies another variant.
- No emojis, and no excessive formatting (heavy bolding, decorative headers) unless the user explicitly requests it.
- Avoid the antithesis cliché such as "it's not just X, it's Y" or "not only X but also Y". State the point directly.
- Cut inflated vocabulary: delve, leverage, robust, seamless, tapestry, realm, testament, underscore, boasts, elevate, unlock, harness, navigate, landscape, game-changer, cutting-edge.
- Drop hedging filler: "it's worth noting", "it's important to note", "needless to say".
- No empty conclusions or recaps ("In conclusion", "Overall", "Ultimately"). Stop when the point is made.
- Avoid transition padding at the start of sentences: "Moreover", "Furthermore", "Additionally".
- Avoid reflexive rule-of-three triplets used only for rhythm.
- Use straight quotes and apostrophes in code and config, not curly ones.

## Working Style

- When ambiguous, state reasonable assumptions and proceed; ask only if execution would otherwise fail.
- Use verifiable facts; write "Unknown" rather than guess.
- Break overly broad requests into parts, and suggest prioritization when everything can't be done at once.
- Keep code comments concise and meaningful; don't over-explain simple concepts.

## Tool Preferences

- Prefer `rg` over `grep`.
- Prefer `fd` over `find`.
- `tree` is available for directory structure.
