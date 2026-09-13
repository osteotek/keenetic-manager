#!/usr/bin/env bash

set -Eeuo pipefail

PROGRAM=${0##*/}
VERSION=1.0.0
EXIT_GENERAL=1
EXIT_USAGE=2
EXIT_CLIENT=3
EXIT_POLICY=4
EXIT_VERIFY=5
CONFIG_FILE=${KEENETIC_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/keenetic-policy/config}
ROUTER_URL=
ROUTER_USERNAME=
ROUTER_PASSWORD=
ROUTER_PASSWORD_COMMAND=
ROUTER_CA_FILE=
ROUTER_INSECURE=false
CLI_CA_FILE=
CLI_INSECURE=false
HTTP_STATUS=
ROUTER_LOCAL_IP=
CURRENT_CLIENT_MAC=
TMP_DIR=
CLIENT_SELECTOR=
CLIENT_VALUE=
POLICY_QUERY=
INTERACTIVE=false
JSON_OUTPUT=false
INIT_CONFIG=false
QUIET=false
COLOR_MODE=auto
SELECTED_CLIENT=
SELECTED_POLICY_ID=
SELECTED_POLICY_LABEL=
SELECTED_INDEX=0
MENU_CURRENT_INDEX=-1
CURSOR_HIDDEN=false
RED=
GREEN=
YELLOW=
DIM=
HIGHLIGHT=
RESET=
CLIENT_NAME_WIDTH=28
CLIENT_IP_WIDTH=15
CLIENT_POLICY_WIDTH=18
declare -a MENU_OPTIONS=()
declare -a POLICY_IDS=()
declare -a POLICY_LABELS=()

usage() {
    cat <<EOF
Usage:
  $PROGRAM                              List connected clients
  $PROGRAM --json                       List connected clients as JSON
  $PROGRAM --interactive                Select client and policy interactively
  $PROGRAM CLIENT_NAME                  Select a policy for a named client
  $PROGRAM --client NAME --policy POLICY
  $PROGRAM --ip ADDRESS --policy POLICY
  $PROGRAM --mac ADDRESS --policy POLICY
                                        Apply a policy non-interactively
  $PROGRAM --init                       Create and test the configuration

Options:
  -i, --interactive                     Select both client and policy
      --client NAME                     Select by exact client name
      --ip ADDRESS                      Select by exact client IP address
      --mac ADDRESS                     Select by exact client MAC address
      --policy POLICY                   Policy ID, description, or "Default"
      --json                            Emit the client list as JSON
  -q, --quiet                           Suppress successful mutation output
      --init                            Configure router credentials securely
      --ca-file FILE                    Trust this CA certificate for HTTPS
      --insecure                        Disable HTTPS certificate verification
      --color[=WHEN]                    Colors: auto, always, or never
      --no-color                        Disable colors
  -V, --version                         Show version
  -h, --help                            Show this help

Interactive controls: Up/Down arrows move, Enter selects, Esc or q cancels.

Configuration: $CONFIG_FILE
Override it with the KEENETIC_CONFIG environment variable.
EOF
}

fail() {
    local status=$EXIT_GENERAL
    if [[ ${1-} =~ ^[1-9][0-9]*$ ]]; then
        status=$1
        shift
    fi
    printf '%sError:%s %s\n' "$RED" "$RESET" "$*" >&2
    exit "$status"
}

warn() {
    printf '%sWarning:%s %s\n' "$YELLOW" "$RESET" "$*" >&2
}

success() {
    $QUIET || printf '%s%s%s\n' "$GREEN" "$*" "$RESET"
}

unchanged() {
    $QUIET || printf '%s%s%s\n' "$YELLOW" "$*" "$RESET"
}

info() {
    $QUIET || printf '%s\n' "$*"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

set_client_selector() {
    local selector=$1 value=$2
    [[ -z $CLIENT_SELECTOR ]] || fail "$EXIT_USAGE" 'use only one of CLIENT_NAME, --client, --ip, or --mac'
    [[ -n $value ]] || fail "$EXIT_USAGE" "--$selector requires a non-empty value"
    CLIENT_SELECTOR=$selector
    CLIENT_VALUE=$value
}

parse_args() {
    local -a positional=()
    while (($#)); do
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            -V|--version)
                printf '%s %s\n' "$PROGRAM" "$VERSION"
                exit 0
                ;;
            -i|--interactive)
                INTERACTIVE=true
                ;;
            --client)
                (($# >= 2)) || fail "$EXIT_USAGE" '--client requires a name'
                set_client_selector client "$2"
                shift
                ;;
            --client=*)
                set_client_selector client "${1#*=}"
                ;;
            --ip)
                (($# >= 2)) || fail "$EXIT_USAGE" '--ip requires an address'
                set_client_selector ip "$2"
                shift
                ;;
            --ip=*)
                set_client_selector ip "${1#*=}"
                ;;
            --mac)
                (($# >= 2)) || fail "$EXIT_USAGE" '--mac requires an address'
                set_client_selector mac "$2"
                shift
                ;;
            --mac=*)
                set_client_selector mac "${1#*=}"
                ;;
            --policy)
                (($# >= 2)) || fail "$EXIT_USAGE" '--policy requires a policy ID or description'
                [[ -n $2 ]] || fail "$EXIT_USAGE" '--policy requires a non-empty policy ID or description'
                POLICY_QUERY=$2
                shift
                ;;
            --policy=*)
                POLICY_QUERY=${1#*=}
                [[ -n $POLICY_QUERY ]] || fail "$EXIT_USAGE" '--policy requires a non-empty policy ID or description'
                ;;
            --json)
                JSON_OUTPUT=true
                ;;
            -q|--quiet)
                QUIET=true
                ;;
            --init)
                INIT_CONFIG=true
                ;;
            --ca-file)
                (($# >= 2)) || fail "$EXIT_USAGE" '--ca-file requires a path'
                [[ -n $2 ]] || fail "$EXIT_USAGE" '--ca-file requires a non-empty path'
                CLI_CA_FILE=$2
                shift
                ;;
            --ca-file=*)
                CLI_CA_FILE=${1#*=}
                [[ -n $CLI_CA_FILE ]] || fail "$EXIT_USAGE" '--ca-file requires a non-empty path'
                ;;
            --insecure)
                CLI_INSECURE=true
                ;;
            --color)
                COLOR_MODE=always
                ;;
            --color=auto|--color=always|--color=never)
                COLOR_MODE=${1#*=}
                ;;
            --color=*)
                fail "$EXIT_USAGE" '--color must be auto, always, or never'
                ;;
            --no-color)
                COLOR_MODE=never
                ;;
            --)
                shift
                while (($#)); do
                    positional+=("$1")
                    shift
                done
                break
                ;;
            -*)
                fail "$EXIT_USAGE" "unknown option: $1"
                ;;
            *)
                positional+=("$1")
                ;;
        esac
        shift
    done

    ((${#positional[@]} <= 1)) || fail "$EXIT_USAGE" 'only one client name may be provided'
    if ((${#positional[@]} == 1)); then
        set_client_selector client "${positional[0]}"
    fi
    if [[ $CLIENT_SELECTOR == mac ]]; then
        CLIENT_VALUE=${CLIENT_VALUE,,}
        [[ $CLIENT_VALUE =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] \
            || fail "$EXIT_USAGE" 'MAC address must use aa:bb:cc:dd:ee:ff format'
    fi
    if $CLI_INSECURE && [[ -n $CLI_CA_FILE ]]; then
        fail "$EXIT_USAGE" '--insecure and --ca-file cannot be combined'
    fi
    if $INIT_CONFIG && { $INTERACTIVE || $JSON_OUTPUT || [[ -n $CLIENT_SELECTOR || -n $POLICY_QUERY ]]; }; then
        fail "$EXIT_USAGE" '--init cannot be combined with a client, policy, --interactive, or --json'
    fi
    if $JSON_OUTPUT && { $INTERACTIVE || [[ -n $CLIENT_SELECTOR || -n $POLICY_QUERY ]]; }; then
        fail "$EXIT_USAGE" '--json is only valid when listing clients'
    fi
    [[ -z $POLICY_QUERY || -n $CLIENT_SELECTOR ]] \
        || fail "$EXIT_USAGE" '--policy requires --client, --ip, or --mac'
    if $INTERACTIVE && [[ -n $CLIENT_SELECTOR || -n $POLICY_QUERY ]]; then
        fail "$EXIT_USAGE" '--interactive selects the client itself; do not combine it with a client or policy'
    fi
}

init_colors() {
    local enabled=false
    if [[ $COLOR_MODE == always ]]; then
        enabled=true
    elif [[ $COLOR_MODE == auto ]] && [[ -t 1 && -t 2 ]] && [[ ! -v NO_COLOR ]] && ! $JSON_OUTPUT; then
        enabled=true
    fi

    if $enabled; then
        RED=$'\033[31m'
        GREEN=$'\033[32m'
        YELLOW=$'\033[33m'
        DIM=$'\033[2m'
        HIGHLIGHT=$'\033[7m'
        RESET=$'\033[0m'
    fi
}

trim_key() {
    local value=$1
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    printf '%s' "$value"
}

resolve_password() {
    local password
    local -a password_command
    if [[ -n $ROUTER_PASSWORD && -n $ROUTER_PASSWORD_COMMAND ]]; then
        fail "ROUTER_PASSWORD and ROUTER_PASSWORD_COMMAND cannot both be set in $CONFIG_FILE"
    fi
    if [[ -n $ROUTER_PASSWORD_COMMAND ]]; then
        read -r -a password_command <<< "$ROUTER_PASSWORD_COMMAND"
        ((${#password_command[@]} > 0)) || fail 'ROUTER_PASSWORD_COMMAND is empty'
        command -v "${password_command[0]}" >/dev/null 2>&1 \
            || fail "password command not found: ${password_command[0]}"
        if ! password=$("${password_command[@]}"); then
            fail 'ROUTER_PASSWORD_COMMAND failed'
        fi
        [[ -n $password ]] || fail 'ROUTER_PASSWORD_COMMAND returned an empty password'
        [[ $password != *$'\n'* ]] || fail 'ROUTER_PASSWORD_COMMAND returned more than one line'
        ROUTER_PASSWORD=$password
    fi
    [[ -n $ROUTER_PASSWORD ]] || fail "set ROUTER_PASSWORD or ROUTER_PASSWORD_COMMAND in $CONFIG_FILE"
}

validate_router_settings() {
    [[ -n $ROUTER_URL ]] || fail 'router URL cannot be empty'
    [[ -n $ROUTER_USERNAME ]] || fail 'router username cannot be empty'
    [[ $ROUTER_URL == http://* || $ROUTER_URL == https://* ]] \
        || fail 'router URL must start with http:// or https://'
    ROUTER_URL=${ROUTER_URL%/}
    [[ $ROUTER_INSECURE == true || $ROUTER_INSECURE == false ]] \
        || fail 'ROUTER_INSECURE must be true or false'
    if [[ -n $ROUTER_CA_FILE && $ROUTER_INSECURE == true ]]; then
        fail 'ROUTER_CA_FILE and ROUTER_INSECURE=true cannot be combined'
    fi
    if [[ -n $ROUTER_CA_FILE && ! -r $ROUTER_CA_FILE ]]; then
        fail "cannot read router CA file: $ROUTER_CA_FILE"
    fi
    resolve_password
}

load_config() {
    [[ -r $CONFIG_FILE ]] || fail "cannot read $CONFIG_FILE
Run '$PROGRAM --init' to create and test it."

    local line key value line_number=0 permissions
    while IFS= read -r line || [[ -n $line ]]; do
        ((line_number += 1))
        line=${line%$'\r'}
        [[ -z $line || $line =~ ^[[:space:]]*# ]] && continue
        [[ $line == *=* ]] || fail "$CONFIG_FILE:$line_number: expected KEY=VALUE"

        key=$(trim_key "${line%%=*}")
        value=${line#*=}
        case $key in
            ROUTER_URL) ROUTER_URL=$value ;;
            ROUTER_USERNAME) ROUTER_USERNAME=$value ;;
            ROUTER_PASSWORD) ROUTER_PASSWORD=$value ;;
            ROUTER_PASSWORD_COMMAND) ROUTER_PASSWORD_COMMAND=$value ;;
            ROUTER_CA_FILE) ROUTER_CA_FILE=$value ;;
            ROUTER_INSECURE) ROUTER_INSECURE=${value,,} ;;
            *) fail "$CONFIG_FILE:$line_number: unknown setting: $key" ;;
        esac
    done < "$CONFIG_FILE"

    [[ -n $ROUTER_URL ]] || fail "ROUTER_URL is missing from $CONFIG_FILE"
    [[ -n $ROUTER_USERNAME ]] || fail "ROUTER_USERNAME is missing from $CONFIG_FILE"
    if [[ -n $CLI_CA_FILE ]]; then
        ROUTER_CA_FILE=$CLI_CA_FILE
        ROUTER_INSECURE=false
    fi
    if $CLI_INSECURE; then
        ROUTER_CA_FILE=
        ROUTER_INSECURE=true
    fi
    validate_router_settings

    if command -v stat >/dev/null 2>&1 && permissions=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null); then
        if [[ $permissions =~ ^[0-7]+$ ]] && (((8#$permissions & 077) != 0)); then
            warn "$CONFIG_FILE is readable by other users; run: chmod 600 '$CONFIG_FILE'"
        fi
    fi
    if [[ $ROUTER_URL == http://* ]]; then
        warn 'HTTP does not protect the authenticated router session; prefer HTTPS or KeenDNS.'
    elif [[ $ROUTER_INSECURE == true ]]; then
        warn 'HTTPS certificate verification is disabled for this connection.'
    fi
}

show_cursor() {
    if $CURSOR_HIDDEN; then
        printf '\033[?25h' >&2
        CURSOR_HIDDEN=false
    fi
}

cleanup() {
    show_cursor
    [[ -z ${TMP_DIR:-} ]] || rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

create_temp_dir() {
    TMP_DIR=$(mktemp -d)
    chmod 700 "$TMP_DIR"
}

http_request() {
    local method=$1 endpoint=$2 output=$3 data=${4-} curl_status response_meta
    local -a arguments=(
        --silent
        --show-error
        --connect-timeout 5
        --max-time 20
        --cookie "$TMP_DIR/cookies"
        --cookie-jar "$TMP_DIR/cookies"
        --dump-header "$TMP_DIR/headers"
        --output "$output"
        --write-out $'%{http_code}\t%{local_ip}'
        --request "$method"
    )
    if [[ $ROUTER_INSECURE == true ]]; then
        arguments+=(--insecure)
    elif [[ -n $ROUTER_CA_FILE ]]; then
        arguments+=(--cacert "$ROUTER_CA_FILE")
    fi

    if [[ $method == POST ]]; then
        arguments+=(--header 'Content-Type: application/json' --data "$data")
    fi

    if response_meta=$(curl "${arguments[@]}" "$ROUTER_URL$endpoint"); then
        HTTP_STATUS=${response_meta%%$'\t'*}
        ROUTER_LOCAL_IP=${response_meta#*$'\t'}
        return 0
    else
        curl_status=$?
    fi

    case $curl_status in
        6)
            fail "cannot resolve the router address in $ROUTER_URL
Check ROUTER_URL and the current network connection."
            ;;
        7)
            fail "cannot connect to the router at $ROUTER_URL
Check that this device is on the router network and its web interface is available."
            ;;
        28)
            fail "the router at $ROUTER_URL did not respond within 20 seconds
Check the network connection and router address."
            ;;
        60)
            fail "TLS certificate verification failed for $ROUTER_URL
Use the router's valid KeenDNS address or a trusted local HTTP address."
            ;;
        *)
            fail "request failed: $method $ROUTER_URL$endpoint (curl exit $curl_status)"
            ;;
    esac
}

response_error() {
    local context=$1 file=$2 detail
    detail=$(jq -r 'if type == "object" then (.message // .error // empty) else empty end' "$file" 2>/dev/null || true)
    if [[ $HTTP_STATUS == 401 || $HTTP_STATUS == 403 ]]; then
        fail "$context (HTTP $HTTP_STATUS)
Check ROUTER_USERNAME and ROUTER_PASSWORD in $CONFIG_FILE."
    elif [[ -n $detail ]]; then
        fail "$context (HTTP $HTTP_STATUS): $detail"
    fi
    fail "$context (HTTP $HTTP_STATUS)"
}

header_value() {
    local wanted=${1,,} name value
    while IFS=: read -r name value; do
        if [[ ${name,,} == "$wanted" ]]; then
            value=${value%$'\r'}
            value=${value#"${value%%[![:space:]]*}"}
            printf '%s' "$value"
            return 0
        fi
    done < "$TMP_DIR/headers"
    return 1
}

authenticate() {
    http_request GET /auth "$TMP_DIR/auth.json"
    case $HTTP_STATUS in
        200) return 0 ;;
        401) ;;
        *) response_error 'authentication probe failed' "$TMP_DIR/auth.json" ;;
    esac

    local realm challenge md5 password_hash payload
    realm=$(header_value x-ndm-realm) || fail 'router did not return the X-NDM-Realm authentication header'
    challenge=$(header_value x-ndm-challenge) || fail 'router did not return the X-NDM-Challenge authentication header'
    md5=$(printf '%s' "$ROUTER_USERNAME:$realm:$ROUTER_PASSWORD" | md5sum)
    md5=${md5%% *}
    password_hash=$(printf '%s' "$challenge$md5" | sha256sum)
    password_hash=${password_hash%% *}
    payload=$(jq -nc --arg login "$ROUTER_USERNAME" --arg password "$password_hash" \
        '{login: $login, password: $password}')

    http_request POST /auth "$TMP_DIR/auth-result.json" "$payload"
    [[ $HTTP_STATUS == 200 ]] || response_error 'authentication failed' "$TMP_DIR/auth-result.json"
}

prompt_value() {
    local prompt=$1 default=$2 value
    printf '%s [%s]: ' "$prompt" "$default" >&2
    IFS= read -r value || fail 'configuration input ended unexpectedly'
    printf '%s' "${value:-$default}"
}

init_config() {
    local answer password_confirmation config_dir config_temp password_command_input ca_input
    if [[ -e $CONFIG_FILE ]]; then
        printf 'Configuration already exists at %s. Overwrite it? [y/N]: ' "$CONFIG_FILE" >&2
        IFS= read -r answer || fail 'configuration input ended unexpectedly'
        [[ ${answer,,} == y || ${answer,,} == yes ]] || {
            unchanged 'No changes made.'
            return 0
        }
    fi

    info 'Configure Keenetic router access. Credentials are tested before being saved.'
    ROUTER_URL=$(prompt_value 'Router URL' 'http://192.168.1.1')
    ROUTER_USERNAME=$(prompt_value 'Username' 'admin')
    printf 'Password command (leave blank to store the password): ' >&2
    IFS= read -r password_command_input || fail 'configuration input ended unexpectedly'
    if [[ -n $password_command_input ]]; then
        ROUTER_PASSWORD_COMMAND=$password_command_input
    else
        printf 'Password: ' >&2
        IFS= read -rs ROUTER_PASSWORD || fail 'configuration input ended unexpectedly'
        printf '\nConfirm password: ' >&2
        IFS= read -rs password_confirmation || fail 'configuration input ended unexpectedly'
        printf '\n' >&2
        [[ $ROUTER_PASSWORD == "$password_confirmation" ]] || fail 'passwords do not match'
    fi

    if [[ -n $CLI_CA_FILE ]]; then
        ROUTER_CA_FILE=$CLI_CA_FILE
    elif $CLI_INSECURE; then
        ROUTER_INSECURE=true
    elif [[ $ROUTER_URL == https://* ]]; then
        printf 'Trusted CA file (leave blank for system trust): ' >&2
        IFS= read -r ca_input || fail 'configuration input ended unexpectedly'
        ROUTER_CA_FILE=$ca_input
        if [[ -z $ROUTER_CA_FILE ]]; then
            printf 'Disable certificate verification? [y/N]: ' >&2
            IFS= read -r answer || fail 'configuration input ended unexpectedly'
            if [[ ${answer,,} == y || ${answer,,} == yes ]]; then
                ROUTER_INSECURE=true
            fi
        fi
    fi
    validate_router_settings

    if [[ $ROUTER_URL == http://* ]]; then
        warn 'HTTP does not protect the authenticated router session; prefer HTTPS or KeenDNS.'
    elif [[ $ROUTER_INSECURE == true ]]; then
        warn 'HTTPS certificate verification is disabled for this connection.'
    fi
    info "Testing connection to $ROUTER_URL..."
    authenticate

    if [[ $CONFIG_FILE == */* ]]; then
        config_dir=${CONFIG_FILE%/*}
    else
        config_dir=.
    fi
    if [[ ! -d $config_dir ]]; then
        mkdir -p -- "$config_dir"
        chmod 700 "$config_dir"
    fi
    config_temp=$(mktemp "$config_dir/.keenetic-policy.XXXXXX")
    chmod 600 "$config_temp"
    {
        printf '%s\n' \
            '# Generated by keenetic-policy.sh --init. Values are literal.' \
            "ROUTER_URL=$ROUTER_URL" \
            "ROUTER_USERNAME=$ROUTER_USERNAME"
        if [[ -n $ROUTER_PASSWORD_COMMAND ]]; then
            printf 'ROUTER_PASSWORD_COMMAND=%s\n' "$ROUTER_PASSWORD_COMMAND"
        else
            printf 'ROUTER_PASSWORD=%s\n' "$ROUTER_PASSWORD"
        fi
        [[ -z $ROUTER_CA_FILE ]] || printf 'ROUTER_CA_FILE=%s\n' "$ROUTER_CA_FILE"
        printf 'ROUTER_INSECURE=%s\n' "$ROUTER_INSECURE"
    } > "$config_temp"
    mv -f -- "$config_temp" "$CONFIG_FILE"
    success "Connected successfully. Configuration saved to $CONFIG_FILE."
}

api_get() {
    local endpoint=$1 output=$2 description=$3 expected_type=$4
    http_request GET "$endpoint" "$output"
    [[ $HTTP_STATUS == 200 ]] || response_error "failed to retrieve $description" "$output"
    jq -e --arg type "$expected_type" 'type == $type' "$output" >/dev/null \
        || fail "the router returned invalid $description data from $endpoint
The installed Keenetic firmware may not support this API."
}

fetch_router_state() {
    api_get /rci/show/ip/hotspot/host "$TMP_DIR/clients.json" 'clients' array
    api_get /rci/show/rc/ip/hotspot/host "$TMP_DIR/assignments.json" 'client policies' array
    api_get /rci/show/rc/ip/policy "$TMP_DIR/policies.json" 'policies' object

    if ! jq -n \
        --slurpfile clients "$TMP_DIR/clients.json" \
        --slurpfile assignments "$TMP_DIR/assignments.json" '
        ($assignments[0]
            | map(select(.mac != null) | {key: (.mac | ascii_downcase), value: .})
            | from_entries) as $by_mac
        | [$clients[0][]
            | select(.link == "up" or .mws.link? == "up")
            | . as $client
            | (($client.mac // "") | ascii_downcase) as $mac
            | ($by_mac[$mac] // {}) as $assignment
            | {
                name: ($client.name // "Unknown"),
                ip: ($client.ip // "N/A"),
                mac: $mac,
                policy: ($assignment.policy // null),
                deny: ($assignment.deny // false)
              }
          ]' > "$TMP_DIR/connected.json"; then
        fail 'could not combine the client and policy data returned by the router'
    fi
}

detect_current_client() {
    local address_file local_mac
    CURRENT_CLIENT_MAC=
    if [[ -n $ROUTER_LOCAL_IP ]]; then
        CURRENT_CLIENT_MAC=$(jq -r --arg ip "$ROUTER_LOCAL_IP" \
            'first(.[] | select(.ip == $ip) | .mac) // empty' "$TMP_DIR/connected.json")
    fi
    [[ -z $CURRENT_CLIENT_MAC ]] || return 0

    for address_file in /sys/class/net/*/address; do
        [[ -r $address_file ]] || continue
        IFS= read -r local_mac < "$address_file" || continue
        local_mac=${local_mac,,}
        [[ $local_mac != 00:00:00:00:00:00 ]] || continue
        if jq -e --arg mac "$local_mac" 'any(.[]; .mac == $mac)' "$TMP_DIR/connected.json" >/dev/null; then
            CURRENT_CLIENT_MAC=$local_mac
            return 0
        fi
    done
}

terminal_columns() {
    local columns=${COLUMNS:-}
    if [[ ! $columns =~ ^[0-9]+$ ]] && [[ -t 2 ]] && command -v tput >/dev/null 2>&1; then
        columns=$(tput cols 2>/dev/null || true)
    fi
    [[ $columns =~ ^[0-9]+$ ]] || columns=80
    printf '%s' "$columns"
}

shorten_text() {
    local text=$1 width=$2
    if ((${#text} > width)); then
        printf '%s~' "${text:0:width - 1}"
    else
        printf '%s' "$text"
    fi
}

compute_client_widths() {
    local prefix_width=$1 columns available
    columns=$(terminal_columns)
    ((columns >= 32)) || fail 'terminal is too narrow; at least 32 columns are required'
    available=$((columns - prefix_width))
    CLIENT_IP_WIDTH=$((available / 4))
    ((CLIENT_IP_WIDTH < 7)) && CLIENT_IP_WIDTH=7
    ((CLIENT_IP_WIDTH > 15)) && CLIENT_IP_WIDTH=15
    CLIENT_POLICY_WIDTH=$((available / 4))
    ((CLIENT_POLICY_WIDTH < 8)) && CLIENT_POLICY_WIDTH=8
    ((CLIENT_POLICY_WIDTH > 18)) && CLIENT_POLICY_WIDTH=18
    CLIENT_NAME_WIDTH=$((available - CLIENT_IP_WIDTH - CLIENT_POLICY_WIDTH - 2))
    ((CLIENT_NAME_WIDTH >= 8)) || fail 'terminal is too narrow to display the client selector'
    ((CLIENT_NAME_WIDTH <= 36)) || CLIENT_NAME_WIDTH=36
}

separator() {
    local width=$1 value
    printf -v value '%*s' "$width" ''
    printf '%s' "${value// /-}"
}

# shellcheck disable=SC2016 # The dollar expression belongs to jq.
policy_label_filter='
    if .deny then
        "Blocked"
    elif .policy == null or .policy == false then
        "Default"
    else
        ($policies[0][(.policy | tostring)].description // (.policy | tostring))
    end
'

list_clients_table() {
    if ! jq -e 'length > 0' "$TMP_DIR/connected.json" >/dev/null; then
        printf 'No connected clients found.\n'
        return 0
    fi
    local display_name name ip mac policy fitted_name fitted_ip fitted_policy
    local name_separator ip_separator policy_separator
    compute_client_widths 0
    name_separator=$(separator "$CLIENT_NAME_WIDTH")
    ip_separator=$(separator "$CLIENT_IP_WIDTH")
    policy_separator=$(separator "$CLIENT_POLICY_WIDTH")

    printf "%-${CLIENT_NAME_WIDTH}s %-${CLIENT_IP_WIDTH}s %-${CLIENT_POLICY_WIDTH}s\n" \
        'NAME' 'IP' 'POLICY'
    printf "%-${CLIENT_NAME_WIDTH}s %-${CLIENT_IP_WIDTH}s %-${CLIENT_POLICY_WIDTH}s\n" \
        "$name_separator" "$ip_separator" "$policy_separator"
    while IFS=$'\t' read -r name ip mac policy; do
        display_name=$name
        [[ $mac != "$CURRENT_CLIENT_MAC" ]] || display_name="* $name (this device)"
        fitted_name=$(shorten_text "$display_name" "$CLIENT_NAME_WIDTH")
        fitted_ip=$(shorten_text "$ip" "$CLIENT_IP_WIDTH")
        fitted_policy=$(shorten_text "$policy" "$CLIENT_POLICY_WIDTH")
        if [[ $mac == "$CURRENT_CLIENT_MAC" ]]; then
            printf "%s%-${CLIENT_NAME_WIDTH}s %-${CLIENT_IP_WIDTH}s %-${CLIENT_POLICY_WIDTH}s%s\n" \
                "$GREEN" "$fitted_name" "$fitted_ip" "$fitted_policy" "$RESET"
        else
            printf "%-${CLIENT_NAME_WIDTH}s %-${CLIENT_IP_WIDTH}s %-${CLIENT_POLICY_WIDTH}s\n" \
                "$fitted_name" "$fitted_ip" "$fitted_policy"
        fi
    done < <(
        jq -r --slurpfile policies "$TMP_DIR/policies.json" \
            "sort_by(.name | ascii_downcase)[] | [.name, .ip, .mac, ($policy_label_filter)] | @tsv" \
            "$TMP_DIR/connected.json"
    )
}

list_clients_json() {
    jq --slurpfile policies "$TMP_DIR/policies.json" \
        "sort_by(.name | ascii_downcase)
        | map({
            name,
            ip,
            policy: ($policy_label_filter),
            policy_id: (if .deny or .policy == null or .policy == false then null else (.policy | tostring) end)
          })" "$TMP_DIR/connected.json"
}

render_arrow_menu() {
    local selected=$1 redraw=$2 count=${#MENU_OPTIONS[@]} index marker style
    if $redraw; then
        printf '\033[%dA' "$count" >&2
    fi

    for ((index = 0; index < count; index++)); do
        marker=' '
        style=
        if ((index == MENU_CURRENT_INDEX)); then
            marker='*'
            style=$DIM
        fi
        if ((index == selected)); then
            printf '\r\033[2K%s> %s %s%s\n' "$HIGHLIGHT" "$marker" "${MENU_OPTIONS[index]}" "$RESET" >&2
        else
            printf '\r\033[2K%s  %s %s%s\n' "$style" "$marker" "${MENU_OPTIONS[index]}" "$RESET" >&2
        fi
    done
}

finish_arrow_menu() {
    show_cursor
}

arrow_menu() {
    local subject=$1 count=${#MENU_OPTIONS[@]} selected=0 key suffix
    ((count > 0)) || fail "no $subject options are available"
    [[ -t 0 && -t 2 ]] || fail "interactive $subject selection requires a terminal"
    if ((MENU_CURRENT_INDEX >= 0)); then
        selected=$MENU_CURRENT_INDEX
    fi

    CURSOR_HIDDEN=true
    printf '\033[?25l' >&2
    printf 'Use Up/Down arrows, Enter to select, or Esc/q to cancel.\n' >&2
    render_arrow_menu "$selected" false
    while true; do
        IFS= read -rsn1 key || fail "$subject selection input ended unexpectedly"
        if [[ $key == $'\033' ]]; then
            suffix=
            IFS= read -rsn2 -t 0.1 suffix || true
            key+=$suffix
        fi

        case $key in
            $'\033[A'|k)
                selected=$(((selected + count - 1) % count))
                ;;
            $'\033[B'|j)
                selected=$(((selected + 1) % count))
                ;;
            '')
                SELECTED_INDEX=$((selected + 1))
                finish_arrow_menu
                return 0
                ;;
            q|Q|$'\033')
                finish_arrow_menu
                return 1
                ;;
            *)
                continue
                ;;
        esac
        render_arrow_menu "$selected" true
    done
}

select_client_from_candidates() {
    local candidates=$1 heading=$2 count name ip mac policy option display_name index=0
    local fitted_name fitted_ip fitted_policy
    count=$(jq 'length' <<< "$candidates")
    ((count > 0)) || fail "$EXIT_CLIENT" 'no connected clients found'
    compute_client_widths 4

    MENU_OPTIONS=()
    MENU_CURRENT_INDEX=-1
    while IFS=$'\t' read -r name ip mac policy; do
        display_name=$name
        if [[ $mac == "$CURRENT_CLIENT_MAC" ]]; then
            display_name+=" (this device)"
            MENU_CURRENT_INDEX=$index
        fi
        fitted_name=$(shorten_text "$display_name" "$CLIENT_NAME_WIDTH")
        fitted_ip=$(shorten_text "$ip" "$CLIENT_IP_WIDTH")
        fitted_policy=$(shorten_text "$policy" "$CLIENT_POLICY_WIDTH")
        printf -v option "%-${CLIENT_NAME_WIDTH}s %-${CLIENT_IP_WIDTH}s %-${CLIENT_POLICY_WIDTH}s" \
            "$fitted_name" "$fitted_ip" "$fitted_policy"
        MENU_OPTIONS+=("$option")
        index=$((index + 1))
    done < <(
        jq -r --slurpfile policies "$TMP_DIR/policies.json" \
            "sort_by([(.name | ascii_downcase), .ip])[] | [.name, .ip, .mac, ($policy_label_filter)] | @tsv" \
            <<< "$candidates"
    )

    printf '%s\n\n' "$heading" >&2
    if ! arrow_menu client; then
        unchanged 'No changes made.'
        return 1
    fi
    SELECTED_CLIENT=$(jq -c --argjson index "$((SELECTED_INDEX - 1))" \
        'sort_by([(.name | ascii_downcase), .ip])[$index]' <<< "$candidates")
}

resolve_client() {
    local selector=$1 value=$2 allow_prompt=$3 matches count label
    case $selector in
        client)
            label="name '$value'"
            matches=$(jq --arg value "$value" \
                '[.[] | select((.name | ascii_downcase) == ($value | ascii_downcase))]' \
                "$TMP_DIR/connected.json")
            ;;
        ip)
            label="IP '$value'"
            matches=$(jq --arg value "$value" '[.[] | select(.ip == $value)]' \
                "$TMP_DIR/connected.json")
            ;;
        mac)
            label="MAC '$value'"
            matches=$(jq --arg value "${value,,}" '[.[] | select(.mac == $value)]' \
                "$TMP_DIR/connected.json")
            ;;
        *)
            fail "unknown client selector: $selector"
            ;;
    esac
    count=$(jq 'length' <<< "$matches")

    if ((count == 0)); then
        fail "$EXIT_CLIENT" "no connected client has $label
Run '$PROGRAM' to list clients or '$PROGRAM --interactive' to select one."
    elif ((count == 1)); then
        SELECTED_CLIENT=$(jq -c '.[0]' <<< "$matches")
    elif $allow_prompt; then
        select_client_from_candidates "$matches" "Multiple connected clients match $label:" || return 1
    else
        printf 'Multiple connected clients match %s:\n' "$label" >&2
        jq -r 'sort_by(.ip)[] | "  \(.name)  \(.ip)"' <<< "$matches" >&2
        fail "$EXIT_CLIENT" "client selector is ambiguous; use '$PROGRAM --interactive' to select one"
    fi
}

select_any_client() {
    local clients
    clients=$(cat "$TMP_DIR/connected.json")
    select_client_from_candidates "$clients" 'Connected clients:'
}

client_policy_id() {
    jq -r 'if .deny then "__blocked__" elif .policy == null or .policy == false then "__default__" else (.policy | tostring) end' \
        <<< "$1"
}

client_policy_label() {
    jq -r --slurpfile policies "$TMP_DIR/policies.json" "$policy_label_filter" <<< "$1"
}

load_policy_options() {
    POLICY_IDS=('__default__')
    POLICY_LABELS=('Default')
    local id label
    while IFS=$'\t' read -r id label; do
        POLICY_IDS+=("$id")
        POLICY_LABELS+=("$label")
    done < <(
        jq -r 'to_entries
            | sort_by(.value.description // .key)
            | .[]
            | [.key, (.value.description // .key)]
            | @tsv' "$TMP_DIR/policies.json"
    )
}

choose_policy_interactively() {
    local client=$1 name ip current_id current_label index option columns option_width
    name=$(jq -r '.name' <<< "$client")
    ip=$(jq -r '.ip' <<< "$client")
    current_id=$(client_policy_id "$client")
    current_label=$(client_policy_label "$client")
    load_policy_options

    MENU_OPTIONS=()
    MENU_CURRENT_INDEX=-1
    columns=$(terminal_columns)
    ((columns >= 12)) || fail 'terminal is too narrow to display the policy selector'
    option_width=$((columns - 4))
    ((option_width <= 40)) || option_width=40
    for ((index = 0; index < ${#POLICY_IDS[@]}; index++)); do
        option=${POLICY_LABELS[index]}
        if [[ ${POLICY_IDS[index]} == "$current_id" ]]; then
            option+=" (current)"
            MENU_CURRENT_INDEX=$index
        fi
        MENU_OPTIONS+=("$(shorten_text "$option" "$option_width")")
    done

    printf 'Client: %s (%s)\n' "$name" "$ip" >&2
    printf 'Current policy: %s\n\n' "$current_label" >&2
    if ! arrow_menu policy; then
        unchanged 'No changes made.'
        return 1
    fi
    SELECTED_POLICY_ID=${POLICY_IDS[SELECTED_INDEX - 1]}
    SELECTED_POLICY_LABEL=${POLICY_LABELS[SELECTED_INDEX - 1]}
}

resolve_policy() {
    local query=$1 matches count
    if [[ ${query,,} == default ]]; then
        SELECTED_POLICY_ID=__default__
        SELECTED_POLICY_LABEL=Default
        return 0
    fi

    matches=$(jq --arg query "$query" \
        '[to_entries[] | select((.key | ascii_downcase) == ($query | ascii_downcase))]' \
        "$TMP_DIR/policies.json")
    count=$(jq 'length' <<< "$matches")
    if ((count == 0)); then
        matches=$(jq --arg query "$query" \
            '[to_entries[] | select(((.value.description // .key) | ascii_downcase) == ($query | ascii_downcase))]' \
            "$TMP_DIR/policies.json")
        count=$(jq 'length' <<< "$matches")
    fi

    if ((count == 0)); then
        printf 'Available policies:\n  Default\n' >&2
        jq -r 'to_entries | sort_by(.value.description // .key)[] | "  \(.value.description // .key) [\(.key)]"' \
            "$TMP_DIR/policies.json" >&2
        fail "$EXIT_POLICY" "unknown policy: $query"
    elif ((count > 1)); then
        fail "$EXIT_POLICY" "policy description is ambiguous: $query; use its policy ID instead"
    fi

    SELECTED_POLICY_ID=$(jq -r '.[0].key' <<< "$matches")
    SELECTED_POLICY_LABEL=$(jq -r '.[0].value.description // .[0].key' <<< "$matches")
}

verify_selected_policy() {
    local mac=$1 assignment actual_id actual_label
    api_get /rci/show/rc/ip/hotspot/host "$TMP_DIR/verify-assignments.json" 'client policies' array
    assignment=$(jq -c --arg mac "$mac" \
        'first(.[] | select((.mac // "" | ascii_downcase) == $mac)) // empty' \
        "$TMP_DIR/verify-assignments.json")
    [[ -n $assignment ]] || fail "$EXIT_VERIFY" \
        "router did not return the updated client while verifying $SELECTED_POLICY_LABEL"
    actual_id=$(client_policy_id "$assignment")
    if [[ $actual_id != "$SELECTED_POLICY_ID" ]]; then
        actual_label=$(client_policy_label "$assignment")
        fail "$EXIT_VERIFY" \
            "router reported policy \"$actual_label\" after applying \"$SELECTED_POLICY_LABEL\""
    fi
}

apply_selected_policy() {
    local client=$1 name mac current_id payload
    name=$(jq -r '.name' <<< "$client")
    mac=$(jq -r '.mac' <<< "$client")
    current_id=$(client_policy_id "$client")

    if [[ $current_id == "$SELECTED_POLICY_ID" ]]; then
        unchanged "$name already uses $SELECTED_POLICY_LABEL. No changes made."
        return 0
    fi

    if [[ $SELECTED_POLICY_ID == __default__ ]]; then
        payload=$(jq -nc --arg mac "$mac" \
            '{mac: $mac, policy: false, permit: true, schedule: false}')
    else
        payload=$(jq -nc --arg mac "$mac" --arg policy "$SELECTED_POLICY_ID" \
            '{mac: $mac, policy: $policy, permit: true, schedule: false}')
    fi

    http_request POST /rci/ip/hotspot/host "$TMP_DIR/apply-result.json" "$payload"
    [[ $HTTP_STATUS == 200 ]] || response_error 'failed to apply policy' "$TMP_DIR/apply-result.json"
    verify_selected_policy "$mac"
    success "Applied and verified policy \"$SELECTED_POLICY_LABEL\" for $name."
}

main() {
    parse_args "$@"
    init_colors
    require_command curl
    require_command jq
    require_command md5sum
    require_command sha256sum
    create_temp_dir

    if $INIT_CONFIG; then
        init_config
        return 0
    fi

    load_config
    authenticate
    fetch_router_state
    detect_current_client

    if $JSON_OUTPUT; then
        list_clients_json
    elif $INTERACTIVE; then
        select_any_client || return 0
        choose_policy_interactively "$SELECTED_CLIENT" || return 0
        apply_selected_policy "$SELECTED_CLIENT"
    elif [[ -n $CLIENT_SELECTOR && -n $POLICY_QUERY ]]; then
        resolve_client "$CLIENT_SELECTOR" "$CLIENT_VALUE" false
        resolve_policy "$POLICY_QUERY"
        apply_selected_policy "$SELECTED_CLIENT"
    elif [[ -n $CLIENT_SELECTOR ]]; then
        resolve_client "$CLIENT_SELECTOR" "$CLIENT_VALUE" true || return 0
        choose_policy_interactively "$SELECTED_CLIENT" || return 0
        apply_selected_policy "$SELECTED_CLIENT"
    else
        list_clients_table
    fi
}

main "$@"
