_keenetic() {
    local current previous options global_options scope=root word index setup=false
    current=${COMP_WORDS[COMP_CWORD]}
    previous=${COMP_WORDS[COMP_CWORD - 1]}
    global_options='--router --ca-file --insecure --quiet --verbose --color --no-color --help --version'
    COMPREPLY=()

    # Skip option values so a router or client named "policy" or "wake" is not
    # mistaken for a subcommand. Stop completing flags after the -- separator.
    for ((index = 1; index < COMP_CWORD; index++)); do
        word=${COMP_WORDS[index]}
        case $word in
            --) return 0 ;;
            --router|--ca-file|--client|--ip|--mac|--policy|--top|--period|--watch|--interface|--limit|--filter|--server|--port|--duration|--sample|--radio)
                if ((index + 1 == COMP_CWORD)); then
                    if [[ $word == --ca-file ]]; then
                        mapfile -t COMPREPLY < <(compgen -f -- "$current")
                    elif [[ $word == --period && $scope == traffic ]]; then
                        mapfile -t COMPREPLY < <(compgen -W '3m 1h 3h 1d' -- "$current")
                    fi
                    return 0
                fi
                index=$((index + 1))
                ;;
            --init|--discover) setup=true ;;
            reboot|save)
                [[ $scope != root ]] || return 0
                [[ $scope != system ]] || scope=system_action
                ;;
            scan) [[ $scope != wifi ]] || scope=wifi_scan ;;
            inspect) [[ $scope != interfaces ]] || scope=interface_inspect ;;
            rename) [[ $scope != clients ]] || scope=clients_rename ;;
            clients)
                if [[ $scope == root ]]; then scope=clients; elif [[ $scope == wifi ]]; then scope=wifi_clients; fi ;;
            policy|wake|interfaces|traffic|wifi|system|vpn|diagnose|logs|wan|dhcp|routes|mesh|speedtest|connections|forwards)
                [[ $scope != root ]] || scope=$word
                ;;
            -*) ;;
            *) [[ $scope != root ]] || return 0 ;;
        esac
    done

    case $scope in
        root)
            options="--init --discover $global_options"
            $setup || options="policy wake interfaces traffic wifi clients system vpn diagnose logs wan dhcp routes mesh speedtest connections forwards --watch --all --json $options"
            ;;
        policy)
            options="inspect --watch --interactive --client --ip --mac --policy --block --unblock --undo --dry-run --all --offline --json $global_options"
            ;;
        interfaces)
            options="inspect --rates --sample --watch --interactive --dry-run --all --json $global_options"
            ;;
        traffic)
            options="--watch --top --period --json $global_options"
            ;;
        wifi)
            options="monitor clients scan --watch --all --json $global_options"
            ;;
        clients) options="inspect rename --watch --all --offline --json $global_options" ;;
        system) options="reboot changes save --watch --json $global_options" ;;
        system_action) options="--dry-run $global_options" ;;
        wan|dhcp|routes|mesh|forwards|interface_inspect|wifi_clients) options="--watch --json $global_options" ;;
        wifi_scan) options="--radio --all --json $global_options" ;;
        clients_rename) options="--dry-run $global_options" ;;
        connections) options="--client --watch --json $global_options" ;;
        speedtest) options="--server --port --duration --reverse --interface --json --dry-run $global_options" ;;
        vpn) options="peers --watch --json $global_options" ;;
        diagnose) options="--interface --json $global_options" ;;
        logs) options="--limit --filter --watch --json $global_options" ;;
        wake)
            options="--client --ip --mac --dry-run $global_options"
            ;;
    esac
    if [[ $scope == traffic && $current == --period=* ]]; then
        mapfile -t COMPREPLY < <(compgen -W '--period=3m --period=1h --period=3h --period=1d' -- "$current")
    elif [[ $previous == --color ]]; then
        mapfile -t COMPREPLY < <(compgen -W 'auto always never' -- "$current")
    else
        mapfile -t COMPREPLY < <(compgen -W "$options" -- "$current")
    fi
}

complete -F _keenetic keenetic
