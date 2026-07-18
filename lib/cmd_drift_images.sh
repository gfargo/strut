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

# _drift_images_project_name <stack> <env_file>
#
# Echoes the compose project name a real deploy of this stack/env resolves
# to (via resolve_compose_cmd — the same helper deploy/status/stop use), so
# `drift images` queries the project `strut deploy` actually created.
# Without --project-name, `docker compose ps` infers the project from the
# compose file's DIRECTORY name (just "<stack>"), which a strut-deployed
# stack (project "<stack>-<env>") never runs under — `ps -q` silently
# returned nothing for every real deployment (strut#382).
_drift_images_project_name() {
  local stack="$1"
  local env_file="$2"
  local compose_cmd
  compose_cmd=$(resolve_compose_cmd "$stack" "$env_file" "" "" 2>/dev/null) || { echo "$stack"; return 0; }
  local project_name
  project_name=$(echo "$compose_cmd" | grep -oE '\-\-project\-name [^ ]+' | awk '{print $2}')
  echo "${project_name:-$stack}"
}

# drift_images <stack> <env_file> [--json] [--remote]
#
# For each running container in the stack's compose project, compares the
# running image digest against what the tag currently resolves to on the
# registry. Reports stale images.
drift_images() {
  local stack="$1"; shift
  local env_file="$1"; shift
  local json_flag=false
  local remote_flag=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json_flag=true; shift ;;
      --remote) remote_flag=true; shift ;;
      *) shift ;;
    esac
  done

  local project_name
  project_name=$(_drift_images_project_name "$stack" "$env_file")

  if $remote_flag; then
    drift_images_remote "$stack" "$json_flag" "$project_name"
    return $?
  fi

  # Local detection
  _drift_images_detect "$stack" "$json_flag" "$project_name"
}

# drift_images_remote <stack> <json_flag> <project_name>
#
# Runs image drift detection on the VPS via SSH.
drift_images_remote() {
  local stack="$1"
  local json_flag="$2"
  local project_name="$3"

  local vps_host="${VPS_HOST:-}"
  local vps_user="${VPS_USER:-ubuntu}"
  local vps_port="${VPS_PORT:-22}"
  local vps_ssh_key="${VPS_SSH_KEY:-}"

  [ -n "$vps_host" ] || { fail "VPS_HOST not set — cannot check remote images"; return 1; }

  local ssh_opts
  ssh_opts=$(build_ssh_opts -p "$vps_port" -k "$vps_ssh_key" --batch)

  local deploy_dir
  deploy_dir=$(resolve_deploy_dir)

  # Run the detection script on the remote. Each container line is one of:
  #   DRIFT|<image>|<running_digest_prefix>|<registry_digest_prefix>
  #   OK|<image>
  #   UNKNOWN|<image>   — digest lookup failed or wasn't safely comparable;
  #                       distinct from OK so it never masks real drift.
  # shellcheck disable=SC2029
  local output rc=0
  output=$(ssh $ssh_opts "$vps_user@$vps_host" "
    set -e
    cd '$deploy_dir' || exit 90

    containers=\$(docker compose -f 'stacks/$stack/docker-compose.yml' --project-name '$project_name' ps -q 2>/dev/null)
    [ -n \"\$containers\" ] || exit 0

    while IFS= read -r cid; do
      [ -n \"\$cid\" ] || continue

      info=\$(docker inspect --format '{{.Config.Image}}|{{index .RepoDigests 0}}' \"\$cid\" 2>/dev/null) || { echo \"UNKNOWN|\$cid\"; continue; }
      image_ref=\"\${info%%|*}\"
      repo_digest=\"\${info#*|}\"

      # Digest-pinned refs are already locked — nothing to compare.
      case \"\$image_ref\" in
        *@sha256:*) echo \"OK|\$image_ref\"; continue ;;
      esac

      # No RepoDigest (e.g. a locally-built image, never pulled from a
      # registry) — Go template index-out-of-range leaves this empty or
      # equal to the raw template text; either way we can't compare.
      case \"\$repo_digest\" in
        ''|*'{{'*) echo \"UNKNOWN|\$image_ref\"; continue ;;
      esac
      running_digest=\"\${repo_digest#*@}\"

      manifest_raw=\$(docker manifest inspect \"\$image_ref\" 2>/dev/null || echo '')
      if [ -z \"\$manifest_raw\" ]; then
        echo \"UNKNOWN|\$image_ref\"
      elif echo \"\$manifest_raw\" | grep -q '\"manifests\"'; then
        # Multi-arch manifest LIST — the first (or only) \"digest\" field in
        # this document is a per-platform manifest digest, never equal to
        # the list digest actually pulled (strut#382's false-positive).
        # Only docker buildx's imagetools can resolve the true list digest
        # portably; without it, report unknown rather than guess.
        list_digest=''
        if docker buildx version >/dev/null 2>&1; then
          list_digest=\$(docker buildx imagetools inspect \"\$image_ref\" 2>/dev/null | grep -m1 '^Digest:' | awk '{print \$2}')
        fi
        if [ -n \"\$list_digest\" ]; then
          if [ \"\$running_digest\" = \"\$list_digest\" ]; then
            echo \"OK|\$image_ref\"
          else
            echo \"DRIFT|\$image_ref|\${running_digest:0:19}|\${list_digest:0:19}\"
          fi
        else
          echo \"UNKNOWN|\$image_ref\"
        fi
      else
        registry_digest=\$(echo \"\$manifest_raw\" | grep -m1 '\"digest\"' | sed 's/.*\"digest\": *\"//;s/\".*//')
        if [ -z \"\$registry_digest\" ]; then
          echo \"UNKNOWN|\$image_ref\"
        elif [ \"\$running_digest\" = \"sha256:\$registry_digest\" ] || [ \"\$running_digest\" = \"\$registry_digest\" ]; then
          echo \"OK|\$image_ref\"
        else
          echo \"DRIFT|\$image_ref|\${running_digest:0:19}|\${registry_digest:0:19}\"
        fi
      fi
    done <<EOF_CONTAINERS
\$containers
EOF_CONTAINERS
  " 2>/dev/null) || rc=$?

  # OpenSSH's own connect/auth failure is 255; the script's own `cd' guard
  # exits 90 for a wrong/missing deploy dir. Both mean \"couldn't check\",
  # not \"nothing drifted\" — surfacing a distinct error instead of the
  # previous silent `|| true` (which made an unreachable host read as
  # clean, the same class of bug as #235) (strut#382).
  if [ "$rc" -eq 255 ] || [ "$rc" -eq 90 ]; then
    error "Could not reach $vps_host to check image digests (SSH connection or deploy dir failure)"
    return 2
  fi

  _drift_images_render "$stack" "$output" "$json_flag"
}

# _drift_images_detect <stack> <json_flag> <project_name>
#
# Local image drift detection against the local Docker daemon.
_drift_images_detect() {
  local stack="$1"
  local json_flag="$2"
  local project_name="$3"
  local cli_root="${CLI_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local compose_file="$cli_root/stacks/$stack/docker-compose.yml"

  [ -f "$compose_file" ] || { warn "No compose file for stack: $stack"; return 0; }

  local containers
  containers=$(docker compose -f "$compose_file" --project-name "$project_name" ps -q 2>/dev/null) || true
  [ -n "$containers" ] || { log "No running containers for $stack"; return 0; }

  local output=""
  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    local info
    info=$(docker inspect --format '{{.Config.Image}}|{{index .RepoDigests 0}}' "$cid" 2>/dev/null) || {
      output="${output}UNKNOWN|$cid
"
      continue
    }
    local image_ref="${info%%|*}"
    local repo_digest="${info#*|}"

    # Digest-pinned refs are already locked.
    if [[ "$image_ref" == *@sha256:* ]]; then
      output="${output}OK|$image_ref
"
      continue
    fi

    # No RepoDigest — can't compare (locally-built image, or the Go
    # template's index-out-of-range left the literal template text).
    if [ -z "$repo_digest" ] || [[ "$repo_digest" == *'{{'* ]]; then
      output="${output}UNKNOWN|$image_ref
"
      continue
    fi
    local running_digest="${repo_digest#*@}"

    local manifest_raw
    manifest_raw=$(docker manifest inspect "$image_ref" 2>/dev/null || echo "")

    if [ -z "$manifest_raw" ]; then
      output="${output}UNKNOWN|$image_ref
"
    elif echo "$manifest_raw" | grep -q '"manifests"'; then
      # Multi-arch manifest list — see drift_images_remote for the full
      # rationale. Only buildx can portably resolve the list digest.
      local list_digest=""
      if docker buildx version >/dev/null 2>&1; then
        list_digest=$(docker buildx imagetools inspect "$image_ref" 2>/dev/null | grep -m1 '^Digest:' | awk '{print $2}')
      fi
      if [ -n "$list_digest" ]; then
        if [ "$running_digest" = "$list_digest" ]; then
          output="${output}OK|$image_ref
"
        else
          output="${output}DRIFT|$image_ref|${running_digest:0:19}|${list_digest:0:19}
"
        fi
      else
        output="${output}UNKNOWN|$image_ref
"
      fi
    else
      local registry_digest
      registry_digest=$(echo "$manifest_raw" | grep -m1 '"digest"' | sed 's/.*"digest": *"//;s/".*//')
      if [ -z "$registry_digest" ]; then
        output="${output}UNKNOWN|$image_ref
"
      elif [ "$running_digest" = "sha256:$registry_digest" ] || [ "$running_digest" = "$registry_digest" ]; then
        output="${output}OK|$image_ref
"
      else
        output="${output}DRIFT|$image_ref|${running_digest:0:19}|${registry_digest:0:19}
"
      fi
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
  local unknown=0
  local total=0
  local json_items=()

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    total=$((total + 1))
    local status="${line%%|*}"
    local rest="${line#*|}"

    case "$status" in
      DRIFT)
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
        ;;
      UNKNOWN)
        unknown=$((unknown + 1))
        local image="${rest%%|*}"
        if [ "$json_flag" = "true" ]; then
          json_items+=("{\"image\":\"$image\",\"status\":\"unknown\"}")
        else
          echo -e "  ${YELLOW}?${NC} $image — could not determine registry digest"
        fi
        ;;
      *)
        local image="${rest%%|*}"
        if [ "$json_flag" = "true" ]; then
          json_items+=("{\"image\":\"$image\",\"status\":\"current\"}")
        fi
        ;;
    esac
  done <<< "$output"

  if [ "$json_flag" = "true" ]; then
    local joined=""
    if [ ${#json_items[@]} -gt 0 ]; then
      joined=$(printf '%s,' "${json_items[@]}")
      joined="${joined%,}"
    fi
    echo "{\"stack\":\"$stack\",\"total\":$total,\"drifted\":$drifted,\"unknown\":$unknown,\"images\":[$joined]}"
  else
    if [ "$total" -eq 0 ]; then
      log "No running images to check for $stack"
    elif [ "$drifted" -eq 0 ] && [ "$unknown" -eq 0 ]; then
      ok "$stack: all $total images current"
    elif [ "$drifted" -eq 0 ]; then
      log "$stack: $unknown/$total image digest(s) could not be checked"
    else
      warn "$stack: $drifted/$total images have stale digests${unknown:+ ($unknown unchecked)}"
    fi
  fi

  [ "$drifted" -eq 0 ]
}
