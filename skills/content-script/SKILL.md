---
description: >
  Create technical content scripts in William's authentic voice. Video scripts,
  tutorial walkthroughs, explainer pieces, lab demos, short-form clips, and
  multi-part series planning. Includes demo notes and screen sharing cues for
  technical content. Trigger when user mentions: content script, video script,
  write a script, tutorial script, explainer script, lab script, demo script,
  short script, plan a series, video series, content series, script for,
  record a video, screen sharing script, walkthrough script, create content,
  new video, new tutorial, new explainer, new lab, /content-script.
argument-hint: "[script | series] <topic>"
---

# Content Script

Create technical content scripts in William's authentic voice with demo notes, screen sharing cues, and dialogue.

## Detect Mode

Parse `$ARGUMENTS` to determine mode:

- Starts with `series` → **Series Mode**
- Starts with `script` or anything else → **Script Mode**
- Empty or unclear → **Prompt for details** (see Step 1)

---

## Script Mode

Create a single content script for video, tutorial, or other technical content.

### Step 1: Gather Details

If the user's request is missing key information, prompt using AskUserQuestion. Gather:

1. **Content type** — What kind of content?
   - `tutorial` — Screen sharing walkthrough (step-by-step, show and tell)
   - `explainer` — Talking head or voiceover (opinion piece, concept breakdown)
   - `lab` — Hands-on technical demonstration (building/configuring something live)
   - `short` — Short-form clip (YouTube Short, social media, under 90 seconds)

2. **Topic** — What is this about? Be specific.
   - Good: "Setting up ContainerLab with Arista spine-leaf topology"
   - Bad: "Networking stuff"

3. **Audience** — Who is watching?
   - Default: Technical practitioners with cloud/infrastructure fundamentals
   - Ask only if the topic suggests a different audience

4. **Key points** — What must be covered? Any specific demos, tools, or outcomes?

5. **Tone angle** — Any specific angle?
   - Default: William's standard voice (pragmatic, opinionated, accessible)
   - Examples: "keep it beginner-friendly", "this is a hot take", "pure hands-on, minimal talking"

If the user provides enough context upfront, extract answers and confirm rather than asking each question individually. Show what you understood and ask if anything needs adjusting.

### Step 2: Study Voice

1. Read `references/video-voice-guide.md` for video-specific voice patterns
2. Read 2-3 existing context videos from `context/youtube/` that match the content type:
   - Tutorial/Lab: Check transcripts from lab videos (MCP, secrets injection, Itential)
   - Explainer: Check the Occam's Razor transcript
   - Short: Derive from the punchiest segments of existing transcripts
3. Note patterns: how William opens, transitions, explains technical concepts, and closes

### Step 3: Research Topic (if needed)

If the topic requires current information or the user asks for research:

1. Use WebSearch to gather recent developments, docs, or context
2. Use WebFetch for specific URLs the user provides
3. If referencing a project (like `~/code/gridctl/`), read relevant files to understand it accurately
4. Compile key facts, talking points, and demo opportunities

Present research findings to the user before writing. Ask: "Does this cover what you had in mind, or should I dig into anything else?"

### Step 4: Write the Script

Select the format from `references/script-formats.md` based on content type:

- **Tutorial** → Tutorial Format (with screen sharing cues and demo notes)
- **Explainer** → Explainer Format (dialogue-focused with visual suggestions)
- **Lab** → Lab Format (heavy demo notes, command sequences, expected output)
- **Short** → Short Format (tight, punchy, single point)

Writing rules:

1. **Voice first** — Every line should sound like William talking. Read it aloud mentally. If it sounds stiff, rewrite it.
2. **Demo notes in context blocks** — Screen sharing content gets `**[SCREEN]**` markers with specific instructions on what to show and do.
3. **Dialogue is natural** — Use contractions, short sentences, natural pauses. No teleprompter voice.
4. **Technical accuracy** — Commands, configs, and outputs must be correct. If unsure, flag it.
5. **Opinions welcome** — William takes positions. "I prefer X because..." not "One could consider X."
6. **Single dashes only** — Never use em dashes or en dashes.
7. **No filler** — Cut "so basically", "essentially", "actually" unless they serve a purpose.

### Step 5: Save the Script

Save to `script/<content-type>/<filename>.md`:

- **Filename format**: `<YYYYMMDD>-<topic-slug>.md` (lowercase, hyphens)
- **Content type directories**: `tutorial/`, `explainer/`, `lab/`, `short/`
- Create the directory if it doesn't exist

Examples:
- `script/tutorial/20260303-containerlab-spine-leaf.md`
- `script/explainer/20260303-occams-razor-in-engineering.md`
- `script/lab/20260303-gridctl-getting-started.md`
- `script/short/20260303-stop-overengineering.md`

### Step 6: Review

Present the complete script to the user. Ask:

- "Does this sound like you? Anything feel off?"
- "Any demos or points to add, cut, or reorder?"

Apply edits and save the updated version.

---

## Series Mode

Plan and optionally generate scripts for a multi-part content series.

### Step 1: Gather Series Concept

Prompt the user for:

1. **Series topic** — What's the overarching subject?
   - Example: "Marketing gridctl to the network automation community"
   - Example: "MCP fundamentals for infrastructure engineers"

2. **Goal** — What should a viewer walk away with after watching the whole series?

3. **Progression** — How should difficulty/depth progress?
   - Default: Beginner → Intermediate → Advanced
   - Alternatives: Conceptual → Practical, Problem → Solution → Optimization

4. **Target length** — How many episodes?
   - Suggest a range based on topic scope

5. **Content types** — Will episodes mix types or stay consistent?
   - Example: "Start with an explainer, then tutorials, finish with a lab"

6. **Project reference** — Is this about a specific project? Provide the path.
   - If given (e.g., `~/code/gridctl/`), read the project to understand its features, architecture, and value proposition

### Step 2: Research and Understand

If a project is referenced:

1. Read the project's README, CHANGELOG, key source files
2. Understand the feature set, target audience, and differentiators
3. Identify natural teaching progression (what concepts build on what)
4. Note demo-worthy features and "aha moment" opportunities

If the topic is broader:

1. WebSearch for existing content in the space (what's been covered, what's missing)
2. Identify gaps the series can fill
3. Note competing/complementary content to reference or differentiate from

### Step 3: Build the Series Plan

Create a series plan document with:

```markdown
# Series: <Series Title>

## Concept
<1-2 paragraph overview of the series, its goal, and who it's for>

## Series Arc
<Description of how the series progresses - what changes from episode 1 to N>

## Episodes

### Episode 1: <Title>
- **Type**: tutorial | explainer | lab | short
- **Goal**: What the viewer learns/takes away
- **Key points**: Bullet list of what's covered
- **Demo highlights**: What gets shown on screen (if applicable)
- **Prerequisites**: What the viewer should know first
- **Estimated length**: Short/Medium/Long

### Episode 2: <Title>
...

## Series Notes
- <Production notes, dependencies between episodes, recommended recording order>
- <Any recurring elements: intro format, branding, catchphrases>
```

### Step 4: Review the Plan

Present the full series plan to the user. Ask:

- "Does this progression make sense?"
- "Any episodes to add, remove, or reorder?"
- "Ready to start generating individual scripts?"

Wait for approval before proceeding.

### Step 5: Save the Series Plan

Save to `script/<primary-content-type>/series-<topic-slug>.md`:

- Example: `script/tutorial/series-gridctl-fundamentals.md`
- Example: `script/lab/series-mcp-deep-dive.md`

### Step 6: Generate Individual Scripts (Optional)

If the user wants to proceed with script generation:

1. Ask which episode(s) to script first
2. For each episode, follow Script Mode Steps 2-6
3. Use the series plan as context for each script - maintain continuity
4. Reference previous episodes naturally: "In the last video, we set up..."

---

## Important Rules

- **Always study voice first** — Read the video voice guide and relevant transcripts before writing. William's voice is specific and recognizable. Generic "tech YouTuber" voice is wrong.
- **Demo notes are critical** — For tutorials and labs, every screen sharing segment needs explicit notes on what to show, what to type, and what the expected output looks like. The script is a production document, not just dialogue.
- **Prompt when unclear** — If the user says "write me a script" with no other context, ask what it's about. Don't guess.
- **Present before saving** — Always show the script to the user before saving. Never save without explicit approval.
- **Series continuity** — When generating scripts for a series, maintain references to previous/next episodes and build on established concepts.
- **Project accuracy** — When scripting about a specific project, read the actual code. Don't make up features or capabilities.
- **Single dashes only** — Never use em dashes (—) or en dashes (-). Use single hyphens or rewrite the sentence.
- **No AI self-reference** — Scripts never mention that AI helped write them.
- **Date format** — Use `YYYYMMDD` for filenames, natural language for script content.
