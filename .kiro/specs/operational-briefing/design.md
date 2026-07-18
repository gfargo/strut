# Operational Briefing - Design

## Overview

Two new per-stack commands, `briefing` and `preflight`, are built on a shared
aggregation library. The core idea is deliberately small: **do not add new
detection logic.** Every fact either command reports already comes from an
existing strut check. The new code (1) runs those checks in isolation, (2)
normalizes each into a common four-level severity, and (3) synthesizes — a
worst-wins posture for `briefing`, a release-safety verdict for `preflight`.

The synthesis stops at structured data. When an AI agent calls the MCP tool it
receives the normalized severities, findings, and remediation commands, and
writes the prose itself. This keeps strut dependency-free (no local LLM bolted
onto a Bash CLI) while still making the integration produce something no single
existing tool could: a one-call operational answer.

```
                    ┌────────────────────────────┐
  strut_briefing ──▶│ strut <stack> briefing      │──┐
  (MCP, read-only)  └────────────────────────────┘  │
                                                     ▼
                    ┌────────────────────────────┐  lib/briefing.sh
  strut_preflight ─▶│ strut <stack> preflight     │──┤  (shared normalizers,
  (MCP, read-only)  └────────────────────────────┘  │   severity ranking,
                                                     │   error-isolated runner)
                                                     ▼
                         re-invokes existing checks via "$STRUT_BIN":
                         health --json · drift detect · drift images --json ·
                         diff --json · backup health --json
                         (health --json carries per-container state, so there is
                          no separate status dimension — cmd_status has no JSON)
```

## Architecture

### Why re-invoke the strut binary per check

Each dimension is gathered by shelling out to the strut entrypoint itself
(`"$STRUT_BIN" "$stack" <check> --json`), exactly as the existing MCP layer and
`cmd_status_all`'s remote path already do. This is chosen over calling the
`cmd_*` functions in-process for three reasons:

1. **Error isolation (Requirement 1.3).** Each check runs in its own process
   with its own `set -euo pipefail`. A check that hard-fails, or a stack whose
   env file is missing a `VPS_HOST`, exits non-zero in the child and cannot
   abort the parent briefing. The parent captures the child's rc and maps it to
   `unknown`.
2. **Local/remote transparency.** Each subcommand already decides whether to
   run locally or dispatch over SSH. The aggregator inherits that for free and
   never has to know the topology.
3. **Consistency.** It mirrors the established pattern in `lib/mcp/tools.sh`
   and `_status_health_remote`, so there is no new dispatch model to learn.

`STRUT_BIN` resolves to `${STRUT_HOME:-${CLI_ROOT}}/strut`, matching how
`lib/mcp/tools.sh` resolves it.

### Bounded fan-out and timeouts

The fan-out is a fixed set of six checks (briefing) or four (preflight) — it is
inherently bounded, not a loop over unbounded input. Each check's worst-case
latency is bounded by SSH `ConnectTimeout` (already set by `build_ssh_opts`).
As an additional guard, `_briefing_run` wraps each check in `timeout`/`gtimeout`
when one is present on the host (per-check cap, default 45s). Using the OS
`timeout` — rather than a hand-rolled background-PID + `kill` — avoids leaving
orphaned SSH children or a lingering timer on the fast path. When neither
`timeout` nor `gtimeout` exists, the check runs directly and relies on SSH's own
timeout.

## Components and Interfaces

### `lib/briefing.sh` — shared aggregation primitives

```bash
# _briefing_bin
#   Echo the absolute path to the strut entrypoint to re-invoke for checks.

# _briefing_run <label> <output_var> <rc_var> -- <strut-args...>
#   Run "$STRUT_BIN <strut-args...>" with an optional timeout wrapper,
#   capturing combined stdout+stderr into <output_var> and the exit code into
#   <rc_var>. NEVER returns non-zero itself (error isolation): a failed or
#   timed-out check just yields a non-zero <rc_var> for the normalizer to read.
#   Timeout exit (124) is preserved so the normalizer can label it distinctly.

# Severity constants and ranking:
#   _briefing_sev_rank <ok|warn|critical|unknown>  -> 0..3 for max-comparison
#   _briefing_worst <sevA> <sevB>                  -> the higher-ranked severity
#     Ranking: critical(3) > warn(2) > ok(1) > unknown(0). Posture treats an
#     all-unknown result as unknown (see _briefing_posture).

# _briefing_json_extract  (stdin -> stdout)
#   Print from the first line beginning with `{` or `[`, dropping any leading
#   log/`ok` lines a check may print before its JSON body (e.g. `backup health
#   --json` prints a "Dashboard data generated" line, then the JSON array).

# Per-dimension normalizers. Each takes the check's captured stdout + rc and
# echoes: "<severity>\t<one-line summary>". They rely primarily on documented
# exit codes, falling back to guarded jq parsing of the --json body:
#   _briefing_norm_health   <out> <rc>   # json .overall_status healthy/degraded/unhealthy (+ container counts); rc 0/1/2 fallback
#   _briefing_norm_drift    <out> <rc>   # drift detect rc: 0 ok; non-zero+stdout -> critical (drift); non-zero+empty -> unknown (couldn't run)
#   _briefing_norm_images   <out> <rc>   # json .drifted: 0 ok, >0 warn(stale); no json -> unknown
#   _briefing_norm_diff     <out> <rc>   # json .has_changes / .has_destructive_changes; no json / rc 2 -> unknown
#   _briefing_norm_backup   <out> <rc>   # json array of {status}: worst of healthy=ok/warning=warn/degraded|critical=critical; empty -> unknown

# _briefing_posture <sev...>  -> overall posture per Requirement 1.4

# _briefing_remedy <dimension> <stack> <env>  -> the exact remediation command
#   string for a non-ok dimension (e.g. "strut <stack> drift fix --env <env>").
```

### `lib/cmd_briefing.sh` — `cmd_briefing`

`--env`/`--json` are consumed by the entrypoint's global flag parser and reach
the handler as `$CMD_ENV_NAME`/`$CMD_JSON`; the handler additionally scans its
own `CMD_ARGS` for `--help`. Flow:

1. Resolve `stack` (`$CMD_STACK`), `env` (`${CMD_ENV_NAME:-prod}`), and
   `json_mode` (`$CMD_JSON` == `--json`, or `OUTPUT_MODE=json`).
2. For each of the five dimensions: `_briefing_run` the check, then the matching
   `_briefing_norm_*` to get `(severity, summary)`.
3. `posture = _briefing_posture` of the five severities.
4. Build the `actions` list from every non-`ok` dimension, sorted worst-first,
   each with `_briefing_remedy`.
5. Emit JSON (via `out_json_*`) or the human report (severity glyphs reusing the
   `GREEN ✓ / YELLOW ⚠ / RED ✗` convention from `_status_health_glyph`).
6. Exit 0 if posture `ok`, else non-zero (Requirement 1.8).

### `lib/cmd_preflight.sh` — `cmd_preflight`

Reuses four normalizers (`diff`, `drift`, `health`, `backup`). Verdict logic:

```
gate NO-GO   if drift == critical              (would clobber VPS changes)
gate NO-GO   if every gathered signal is unknown / no remote target
gate CAUTION if health == critical             (deploying onto a broken stack)
gate CAUTION if diff has_destructive_changes   (data-loss risk)
gate CAUTION if backup in {warn, critical}     (no recent good backup)
note         if diff == ok (no changes)        (informational; verdict stays GO)
else GO
```

Exit codes: `GO` → 0, `CAUTION` → 1, `NO-GO` → 2 (Requirement 2.8), so
automation can branch on all three.

### MCP integration (`lib/mcp/tools.sh`, `lib/cmd_mcp.sh`)

- Add two entries to `_mcp_tools_list`:
  - `strut_briefing` — `{stack (required), env}`
  - `strut_preflight` — `{stack (required), env}`
- Add two `case` arms to `_mcp_tools_call`, each using the existing `_mcp_arg`
  validator for `stack`/`env` and invoking
  `"$strut_bin" "$stack" briefing|preflight --env "$env" --json`.
- Both are read-only → add to the `autoApprove` array (the `jq`-built Kiro
  config) and the two printed "Read-only tools" summaries in `_mcp_cmd_install`.

## Data Models

### `briefing --json`

```json
{
  "stack": "web",
  "env": "prod",
  "generated_at": "2026-07-17T18:04:11Z",
  "posture": "warn",
  "dimensions": [
    { "name": "health",  "severity": "ok",   "summary": "3/3 containers healthy" },
    { "name": "drift",   "severity": "ok",   "summary": "config in sync" },
    { "name": "images",  "severity": "warn", "summary": "1/3 images have stale digests" },
    { "name": "diff",    "severity": "ok",   "summary": "no pending changes" },
    { "name": "backups", "severity": "warn", "summary": "backup health warning" }
  ],
  "actions": [
    { "severity": "warn", "dimension": "images",  "summary": "1/3 images have stale digests",
      "command": "strut web deploy --env prod" },
    { "severity": "warn", "dimension": "backups", "summary": "backup health degraded (score 74)",
      "command": "strut web backup all --env prod" }
  ]
}
```

### `preflight --json`

```json
{
  "stack": "web",
  "env": "prod",
  "generated_at": "2026-07-17T18:05:02Z",
  "verdict": "NO-GO",
  "checks": { "diff": "warn", "drift": "critical", "health": "ok", "backups": "ok" },
  "reasons": [
    { "severity": "critical", "message": "Config drift detected on the VPS — deploying would overwrite un-committed changes",
      "command": "strut web drift fix --env prod" },
    { "severity": "info", "message": "Pending changes are ready to deploy",
      "command": "strut web deploy --env prod" }
  ]
}
```

## Error Handling

- **Per-check isolation (Requirement 1.3).** `_briefing_run` swallows the
  child's non-zero exit and hands the rc to the normalizer. A hard failure,
  a missing env file, or a timeout (rc 124) maps to `unknown` — never aborts.
- **No `VPS_HOST` / diff hard-error (rc 2).** `diff` returns 2 when there is no
  remote target or missing files. The `diff` normalizer maps rc 2 to `unknown`;
  in `preflight`, an all-`unknown` signal set triggers the `NO-GO`-blind gate.
- **Malformed JSON from a check.** Normalizers guard every `jq` call
  (`|| echo unknown`) so a parse failure degrades that one dimension to
  `unknown` rather than crashing the aggregator.
- **Partial JSON on the main command.** `cmd_briefing`/`cmd_preflight` assemble
  their own JSON with `out_json_*`; if a normalizer errors it still returns a
  severity string, so the top-level JSON always closes cleanly.

## Testing Strategy

- **`tests/test_briefing.bats`**
  - Each normalizer: table-driven cases mapping (rc, json) → expected severity
    (health 0/1/2, drift 0/non-zero, images drifted 0/>0, diff
    changes/destructive/rc-2, backup healthy/warning/degraded/critical,
    status running/down/mixed).
  - `_briefing_worst` / `_briefing_posture`: worst-wins, all-unknown → unknown,
    ok-with-unknowns → ok.
  - Error isolation: a stubbed check that exits 1 yields `unknown` and the
    other dimensions still report (fake `$STRUT_BIN` in a temp dir, as
    `test_mcp_tools.bats` does).
  - JSON shape: `--json` output parses with `jq` and has the documented keys;
    text mode contains a glyph per dimension.
  - Exit codes: posture ok → 0, warn/critical/unknown → non-zero.
- **`tests/test_preflight.bats`**
  - Verdict matrix: drift-critical → NO-GO; all-unknown → NO-GO; unhealthy /
    destructive-diff / stale-backup (no NO-GO) → CAUTION; clean → GO.
  - Exit codes 0 / 1 / 2 for GO / CAUTION / NO-GO.
  - `reasons` carry a recommended command; `checks` echoes every dimension.
- **`tests/test_mcp_tools.bats` (extended)**
  - `strut_briefing` / `strut_preflight`: injection payload in `stack`/`env` is
    rejected before `strut_bin` runs; a valid `stack` reaches
    `"$strut_bin" <stack> briefing|preflight --env prod --json`.
- **Real-project run (not just mocks).** Scaffold a throwaway project, run
  `strut <stack> briefing` and `preflight` against it end-to-end, confirming
  graceful degradation to `unknown` where no VPS/Docker is reachable and that
  the JSON is well-formed. This is the "must be a working project, not a
  mockup" gate.
