#compdef strut
# zsh completion for strut
# ========================
# Source: `eval "$(strut completions zsh)"` in your .zshrc, or save to
# a file on $fpath named `_strut`.

_strut_find_project_root() {
  local dir="$PWD"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/strut.conf" ]; then
      print -- "$dir"
      return 0
    fi
    dir=${dir:h}
  done
  return 1
}

_strut_stacks() {
  local root stack
  root=$(_strut_find_project_root) || return 0
  [ -d "$root/stacks" ] || return 0
  for stack in "$root"/stacks/*(/N); do
    local name=${stack:t}
    [ "$name" = shared ] && continue
    print -- "$name"
  done
}

_strut_envs() {
  local root f name
  root=$(_strut_find_project_root) || return 0
  for f in "$root"/.*.env(N) "$root"/.env(N); do
    name=${f:t}
    case "$name" in
      .env)   print -- prod ;;
      .*.env) name=${name#.}; name=${name%.env}; print -- "$name" ;;
    esac
  done
}

_strut_groups() {
  local root
  root=$(_strut_find_project_root) || return 0
  [ -f "$root/groups.conf" ] || return 0
  awk -F'=' '/^[a-zA-Z_][a-zA-Z0-9_-]*=/{print $1}' "$root/groups.conf" 2>/dev/null
}

_strut() {
  local -a top_cmds per_stack_cmds profiles
  top_cmds=(init list scaffold upgrade doctor status-all posture group monitoring audit audit:list audit:generate migrate migrate:status notify skills help completions --version --help)
  per_stack_cmds=(update release deploy stop diff lock health logs logs:download logs:rotate migrate backup restore db:pull db:push db:schema shell exec status volumes prune local prod staging dev debug keys validate rollback domain --help)
  profiles=(messaging ui full gdrive)

  local -a words_arr
  words_arr=("${(@)words}")
  local n=$#words_arr
  local pos=$CURRENT

  # Flag-value completions — look at previous word
  local prev="${words_arr[pos-1]:-}"
  case "$prev" in
    --env)
      local -a envs
      envs=("${(@f)$(_strut_envs)}")
      compadd -a envs
      return 0
      ;;
    --services)
      compadd -a profiles
      return 0
      ;;
    --registry)
      compadd ghcr dockerhub ecr none
      return 0
      ;;
    completions)
      compadd bash zsh fish
      return 0
      ;;
  esac

  if [ "$pos" -eq 2 ]; then
    local -a stacks
    stacks=("${(@f)$(_strut_stacks)}")
    compadd -a stacks
    compadd -a top_cmds
    return 0
  fi

  local root_word="${words_arr[2]:-}"

  case "$root_word" in
    list)
      [ "$pos" -eq 3 ] && { compadd plugins --json; return 0 }
      ;;
    group)
      [ "$pos" -eq 3 ] && { local -a groups; groups=("${(@f)$(_strut_groups)}"); compadd list show add remove; compadd -a groups; return 0 }
      ;;
    monitoring)
      [ "$pos" -eq 3 ] && { compadd deploy add-target remove-target alert-channel status; return 0 }
      ;;
    notify)
      [ "$pos" -eq 3 ] && { compadd test; return 0 }
      [ "$pos" -eq 4 ] && { compadd slack discord webhook; return 0 }
      ;;
    skills)
      [ "$pos" -eq 3 ] && { compadd list install --format; return 0 }
      ;;
    help)
      [ "$pos" -eq 3 ] && { compadd -a top_cmds; compadd -a per_stack_cmds; return 0 }
      ;;
    init)
      compadd --registry --org --completions
      return 0
      ;;
    doctor)
      compadd --check-vps --json --fix
      return 0
      ;;
  esac

  # Stack-level: strut <stack> <cmd>
  if [ "$pos" -eq 3 ]; then
    compadd -a per_stack_cmds
    return 0
  fi

  local cmd="${words_arr[3]:-}"
  case "$cmd" in
    backup)
      [ "$pos" -eq 4 ] && { compadd postgres neo4j mysql sqlite gdrive-transcripts all verify list health schedule retention; return 0 }
      ;;
    drift)
      [ "$pos" -eq 4 ] && { compadd detect report fix monitor history auto-fix; return 0 }
      ;;
    db:pull|db:push)
      [ "$pos" -eq 4 ] && { compadd postgres neo4j mysql sqlite all --download-only --upload-only --file; return 0 }
      ;;
    db:schema)
      [ "$pos" -eq 4 ] && { compadd apply verify all; return 0 }
      ;;
    volumes)
      [ "$pos" -eq 4 ] && { compadd status init config; return 0 }
      ;;
    lock)
      [ "$pos" -eq 4 ] && { compadd status release --force --remote --local; return 0 }
      ;;
    local|prod|staging|dev)
      [ "$pos" -eq 4 ] && { compadd start stop reset sync-env sync-db logs test debug; return 0 }
      ;;
    debug)
      [ "$pos" -eq 4 ] && { compadd exec shell port-forward copy snapshot inspect-env stats; return 0 }
      ;;
    keys)
      [ "$pos" -eq 4 ] && { compadd rotate status check env ssh github; return 0 }
      ;;
    migrate)
      [ "$pos" -eq 4 ] && { compadd neo4j postgres --status --up --down; return 0 }
      ;;
    deploy)
      compadd --env --services --pull-only --skip-validation --force-unlock --no-lock --dry-run
      return 0
      ;;
    health)
      compadd --env --services --json
      return 0
      ;;
    diff)
      compadd --env --json
      return 0
      ;;
  esac

  compadd --env --services --json --dry-run --help
}

compdef _strut strut
