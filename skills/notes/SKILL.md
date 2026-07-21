---
name: notes
description: Create notes in the ~/code/notes vault, either by capturing architectural decisions from the current conversation or by authoring research, reference, or project notes from provided context. Trigger when the user says: take notes, note this, capture this conversation, add to my notes, save this for later, create a research note, write this up in my notes.
state: draft
---

# Notes

Create a note in the Obsidian vault at `~/code/notes/` in one of two modes. Capture
mode distills the current AI conversation into a short architectural summary the
user can reference later. Author mode takes context the user provides (a topic,
pasted material, or URLs) and writes a full note. Both modes follow the vault's
own conventions and produce a signed git commit.

The vault's `CLAUDE.md` is the source of truth for folder structure, frontmatter
schema, filenames, and per-type tone. Read it at the start of every run; if this
skill and that file ever disagree, the vault wins.

## Voice

Per-type tone rules in the vault override everything: reference notes stay terse
tables, research notes stay academic and sourced. Where narrative prose is
allowed (summaries, capture notes, project notes), blend two registers:

- William's baseline, per `skills/blog/references/voice-guide.md`: conversational
  but technical, short active sentences, contractions, clear opinions, simplicity
  as the north star.
- A Chamath Palihapitiya layer: reason from first principles, open with the
  one-sentence version of the point, name the constraint or incentive behind each
  decision, and state tradeoffs plainly. If something was a bad idea, say so and
  say why. No hedging, no filler.

Voice never overrides structure. A capture note is a decision record, not an
essay; keep it under one page.

## Steps

1. Verify preconditions. `~/code/notes/` exists and is a git repository. Read
   `~/code/notes/CLAUDE.md` for current conventions.
2. Determine the mode from the request. References to "this conversation",
   "what we just did", or "capture this" mean capture mode. Provided topics,
   pasted material, or URLs mean author mode. If genuinely unclear, ask.
3. Pick the note type and destination folder using the vault's structure table.
   Capture mode: use `projects/<project>/` with type `project` when the
   conversation concerns a repo that already has a project folder; otherwise
   `research/`. Author mode: match the material (research, reference, tutorial).
   If no type fits cleanly, use `inbox/` with `status: draft` and say so.
4. Draft the content.
   - Capture mode sections: Context (two or three sentences on what was being
     built and why), Decisions (each decision with its reason in one sentence),
     Tradeoffs (what was given up and what was gained), Open Questions, and
     References (file paths, PRs, and links from the conversation). Distill;
     do not transcribe.
   - Author mode: start from the matching file in `templates/` and fill every
     section. Fetch user-provided URLs with WebFetch when needed and cite them
     in Sources.
5. Fill all frontmatter fields per the vault schema. Set `source:` to
   `conversation` in capture mode or to the provided URL or origin in author
   mode. Dates are today's date, ISO format.
6. Write the file with a lowercase kebab-case filename in the destination
   folder. Never overwrite an existing note: if the topic already has a note,
   update that note and bump `updated` instead; if it is a different topic with
   a colliding name, pick a more specific filename.
7. Add a wiki-link with a one-line hook to the most relevant MOC in `maps/`.
   If no MOC fits, skip this step and flag it in the output rather than
   creating a new MOC.
8. Commit on the current branch: stage only the files this run created or
   modified, then `git commit -S` with a `docs: <subject>` message following
   the global commit conventions. Do not push.

## Output

Return the note's path, its type and status, which MOC was updated (or that
none fit), the commit hash, and the note's summary paragraph so the user can
sanity-check the distillation without opening the file.

## Failure modes

- `~/code/notes/` missing or not a git repository: stop and report. Do not
  create the vault.
- Template for the chosen type missing: fall back to the research template and
  flag the fallback in the output.
- Commit signing fails: leave the changes staged, stop, and ask. Never commit
  unsigned.
- Vault has unrelated uncommitted changes: proceed, but stage only this run's
  files and mention the untouched changes in the output.
- Capture mode invoked in a conversation with no architectural substance: say
  so instead of manufacturing a note.
