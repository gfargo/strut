# Operational Briefing - Implementation Plan

Tasks are unchecked at spec time and checked off as each is implemented and
verified. Discovered fixes are appended to the relevant task with their own
`_Requirements:_` line, so the spec records what actually happened (including
bugs found during live testing) rather than pretending the design was perfect.

- [x] 1. Shared aggregation library `lib/briefing.sh`
  - [x] 1.1 `_briefing_bin` + `_briefing_run` (error-isolated runner, optional
        `timeout`/`gtimeout` wrapper, preserves rc incl. 124)
    - _Requirements: 1.3, and design "Bounded fan-out and timeouts"_
  - [x] 1.2 Severity ranking helpers `_briefing_sev_rank`, `_briefing_worst`,
        `_briefing_posture`
    - _Requirements: 1.2, 1.4_
  - [x] 1.3 Per-dimension normalizers (health, drift, images, diff, backup)
        mapping (rc, json) → severity + summary
    - _Requirements: 1.1, 1.2, and Error Handling (guarded jq)_
    - [x] 1.3a FIX (found in unit smoke test): the diff normalizer used
          `.has_changes // empty`, but jq's `//` treats a literal `false` as
          empty — so a clean "no changes" diff was misread as `unknown`. Switched
          to an explicit `has("has_changes")` presence check + `tostring`, and
          made the severity a strict `case` on `true`/`false`/other so empty
          stdin (rc 2, no remote) correctly yields `unknown`.
    - _Requirements: 1.2, Error Handling_
    - [x] 1.3b Added `_briefing_json_extract` to strip a leading log/`ok` line
          before a JSON body (`backup health --json` prints "Dashboard data
          generated" before its array).
    - _Requirements: Error Handling (guarded parsing)_
  - [x] 1.4 `_briefing_remedy` — remediation command per dimension
    - _Requirements: 1.5_

- [x] 2. `lib/cmd_briefing.sh` — situation report
  - [x] 2.1 Reads `$CMD_STACK`/`$CMD_ENV_NAME`/`$CMD_JSON`; scans args for `--help`
    - _Requirements: 4.1_
  - [x] 2.2 Fan out five dimensions, normalize, compute posture
    - _Requirements: 1.1, 1.2, 1.3, 1.4_
  - [x] 2.3 Build prioritized `actions` list (worst-first, with commands)
    - _Requirements: 1.5_
    - [x] 2.3a REFINEMENT (found in real-project run): actions now include only
          dimensions strictly worse than ok (warn/critical). `unknown` ranks
          below ok — it means "couldn't assess", not a defect — so proposing a
          fix command (e.g. `drift fix` for a drift check that merely couldn't
          run) was misleading. Unknowns still appear in the dimensions table.
    - _Requirements: 1.5_
  - [x] 2.4 JSON output (`out_json_*`) and human report (glyphs, NO_COLOR-safe)
    - _Requirements: 1.6, 1.7_
  - [x] 2.5 Exit code reflects posture
    - _Requirements: 1.8_

- [x] 3. `lib/cmd_preflight.sh` — deploy go/no-go
  - [x] 3.1 Fan out diff/drift/health/backup, normalize
    - _Requirements: 2.1_
  - [x] 3.2 Verdict logic (NO-GO/CAUTION/GO gates) + reasons with commands
    - _Requirements: 2.2, 2.3, 2.4, 2.5, 2.6_
  - [x] 3.3 JSON + human output; exit codes 0/1/2
    - _Requirements: 2.7, 2.8_
    - [x] 3.3a FIX: `checks` is a keyed nested object, but the output API has no
          "open keyed object" helper — assembled it with `out_json_field_raw`
          from the fixed-vocabulary severities (no escaping needed).
    - _Requirements: 2.7_
    - [x] 3.3b REVIEW tightening: degraded (warn) health was only visible in the
          `checks` object — preflight now also emits an `info` reason for it, so
          a non-ok health state is always explained in `reasons`. Verdict is
          unchanged (still GO — degraded doesn't block).
    - _Requirements: 2.6 (extended)_

- [x] 4. Entrypoint wiring
  - [x] 4.1 Source `lib/briefing.sh`, `lib/cmd_briefing.sh`, `lib/cmd_preflight.sh`
    - _Requirements: 4.1_
  - [x] 4.2 Add `briefing)` and `preflight)` to per-stack dispatch
    - _Requirements: 4.1_
  - [x] 4.3 Usage/help text for both commands (+ `usage()` command list)
    - _Requirements: 4.2_

- [x] 5. MCP exposure
  - [x] 5.1 Add `strut_briefing` + `strut_preflight` to `_mcp_tools_list` (15 tools)
    - _Requirements: 3.1_
  - [x] 5.2 Add `case` arms to `_mcp_tools_call` using `_mcp_arg` validation
    - _Requirements: 3.2, 3.3_
  - [x] 5.3 Add both to auto-approve list + printed summaries in cmd_mcp.sh
    - _Requirements: 3.4_

- [x] 6. Tests
  - [x] 6.1 `tests/test_briefing.bats` (31 tests: normalizers, posture, isolation,
        JSON, exit, unknown-not-actioned)
    - _Requirements: 1.2, 1.3, 1.4, 1.6, 1.8, 4.4_
  - [x] 6.2 `tests/test_preflight.bats` (13 tests: verdict matrix, exit codes, reasons)
    - _Requirements: 2.2–2.8, 4.4_
  - [x] 6.3 Extend `tests/test_mcp_tools.bats` (both tools: injection + pass-through)
    - _Requirements: 3.2, 3.3, 4.4_

- [x] 7. Docs + completions + skill
  - [x] 7.1 README: command table + examples
    - _Requirements: 4.2, 4.3_
  - [x] 7.2 `completions/bash.sh` + `zsh.sh` + `fish.fish` per-stack commands
        (required by the completions-sync test)
    - _Requirements: 4.2_
  - [x] 7.3 `.kiro/skills/strut/SKILL.md` (Inspect list + core principle)
    - _Requirements: 4.3_

- [x] 8. Verification + audit
  - [x] 8.1 `shellcheck` green on all new/modified files; syntax + completions-sync
        tests pass
    - _Requirements: 4.4_
  - [x] 8.2 Real scaffolded-project run of briefing + preflight (init + scaffold,
        no VPS): briefing → posture critical/unknowns, valid JSON, exit 1;
        preflight → NO-GO (blind), exit 2. Confirms graceful degradation, not a
        mockup.
    - _Requirements: design "Testing Strategy — Real-project run"_
  - [x] 8.3 Authorship (human) + whole-diff secrets scan clean; no
        `.kiro/settings/mcp.json` in repo; no AI-attribution in new files
    - _Requirements: challenge brief (authorship + secrets audit)_
