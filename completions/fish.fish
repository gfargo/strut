# fish completion for strut
# =========================
# Install: `strut completions fish > ~/.config/fish/completions/strut.fish`

function __strut_project_root
    set -l dir $PWD
    while test "$dir" != /
        if test -f "$dir/strut.conf"
            echo $dir
            return 0
        end
        set dir (dirname $dir)
    end
    return 1
end

function __strut_stacks
    set -l root (__strut_project_root); or return 0
    test -d "$root/stacks"; or return 0
    for d in "$root/stacks"/*/
        set -l name (basename $d)
        test "$name" = shared; and continue
        echo $name
    end
end

function __strut_envs
    set -l root (__strut_project_root); or return 0
    for f in "$root"/.*.env "$root"/.env
        test -f "$f"; or continue
        set -l name (basename $f)
        switch $name
            case .env
                echo prod
            case '.*.env'
                set name (string replace -r '^\.' '' $name)
                set name (string replace -r '\.env$' '' $name)
                echo $name
        end
    end
end

function __strut_groups
    set -l root (__strut_project_root); or return 0
    test -f "$root/groups.conf"; or return 0
    awk -F'=' '/^[a-zA-Z_][a-zA-Z0-9_-]*=/{print $1}' "$root/groups.conf" 2>/dev/null
end

# Position helpers — fish gives us the whole tokenized command
function __strut_at_pos
    set -l tokens (commandline -opc)
    test (count $tokens) -eq $argv[1]
end

function __strut_tok
    set -l tokens (commandline -opc)
    if test (count $tokens) -ge $argv[1]
        echo $tokens[$argv[1]]
    end
end

set -l top_cmds init list scaffold upgrade doctor status-all posture group monitoring audit audit:list audit:generate migrate migrate:status notify skills help completions
set -l per_stack_cmds update release deploy stop diff lock health logs logs:download logs:rotate migrate backup restore db:pull db:push db:schema shell exec status volumes prune local prod staging dev debug keys validate rollback domain

# Disable file completion by default; re-enable where relevant
complete -c strut -f

# Top-level: stacks + commands (position 1)
complete -c strut -n '__strut_at_pos 1' -a '(__strut_stacks)' -d 'stack'
complete -c strut -n '__strut_at_pos 1' -a "$top_cmds" -d 'command'

# Flag-value completions — position-independent
complete -c strut -l env -x -a '(__strut_envs)' -d 'environment'
complete -c strut -l services -x -a 'messaging ui full gdrive' -d 'service profile'
complete -c strut -l registry -x -a 'ghcr dockerhub ecr none' -d 'registry type'
complete -c strut -l json -d 'JSON output'
complete -c strut -l dry-run -d 'preview without executing'
complete -c strut -l help -s h -d 'show help'

# completions <shell>
complete -c strut -n '__strut_tok 2 = completions' -a 'bash zsh fish'

# list subcommand
complete -c strut -n '__strut_tok 2 = list; and __strut_at_pos 2' -a 'plugins' -d 'list plugins'

# group subcommand
complete -c strut -n '__strut_tok 2 = group; and __strut_at_pos 2' -a 'list show add remove (__strut_groups)'

# monitoring subcommand
complete -c strut -n '__strut_tok 2 = monitoring; and __strut_at_pos 2' -a 'deploy add-target remove-target alert-channel status'

# notify subcommand
complete -c strut -n '__strut_tok 2 = notify; and __strut_at_pos 2' -a 'test'
complete -c strut -n '__strut_tok 2 = notify; and __strut_tok 3 = test; and __strut_at_pos 3' -a 'slack discord webhook'

# skills subcommand
complete -c strut -n '__strut_tok 2 = skills; and __strut_at_pos 2' -a 'list install'

# help <cmd>
complete -c strut -n '__strut_tok 2 = help; and __strut_at_pos 2' -a "$top_cmds $per_stack_cmds"

# Per-stack: position 2 after a stack name
complete -c strut -n 'contains -- (__strut_tok 2) (__strut_stacks); and __strut_at_pos 2' -a "$per_stack_cmds"

# Per-stack subcommand completions (position 3)
complete -c strut -n 'contains -- (__strut_tok 2) (__strut_stacks); and __strut_tok 3 = backup; and __strut_at_pos 3' \
    -a 'postgres neo4j mysql sqlite gdrive-transcripts all verify list health schedule retention'
complete -c strut -n 'contains -- (__strut_tok 2) (__strut_stacks); and __strut_tok 3 = drift; and __strut_at_pos 3' \
    -a 'detect report fix monitor history auto-fix'
complete -c strut -n 'contains -- (__strut_tok 2) (__strut_stacks); and contains -- (__strut_tok 3) db:pull db:push; and __strut_at_pos 3' \
    -a 'postgres neo4j mysql sqlite all'
complete -c strut -n 'contains -- (__strut_tok 2) (__strut_stacks); and __strut_tok 3 = db:schema; and __strut_at_pos 3' \
    -a 'apply verify all'
complete -c strut -n 'contains -- (__strut_tok 2) (__strut_stacks); and __strut_tok 3 = volumes; and __strut_at_pos 3' \
    -a 'status init config'
complete -c strut -n 'contains -- (__strut_tok 2) (__strut_stacks); and __strut_tok 3 = lock; and __strut_at_pos 3' \
    -a 'status release'
complete -c strut -n 'contains -- (__strut_tok 2) (__strut_stacks); and contains -- (__strut_tok 3) local prod staging dev; and __strut_at_pos 3' \
    -a 'start stop reset sync-env sync-db logs test debug'
complete -c strut -n 'contains -- (__strut_tok 2) (__strut_stacks); and __strut_tok 3 = debug; and __strut_at_pos 3' \
    -a 'exec shell port-forward copy snapshot inspect-env stats'
complete -c strut -n 'contains -- (__strut_tok 2) (__strut_stacks); and __strut_tok 3 = keys; and __strut_at_pos 3' \
    -a 'rotate status check env ssh github'
complete -c strut -n 'contains -- (__strut_tok 2) (__strut_stacks); and __strut_tok 3 = migrate; and __strut_at_pos 3' \
    -a 'neo4j postgres'
