_keenetic_policy() {
    local current previous options
    current=${COMP_WORDS[COMP_CWORD]}
    previous=${COMP_WORDS[COMP_CWORD - 1]}
    options='--interactive --client --ip --mac --policy --block --unblock --wake --undo --dry-run --all --offline --router --discover --json --quiet --verbose --init --ca-file --insecure --color --no-color --version --help'

    case $previous in
        --ca-file)
            mapfile -t COMPREPLY < <(compgen -f -- "$current")
            ;;
        --color)
            mapfile -t COMPREPLY < <(compgen -W 'auto always never' -- "$current")
            ;;
        --client|--ip|--mac|--policy|--router)
            COMPREPLY=()
            ;;
        *)
            mapfile -t COMPREPLY < <(compgen -W "$options" -- "$current")
            ;;
    esac
}

complete -F _keenetic_policy keenetic-policy keenetic-policy.sh
