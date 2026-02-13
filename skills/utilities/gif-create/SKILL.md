---
description: Create terminal GIFs with VHS, iterating until output meets brand/style criteria
argument-hint: "[command] (e.g., 'gridctl deploy examples/basic.yaml')"
---

# Create Terminal GIF

Create polished terminal GIFs using VHS (Charmbracelet's terminal recorder). This command iterates through design, recording, and review cycles until the output meets quality criteria.

**Requirements:**
- VHS installed (`brew install vhs` or `go install github.com/charmbracelet/vhs@latest`)
- ffmpeg (for GIF generation)

**Usage:**
- `/gif-create` - Interactive mode, prompts for command and brand context
- `/gif-create gridctl deploy examples/basic.yaml` - Create GIF for specific command

---

## 1. Gather Requirements

**Goal**: Collect command to record and brand/style context

### 1.1 Check for VHS

```bash
which vhs && vhs --version
```

If VHS not found:
> **Error:** VHS is not installed.
>
> Install VHS:
> ```bash
> # macOS
> brew install vhs
>
> # Go
> go install github.com/charmbracelet/vhs@latest
>
> # Or download from https://github.com/charmbracelet/vhs/releases
> ```

### 1.2 Determine Command to Record

**If `$ARGUMENTS` is provided:**
- Use `$ARGUMENTS` as the command to record

**If `$ARGUMENTS` is empty:**
- Use `AskUserQuestion`:

> What command would you like to record?
>
> Provide the full command as you would type it in the terminal.

Options:
- **CLI help** - Record `<tool> --help` output
- **Demo workflow** - Multi-step command sequence
- **Single command** - One command with output

After selection, prompt for the specific command text.

### 1.3 Gather Brand Context

Use `AskUserQuestion`:

> How should we style the GIF? Provide brand/color context.

Options:
- **AGENTS.md / README** - Extract colors from project documentation
- **Hex color** - Single brand color (e.g., `#7C3AED`)
- **Theme preset** - Use a Charmbracelet theme (Dracula, Tokyo Night, etc.)
- **Default** - Use VHS defaults

**If user selects AGENTS.md / README:**
- Read `AGENTS.md`, `README.md`, or similar files in current directory
- Look for color definitions, brand guidelines, or theme references
- Extract primary color, background color, accent colors

**If user selects Hex color:**
- Prompt for the hex color value
- Derive complementary colors for background/foreground

**If user selects Theme preset:**
- Present common themes: Dracula, Tokyo Night, Catppuccin, Nord, Gruvbox

### 1.4 Gather Output Preferences

Use `AskUserQuestion`:

> What output format and dimensions?

Options:
- **GitHub README** - 800x500, optimized for markdown embedding
- **Documentation** - 1200x600, larger for docs sites
- **Social media** - 1280x720, 16:9 for Twitter/LinkedIn
- **Custom** - Specify dimensions

Also ask:

> Output filename?

Default to descriptive name based on command (e.g., `gridctl-deploy-demo.gif`).

---

## 2. Design VHS Tape

**Goal**: Create the VHS tape file that scripts the recording

### 2.1 Create Working Directory

```bash
mkdir -p .vhs-workspace
```

### 2.2 Build Tape Configuration

Based on gathered requirements, construct the tape file:

```tape
# Output settings
Output <filename>.gif

# Terminal dimensions
Set Width <width>
Set Height <height>

# Typography
Set FontSize <size>
Set FontFamily "JetBrains Mono"
Set LineHeight 1.2

# Colors (from brand context)
Set Theme <theme>
# Or custom colors:
# Set Shell "bash"
# Set Background "<bg-color>"
# Set Foreground "<fg-color>"

# Timing
Set TypingSpeed 50ms
Set Padding 20

# Recording sequence
Type "<command>"
Enter
Sleep 500ms
<wait for output>
Sleep 2s
```

### 2.3 Write Tape File

Write the tape to `.vhs-workspace/recording.tape`.

**Tape design principles:**
- Start with a brief pause before typing
- Use realistic typing speed (40-80ms)
- Add appropriate delays after command execution
- End with pause so viewer can see final output
- Keep total duration reasonable (5-15 seconds ideal)

### 2.4 Handle Multi-Step Commands

If the command involves multiple steps:
- Break into logical segments
- Add `Sleep` between steps
- Consider using `Ctrl+C` for long-running processes
- Use `Hide` and `Show` to skip boring parts

Example multi-step tape:
```tape
Type "cd examples"
Enter
Sleep 500ms

Type "cat basic.yaml"
Enter
Sleep 2s

Type "gridctl deploy basic.yaml"
Enter
Sleep 5s
```

---

## 3. Record GIF

**Goal**: Execute VHS to create the GIF

### 3.1 Run VHS

```bash
cd .vhs-workspace && vhs recording.tape
```

### 3.2 Check Output

```bash
ls -la .vhs-workspace/*.gif
```

Verify the GIF was created successfully.

### 3.3 Get GIF Info

```bash
file .vhs-workspace/<filename>.gif
```

---

## 4. Review and Iterate

**Goal**: Evaluate output quality and refine until acceptable

### 4.1 Present Result

Display the GIF path and details to user:

> **GIF Created:** `.vhs-workspace/<filename>.gif`
>
> **Size:** X.X MB
> **Dimensions:** WxH

Use `AskUserQuestion`:

> Review the GIF. How does it look?

Options:
- **Perfect** - Move to final output
- **Adjust timing** - Speed up/slow down, change pauses
- **Adjust colors** - Tweak theme or colors
- **Adjust dimensions** - Change size
- **Re-record** - Start fresh with different approach

### 4.2 Handle Adjustments

**If timing adjustment needed:**
- Ask what to change (typing speed, pauses, total duration)
- Modify tape file
- Re-record

**If color adjustment needed:**
- Ask for new color preferences
- Update tape theme/colors
- Re-record

**If dimension adjustment needed:**
- Ask for new dimensions
- Update tape Width/Height
- Re-record

### 4.3 Iteration Loop

Repeat sections 3-4 until user approves the result.

**Max iterations:** 5 (warn user if approaching limit)

---

## 5. Finalize Output

**Goal**: Move approved GIF to final location

### 5.1 Determine Output Location

Use `AskUserQuestion`:

> Where should the final GIF be saved?

Options:
- **Project assets** - `./assets/<filename>.gif`
- **Documentation** - `./docs/images/<filename>.gif`
- **Current directory** - `./<filename>.gif`
- **Custom path** - Specify location

### 5.2 Move and Optimize

```bash
# Create destination directory if needed
mkdir -p <destination-dir>

# Move GIF to final location
mv .vhs-workspace/<filename>.gif <destination>
```

### 5.3 Optional: Optimize GIF Size

If GIF is large (>5MB), offer optimization:

```bash
# Using gifsicle if available
gifsicle -O3 --lossy=80 <filename>.gif -o <filename>-optimized.gif
```

### 5.4 Cleanup

```bash
rm -rf .vhs-workspace
```

---

## 6. Report

**Goal**: Provide final output details and usage instructions

> **GIF Created Successfully**
>
> **Location:** `<final-path>`
> **Size:** X.X MB
> **Dimensions:** WxH
>
> **Embed in Markdown:**
> ```markdown
> ![Demo](<relative-path>)
> ```
>
> **Embed in HTML:**
> ```html
> <img src="<path>" alt="Demo" width="<width>">
> ```

---

## VHS Tape Reference

### Common Settings

| Setting | Description | Example |
|---------|-------------|---------|
| `Output` | Output filename | `Output demo.gif` |
| `Set Width` | Terminal width in pixels | `Set Width 1200` |
| `Set Height` | Terminal height in pixels | `Set Height 600` |
| `Set FontSize` | Font size in pixels | `Set FontSize 14` |
| `Set FontFamily` | Font family | `Set FontFamily "JetBrains Mono"` |
| `Set Theme` | Color theme | `Set Theme "Dracula"` |
| `Set TypingSpeed` | Delay between keystrokes | `Set TypingSpeed 50ms` |
| `Set Padding` | Terminal padding | `Set Padding 20` |

### Available Themes

- Dracula
- Tokyo Night
- Catppuccin Mocha
- Nord
- Gruvbox
- One Dark
- Solarized Dark

### Commands

| Command | Description | Example |
|---------|-------------|---------|
| `Type` | Type text | `Type "echo hello"` |
| `Enter` | Press enter | `Enter` |
| `Sleep` | Wait duration | `Sleep 2s` |
| `Ctrl+C` | Send interrupt | `Ctrl+C` |
| `Hide` | Hide subsequent output | `Hide` |
| `Show` | Show output again | `Show` |
| `Source` | Include another tape | `Source setup.tape` |

### Custom Colors

```tape
Set Background "#1a1b26"
Set Foreground "#c0caf5"
Set CursorColor "#c0caf5"
Set BorderColor "#7aa2f7"
```

---

## Troubleshooting

### GIF Too Large

- Reduce dimensions
- Shorten recording duration
- Use `gifsicle` for optimization
- Consider WebP output instead

### Command Output Not Captured

- Increase `Sleep` duration after command
- Check if command requires TTY
- Try running command manually first

### Colors Don't Match Brand

- Use exact hex values from brand guide
- Test with VHS `--preview` flag
- Consider screenshot comparison

### VHS Crashes

- Update to latest version
- Check ffmpeg installation
- Try simpler tape first to isolate issue

---

## Examples

### Simple Help Command

```tape
Output gridctl-help.gif
Set Width 800
Set Height 500
Set FontSize 14
Set Theme "Tokyo Night"
Set TypingSpeed 50ms

Type "gridctl --help"
Enter
Sleep 3s
```

### Multi-Command Demo

```tape
Output gridctl-demo.gif
Set Width 1200
Set Height 600
Set FontSize 14
Set Theme "Dracula"
Set TypingSpeed 40ms

Sleep 500ms
Type "cat examples/basic.yaml"
Enter
Sleep 2s

Type "gridctl deploy examples/basic.yaml"
Enter
Sleep 5s

Type "gridctl status"
Enter
Sleep 3s
```

### Branded Recording

```tape
Output demo.gif
Set Width 1200
Set Height 600
Set FontSize 14
Set Background "#0d1117"
Set Foreground "#c9d1d9"
Set BorderColor "#7C3AED"
Set TypingSpeed 50ms
Set Padding 30

Type "my-cli demo"
Enter
Sleep 4s
```
