# VHS Tape Reference

## Settings

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

## Available Themes

- Dracula
- Tokyo Night
- Catppuccin Mocha
- Nord
- Gruvbox
- One Dark
- Solarized Dark

## Commands

| Command | Description | Example |
|---------|-------------|---------|
| `Type` | Type text | `Type "echo hello"` |
| `Enter` | Press enter | `Enter` |
| `Sleep` | Wait duration | `Sleep 2s` |
| `Ctrl+C` | Send interrupt | `Ctrl+C` |
| `Hide` | Hide subsequent output | `Hide` |
| `Show` | Show output again | `Show` |
| `Source` | Include another tape | `Source setup.tape` |

## Custom Colors

```tape
Set Background "#1a1b26"
Set Foreground "#c0caf5"
Set CursorColor "#c0caf5"
Set BorderColor "#7aa2f7"
```

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

### VHS Crashes
- Update to latest version
- Check ffmpeg installation
- Try simpler tape first to isolate issue
