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
            load|monitor) [[ $scope != wifi ]] || scope=wifi_monitor ;;
            inspect|show)
                case $scope in interfaces|clients|policy) scope=interface_inspect ;; system) scope=view ;; esac ;;
            rename) [[ $scope != clients ]] || scope=clients_rename ;;
            list)
                case $scope in policy) scope=view ;; esac ;;
            rates) [[ $scope != interfaces ]] || scope=interface_rates ;;
            up|down) [[ $scope != interfaces ]] || scope=action ;;
            assign|set|block|unblock)
                case $scope in clients|policy) scope=action ;; esac ;;
            undo) [[ $scope != policy ]] || scope=policy_undo ;;
            wake)
                if [[ $scope == root || $scope == clients ]]; then scope=wake; fi ;;
            nat|connections)
                if [[ $scope == root || $scope == clients ]]; then scope=connections; fi ;;
            init) [[ $scope != config ]] || scope=config_init ;;
            discover) [[ $scope != config ]] || return 0 ;;
            client|clients)
                if [[ $scope == root ]]; then scope=clients; elif [[ $scope == wifi ]]; then scope=wifi_clients; fi ;;
            interface|interfaces) [[ $scope != root ]] || scope=interfaces ;;
            policies) [[ $scope != root ]] || scope=policy ;;
            log) [[ $scope != root ]] || scope=logs ;;
            status) [[ $scope != root ]] || scope=view ;;
            config) [[ $scope != root ]] || scope=config ;;
            policy|traffic|wifi|system|vpn|diagnose|logs|wan|dhcp|routes|mesh|speedtest|forwards)
                [[ $scope != root ]] || scope=$word
                ;;
            -*) ;;
            *) [[ $scope != root ]] || return 0 ;;
        esac
    done

    case $scope in
        root)
            options="--init --discover $global_options"
            $setup || options="status client policy interface wifi vpn traffic wan dhcp routes mesh nat forwards system logs diagnose speedtest config --interactive --watch --all --json $options"
            ;;
        policy)
            options="list show assign block unblock undo --watch --interactive --client --ip --mac --policy --block --unblock --undo --dry-run --all --offline --json $global_options"
            ;;
        policy_undo) options="--interactive --dry-run $global_options" ;;
        interfaces)
            options="list show rates up down --sample --watch --interactive --dry-run --all --json $global_options"
            ;;
        interface_rates) options="--sample --watch --all --json $global_options" ;;
        action) options="--interactive --dry-run $global_options" ;;
        view) options="--watch --json $global_options" ;;
        config) options="init discover $global_options" ;;
        config_init) options="--router --ca-file --insecure $global_options" ;;
        traffic)
            options="--watch --top --period --json $global_options"
            ;;
        wifi)
            options="list clients scan load --watch --all --json $global_options"
            ;;
        wifi_monitor) options="--watch --all --json $global_options" ;;
        clients) options="list show rename wake block unblock assign nat --interactive --watch --all --offline --json $global_options" ;;
        system) options="show reboot changes save --watch --json $global_options" ;;
        system_action) options="--dry-run --yes $global_options" ;;
        wan|dhcp|routes|mesh|forwards|interface_inspect|wifi_clients) options="--watch --json $global_options" ;;
        wifi_scan) options="--radio --interactive --all --json $global_options" ;;
        clients_rename) options="--dry-run $global_options" ;;
        connections) options="--client --interactive --watch --json $global_options" ;;
        speedtest) options="--server --port --duration --reverse --interface --interactive --json --dry-run $global_options" ;;
        vpn) options="peers --watch --json $global_options" ;;
        diagnose) options="--interface --interactive --json $global_options" ;;
        logs) options="--limit --filter --interactive --watch --json $global_options" ;;
        wake)
            options="--client --ip --mac --interactive --dry-run $global_options"
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
