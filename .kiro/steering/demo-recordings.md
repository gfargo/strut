---
inclusion: fileMatch
fileMatchPattern: "bin/**,bin/tapes/**"
description: "VHS tape authoring and GIF generation for marketing/docs assets"
---

# Demo Recording Pipeline (VHS)

Terminal demos in `bin/` are recorded with [Charm VHS](https://github.com/charmbracelet/vhs) and consumed by the marketing site (strut-www) and README. See `bin/README.md` for the full reference — this file covers the conventions an agent must follow when adding or fixing a recording.

## Non-Negotiables

**Always set an explicit monospace font.** Every tape must include:

```tape
Set FontFamily "JetBrains Mono"
```

Without it, VHS falls back to whatever the host provides. On a machine with no monospace font installed (most Linux containers, CI runners) that fallback is a *proportional* font, which silently produces broken kerning and misaligned columns. The GIF still renders, so this fails quietly — it is only caught by eye. Never omit `FontFamily`.

**Output never comes from the real CLI.** Each tape sources a matching `bin/tapes/shims/<name>.sh` that defines a fake `strut()` printing canned output. This keeps recordings deterministic and avoids stray errors, SSH, or Docker. A tape and its shim are always added/edited together.

## Shim Output Conventions

Match the existing recordings or the new GIF will look out of place next to them:

| Element | Format | Use |
|---------|--------|-----|
| Progress step | `→ Doing a thing...` | Top-level action, unindented |
| Sub-item success | `  \033[32m✓\033[0m Detail` | Two-space indent, green check |
| Final success | `\033[1;33m✓ Summary\033[0m` | Bold gold, closes the scene |
| Error / warning | `\033[1;31m✗ text\033[0m` | Red |
| Service status dot | `\033[32m●\033[0m` | Green |
| Dim label | `\033[90m[api]\033[0m` | Log prefixes |

Structure a scene as: arrow steps → indented checks → one gold summary line. Use `sleep` between `printf` calls for staged reveal, and make the tape's trailing `Sleep` at least as long as the shim's total internal sleep time or the recording cuts off mid-output.

## Standard Tape Header

```tape
Set Shell "bash"
Set FontFamily "JetBrains Mono"
Set FontSize 20
Set Padding 24
Set Theme "Catppuccin Mocha"
Set CursorBlink false
Set TypingSpeed 40ms
Set WindowBar Colorful

Output ../output/gif/<name>.gif

Hide
Type `export PS1="~/project $ "` Enter
Type "source shims/<name>.sh" Enter
Type "clear" Enter
Show
```

Output paths are relative to the tape file. `Catppuccin Mocha` is chosen because it maps cleanly onto the Charcoal/Bone/Gold brand palette.

## Recording

```bash
./bin/record.sh                            # all tapes
./bin/record.sh tapes/workflow-init.tape   # one tape
./bin/optimize.sh --lossy --colors 64      # runs automatically after record.sh
```

Generated GIFs in `bin/output/` are **gitignored** — the `.tape` + shim files are the source of truth. The committed copies live in the strut-www repo because they are served as static assets.

## Syncing to the Marketing Site

```bash
cd .www && npm run sync-demos
```

The strut-www repo is checked out inside this one as `.www/`, and its `sync-demos` script
reads `../bin/output/` — so it only works from that nested location. It copies
`bin/output/gif/*.gif` and `bin/output/png/*.png` into `public/demos/`. Commit the GIFs in
strut-www: VHS cannot run in Vercel's build environment, so assets must be generated ahead
of time and checked in.

## Running VHS in a Linux Container / CI

The pipeline is macOS-first (`brew install vhs gifsicle`) but does run headless. Requirements:

- `vhs` — `go install github.com/charmbracelet/vhs@latest`
- `ffmpeg` — static build works fine (no distro package on Amazon Linux 2023)
- `ttyd` — single binary from the ttyd releases page
- A monospace font installed **and** `fc-cache -f` run, or `FontFamily` resolves to nothing
- Chromium — VHS drives it via go-rod. Running as root requires `--no-sandbox`, which VHS does not expose, so wrap the Chromium binary in a shell script that injects the flag
- `gifsicle` is optional; skipping it just means no post-optimization

## Naming

One tape per story, named for the story: `workflow-init`, `ship`, `rollback`. Tapes under `bin/tapes/live/` run **real** commands against a real VPS via `bin/record-live.sh` and need credentials in `~/.strut-live.env` — keep those separate from the shimmed tapes.
