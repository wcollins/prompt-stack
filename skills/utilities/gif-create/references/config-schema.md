# Project Configuration Schema

The gif-create skill looks for a `.gif-create.yml` file in the project root. This file lets projects define brand guidelines, output defaults, and directory conventions once — so every GIF created in the project is consistent without interactive prompts.

## Full Schema

```yaml
# .gif-create.yml

# Brand / visual identity
brand:
  # Option A: Use a VHS theme name
  theme: "Tokyo Night"

  # Option B: Custom colors (overrides theme)
  colors:
    background: "#0d1117"
    foreground: "#c9d1d9"
    cursor: "#c9d1d9"
    border: "#7C3AED"
    # Optional ANSI color overrides
    black: "#0d1117"
    red: "#ff7b72"
    green: "#7ee787"
    yellow: "#d29922"
    blue: "#79c0ff"
    magenta: "#d2a8ff"
    cyan: "#a5d6ff"
    white: "#c9d1d9"

  # Typography
  font_family: "JetBrains Mono"
  font_size: 14
  line_height: 1.2
  padding: 20

# Default output settings
defaults:
  # Preset: github-readme | documentation | social-media
  preset: "github-readme"
  # Or explicit dimensions (overrides preset)
  width: 800
  height: 500
  typing_speed: "50ms"

# Directory conventions
paths:
  # Where .tape files are stored (relative to project root)
  tapes: "assets/gifs/tapes"
  # Where generated GIFs are saved
  output: "assets/gifs"
```

## Minimal Example

```yaml
brand:
  theme: "Dracula"

defaults:
  preset: "github-readme"

paths:
  tapes: "assets/gifs/tapes"
  output: "assets/gifs"
```

## Preset Dimensions

| Preset | Width | Height | Best for |
|--------|-------|--------|----------|
| `github-readme` | 800 | 500 | README.md embedding |
| `documentation` | 1200 | 600 | Docs sites |
| `social-media` | 1280 | 720 | Twitter, LinkedIn (16:9) |

## Notes

- All paths are relative to the project root
- `brand.colors` takes precedence over `brand.theme` when both are set
- The config file is optional — the skill falls back to interactive prompts
- Commit `.gif-create.yml` to version control so the team shares brand consistency
- The `paths.tapes` directory is useful for versioning tape files alongside the project
