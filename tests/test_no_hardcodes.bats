#!/usr/bin/env bats
# ==================================================
# tests/test_no_hardcodes.bats — Static analysis: no hardcoded references
# ==================================================
# Validates that the modularization is complete and no Climate-Hub-specific
# or organization-specific references remain in the engine code.
#
# Requirements: 3.4, 4.3, 4.4, 5.5, 6.6, 8.3, 9.3, 9.4, 10.4,
#               16.6, 17.2, 18.4, 19.3, 20.6, 21.3, 22.3

setup() {
  CLI_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

# ── Helper: grep across all lib shell files ──────────────────────────
# Recurses the whole lib/ tree (not an explicit subdir allowlist) so new
# modules — e.g. lib/notify/*.sh, lib/domain/*.sh, lib/cmd_*.sh, or any future
# subdirectory — are covered automatically instead of silently falling
# outside the glob (strut #252 / audit T8: the old explicit-subdir glob is
# exactly why leftover branding survived undetected in files it missed).

grep_lib() {
  # Returns matches (exit 0) or no matches (exit 1).
  # -r recursive, -n line numbers, -E extended regex
  grep -rnE --include='*.sh' "$1" "$CLI_ROOT/lib" 2>/dev/null
}

# ── Branding: no Climate-Hub / ch-deploy / c6-hub references ────────

@test "no 'climate-hub' in any lib/**/*.sh file — Req 4.4, 20.6" {
  if matches=$(grep_lib "climate-hub"); then
    echo "Found 'climate-hub' references:" >&2
    echo "$matches" >&2
    return 1
  fi
}

@test "no 'ch-deploy' in any lib/**/*.sh file — Req 4.3, 20.6" {
  if matches=$(grep_lib "ch-deploy"); then
    echo "Found 'ch-deploy' references:" >&2
    echo "$matches" >&2
    return 1
  fi
}

@test "no 'c6-hub' in any lib/**/*.sh file — Req 9.3, 9.4, 20.6" {
  if matches=$(grep_lib "c6-hub"); then
    echo "Found 'c6-hub' references:" >&2
    echo "$matches" >&2
    return 1
  fi
}

@test "no 'climate_hub' in any lib/**/*.sh file — Req 21.3, 20.6" {
  if matches=$(grep_lib "climate_hub"); then
    echo "Found 'climate_hub' references:" >&2
    echo "$matches" >&2
    return 1
  fi
}


# ── Deploy orchestration: no hardcoded fallback vars ─────────────────

@test "no hardcoded NEO4J_URI in deploy orchestration — Req 3.4" {
  if matches=$(grep -rnE "NEO4J_URI" "$CLI_ROOT"/lib/deploy.sh "$CLI_ROOT"/lib/cmd_deploy.sh 2>/dev/null); then
    echo "Found hardcoded NEO4J_URI:" >&2
    echo "$matches" >&2
    return 1
  fi
}

@test "no hardcoded MISTRAL_API_KEY in deploy orchestration — Req 3.4" {
  if matches=$(grep -rnE "MISTRAL_API_KEY" "$CLI_ROOT"/lib/deploy.sh "$CLI_ROOT"/lib/cmd_deploy.sh 2>/dev/null); then
    echo "Found hardcoded MISTRAL_API_KEY:" >&2
    echo "$matches" >&2
    return 1
  fi
}

# ── Health engine: no hardcoded service names ────────────────────────
# Scoped to all of lib/ (not just health.sh) — these are known ex-Climate-Hub
# service names, and a leftover example/doc-string reference anywhere in the
# engine is the same branding leak as a live hardcode.

@test "no hardcoded 'ch-api' in any lib/**/*.sh file — Req 5.5" {
  if matches=$(grep_lib "ch-api"); then
    echo "Found hardcoded 'ch-api':" >&2
    echo "$matches" >&2
    return 1
  fi
}

@test "no hardcoded 'ch-ingest-otter' in any lib/**/*.sh file — Req 5.5" {
  if matches=$(grep_lib "ch-ingest-otter"); then
    echo "Found hardcoded 'ch-ingest-otter':" >&2
    echo "$matches" >&2
    return 1
  fi
}

@test "no hardcoded 'ch-whatsapp' in any lib/**/*.sh file — Req 5.5" {
  if matches=$(grep_lib "ch-whatsapp"); then
    echo "Found hardcoded 'ch-whatsapp':" >&2
    echo "$matches" >&2
    return 1
  fi
}

@test "no hardcoded 'ch-chatbot' in any lib/**/*.sh file — Req 5.5" {
  if matches=$(grep_lib "ch-chatbot"); then
    echo "Found hardcoded 'ch-chatbot':" >&2
    echo "$matches" >&2
    return 1
  fi
}

# ── Health engine: no hardcoded port numbers ─────────────────────────

@test "no hardcoded port 8000 in health/network checks — Req 10.4" {
  if matches=$(grep -rnE '\b8000\b' "$CLI_ROOT"/lib/health.sh 2>/dev/null); then
    echo "Found hardcoded port 8000:" >&2
    echo "$matches" >&2
    return 1
  fi
}

@test "no hardcoded port 8001 in health/network checks — Req 10.4" {
  if matches=$(grep -rnE '\b8001\b' "$CLI_ROOT"/lib/health.sh 2>/dev/null); then
    echo "Found hardcoded port 8001:" >&2
    echo "$matches" >&2
    return 1
  fi
}

@test "no hardcoded port 8002 in health/network checks — Req 10.4" {
  if matches=$(grep -rnE '\b8002\b' "$CLI_ROOT"/lib/health.sh 2>/dev/null); then
    echo "Found hardcoded port 8002:" >&2
    echo "$matches" >&2
    return 1
  fi
}

@test "no hardcoded port 8501 in health/network checks — Req 10.4" {
  if matches=$(grep -rnE '\b8501\b' "$CLI_ROOT"/lib/health.sh 2>/dev/null); then
    echo "Found hardcoded port 8501:" >&2
    echo "$matches" >&2
    return 1
  fi
}

# ── VPS sync: no hardcoded origin/main ───────────────────────────────

@test "no hardcoded 'origin/main' in VPS sync logic — Req 8.3" {
  if matches=$(grep -rnE "origin/main" "$CLI_ROOT"/lib/deploy.sh 2>/dev/null); then
    echo "Found hardcoded 'origin/main':" >&2
    echo "$matches" >&2
    return 1
  fi
}

# ── Volumes: no hardcoded paths or UIDs ──────────────────────────────

@test "no hardcoded NEO4J_DATA_PATH in volumes.sh — Req 16.6" {
  if matches=$(grep -rnE "NEO4J_DATA_PATH" "$CLI_ROOT"/lib/volumes.sh 2>/dev/null); then
    echo "Found hardcoded NEO4J_DATA_PATH:" >&2
    echo "$matches" >&2
    return 1
  fi
}

@test "no hardcoded GDRIVE_TRANSCRIPTS_PATH in volumes.sh — Req 16.6" {
  if matches=$(grep -rnE "GDRIVE_TRANSCRIPTS_PATH" "$CLI_ROOT"/lib/volumes.sh 2>/dev/null); then
    echo "Found hardcoded GDRIVE_TRANSCRIPTS_PATH:" >&2
    echo "$matches" >&2
    return 1
  fi
}

@test "no hardcoded UID 7474 in volumes.sh — Req 16.6" {
  if matches=$(grep -rnE '\b7474\b' "$CLI_ROOT"/lib/volumes.sh 2>/dev/null); then
    echo "Found hardcoded UID 7474:" >&2
    echo "$matches" >&2
    return 1
  fi
}

@test "no hardcoded UID 999 in volumes.sh — Req 16.6" {
  # Match standalone 999 (not part of a larger number)
  if matches=$(grep -rnE '\b999\b' "$CLI_ROOT"/lib/volumes.sh 2>/dev/null); then
    echo "Found hardcoded UID 999:" >&2
    echo "$matches" >&2
    return 1
  fi
}

# ── Deploy dir: no hardcoded /home/ubuntu/ch-deploy ──────────────────

@test "no hardcoded '/home/ubuntu/ch-deploy' in any lib module — Req 17.2" {
  if matches=$(grep_lib "/home/ubuntu/ch-deploy"); then
    echo "Found hardcoded deploy dir:" >&2
    echo "$matches" >&2
    return 1
  fi
}

# ── Registry: no hardcoded ghcr.io/c6-hub image refs ────────────────

@test "no hardcoded 'ghcr.io/c6-hub' in any lib module — Req 19.3" {
  if matches=$(grep_lib "ghcr.io/c6-hub"); then
    echo "Found hardcoded GHCR image references:" >&2
    echo "$matches" >&2
    return 1
  fi
}

# ── Keys: no hardcoded c6-hub/ch-* repo names ───────────────────────

@test "no hardcoded 'c6-hub/ch-' repo names in keys modules — Req 18.4" {
  if matches=$(grep -rnE "c6-hub/ch-" "$CLI_ROOT"/lib/keys/*.sh "$CLI_ROOT"/lib/keys.sh 2>/dev/null); then
    echo "Found hardcoded repo names:" >&2
    echo "$matches" >&2
    return 1
  fi
}

# ── Database: no hardcoded climate_hub default ───────────────────────

@test "no hardcoded 'climate_hub' as default DB name — Req 21.3" {
  # Check all files that might set a default database name
  if matches=$(grep -rnE 'climate_hub' \
    "$CLI_ROOT"/lib/schema.sh \
    "$CLI_ROOT"/lib/keys/db.sh \
    "$CLI_ROOT"/lib/keys/test.sh \
    "$CLI_ROOT"/lib/backup/compare.sh \
    2>/dev/null); then
    echo "Found hardcoded 'climate_hub' DB default:" >&2
    echo "$matches" >&2
    return 1
  fi
}

# ── SSH: no hardcoded climate-hub- key prefix ────────────────────────

@test "no hardcoded 'climate-hub-' SSH key prefix — Req 22.3" {
  if matches=$(grep -rnE "climate-hub-" "$CLI_ROOT"/lib/keys/ssh.sh 2>/dev/null); then
    echo "Found hardcoded SSH key prefix:" >&2
    echo "$matches" >&2
    return 1
  fi
}

# ── Reverse proxy: no hardcoded nginx outside dispatch branches ──────
# Feature: pluggable-reverse-proxy, Requirements 1.1, 2.1, 3.1
# Verifies that engine dispatch files don't reference nginx outside of
# case branches or REVERSE_PROXY default assignments.

@test "no hardcoded nginx outside proxy dispatch in deploy.sh — Req 2.1" {
  # Grep for 'nginx' but exclude:
  #   - case branch labels: nginx) or nginx|caddy)
  #   - REVERSE_PROXY default: ${REVERSE_PROXY:-nginx}
  #   - comments (lines starting with #)
  #   - ok/warn messages that reference the proxy by $proxy variable result
  if matches=$(grep -nE 'nginx' "$CLI_ROOT"/lib/deploy.sh 2>/dev/null \
    | grep -vE '(nginx\)|nginx\|caddy|REVERSE_PROXY:-nginx|^\s*#|"nginx reloaded"|"nginx reload failed")'); then
    echo "Found hardcoded nginx outside dispatch in deploy.sh:" >&2
    echo "$matches" >&2
    return 1
  fi
}

@test "no hardcoded nginx outside proxy dispatch in health.sh — Req 7.1" {
  if matches=$(grep -nE 'nginx' "$CLI_ROOT"/lib/health.sh 2>/dev/null \
    | grep -vE '(nginx\)|nginx\|caddy|REVERSE_PROXY:-nginx|^\s*#|^[0-9]+:\s*#)'); then
    echo "Found hardcoded nginx outside dispatch in health.sh:" >&2
    echo "$matches" >&2
    return 1
  fi
}

@test "no hardcoded nginx outside proxy dispatch in drift.sh — Req 5.1" {
  if matches=$(grep -nE 'nginx' "$CLI_ROOT"/lib/drift.sh 2>/dev/null \
    | grep -vE '(nginx\)|nginx\|caddy|REVERSE_PROXY:-nginx|^\s*#|^[0-9]+:\s*#|nginx\.conf|nginx -t|command -v nginx)'); then
    echo "Found hardcoded nginx outside dispatch in drift.sh:" >&2
    echo "$matches" >&2
    return 1
  fi
}

# ── Entrypoint: no old cli.sh references in user-facing output ───────

# ── Backup: no gdrive/ch-ingest-gdrive app-specifics ─────────────────

@test "no 'gdrive' in backup modules/completions/usage text — Req audit-2026-07" {
  if matches=$(grep -rnE "gdrive" \
    "$CLI_ROOT"/lib/backup.sh \
    "$CLI_ROOT"/lib/backup/*.sh \
    "$CLI_ROOT"/completions/*.sh \
    "$CLI_ROOT"/completions/*.fish \
    "$CLI_ROOT"/strut \
    2>/dev/null); then
    echo "Found 'gdrive' references:" >&2
    echo "$matches" >&2
    return 1
  fi
}

@test "no 'ch-ingest-gdrive' in any lib/**/*.sh file — Req audit-2026-07" {
  if matches=$(grep_lib "ch-ingest-gdrive"); then
    echo "Found 'ch-ingest-gdrive' references:" >&2
    echo "$matches" >&2
    return 1
  fi
}

# ── Backup: no hardcoded neo4j:5.15 image tag ────────────────────────

@test "no hardcoded 'neo4j:5.15' image tag in lib/backup.sh — Req audit-2026-07" {
  if matches=$(grep -nE "neo4j:5\.15" "$CLI_ROOT"/lib/backup.sh 2>/dev/null); then
    echo "Found hardcoded neo4j:5.15 image tag:" >&2
    echo "$matches" >&2
    return 1
  fi
}

# ── Database: no hardcoded 'app_db' default anywhere in lib/**/*.sh ──

@test "no hardcoded 'app_db' default anywhere in lib modules — Req audit-2026-07" {
  if matches=$(grep_lib "app_db"); then
    echo "Found hardcoded 'app_db' default:" >&2
    echo "$matches" >&2
    return 1
  fi
}

# ── Monitor: no hardcoded twenty/vps-2/ch-api app-specifics ──────────

@test "no 'twenty', 'vps-2', or 'ch-api' in lib/monitor.sh — Req audit-2026-07" {
  if matches=$(grep -nE "twenty|vps-2|ch-api" "$CLI_ROOT"/lib/monitor.sh 2>/dev/null); then
    echo "Found hardcoded app-specific references:" >&2
    echo "$matches" >&2
    return 1
  fi
}

# ── Keys: no hardcoded SEMANTIC_API_KEYS env var name ────────────────

@test "no hardcoded 'SEMANTIC_API_KEYS' in lib/keys/api.sh — Req audit-2026-07" {
  if matches=$(grep -nE "SEMANTIC_API_KEYS" "$CLI_ROOT"/lib/keys/api.sh 2>/dev/null); then
    echo "Found hardcoded SEMANTIC_API_KEYS env var name:" >&2
    echo "$matches" >&2
    return 1
  fi
}

# ── Deploy: no hardcoded data/gdrive default data dir ────────────────

@test "no hardcoded 'data/gdrive' default in lib/deploy.sh — Req audit-2026-07" {
  if matches=$(grep -nE "data/gdrive" "$CLI_ROOT"/lib/deploy.sh 2>/dev/null); then
    echo "Found hardcoded data/gdrive default:" >&2
    echo "$matches" >&2
    return 1
  fi
}

# ── Utils: no leftover CH_API_PORT docstring example ─────────────────

@test "no 'CH_API_PORT' in lib/utils.sh — Req audit-2026-07" {
  if matches=$(grep -nE "CH_API_PORT" "$CLI_ROOT"/lib/utils.sh 2>/dev/null); then
    echo "Found leftover CH_API_PORT reference:" >&2
    echo "$matches" >&2
    return 1
  fi
}

@test "no './cli.sh' references in any lib module" {
  if matches=$(grep_lib '\./cli\.sh'); then
    echo "Found './cli.sh' references (should be 'strut'):" >&2
    echo "$matches" >&2
    return 1
  fi
}

@test "no 'cli.sh' in user-facing strings in lib modules" {
  # Exclude comments (lines starting with #) — only check code/strings
  if matches=$(grep_lib 'cli\.sh' | grep -v '^\s*#'); then
    echo "Found 'cli.sh' in non-comment lines:" >&2
    echo "$matches" >&2
    return 1
  fi
}
