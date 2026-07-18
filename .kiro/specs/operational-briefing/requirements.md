# Operational Briefing - Requirements

## Introduction

strut already exposes thirteen MCP tools, but each one is a thin 1:1 wrapper
over a single `strut` subcommand (`strut_status` → `status`, `strut_health` →
`health`, and so on). An AI agent that wants a real answer to "how is my
production stack doing?" or "is it safe to deploy right now?" has to call five
or six tools, hold the raw output of each in context, and reconcile them
itself — reconstructing operator judgement from scratch on every question.

This feature adds two **synthesis** capabilities that fuse the existing
read-only checks into a single situational answer:

- **`briefing`** — a situation report. One call fans out every read-only check
  for a stack (containers, health, config drift, image staleness, pending
  diff, backup health), normalizes each into a common severity, computes an
  overall posture, and returns a prioritized list of what needs attention with
  the exact remediation command for each finding.
- **`preflight`** — a deploy go/no-go. It reuses the deploy-relevant subset of
  those checks and applies release-safety logic to return a single verdict
  (`GO` / `CAUTION` / `NO-GO`) with the reasons behind it and the pre-steps a
  human should take first.

Both are exposed as real `strut <stack> <command>` CLI commands (so they are
independently testable, scriptable, and useful outside an IDE) and as
read-only MCP tools (`strut_briefing`, `strut_preflight`). Neither introduces a
new external dependency or any new detection logic — they aggregate checks
strut already performs, add one normalization/scoring pass, and let the calling
agent narrate from the structured result.

## Requirements

### Requirement 1: Situation report aggregation (`briefing`)

**User Story:** As an operator (or an AI agent acting for one), I want a single
command that summarizes every dimension of a stack's operational health, so
that I can understand its state without running six separate checks and
reconciling them by hand.

#### Acceptance Criteria

1. WHEN `strut <stack> briefing` runs THEN the system SHALL collect results for
   each of these dimensions: health (which includes per-container running
   state), config drift, image staleness, pending diff, and backup health.
   > Refinement (during implementation): an early draft listed "containers" as
   > a separate dimension sourced from `status --json`, but `cmd_status` does
   > not emit structured JSON (it prints `docker compose ps`). `health --json`
   > already reports each container as a check with `overall_status`, so
   > container state is folded into the health dimension rather than derived
   > from an unreliable second source. Five dimensions, not six.
2. WHEN a dimension's underlying check succeeds THEN the system SHALL normalize
   it into exactly one severity: `ok`, `warn`, `critical`, or `unknown`.
3. WHEN one dimension's check fails, errors, or times out THEN the system SHALL
   record that dimension as `unknown` and STILL report every other dimension —
   one failing sub-check SHALL NOT blank out its siblings.
4. WHEN all dimensions are collected THEN the system SHALL compute an overall
   posture as the worst observed severity, where `critical` > `warn` > `ok`,
   and `unknown` only becomes the posture when no dimension reached `ok` or
   worse.
5. WHEN a dimension is worse than `ok` THEN the system SHALL include it in a
   prioritized `actions` list (most severe first), each carrying a
   human-readable summary and the exact `strut` command that remediates it.
6. WHEN `--json` is passed THEN the system SHALL emit a single structured JSON
   object with `stack`, `env`, `generated_at`, `posture`, a `dimensions` array,
   and an `actions` array, and SHALL emit nothing else on stdout.
7. WHEN `--json` is NOT passed THEN the system SHALL render a human-readable
   report with per-dimension severity glyphs, honoring `NO_COLOR` and non-TTY
   output the same way the rest of strut does.
8. WHEN the posture is `ok` THEN the command SHALL exit 0; WHEN the posture is
   `warn`, `critical`, or `unknown` THEN it SHALL exit non-zero, so CI and
   scripts can gate on it.

### Requirement 2: Deploy go/no-go (`preflight`)

**User Story:** As an operator about to release, I want one command that tells
me whether it is safe to deploy right now and why, so that I do not clobber
un-reconciled drift, deploy onto a broken stack, or ship without a recent
backup.

#### Acceptance Criteria

1. WHEN `strut <stack> preflight` runs THEN the system SHALL evaluate the
   deploy-safety dimensions: pending diff, config drift, current health, and
   backup freshness.
2. IF config drift is detected THEN the verdict SHALL be `NO-GO`, because a
   deploy would overwrite un-committed changes on the VPS.
3. IF the required signals cannot be gathered at all (e.g. no remote target
   configured, all checks `unknown`) THEN the verdict SHALL be `NO-GO`, because
   deploying blind is unsafe.
4. IF the stack is currently unhealthy, OR the pending diff is destructive, OR
   backups are stale/failing, AND no `NO-GO` condition holds THEN the verdict
   SHALL be `CAUTION` with the specific reason(s) listed.
5. WHEN no `NO-GO` or `CAUTION` condition holds THEN the verdict SHALL be `GO`.
6. WHEN there are no pending changes to deploy THEN the system SHALL surface
   that as an informational reason (it does not by itself change a `GO`).
   Likewise, WHEN health is `degraded` (milder than unhealthy) THEN the system
   SHALL surface it as an informational reason without, on its own, downgrading
   a `GO` — a deploy often restores a degraded stack.
7. WHEN `--json` is passed THEN the system SHALL emit a structured object with
   `stack`, `env`, `generated_at`, `verdict`, a `reasons` array (each with a
   severity, message, and recommended command), and a `checks` object echoing
   each evaluated dimension's severity.
8. WHEN the verdict is `GO` THEN the command SHALL exit 0; `CAUTION` SHALL exit
   a distinct non-zero code from `NO-GO`, so automation can branch on the three
   outcomes.

### Requirement 3: MCP exposure (read-only)

**User Story:** As an AI agent connected to strut over MCP, I want `briefing`
and `preflight` available as tools, so that I can answer high-level operational
questions in one call.

#### Acceptance Criteria

1. WHEN an MCP client lists tools THEN `strut_briefing` and `strut_preflight`
   SHALL appear with an input schema requiring `stack` and optionally accepting
   `env`.
2. WHEN either tool is called THEN its arguments SHALL pass through the same
   identifier validation as every other strut MCP tool (rejecting shell
   metacharacters) BEFORE `strut` is invoked.
3. WHEN either tool is called with a valid `stack` THEN it SHALL invoke the
   corresponding `strut <stack> <command> --json` and return the result as an
   MCP text content block.
4. BECAUSE both tools are strictly read-only (they run no state-changing
   operations) THEN they SHALL be added to the auto-approve list alongside the
   other read-only tools, and documented as such.

### Requirement 4: Consistency and no regressions

**User Story:** As a maintainer, I want the new commands to follow strut's
existing conventions and not break anything, so that they read as native.

#### Acceptance Criteria

1. WHEN the new lib files are added THEN they SHALL start with
   `set -euo pipefail`, use the shared `out_json_*`/log/color helpers, and be
   sourced by the `strut` entrypoint in the command-handler block.
2. WHEN the new commands are added to dispatch THEN they SHALL also appear in
   usage/help text, shell completions (bash + zsh), and the README command
   surface.
3. WHEN the MCP tool count or tool list is stated in any doc surface (README,
   install output, skill references) THEN every such surface SHALL be updated
   consistently.
4. WHEN the full `bats` suite and `shellcheck` run THEN they SHALL pass,
   including new tests covering the normalization, posture/verdict logic, error
   isolation, and MCP argument validation for both tools.
