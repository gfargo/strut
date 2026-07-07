#!/usr/bin/env bash
# ==================================================
# lib/cmd_drift_images.sh — Image-digest drift detection
# ==================================================
# Detects when running containers use stale images whose tags have moved
# on the registry (running digest ≠ current registry digest).
#
# Provides:
#   drift_images         — detect image drift for a stack (local or remote)
#   drift_images_remote  — run detection on a remote VPS via SSH

set -euo pipefail

# drift_images <stack> [--json] [--remote]
#
# For each running container in the stack's compose project, compares the
# running image digest against what the tag currently resolves to on the
# registry. Reports stale images.
drift_images() {
  local stack="$1"; shift
  local json_flag=false
  local remote_flag=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json_flag=true; shift ;;
      --remote) remote_flag=true; shift ;;
      *) shift ;;
    esac
  done

  if $remote_flag; then
    drift_images_remote "$stack" "$json_flag"
    return $?
  fi

  # Local detection
  _drift_images_detect "$stack" "$json_flag"
}

# drift_images_remote <stack> <json_flag>
#
# Runs image drift detection on the VPS via SSH.
drift_images_remote() {
  local stack="$1"
  local json_flag="$2"

  local vps_host="${VPS_HOST:-}"
  local vps_user="${VPS_USER:-ubuntu}"
  local vps_port="${VPS_PORT:-22}"
  local vps_ssh_key="${VPS_SSH_KEY:-}"

  [ -n "$vps_host" ] || { fail "VPS_HOST not set — cannot check remote images"; return 1; }

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$vps_port" -k "$vps_ssh_key" --batch)

  local deploy_dir
  deploy_dir=$(resolve_deploy_dir)

  # Run the detection script on the remote
  # shellcheck disable=SC2029
  local output
  output=$(ssh $ssh_opts "$vps_user@$vps_host" "
    set -e
    cd '$deploy_dir' 2>/dev/null || exit 0

    # Find compose project for this stack
    project=\$(docker compose -f 'stacks/$stack/docker-compose.yml' ps -q 2>/dev/null | head -1)
    [ -n \"\$project\" ] || exit 0

    # Get running containers for this project
    containers=\$(docker compose -f 'stacks/$stack/docker-compose.yml' ps -q 2>/dev/null)
    [ -n \"\$containers\" ] || exit 0

    while IFS= read -r cid; do
      [ -n \"\$cid\" ] || continue
      # Get the image reference and running digest
      info=\$(docker inspect --format '{{.Config.Image}}|{{.Image}}' \"\$cid\" 2>/dev/null) || continue
      image_ref=\"\${info%%|*}\"
      running_digest=\"\${info#*|}\"

      # Skip digest-pinned refs (already locked)
      [[ \"\$image_ref\" == *@sha256:* ]] && continue

      # Try to get the current registry digest
      registry_digest=\$(docker manifest inspect \"\$image_ref\" 2>/dev/null | grep -m1 '\"digest\"' | sed 's/.*\"digest\": *\"//;s/\".*//' || echo \"\")

      if [ -n \"\$registry_digest\" ] && [ \"\$running_digest\" != \"sha256:\$registry_digest\" ] && [ \"\$running_digest\" != \"\$registry_digest\" ]; then
        echo \"DRIFT|\$image_ref|\${running_digest:0:19}|\${registry_digest:0:19}\"
      else
        echo \"OK|\$image_ref\"
      fi
    done <<< \"\$containers\"
  " 2>/dev/null) || true

  _drift_images_render "$stack" "$output" "$json_flag"
}

# _drift_images_detect <stack> <json_flag>
#
# Local image drift detection against the local Docker daemon.
_drift_images_detect() {
  local stack="$1"
  local json_flag="$2"
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local compose_file="$cli_root/stacks/$stack/docker-compose.yml"

  [ -f "$compose_file" ] || { warn "No compose file for stack: $stack"; return 0; }

  local containers
  containers=$(docker compose -f "$compose_file" ps -q 2>/dev/null) || true
  [ -n "$containers" ] || { log "No running containers for $stack"; return 0; }

  local output=""
  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    local info
    info=$(docker inspect --format '{{.Config.Image}}|{{.Image}}' "$cid" 2>/dev/null) || continue
    local image_ref="${info%%|*}"
    local running_digest="${info#*|}"

    # Skip digest-pinned refs
    [[ "$image_ref" == *@sha256:* ]] && continue

    # Get registry digest
    local registry_digest=""
    registry_digest=$(docker manifest inspect "$image_ref" 2>/dev/null | grep -m1 '"digest"' | sed 's/.*"digest": *"//;s/".*//' || echo "")

    if [ -n "$registry_digest" ] && [ "$running_digest" != "sha256:$registry_digest" ] && [ "$running_digest" != "$registry_digest" ]; then
      output="${output}DRIFT|$image_ref|${running_digest:0:19}|${registry_digest:0:19}
"
    else
      output="${output}OK|$image_ref
"
    fi
  done <<< "$containers"

  _drift_images_render "$stack" "$output" "$json_flag"
}

# _drift_images_render <stack> <output_lines> <json_flag>
_drift_images_render() {
  local stack="$1"
  local output="$2"
  local json_flag="$3"

  local drifted=0
  local total=0
  local json_items=()

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    total=$((total + 1))
    local status="${line%%|*}"
    local rest="${line#*|}"

    if [ "$status" = "DRIFT" ]; then
      drifted=$((drifted + 1))
      local image="${rest%%|*}"
      rest="${rest#*|}"
      local running="${rest%%|*}"
      local registry="${rest#*|}"

      if [ "$json_flag" = "true" ]; then
        json_items+=("{\"image\":\"$image\",\"status\":\"stale\",\"running\":\"$running\",\"registry\":\"$registry\"}")
      else
        echo -e "  ${RED}✗${NC} $image — stale (running: ${running}…, registry: ${registry}…)"
      fi
    else
      local image="${rest%%|*}"
      if [ "$json_flag" = "true" ]; then
        json_items+=("{\"image\":\"$image\",\"status\":\"current\"}")
      fi
    fi
  done <<< "$output"

  if [ "$json_flag" = "true" ]; then
    local joined=""
    if [ ${#json_items[@]} -gt 0 ]; then
      joined=$(printf '%s,' "${json_items[@]}")
      joined="${joined%,}"
    fi
    echo "{\"stack\":\"$stack\",\"total\":$total,\"drifted\":$drifted,\"images\":[$joined]}"
  else
    if [ "$total" -eq 0 ]; then
      log "No running images to check for $stack"
    elif [ "$drifted" -eq 0 ]; then
      ok "$stack: all $total images current"
    else
      warn "$stack: $drifted/$total images have stale digests"
    fi
  fi

  [ "$drifted" -eq 0 ]
}
