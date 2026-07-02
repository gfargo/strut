# live/ — Recordings that deploy to a real VPS

Unlike the shimmed tapes in the parent directory (which use canned output for
determinism), these tapes run **real** strut commands against a real target VPS.
They demonstrate the actual SSH-based remote-execution and container-deploy paths.

## Prerequisites

1. **A reachable VPS** with SSH access. The droplet you use for `strut-action`'s
   e2e workflow works fine here too.
2. **`vhs` and `gifsicle`** installed locally (`brew install vhs gifsicle`).
3. **Credentials file** at `~/.strut-live.env`:

   ```bash
   STRUT_LIVE_HOST=<vps-ip>
   STRUT_LIVE_USER=root
   STRUT_LIVE_SSH_KEY=/absolute/path/to/private-key
   ```

   Gitignored — never committed. `bin/record-live.sh` sources this before
   invoking `vhs`.

## Recording

```bash
# One tape at a time:
bin/record-live.sh live-preflight.tape

# All of them:
bin/record-live.sh
```

The wrapper verifies SSH connectivity before spending time on the render.

## The three tapes

- **`live-preflight.tape`** — `strut doctor --deep` against the real VPS.
  Read-only. The safest tape; makes a great single-command demo for the
  "should I deploy here?" pitch.

- **`live-remote-exec.tape`** — `strut probe exec 'uname -a && docker --version'`
  showing SSH-multiplexed remote execution. Read-only.

- **`live-deploy.tape`** — full up/curl/down cycle. Spins an `nginx:alpine`
  container on port `18081` via `strut exec`, HTTP-checks it from the runner,
  then removes it. Idempotent (safe to re-record).

## Safety

- All live tapes bind demo containers to **high ports (18000+)** so they can't
  collide with anything the target host serves on 80/443.
- `live-deploy` pre-cleans any leftover container from previous recordings.
- The credentials file stays out of the repo.
