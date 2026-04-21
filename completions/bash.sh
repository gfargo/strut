# bash completion for strut
# ===========================
# Source: `eval "$(strut completions bash)"` in your .bashrc.
#
# Completes:
#   - stack names (from $PROJECT_ROOT/stacks/*/)
#   - top-level commands + per-stack commands + their subcommands
#   - environment names (from .*env files at PROJECT_ROOT)
#   - service profiles for --services
#   - known flags per command

_strut_find_project_root() {
  local dir="$PWD"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/strut.conf" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir=$(dirname "$dir")
  done
  return 1
}

_strut_stacks() {
  local root
  root=$(_strut_find_project_root) || return 0
  [ -d "$root/stacks" ] || return 0
  local d
  for d in "$root/stacks"/*/; do
    [ -d "$d" ] || continue
    local name
    name=$(basename "$d")
    [ "$name" = "shared" ] && continue
    printf '%s\n' "$name"
  done
}

_strut_envs() {
  local root
  root=$(_strut_find_project_root) || return 0
  local f name
  for f in "$root"/.*.env "$root"/.env; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    # Strip leading dot and trailing .env; map .env itself to "prod"
    case "$name" in
      .env) printf '%s\n' "prod" ;;
      .*.env)
        name=${name#.}
        name=${name%.env}
        printf '%s\n' "$name"
        ;;
    esac
  done
}

_strut_groups() {
  local root
  root=$(_strut_find_project_root) || return 0
  [ -f "$root/groups.conf" ] || return 0
  awk -F'=' '/^[a-zA-Z_][a-zA-Z0-9_-]*=/{print $1}' "$root/groups.conf" 2>/dev/null
}

_strut_completions() {
  local cur prev words cword
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  cword=$COMP_CWORD

  local top_cmds="init list scaffold upgrade doctor status-all posture group monitoring audit audit:list audit:generate migrate migrate:status notify skills help completions --version -v --help -h"
  local per_stack_cmds="update release deploy stop diff lock health logs logs:download logs:rotate migrate backup restore db:pull db:push db:schema shell exec status volumes prune local prod staging dev debug keys validate rollback domain --help"
  local profiles="messaging ui full gdrive"

  # Flag-value completions — operate on prev regardless of position
  case "$prev" in
    --env)
      local envs
      envs=$(_strut_envs)
      mapfile -t COMPREPLY < <(compgen -W "$envs" -- "$cur")
      return 0
      ;;
    --services)
      mapfile -t COMPREPLY < <(compgen -W "$profiles" -- "$cur")
      return 0
      ;;
    --registry)
      mapfile -t COMPREPLY < <(compgen -W "ghcr dockerhub ecr none" -- "$cur")
      return 0
      ;;
    completions)
      mapfile -t COMPREPLY < <(compgen -W "bash zsh fish" -- "$cur")
      return 0
      ;;
  esac

  if [ "$cword" -eq 1 ]; then
    local stacks
    stacks=$(_strut_stacks)
    mapfile -t COMPREPLY < <(compgen -W "$top_cmds $stacks" -- "$cur")
    return 0
  fi

  local root_word="${COMP_WORDS[1]}"

  # Top-level dispatchers that take subcommands
  case "$root_word" in
    list)
      [ "$cword" -eq 2 ] && mapfile -t COMPREPLY < <(compgen -W "plugins --json" -- "$cur") && return 0
      ;;
    group)
      [ "$cword" -eq 2 ] && mapfile -t COMPREPLY < <(compgen -W "list show add remove $(_strut_groups)" -- "$cur") && return 0
      ;;
    monitoring)
      [ "$cword" -eq 2 ] && mapfile -t COMPREPLY < <(compgen -W "deploy add-target remove-target alert-channel status" -- "$cur") && return 0
      ;;
    notify)
      [ "$cword" -eq 2 ] && mapfile -t COMPREPLY < <(compgen -W "test" -- "$cur") && return 0
      [ "$cword" -eq 3 ] && mapfile -t COMPREPLY < <(compgen -W "slack discord webhook" -- "$cur") && return 0
      ;;
    skills)
      [ "$cword" -eq 2 ] && mapfile -t COMPREPLY < <(compgen -W "list install --format" -- "$cur") && return 0
      ;;
    help)
      [ "$cword" -eq 2 ] && mapfile -t COMPREPLY < <(compgen -W "$top_cmds $per_stack_cmds" -- "$cur") && return 0
      ;;
    init)
      mapfile -t COMPREPLY < <(compgen -W "--registry --org --completions" -- "$cur")
      return 0
      ;;
    doctor)
      mapfile -t COMPREPLY < <(compgen -W "--check-vps --json --fix" -- "$cur")
      return 0
      ;;
  esac

  # Stack-level: strut <stack> <cmd> ...
  if [ "$cword" -eq 2 ]; then
    mapfile -t COMPREPLY < <(compgen -W "$per_stack_cmds" -- "$cur")
    return 0
  fi

  # Per-command subcommands + flags
  local cmd="${COMP_WORDS[2]}"
  case "$cmd" in
    backup)
      [ "$cword" -eq 3 ] && mapfile -t COMPREPLY < <(compgen -W "postgres neo4j mysql sqlite gdrive-transcripts all verify list health schedule retention" -- "$cur") && return 0
      ;;
    drift)
      [ "$cword" -eq 3 ] && mapfile -t COMPREPLY < <(compgen -W "detect report fix monitor history auto-fix" -- "$cur") && return 0
      ;;
    db:pull|db:push)
      [ "$cword" -eq 3 ] && mapfile -t COMPREPLY < <(compgen -W "postgres neo4j mysql sqlite all --download-only --upload-only --file" -- "$cur") && return 0
      ;;
    db:schema)
      [ "$cword" -eq 3 ] && mapfile -t COMPREPLY < <(compgen -W "apply verify all" -- "$cur") && return 0
      ;;
    volumes)
      [ "$cword" -eq 3 ] && mapfile -t COMPREPLY < <(compgen -W "status init config" -- "$cur") && return 0
      ;;
    lock)
      [ "$cword" -eq 3 ] && mapfile -t COMPREPLY < <(compgen -W "status release --force --remote --local" -- "$cur") && return 0
      ;;
    local|prod|staging|dev)
      [ "$cword" -eq 3 ] && mapfile -t COMPREPLY < <(compgen -W "start stop reset sync-env sync-db logs test debug" -- "$cur") && return 0
      ;;
    debug)
      [ "$cword" -eq 3 ] && mapfile -t COMPREPLY < <(compgen -W "exec shell port-forward copy snapshot inspect-env stats" -- "$cur") && return 0
      ;;
    keys)
      [ "$cword" -eq 3 ] && mapfile -t COMPREPLY < <(compgen -W "rotate status check env ssh github" -- "$cur") && return 0
      ;;
    migrate)
      [ "$cword" -eq 3 ] && mapfile -t COMPREPLY < <(compgen -W "neo4j postgres --status --up --down" -- "$cur") && return 0
      ;;
    deploy)
      mapfile -t COMPREPLY < <(compgen -W "--env --services --pull-only --skip-validation --force-unlock --no-lock --dry-run" -- "$cur")
      return 0
      ;;
    health)
      mapfile -t COMPREPLY < <(compgen -W "--env --services --json" -- "$cur")
      return 0
      ;;
    diff)
      mapfile -t COMPREPLY < <(compgen -W "--env --json" -- "$cur")
      return 0
      ;;
  esac

  # Fallback: common global flags
  mapfile -t COMPREPLY < <(compgen -W "--env --services --json --dry-run --help" -- "$cur")
  return 0
}

complete -F _strut_completions strut
