# nanoedit

A minimal floating text editor for macOS, designed for use as an external editor (`$EDITOR` / `$VISUAL`).

## Features

- Floating window (always on top)
- Markdown syntax highlighting
- `@`-mention file path completion
- Translucent background with blur effect
- Save and exit with `Cmd+S`
- No Dock icon

## Install

### Build from source

```bash
git clone https://github.com/wtshm/nanoedit.git
cd nanoedit
swift build -c release
cp .build/release/nanoedit /usr/local/bin/
```

## Usage

```bash
nanoedit <filepath>
```

### As default editor

Set `EDITOR` or `VISUAL` in your shell profile:

```bash
export VISUAL="nanoedit"
```

### With Claude Code

Add to `~/.claude/settings.json`:

```json
{
  "env": {
    "VISUAL": "nanoedit"
  }
}
```

> [!NOTE]
> In Claude Code, the session output currently disappears after an external editor exits. Resizing the terminal restores it.
>
> https://github.com/anthropics/claude-code/issues/32467

## Key Bindings

| Key | Action |
|-----|--------|
| Cmd+S | Save and exit |
| Cmd+W | Close (confirms if modified) |
| Escape | Close (confirms if modified) |
| Cmd+Q | Quit |

## Requirements

- macOS 13.0+ (Ventura)

## License

MIT
