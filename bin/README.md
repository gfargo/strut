# bin/ — Screenshot & GIF Generation Pipeline

Captures real terminal recordings of `strut` commands using [Charm VHS](https://github.com/charmbracelet/vhs) for marketing materials, README assets, and documentation.

## Prerequisites

```bash
brew install vhs        # terminal recorder (pulls in ffmpeg + ttyd)
brew install gifsicle   # lossless GIF optimization
```

Verify: `vhs --version && gifsicle --version`

## Usage

```bash
# Record all tapes (GIFs + PNGs)
./bin/record.sh

# Record a single tape
./bin/record.sh tapes/hero-deploy.tape

# Optimize all GIFs (runs automatically after record)
./bin/optimize.sh

# Optimize a specific GIF
./bin/optimize.sh bin/output/gif/hero-deploy.gif
```

## Structure

```
bin/
├── README.md           # This file
├── record.sh           # Main driver — renders tapes, optimizes output
├── optimize.sh         # Lossless GIF optimization (gifsicle -O3)
├── tapes/              # VHS tape files (the "screenplays")
│   ├── hero-deploy.tape        # Init → scaffold → deploy flow (hero GIF)
│   ├── backup-restore.tape     # Backup + verify workflow (feature GIF)
│   ├── drift-detect.tape       # Drift detection + auto-fix (feature GIF)
│   └── health-status.tape      # Health check overview (still PNG)
└── output/             # Generated assets (gitignored except .gitkeep)
    ├── gif/            # Optimized animated GIFs
    └── png/            # Still screenshots
```

## Adding a new capture

1. Create a `.tape` file in `bin/tapes/`
2. Use `../output/gif/name.gif` for GIF output or `../output/png/name.png` for stills
3. Run `./bin/record.sh tapes/your-tape.tape`
4. Check `bin/output/` for results — GIFs are automatically optimized

### Tape anatomy

Every tape follows this pattern:

```tape
# ── Settings (determinism + brand) ────────────────────────
Set Shell "bash"
Set FontSize 20
Set Padding 24
Set Theme "Catppuccin Mocha"
Set CursorBlink false
Set TypingSpeed 40ms
Set WindowBar Colorful

Output ../output/gif/my-demo.gif    # GIF output
# or: Screenshot ../output/png/my-still.png   # PNG still

# ── Hidden setup (not recorded) ───────────────────────────
Hide
Type `export PS1="~/project $ "` Enter
Type "clear" Enter
Show

# ── The scene ─────────────────────────────────────────────
Sleep 800ms
Type "strut my-app deploy --env prod"
Sleep 300ms
Enter
# ... simulated output via printf ...
```

### Key conventions

- **Output paths** are relative to the tape file: `../output/gif/` and `../output/png/`
- **Simulated output** uses `printf` with ANSI codes (no live VPS needed)
- **Gold accent** for success: `\\033[1;33m✓ text\\033[0m`
- **Red** for errors/warnings: `\\033[1;31m✗ text\\033[0m`
- **Green dots** for status: `\\033[32m●\\033[0m`
- **PS1 prompt** is set to `~/project $ ` for consistency across all tapes
- **Sleep timings** — hold long enough for a viewer to read, short enough to stay tight

### GIF vs PNG

| Use case | Command | Notes |
|----------|---------|-------|
| Motion demo | `Output ../output/gif/name.gif` | Animated recording of the full session |
| Single still | `Screenshot ../output/png/name.png` | Captures one frame at that point |

You can combine both in one tape (record a GIF, then Screenshot a key frame as PNG).

## GIF Size Optimization

GIFs go through a multi-stage optimization pipeline. The levers, in order of impact:

### 1. Lossless optimization (automatic)

`gifsicle -O3` runs automatically after every render. It rewrites only the pixels
that change between frames — **zero quality loss**. This typically provides 5-30%
reduction depending on how much changes frame-to-frame.

### 2. Tighten the story (authoring)

The biggest size lever is **duration and content**. Each frame costs bytes.

- Keep demos to **one story, one point**. Don't tack on extra beats.
- Use `Set TypingSpeed 30ms` (faster typing = fewer frames) where readability allows
- Reduce hold times (`Sleep`) to the minimum needed to read each beat
- Avoid full-screen redraws (clears, overlays) — they create expensive keyframes
- End on the last meaningful frame, not a trailing prompt

### 3. Increase typing speed (fewer frames)

The default `40ms` between characters creates many near-identical frames. For
commands the viewer already expects (like a path they've seen), faster typing helps:

```tape
Set TypingSpeed 30ms          # global default
Type@20ms "/long/path/name"   # even faster for unimportant strings
```

### 4. Reduce frame rate (advanced)

VHS records at its internal framerate. You can trim post-hoc:

```bash
# Drop to every other frame (halves file size, slightly choppy)
gifsicle -O3 --resize-method lanczos --unoptimize \
  input.gif '#0-' --delete '#1' '#3' '#5' ... -o smaller.gif
```

In practice, tightening the story and increasing typing speed are more effective.

### 5. Shrink canvas dimensions (last resort)

Smaller pixels = smaller file, but costs legibility. Only reach for this after
exhausting the above:

```tape
Set FontSize 16    # smaller font → smaller canvas (VHS auto-sizes)
```

### Current output sizes

| File | Raw | Optimized | Duration |
|------|-----|-----------|----------|
| hero-deploy.gif | ~1.1 MB | ~1.0 MB | ~15s |
| backup-restore.gif | ~670 KB | ~627 KB | ~12s |
| drift-detect.gif | ~514 KB | ~484 KB | ~11s |
| health-status.png | — | 304 KB | (still) |

These are already web-viable. For aggressive reduction, trim Sleep durations
and increase TypingSpeed first.

## Design Decisions

- **Deterministic**: tapes pin timing, theme, cursor blink, and prompt
- **Brand-aligned**: Catppuccin Mocha maps well to our Charcoal/Bone/Gold palette
- **No real infra**: tapes simulate strut output via printf — no SSH, no Docker, no VPS
- **Web-ready**: all GIFs are losslessly optimized as a pipeline step
- **Regenerable**: run `./bin/record.sh` anytime to rebuild all assets from source

## VHS quick reference

| Command | What it does |
|---------|-------------|
| `Set Theme "..."` | Terminal color scheme |
| `Set FontSize N` | Font size (controls canvas size) |
| `Set TypingSpeed Nms` | Delay between typed characters |
| `Set CursorBlink false` | Disable cursor blink (reduces frame noise) |
| `Set WindowBar Colorful` | Draw macOS-style traffic lights |
| `Type "text"` | Type characters (respects TypingSpeed) |
| `Type@10ms "text"` | Override speed for this line |
| `Enter` | Press Return |
| `Sleep Nms` / `Sleep Ns` | Pause |
| `Hide` / `Show` | Hide/show recording (for setup) |
| `Output file.gif` | Record session as GIF |
| `Screenshot file.png` | Capture single frame |

Full DSL: https://github.com/charmbracelet/vhs

## Troubleshooting

**"command not found: strut"** in the tape output  
Expected — tapes use `printf` to simulate output rather than running real strut commands. The `Type "strut ..."` line types the command visually; the `printf` on the next line fakes the output.

**GIF shows the printf commands being typed**  
Make sure the `printf` lines execute after `Enter` (the command prompt runs them). The viewer sees: typed command → output appears.

**Screenshot is empty / shows loading state**  
Increase the `Sleep` before `Screenshot`. The terminal needs time to render output.

**Artifacts in tapes/ directory (stacks/, strut.conf)**  
These are created when VHS actually executes typed strut commands during recording.
They're gitignored via `bin/tapes/.gitignore`.
