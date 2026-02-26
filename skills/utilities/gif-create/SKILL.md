---
description: >
  Create terminal GIFs with VHS, iterating until output meets brand/style criteria.
  Supports per-project brand config via .gif-create.yml. Analyzes command output to
  determine optimal sizing, timing, and pauses. Tape files and GIFs persist in the
  consuming repository. Trigger when the user mentions: create a gif, terminal gif,
  record a command, vhs recording, demo gif, make a gif, screen recording, cli demo,
  terminal recording, record terminal output, gif-create.
argument-hint: "[command] (e.g., 'kubectl get pods', 'cargo build --release')"
---

# Create Terminal GIF

Create polished terminal GIFs using VHS (Charmbracelet's terminal recorder). Analyzes command output to calculate optimal dimensions and timing, supports per-project brand configuration, and keeps all artifacts in the consuming repository.

**Requirements:**
- VHS installed (`brew install vhs` or `go install github.com/charmbracelet/vhs@latest`)
- ffmpeg (for GIF generation)

---

## 1. Preflight

### 1.1 Check VHS

```bash
which vhs && vhs --version
```

If not found, show install instructions and stop.

### 1.2 Load Project Config

Look for `.gif-create.yml` (or `.gif-create.yaml`) in the project root.

If found, parse it and use values as defaults for all subsequent phases. See `references/config-schema.md` for the full schema. Key sections:
- `brand` — theme, colors, font settings
- `defaults` — dimensions preset, typing speed
- `paths` — where tapes and GIFs live

If not found, proceed with interactive prompts (Phase 2).

### 1.3 Determine Command

**If `$ARGUMENTS` provided:** Use as the command to record.

**If empty**, ask:

> What command would you like to record?

Options:
- **CLI help** — `<tool> --help` output
- **Demo workflow** — Multi-step command sequence
- **Single command** — One command with output

---

## 2. Gather Context (Interactive Fallback)

Skip any step where the project config already provides the value.

### 2.1 Brand Context

Ask only if `.gif-create.yml` has no `brand` section:

> How should we style the GIF?

Options:
- **Project docs** — Extract colors from AGENTS.md, README.md, or similar files in the project. Look for color definitions, brand guidelines, or theme references.
- **Hex color** — Single brand color (e.g., `#7C3AED`). Derive complementary colors for background/foreground.
- **Theme preset** — Charmbracelet theme (Dracula, Tokyo Night, Catppuccin Mocha, Nord, Gruvbox, One Dark, Solarized Dark)
- **Default** — VHS defaults

### 2.2 Output Preset

Ask only if `.gif-create.yml` has no `defaults` section:

> What output format?

Options:
- **GitHub README** — 800x500, optimized for markdown embedding
- **Documentation** — 1200x600, for docs sites
- **Social media** — 1280x720, 16:9 for Twitter/LinkedIn
- **Custom** — Specify dimensions

### 2.3 Offer Config Scaffold

If no `.gif-create.yml` exists and the user provided brand/output preferences interactively, offer to create one:

> Save these settings to `.gif-create.yml` so future GIFs use the same brand?

If yes, write the config file using the values gathered. See `references/config-schema.md` for the schema.

---

## 3. Analyze Command

**Goal**: Run the command to measure output characteristics, then calculate optimal tape settings.

### 3.1 Capture Output Metrics

Run the command and capture output:

```bash
# Capture output, measure lines and max width
<command> 2>&1 | tee /tmp/gif-create-analysis.txt
```

If the command is interactive, long-running, or destructive (deploys, writes, deletes), ask the user whether it's safe to run. If not safe, ask the user to estimate the output size or provide a sample.

Measure:
- **Line count** — `wc -l < /tmp/gif-create-analysis.txt`
- **Max line width** — `awk '{ print length }' /tmp/gif-create-analysis.txt | sort -rn | head -1`
- **Execution time** — time the command run (wall clock)
- **Has color/formatting** — check for ANSI escape sequences

Clean up: `rm -f /tmp/gif-create-analysis.txt`

### 3.2 Calculate Optimal Settings

Use the metrics to determine tape settings. These supplement (not override) any values from `.gif-create.yml` — config values always win.

**Height calculation:**
- Base: line count from output + 3 lines padding (prompt + blank lines)
- Multiply by `(font_size * line_height)` to get pixel height
- Add padding (top + bottom)
- Clamp to preset dimensions if a preset is active
- If output exceeds preset height, increase height to fit or note the overflow

**Width calculation:**
- Take max line width from output
- Multiply by approximate character width (`font_size * 0.6`)
- Add padding (left + right)
- Clamp to preset minimum, but expand if output is wider
- Minimum: 600px (avoids cramped recordings)

**Sleep calculation after command:**
- If execution takes <1s: `Sleep 2s` (let viewer read output)
- If execution takes 1-3s: `Sleep` = execution time + 1s
- If execution takes >3s: use actual execution time + 500ms
- For multi-screen output (>30 lines): add extra 1-2s reading time
- Cap at 8s unless user overrides

**Typing speed:**
- Short commands (<20 chars): 50ms (quick, natural)
- Medium commands (20-60 chars): 40ms (slightly faster to avoid tedium)
- Long commands (>60 chars): 30ms (faster so viewer doesn't lose patience)

**Pre-command pause:** 500ms (orient the viewer)
**Post-output pause:** 1.5s (let viewer absorb the final state)

### 3.3 Present Analysis

Show the user what was detected and the calculated settings:

> **Command analysis:**
> - Output: N lines, max M chars wide
> - Execution time: X.Xs
> - Calculated dimensions: WxH
> - Post-command sleep: Ns
> - Typing speed: Nms

Let the user override any value before proceeding.

---

## 4. Design and Write Tape

### 4.1 Resolve Directories

Determine tape and output paths:
- From `.gif-create.yml` `paths` section, or
- Default: `assets/gifs/tapes/` for tapes, `assets/gifs/` for output

```bash
mkdir -p <tape-dir> <output-dir>
```

### 4.2 Generate Tape Filename

Derive from the command:
- `kubectl get pods` → `kubectl-get-pods.tape`
- `cargo build --release` → `cargo-build-release.tape`

Strip flags with values, keep the structure readable.

### 4.3 Build Tape Content

Read `references/vhs-reference.md` for VHS syntax details.

Construct the tape from resolved settings:

```tape
# Generated by gif-create
Output <output-dir>/<name>.gif

# Terminal
Set Width <calculated-width>
Set Height <calculated-height>
Set FontSize <font-size>
Set FontFamily "<font-family>"
Set LineHeight <line-height>
Set Padding <padding>

# Brand
Set Theme "<theme>"
# Or custom colors:
# Set Background "<bg>"
# Set Foreground "<fg>"
# Set CursorColor "<cursor>"
# Set BorderColor "<border>"

# Timing
Set TypingSpeed <speed>

# Recording
Sleep 500ms
Type "<command>"
Enter
Sleep <calculated-sleep>
```

### 4.4 Handle Multi-Step Commands

If the command involves multiple steps:
- Break into logical segments
- Add `Sleep` between steps (500ms-2s depending on output)
- Use `Ctrl+C` for long-running processes
- Use `Hide`/`Show` to skip boring parts (setup, installs)

### 4.5 Write Tape

Write to `<tape-dir>/<name>.tape`. If a tape with that name exists, ask before overwriting.

---

## 5. Record and Iterate

### 5.1 Run VHS

```bash
vhs <tape-dir>/<name>.tape
```

### 5.2 Verify Output

Check the GIF was created and get file details:

```bash
ls -la <output-dir>/<name>.gif
file <output-dir>/<name>.gif
```

### 5.3 Present Result

> **GIF created:** `<output-path>`
> **Size:** X.X MB | **Dimensions:** WxH

Ask:

> Review the GIF. How does it look?

Options:
- **Perfect** — Finalize
- **Adjust timing** — Change typing speed, pauses, sleep durations
- **Adjust colors** — Tweak theme or brand colors
- **Adjust dimensions** — Change width/height
- **Re-record** — Start fresh with different approach

### 5.4 Iterate

Apply requested changes to the tape file, re-record, and present again. Max 5 iterations — warn if approaching the limit.

---

## 6. Finalize

### 6.1 Optimize (if needed)

If GIF exceeds 5MB, offer optimization:

```bash
gifsicle -O3 --lossy=80 <output>.gif -o <output>-optimized.gif
```

If optimized version is acceptable, replace the original.

### 6.2 Report

> **GIF created**
>
> | | |
> |---|---|
> | **File** | `<output-path>` |
> | **Tape** | `<tape-path>` |
> | **Size** | X.X MB |
> | **Dimensions** | WxH |
>
> **Embed in markdown:**
> ```markdown
> ![Demo](<relative-path>)
> ```
>
> **Re-record later:**
> ```bash
> vhs <tape-path>
> ```

The tape file persists in the project — edit it directly and re-run `vhs` to regenerate the GIF without re-running this skill.

---

## Examples

### Simple CLI help

```tape
Output assets/gifs/myapp-help.gif
# Tape: assets/gifs/tapes/myapp-help.tape
Set Width 800
Set Height 500
Set FontSize 14
Set Theme "Tokyo Night"
Set TypingSpeed 50ms
Set Padding 20

Sleep 500ms
Type "myapp --help"
Enter
Sleep 3s
```

### Multi-command demo with brand colors

```tape
Output assets/gifs/deploy-demo.gif
# Tape: assets/gifs/tapes/deploy-demo.tape
Set Width 1200
Set Height 700
Set FontSize 14
Set Background "#0d1117"
Set Foreground "#c9d1d9"
Set BorderColor "#7C3AED"
Set TypingSpeed 40ms
Set Padding 30

Sleep 500ms
Type "cat examples/config.yaml"
Enter
Sleep 2s

Type "myapp deploy examples/config.yaml"
Enter
Sleep 5s

Type "myapp status"
Enter
Sleep 3s
```

### Verbose output (auto-sized)

For a command that outputs 45 lines of text at 90 chars wide:
- Calculated height: ~680px (45+3 lines * 14 * 1.2 + 40 padding)
- Calculated width: ~800px (90 * 8.4 + 40 padding)
- Post-command sleep: 4s (>30 lines, extra reading time)

```tape
Output assets/gifs/test-results.gif
# Tape: assets/gifs/tapes/test-results.tape
Set Width 800
Set Height 680
Set FontSize 14
Set Theme "Dracula"
Set TypingSpeed 40ms
Set Padding 20

Sleep 500ms
Type "cargo test -- --nocapture"
Enter
Sleep 4s
```
