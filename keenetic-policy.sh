#!/usr/bin/env bash

set -Eeuo pipefail

PROGRAM=${0##*/}
VERSION=1.1.0
EXIT_GENERAL=1
EXIT_USAGE=2
EXIT_CLIENT=3
EXIT_POLICY=4
EXIT_VERIFY=5
CONFIG_ENV_SET=false
[[ -v KEENETIC_CONFIG ]] && CONFIG_ENV_SET=true
CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}/keenetic-policy
CONFIG_FILE=${KEENETIC_CONFIG:-$CONFIG_HOME/config}
STATE_HOME=${XDG_STATE_HOME:-$HOME/.local/state}/keenetic-policy
HISTORY_FILE=${KEENETIC_STATE_FILE:-$STATE_HOME/history.json}
ROUTER_URL=
ROUTER_USERNAME=
ROUTER_PASSWORD=
ROUTER_PASSWORD_COMMAND=
ROUTER_PASSWORD_FILE=
ROUTER_CA_FILE=
ROUTER_INSECURE=false
CLI_CA_FILE=
CLI_INSECURE=false
ROUTER_PROFILE=
HTTP_STATUS=
ROUTER_LOCAL_IP=
CURRENT_CLIENT_MAC=
TMP_DIR=
POLICY_QUERY=
FZF_COMMAND=${KEENETIC_FZF:-fzf}
ACTION=
VIEW_MODE=connected
INTERACTIVE=false
JSON_OUTPUT=false
INIT_CONFIG=false
DISCOVER=false
DRY_RUN=false
UNDO=false
QUIET=false
VERBOSE=false
COLOR_MODE=auto
SELECTED_CLIENT=
SELECTED_POLICY_ID=
SELECTED_POLICY_LABEL=
SELECTED_INDEX=0
MENU_CURRENT_INDEX=-1
MENU_RESIZED=false
CURSOR_HIDDEN=false
OPERATION_CONTEXT=
RED=
GREEN=
YELLOW=
DIM=
HIGHLIGHT=
RESET=
CLIENT_NAME_WIDTH=28
CLIENT_IP_WIDTH=15
CLIENT_POLICY_WIDTH=18
declare -a CLIENT_SELECTORS=()
declare -a CLIENT_VALUES=()
declare -a SELECTED_CLIENTS=()
declare -a MENU_OPTIONS=()
MENU_KIND=
declare -a POLICY_IDS=()
declare -a POLICY_LABELS=()

usage() {
    cat <<EOF
Usage:
  $PROGRAM [--all|--offline] [--json]
  $PROGRAM --interactive
  $PROGRAM CLIENT_NAME
  $PROGRAM SELECTOR... (--policy POLICY|--block|--unblock|--wake) [--dry-run]
  $PROGRAM --undo [--dry-run]
  $PROGRAM --discover
  $PROGRAM --init

Selectors (repeatable for batch changes):
      --client NAME              Select by exact client name
      --ip ADDRESS               Select by exact IP address
      --mac ADDRESS              Select by exact MAC address

Actions:
      --policy POLICY            Apply policy ID, description, or "Default"
      --block                    Block Internet access
      --unblock                  Remove Internet block
      --wake                     Send Wake-on-LAN
      --undo                     Restore the most recent recorded change
      --dry-run                  Resolve and print changes without POSTing

Listing and connection:
  -i, --interactive              Select with fzf when available, else arrow keys
      --all                      Include connected and offline clients
      --offline                  Show only offline clients
      --router NAME              Use config from $CONFIG_HOME/routers/NAME
      --discover                 Test the default gateway for Keenetic API access
      --json                     Emit client list as JSON
      --ca-file FILE             Trust this CA certificate for HTTPS
      --insecure                 Disable HTTPS certificate verification

Output and setup:
  -q, --quiet                    Suppress successful mutation output
  -v, --verbose                  Print sanitized request and state diagnostics
      --init                     Configure router credentials securely
      --color[=WHEN]             Colors: auto, always, or never
      --no-color                 Disable colors
  -V, --version                  Show version
  -h, --help                     Show this help

Interactive controls without fzf: Up/Down arrows move, Enter selects, Esc or q cancels.

Configuration: $CONFIG_FILE
Override it with KEENETIC_CONFIG.
EOF
}
fail() {
    local status=$EXIT_GENERAL
    if [[ ${1-} =~ ^[1-9][0-9]*$ ]]; then
        status=$1
        shift
    fi
    if [[ -n $OPERATION_CONTEXT ]]; then
        set -- "$OPERATION_CONTEXT: $*"
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

debug() {
    $VERBOSE && printf 'Debug: %s\n' "$*" >&2 || true
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

add_client_selector() {
    local selector=$1 value=$2
    [[ -n $value ]] || fail "$EXIT_USAGE" "--$selector requires a non-empty value"
    if [[ $selector == mac ]]; then
        value=${value,,}
        [[ $value =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] \
            || fail "$EXIT_USAGE" 'MAC address must use aa:bb:cc:dd:ee:ff format'
    fi
    CLIENT_SELECTORS+=("$selector")
    CLIENT_VALUES+=("$value")
}

set_action() {
    local action=$1
    [[ -z $ACTION || $ACTION == "$action" ]] \
        || fail "$EXIT_USAGE" 'use only one of --policy, --block, --unblock, or --wake'
    ACTION=$action
}

parse_args() {
    local selector
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
            --client|--ip|--mac)
                (($# >= 2)) || fail "$EXIT_USAGE" "$1 requires a value"
                add_client_selector "${1#--}" "$2"
                shift
                ;;
            --client=*|--ip=*|--mac=*)
                selector=${1%%=*}
                add_client_selector "${selector#--}" "${1#*=}"
                ;;
            --policy)
                (($# >= 2)) || fail "$EXIT_USAGE" '--policy requires an ID or description'
                [[ -n $2 ]] || fail "$EXIT_USAGE" '--policy requires a non-empty ID or description'
                set_action policy
                POLICY_QUERY=$2
                shift
                ;;
            --policy=*)
                set_action policy
                POLICY_QUERY=${1#*=}
                [[ -n $POLICY_QUERY ]] || fail "$EXIT_USAGE" '--policy requires a non-empty ID or description'
                ;;
            --block)
                set_action block
                ;;
            --unblock)
                set_action unblock
                ;;
            --wake)
                set_action wake
                ;;
            --undo)
                UNDO=true
                ;;
            --dry-run)
                DRY_RUN=true
                ;;
            --all)
                [[ $VIEW_MODE == connected || $VIEW_MODE == all ]] \
                    || fail "$EXIT_USAGE" '--all and --offline cannot be combined'
                VIEW_MODE=all
                ;;
            --offline)
                [[ $VIEW_MODE == connected || $VIEW_MODE == offline ]] \
                    || fail "$EXIT_USAGE" '--all and --offline cannot be combined'
                VIEW_MODE=offline
                ;;
            --router)
                (($# >= 2)) || fail "$EXIT_USAGE" '--router requires a profile name'
                ROUTER_PROFILE=$2
                shift
                ;;
            --router=*)
                ROUTER_PROFILE=${1#*=}
                ;;
            --discover)
                DISCOVER=true
                ;;
            --json)
                JSON_OUTPUT=true
                ;;
            -q|--quiet)
                QUIET=true
                ;;
            -v|--verbose)
                VERBOSE=true
                ;;
            --init)
                INIT_CONFIG=true
                ;;
            --ca-file)
                (($# >= 2)) || fail "$EXIT_USAGE" '--ca-file requires a path'
                CLI_CA_FILE=$2
                shift
                ;;
            --ca-file=*)
                CLI_CA_FILE=${1#*=}
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

    for value in "${positional[@]}"; do
        add_client_selector client "$value"
    done
    if [[ -n $ROUTER_PROFILE ]]; then
        [[ $ROUTER_PROFILE =~ ^[A-Za-z0-9._-]+$ ]] \
            || fail "$EXIT_USAGE" 'router profile may contain only letters, digits, dots, underscores, and hyphens'
        $CONFIG_ENV_SET && fail "$EXIT_USAGE" '--router cannot be combined with KEENETIC_CONFIG'
        CONFIG_FILE=$CONFIG_HOME/routers/$ROUTER_PROFILE
    fi
    $CLI_INSECURE && [[ -n $CLI_CA_FILE ]] \
        && fail "$EXIT_USAGE" '--insecure and --ca-file cannot be combined'
    if $DISCOVER; then
        $INIT_CONFIG || $INTERACTIVE || $JSON_OUTPUT || $UNDO || [[ -n $ACTION ]] || ((${#CLIENT_SELECTORS[@]} > 0)) \
            && fail "$EXIT_USAGE" '--discover must be used alone'
    fi
    if $UNDO; then
        $INTERACTIVE || $JSON_OUTPUT || $INIT_CONFIG || [[ -n $ACTION ]] || ((${#CLIENT_SELECTORS[@]} > 0)) \
            && fail "$EXIT_USAGE" '--undo cannot be combined with another action or client selector'
    fi
    if $INIT_CONFIG; then
        $INTERACTIVE || $JSON_OUTPUT || [[ -n $ACTION ]] || ((${#CLIENT_SELECTORS[@]} > 0)) \
            && fail "$EXIT_USAGE" '--init cannot be combined with a client, action, --interactive, or --json'
    fi
    if $JSON_OUTPUT && { $INTERACTIVE || [[ -n $ACTION ]] || ((${#CLIENT_SELECTORS[@]} > 0)); }; then
        fail "$EXIT_USAGE" '--json is only valid when listing clients'
    fi
    if [[ -n $ACTION ]] && ((${#CLIENT_SELECTORS[@]} == 0)); then
        fail "$EXIT_USAGE" 'an action requires at least one --client, --ip, or --mac selector'
    fi
    if $INTERACTIVE && { [[ -n $ACTION ]] || ((${#CLIENT_SELECTORS[@]} > 0)); }; then
        fail "$EXIT_USAGE" '--interactive selects the client and action itself'
    fi
    if ((${#CLIENT_SELECTORS[@]} > 1)) && [[ -z $ACTION ]]; then
        fail "$EXIT_USAGE" 'multiple client selectors require an explicit action'
    fi
    if $DRY_RUN && [[ -z $ACTION ]] && ! $INTERACTIVE && ! $UNDO; then
        fail "$EXIT_USAGE" '--dry-run requires an action, --interactive, or --undo'
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
    local password source_count=0
    local -a password_command password_lines
    [[ -n $ROUTER_PASSWORD ]] && ((source_count += 1))
    [[ -n $ROUTER_PASSWORD_COMMAND ]] && ((source_count += 1))
    [[ -n $ROUTER_PASSWORD_FILE ]] && ((source_count += 1))
    ((source_count <= 1)) \
        || fail "set exactly one of ROUTER_PASSWORD, ROUTER_PASSWORD_COMMAND, or ROUTER_PASSWORD_FILE in $CONFIG_FILE"

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
    elif [[ -n $ROUTER_PASSWORD_FILE ]]; then
        [[ -r $ROUTER_PASSWORD_FILE ]] || fail "cannot read password file: $ROUTER_PASSWORD_FILE"
        mapfile -t password_lines < "$ROUTER_PASSWORD_FILE"
        ((${#password_lines[@]} == 1)) \
            || fail 'ROUTER_PASSWORD_FILE must contain exactly one line'
        [[ -n ${password_lines[0]} ]] || fail 'ROUTER_PASSWORD_FILE contains an empty password'
        ROUTER_PASSWORD=${password_lines[0]}
    fi
    [[ -n $ROUTER_PASSWORD ]] \
        || fail "set ROUTER_PASSWORD, ROUTER_PASSWORD_COMMAND, or ROUTER_PASSWORD_FILE in $CONFIG_FILE"
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
            ROUTER_PASSWORD_FILE) ROUTER_PASSWORD_FILE=$value ;;
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

    debug "$method $endpoint"
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
hash_md5() {
    if command -v md5sum >/dev/null 2>&1; then
        md5sum
    elif command -v md5 >/dev/null 2>&1; then
        md5 -q
    else
        fail 'required MD5 tool not found: install md5sum or md5'
    fi
}

hash_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256
    else
        fail 'required SHA-256 tool not found: install sha256sum or shasum'
    fi
}

authenticate() {
    http_request GET /auth "$TMP_DIR/auth.json"
    case $HTTP_STATUS in
        200)
            debug 'Authentication: existing session accepted'
            return 0
            ;;
        401)
            debug 'Authentication: challenge response'
            ;;
        *) response_error 'authentication probe failed' "$TMP_DIR/auth.json" ;;
    esac

    local realm challenge md5 password_hash payload
    realm=$(header_value x-ndm-realm) || fail 'router did not return the X-NDM-Realm authentication header'
    challenge=$(header_value x-ndm-challenge) || fail 'router did not return the X-NDM-Challenge authentication header'
    md5=$(printf '%s' "$ROUTER_USERNAME:$realm:$ROUTER_PASSWORD" | hash_md5)
    md5=${md5%% *}
    password_hash=$(printf '%s' "$challenge$md5" | hash_sha256)
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

discover_router() {
    local gateway url status
    require_command ip
    require_command jq
    require_command curl
    gateway=$(ip -json route show default \
        | jq -r '[.[] | select(.gateway != null)] | sort_by(.metric // 0) | .[0].gateway // empty') \
        || fail 'cannot inspect the default route'
    [[ -n $gateway ]] || fail 'no default gateway was found'
    if [[ $gateway == *:* ]]; then
        url=http://[$gateway]
    else
        url=http://$gateway
    fi
    debug "Probing GET $url/auth"
    if ! status=$(curl --silent --show-error --connect-timeout 3 --max-time 5 \
        --output /dev/null --write-out '%{http_code}' "$url/auth"); then
        fail "default gateway $gateway did not respond to an HTTP authentication probe"
    fi
    case $status in
        200|401)
            printf '%s\n' "$url"
            ;;
        *)
            fail "default gateway $gateway did not expose a Keenetic-compatible /auth endpoint (HTTP $status)"
            ;;
    esac
}

init_config() {
    local answer password_confirmation config_dir config_temp password_command_input password_file_input ca_input
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
    printf 'Password command (leave blank to use a password file or stored password): ' >&2
    IFS= read -r password_command_input || fail 'configuration input ended unexpectedly'
    if [[ -n $password_command_input ]]; then
        ROUTER_PASSWORD_COMMAND=$password_command_input
    else
        printf 'Password file (leave blank to store the password): ' >&2
        IFS= read -r password_file_input || fail 'configuration input ended unexpectedly'
        if [[ -n $password_file_input ]]; then
            ROUTER_PASSWORD_FILE=$password_file_input
        else
            printf 'Password: ' >&2
            IFS= read -rs ROUTER_PASSWORD || fail 'configuration input ended unexpectedly'
            printf '\nConfirm password: ' >&2
            IFS= read -rs password_confirmation || fail 'configuration input ended unexpectedly'
            printf '\n' >&2
            [[ $ROUTER_PASSWORD == "$password_confirmation" ]] || fail 'passwords do not match'
        fi
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
        elif [[ -n $ROUTER_PASSWORD_FILE ]]; then
            printf 'ROUTER_PASSWORD_FILE=%s\n' "$ROUTER_PASSWORD_FILE"
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
            | . as $client
            | (($client.mac // "") | ascii_downcase) as $mac
            | ($by_mac[$mac] // {}) as $assignment
            | {
                name: ($client.name // "Unknown"),
                ip: ($client.ip // "N/A"),
                mac: $mac,
                policy: ($assignment.policy // null),
                deny: ($assignment.deny // false),
                online: (.link == "up" or .mws.link? == "up")
              }
          ]' > "$TMP_DIR/all-clients.json"; then
        fail 'could not combine the client and policy data returned by the router'
    fi
    case $VIEW_MODE in
        connected) jq '[.[] | select(.online)]' "$TMP_DIR/all-clients.json" > "$TMP_DIR/clients-view.json" ;;
        offline) jq '[.[] | select(.online | not)]' "$TMP_DIR/all-clients.json" > "$TMP_DIR/clients-view.json" ;;
        all) cp "$TMP_DIR/all-clients.json" "$TMP_DIR/clients-view.json" ;;
    esac
    cp "$TMP_DIR/clients-view.json" "$TMP_DIR/connected.json"
    debug "Router: $ROUTER_URL"
    debug "Local address: ${ROUTER_LOCAL_IP:-unknown}"
    debug "Clients: $(jq 'length' "$TMP_DIR/all-clients.json") total, $(jq '[.[] | select(.online)] | length' "$TMP_DIR/all-clients.json") online"
    debug "Policies: $(jq '[to_entries[] | select(.value.description? != null)] | length' "$TMP_DIR/policies.json")"
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
    local text_width=$width
    # Bash has no wcwidth(3). A conservative half-width limit guarantees that
    # double-width CJK and emoji do not spill into the next column.
    if [[ $text == *[![:ascii:]]* ]]; then
        text_width=$((width / 2))
        ((text_width >= 2)) || text_width=2
    fi
    if ((${#text} > text_width)); then
        printf '%s~' "${text:0:text_width - 1}"
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
    local empty_message='No connected clients found.'
    [[ $VIEW_MODE == offline ]] && empty_message='No offline clients found.'
    [[ $VIEW_MODE == all ]] && empty_message='No known clients found.'
    if ! jq -e 'length > 0' "$TMP_DIR/connected.json" >/dev/null; then
        printf '%s\n' "$empty_message"
        return 0
    fi
    local display_name name ip mac policy online fitted_name fitted_ip fitted_policy
    local name_separator ip_separator policy_separator
    compute_client_widths 0
    name_separator=$(separator "$CLIENT_NAME_WIDTH")
    ip_separator=$(separator "$CLIENT_IP_WIDTH")
    policy_separator=$(separator "$CLIENT_POLICY_WIDTH")

    printf "%-${CLIENT_NAME_WIDTH}s %-${CLIENT_IP_WIDTH}s %-${CLIENT_POLICY_WIDTH}s\n" \
        'NAME' 'IP' 'POLICY'
    printf "%-${CLIENT_NAME_WIDTH}s %-${CLIENT_IP_WIDTH}s %-${CLIENT_POLICY_WIDTH}s\n" \
        "$name_separator" "$ip_separator" "$policy_separator"
    while IFS=$'\t' read -r name ip mac policy online; do
        display_name=$name
        if [[ -n $CURRENT_CLIENT_MAC && $mac == "$CURRENT_CLIENT_MAC" ]]; then
            display_name="* $name (this device)"
        elif [[ $online != true ]]; then
            display_name="$name (offline)"
        fi
        fitted_name=$(shorten_text "$display_name" "$CLIENT_NAME_WIDTH")
        fitted_ip=$(shorten_text "$ip" "$CLIENT_IP_WIDTH")
        fitted_policy=$(shorten_text "$policy" "$CLIENT_POLICY_WIDTH")
        if [[ -n $CURRENT_CLIENT_MAC && $mac == "$CURRENT_CLIENT_MAC" ]]; then
            printf "%s%-${CLIENT_NAME_WIDTH}s %-${CLIENT_IP_WIDTH}s %-${CLIENT_POLICY_WIDTH}s%s\n" \
                "$GREEN" "$fitted_name" "$fitted_ip" "$fitted_policy" "$RESET"
        else
            printf "%-${CLIENT_NAME_WIDTH}s %-${CLIENT_IP_WIDTH}s %-${CLIENT_POLICY_WIDTH}s\n" \
                "$fitted_name" "$fitted_ip" "$fitted_policy"
        fi
    done < <(
        jq -r --slurpfile policies "$TMP_DIR/policies.json" \
            "sort_by([if .online then 0 else 1 end, (.name | ascii_downcase)])[]
            | [.name, .ip, .mac, ($policy_label_filter), .online] | @tsv" \
            "$TMP_DIR/connected.json"
    )
}

list_clients_json() {
    jq --slurpfile policies "$TMP_DIR/policies.json" \
        "sort_by([if .online then 0 else 1 end, (.name | ascii_downcase)])
        | map({
            name,
            ip,
            mac,
            online,
            blocked: .deny,
            policy: ($policy_label_filter),
            policy_id: (if .deny or .policy == null or .policy == false then null else (.policy | tostring) end)
          })" "$TMP_DIR/connected.json"
}

format_menu_option() {
    local index=$1 columns name ip policy status fitted_name fitted_ip fitted_policy option_width
    if [[ $MENU_KIND == client ]]; then
        IFS=$'\t' read -r name ip policy status <<< "${MENU_OPTIONS[index]}"
        [[ $status == online ]] || name="$name (offline)"
        compute_client_widths 4
        fitted_name=$(shorten_text "$name" "$CLIENT_NAME_WIDTH")
        fitted_ip=$(shorten_text "$ip" "$CLIENT_IP_WIDTH")
        fitted_policy=$(shorten_text "$policy" "$CLIENT_POLICY_WIDTH")
        printf "%-${CLIENT_NAME_WIDTH}s %-${CLIENT_IP_WIDTH}s %-${CLIENT_POLICY_WIDTH}s" \
            "$fitted_name" "$fitted_ip" "$fitted_policy"
    else
        columns=$(terminal_columns)
        ((columns >= 20)) || fail 'terminal is too narrow to display the policy selector'
        option_width=$((columns - 6))
        shorten_text "${MENU_OPTIONS[index]}" "$option_width"
    fi
}

render_arrow_menu() {
    local selected=$1 redraw=$2 count=${#MENU_OPTIONS[@]} index marker style option
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
        option=$(format_menu_option "$index")
        if ((index == selected)); then
            printf '\r\033[2K%s> %s %s%s\n' "$HIGHLIGHT" "$marker" "$option" "$RESET" >&2
        else
            printf '\r\033[2K%s  %s %s%s\n' "$style" "$marker" "$option" "$RESET" >&2
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
    MENU_RESIZED=false
    trap 'MENU_RESIZED=true' WINCH
    printf '\033[?25l' >&2
    printf 'Use Up/Down arrows, Enter to select, or Esc/q to cancel.\n' >&2
    render_arrow_menu "$selected" false
    while true; do
        if ! IFS= read -rsn1 -t 0.2 key; then
            if $MENU_RESIZED; then
                MENU_RESIZED=false
                render_arrow_menu "$selected" true
            fi
            continue
        fi
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
                trap - WINCH
                finish_arrow_menu
                return 0
                ;;
            q|Q|$'\033')
                trap - WINCH
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
    local candidates=$1 heading=$2 count name ip mac policy online display_name index=0 selected selected_index
    count=$(jq 'length' <<< "$candidates")
    ((count > 0)) || fail "$EXIT_CLIENT" 'no matching clients found'
    jq --arg current "$CURRENT_CLIENT_MAC" \
        'sort_by([if .mac == $current then 0 else 1 end, if .online then 0 else 1 end, (.name | ascii_downcase), .ip])' \
        <<< "$candidates" > "$TMP_DIR/menu-clients.json"

    if [[ -t 0 && -t 2 ]] && command -v "$FZF_COMMAND" >/dev/null 2>&1; then
        selected=$(
            jq -r --slurpfile policies "$TMP_DIR/policies.json" \
                "to_entries[] | [
                    (.key | tostring),
                    (.value.name + (if .value.mac == \"$CURRENT_CLIENT_MAC\" then \" (this device)\" else \"\" end)),
                    .value.ip,
                    ($policy_label_filter),
                    (if .value.online then \"online\" else \"offline\" end)
                ] | @tsv" "$TMP_DIR/menu-clients.json" \
            | "$FZF_COMMAND" --delimiter=$'\t' --with-nth=2.. --height=70% --layout=reverse \
                --prompt='Client> ' --header="$heading  Name | IP | Policy | Status"
        ) || {
            unchanged 'No changes made.'
            return 1
        }
        selected_index=${selected%%$'\t'*}
        SELECTED_CLIENT=$(jq -c --argjson index "$selected_index" '.[$index]' "$TMP_DIR/menu-clients.json")
        return 0
    fi

    MENU_OPTIONS=()
    MENU_CURRENT_INDEX=-1
    MENU_KIND=client
    while IFS=$'\t' read -r name ip mac policy online; do
        display_name=$name
        if [[ -n $CURRENT_CLIENT_MAC && $mac == "$CURRENT_CLIENT_MAC" ]]; then
            display_name+=" (this device)"
            MENU_CURRENT_INDEX=$index
        fi
        MENU_OPTIONS+=("$display_name"$'\t'"$ip"$'\t'"$policy"$'\t'"$([[ $online == true ]] && printf online || printf offline)")
        index=$((index + 1))
    done < <(
        jq -r --slurpfile policies "$TMP_DIR/policies.json" \
            ".[] | [.name, .ip, .mac, ($policy_label_filter), .online] | @tsv" \
            "$TMP_DIR/menu-clients.json"
    )

    printf '%s\n\n' "$heading" >&2
    if ! arrow_menu client; then
        unchanged 'No changes made.'
        return 1
    fi
    SELECTED_CLIENT=$(jq -c --argjson index "$((SELECTED_INDEX - 1))" \
        '.[$index]' "$TMP_DIR/menu-clients.json")
}

resolve_client() {
    local selector=$1 value=$2 allow_prompt=$3 matches count label
    local pool=$TMP_DIR/connected.json
    [[ $ACTION == wake ]] && pool=$TMP_DIR/all-clients.json
    case $selector in
        client)
            label="name '$value'"
            matches=$(jq --arg value "$value" \
                '[.[] | select((.name | ascii_downcase) == ($value | ascii_downcase))]' "$pool")
            ;;
        ip)
            label="IP '$value'"
            matches=$(jq --arg value "$value" '[.[] | select(.ip == $value)]' "$pool")
            ;;
        mac)
            label="MAC '$value'"
            matches=$(jq --arg value "${value,,}" '[.[] | select(.mac == $value)]' "$pool")
            ;;
        *)
            fail "unknown client selector: $selector"
            ;;
    esac
    count=$(jq 'length' <<< "$matches")

    if ((count == 0)); then
        fail "$EXIT_CLIENT" "no client in the selected view has $label
Use --all to include offline clients."
    elif ((count == 1)); then
        SELECTED_CLIENT=$(jq -c '.[0]' <<< "$matches")
    elif $allow_prompt; then
        select_client_from_candidates "$matches" "Multiple clients match $label:" || return 1
    else
        printf 'Multiple clients match %s:\n' "$label" >&2
        jq -r 'sort_by(.ip)[] | "  \(.name)  \(.ip)  \(.mac)"' <<< "$matches" >&2
        fail "$EXIT_CLIENT" "client selector is ambiguous; use --ip or --mac"
    fi
}

select_any_client() {
    local clients heading='Connected clients:'
    clients=$(cat "$TMP_DIR/connected.json")
    [[ $VIEW_MODE == all ]] && heading='Known clients:'
    [[ $VIEW_MODE == offline ]] && heading='Offline clients:'
    select_client_from_candidates "$clients" "$heading"
}

client_policy_id() {
    jq -r 'if .deny then "__block__" elif .policy == null or .policy == false then "__default__" else (.policy | tostring) end' \
        <<< "$1"
}

client_policy_label() {
    jq -r --slurpfile policies "$TMP_DIR/policies.json" "$policy_label_filter" <<< "$1"
}

load_policy_options() {
    POLICY_IDS=('__default__' '__block__')
    POLICY_LABELS=('Default' 'Block Internet')
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
    local client=$1 name ip current_id current_label index option selected selected_id
    name=$(jq -r '.name' <<< "$client")
    ip=$(jq -r '.ip' <<< "$client")
    current_id=$(client_policy_id "$client")
    current_label=$(client_policy_label "$client")
    load_policy_options

    if [[ -t 0 && -t 2 ]] && command -v "$FZF_COMMAND" >/dev/null 2>&1; then
        selected=$(
            {
                for ((index = 0; index < ${#POLICY_IDS[@]}; index++)); do
                    [[ ${POLICY_IDS[index]} == "$current_id" ]] || continue
                    printf '%s\t%s (current)\n' "${POLICY_IDS[index]}" "${POLICY_LABELS[index]}"
                done
                for ((index = 0; index < ${#POLICY_IDS[@]}; index++)); do
                    [[ ${POLICY_IDS[index]} != "$current_id" ]] || continue
                    printf '%s\t%s\n' "${POLICY_IDS[index]}" "${POLICY_LABELS[index]}"
                done
            } | "$FZF_COMMAND" --delimiter=$'\t' --with-nth=2.. --height=70% --layout=reverse \
                --prompt='Policy> ' --header="Client: $name ($ip) | Current: $current_label"
        ) || {
            unchanged 'No changes made.'
            return 1
        }
        selected_id=${selected%%$'\t'*}
        for ((index = 0; index < ${#POLICY_IDS[@]}; index++)); do
            if [[ ${POLICY_IDS[index]} == "$selected_id" ]]; then
                SELECTED_POLICY_ID=$selected_id
                SELECTED_POLICY_LABEL=${POLICY_LABELS[index]}
                return 0
            fi
        done
        fail 'fzf returned an unknown policy selection'
    fi

    MENU_OPTIONS=()
    MENU_CURRENT_INDEX=-1
    MENU_KIND=policy
    for ((index = 0; index < ${#POLICY_IDS[@]}; index++)); do
        option=${POLICY_LABELS[index]}
        if [[ ${POLICY_IDS[index]} == "$current_id" ]]; then
            option+=" (current)"
            MENU_CURRENT_INDEX=$index
        fi
        MENU_OPTIONS+=("$option")
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

verify_client_state() {
    local mac=$1 expected=$2 target_label=$3 delay attempt=0 assignment actual last_label=Unknown
    local -a delays=(0 0.25 0.25 0.5)
    for delay in "${delays[@]}"; do
        [[ $delay == 0 ]] || sleep "$delay"
        attempt=$((attempt + 1))
        api_get /rci/show/rc/ip/hotspot/host "$TMP_DIR/verify-assignments-$attempt.json" 'client policies' array
        assignment=$(jq -c --arg mac "$mac" \
            'first(.[] | select((.mac // "" | ascii_downcase) == $mac)) // empty' \
            "$TMP_DIR/verify-assignments-$attempt.json")
        if [[ -n $assignment ]]; then
            actual=$(jq -c '{policy: (.policy // false), deny: (.deny // false)}' <<< "$assignment")
        else
            actual='{"policy":false,"deny":false}'
        fi
        if jq -e --argjson expected "$expected" \
            '(.deny == $expected.deny) and (.policy == $expected.policy)' <<< "$actual" >/dev/null; then
            debug "Verification: $target_label observed on attempt $attempt"
            return 0
        fi
        last_label=$(client_policy_label "$actual")
    done
    fail "$EXIT_VERIFY" \
        "router still reported \"$last_label\" after applying \"$target_label\" (4 checks over 1 second)"
}

history_state() {
    jq -c '{policy: (.policy // false), deny: (.deny // false)}' <<< "$1"
}

record_history() {
    local client=$1 before=$2 after=$3 action=$4 directory temporary entry existing='[]'
    directory=${HISTORY_FILE%/*}
    [[ $directory == "$HISTORY_FILE" ]] && directory=.
    mkdir -p -- "$directory"
    chmod 700 "$directory"
    if [[ -e $HISTORY_FILE ]]; then
        jq -e 'type == "array"' "$HISTORY_FILE" >/dev/null \
            || fail "rollback history is not a JSON array: $HISTORY_FILE"
        existing=$(cat "$HISTORY_FILE")
    fi
    entry=$(jq -nc \
        --arg router "$ROUTER_URL" \
        --arg mac "$(jq -r '.mac' <<< "$client")" \
        --arg name "$(jq -r '.name' <<< "$client")" \
        --arg action "$action" \
        --arg timestamp "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
        --argjson before "$before" \
        --argjson after "$after" \
        '{router:$router, mac:$mac, name:$name, action:$action, timestamp:$timestamp, before:$before, after:$after}')
    temporary=$(mktemp "$directory/.history.XXXXXX")
    jq --argjson entry "$entry" '. + [$entry] | if length > 20 then .[-20:] else . end' \
        <<< "$existing" > "$temporary"
    chmod 600 "$temporary"
    mv -f -- "$temporary" "$HISTORY_FILE"
    debug "Rollback history: recorded $action for $(jq -r '.mac' <<< "$client")"
}

action_description() {
    local client=$1 name
    name=$(jq -r '.name' <<< "$client")
    case $ACTION in
        policy) printf 'set %s to policy "%s"' "$name" "$SELECTED_POLICY_LABEL" ;;
        block) printf 'block Internet for %s' "$name" ;;
        unblock) printf 'unblock Internet for %s' "$name" ;;
        wake) printf 'wake %s' "$name" ;;
    esac
}

apply_client_action() {
    local client=$1 action=$2 record=${3:-true}
    local name mac before current_id current_policy payload expected target_label success_message
    name=$(jq -r '.name' <<< "$client")
    mac=$(jq -r '.mac' <<< "$client")
    before=$(history_state "$client")
    current_id=$(client_policy_id "$client")
    current_policy=$(jq -c '.policy // false' <<< "$client")

    case $action in
        policy)
            target_label=$SELECTED_POLICY_LABEL
            if [[ $current_id == "$SELECTED_POLICY_ID" ]]; then
                unchanged "$name already uses $SELECTED_POLICY_LABEL. No changes made."
                return 0
            fi
            if [[ $SELECTED_POLICY_ID == __default__ ]]; then
                expected='{"policy":false,"deny":false}'
                payload=$(jq -nc --arg mac "$mac" \
                    '{mac:$mac, policy:false, permit:true, schedule:false}')
            else
                expected=$(jq -nc --arg policy "$SELECTED_POLICY_ID" \
                    '{policy:$policy, deny:false}')
                payload=$(jq -nc --arg mac "$mac" --arg policy "$SELECTED_POLICY_ID" \
                    '{mac:$mac, policy:$policy, permit:true, schedule:false}')
            fi
            success_message="Applied and verified policy \"$target_label\" for $name."
            ;;
        block)
            target_label='Blocked'
            if jq -e '.deny' <<< "$before" >/dev/null; then
                unchanged "$name is already blocked. No changes made."
                return 0
            fi
            expected=$(jq -nc --argjson policy "$current_policy" '{policy:$policy, deny:true}')
            payload=$(jq -nc --arg mac "$mac" '{mac:$mac, schedule:false, deny:true}')
            success_message="Blocked Internet access for $name and verified it."
            ;;
        unblock)
            target_label=$(client_policy_label "$(jq -c '.deny = false' <<< "$client")")
            if ! jq -e '.deny' <<< "$before" >/dev/null; then
                unchanged "$name is not blocked. No changes made."
                return 0
            fi
            expected=$(jq -nc --argjson policy "$current_policy" '{policy:$policy, deny:false}')
            payload=$(jq -nc --arg mac "$mac" --argjson policy "$current_policy" \
                '{mac:$mac, policy:$policy, permit:true, schedule:false}')
            success_message="Unblocked Internet access for $name and verified it."
            ;;
        *)
            fail "unsupported client action: $action"
            ;;
    esac

    if $DRY_RUN; then
        printf 'Would %s.\n' "$(action_description "$client")"
        return 0
    fi
    http_request POST /rci/ip/hotspot/host "$TMP_DIR/apply-result.json" "$payload"
    [[ $HTTP_STATUS == 200 ]] || response_error "failed to $action client" "$TMP_DIR/apply-result.json"
    verify_client_state "$mac" "$expected" "$target_label"
    $record && record_history "$client" "$before" "$expected" "$action"
    success "$success_message"
}

wake_client() {
    local client=$1 name mac payload detail
    name=$(jq -r '.name' <<< "$client")
    mac=$(jq -r '.mac' <<< "$client")
    if $DRY_RUN; then
        printf 'Would wake %s (%s).\n' "$name" "$mac"
        return 0
    fi
    payload=$(jq -nc --arg mac "$mac" '{mac:$mac}')
    http_request POST /rci/ip/hotspot/wake "$TMP_DIR/wake-result.json" "$payload"
    [[ $HTTP_STATUS == 200 ]] || response_error 'failed to send Wake-on-LAN' "$TMP_DIR/wake-result.json"
    detail=$(jq -r 'if type == "string" then . elif type == "object" then (.message // .result // tostring) else tostring end' \
        "$TMP_DIR/wake-result.json" 2>/dev/null || cat "$TMP_DIR/wake-result.json")
    success "Wake-on-LAN request for $name: $detail"
}

preflight_clients() {
    local index existing mac duplicate
    SELECTED_CLIENTS=()
    for ((index = 0; index < ${#CLIENT_SELECTORS[@]}; index++)); do
        resolve_client "${CLIENT_SELECTORS[index]}" "${CLIENT_VALUES[index]}" false
        mac=$(jq -r '.mac' <<< "$SELECTED_CLIENT")
        duplicate=false
        for existing in "${SELECTED_CLIENTS[@]}"; do
            [[ $(jq -r '.mac' <<< "$existing") == "$mac" ]] && duplicate=true
        done
        $duplicate || SELECTED_CLIENTS+=("$SELECTED_CLIENT")
    done
}

run_selected_actions() {
    local client index total=${#SELECTED_CLIENTS[@]}
    if ((total > 1)) || $DRY_RUN; then
        printf 'Plan (%d client%s):\n' "$total" "$([[ $total == 1 ]] || printf s)"
        for client in "${SELECTED_CLIENTS[@]}"; do
            printf '  - %s\n' "$(action_description "$client")"
        done
    fi
    for ((index = 0; index < total; index++)); do
        client=${SELECTED_CLIENTS[index]}
        if ((total > 1)); then
            OPERATION_CONTEXT="batch item $((index + 1))/$total ($(jq -r '.name' <<< "$client"); $index already completed)"
        fi
        if [[ $ACTION == wake ]]; then
            wake_client "$client"
        else
            apply_client_action "$client" "$ACTION"
        fi
        OPERATION_CONTEXT=
    done
}

remove_history_entry() {
    local index=$1 directory temporary
    directory=${HISTORY_FILE%/*}
    [[ $directory == "$HISTORY_FILE" ]] && directory=.
    temporary=$(mktemp "$directory/.history.XXXXXX")
    jq --argjson index "$index" 'del(.[$index])' "$HISTORY_FILE" > "$temporary"
    chmod 600 "$temporary"
    mv -f -- "$temporary" "$HISTORY_FILE"
}

undo_last_action() {
    local index entry mac name before client current payload target_label
    [[ -r $HISTORY_FILE ]] || fail 'no rollback history is available'
    jq -e 'type == "array"' "$HISTORY_FILE" >/dev/null \
        || fail "rollback history is not a JSON array: $HISTORY_FILE"
    index=$(jq -r --arg router "$ROUTER_URL" \
        '[to_entries[] | select(.value.router == $router)] | last | .key // empty' "$HISTORY_FILE")
    [[ -n $index ]] || fail "no rollback entry exists for $ROUTER_URL"
    entry=$(jq -c --argjson index "$index" '.[$index]' "$HISTORY_FILE")
    mac=$(jq -r '.mac' <<< "$entry")
    name=$(jq -r '.name' <<< "$entry")
    before=$(jq -c '.before' <<< "$entry")
    client=$(jq -c --arg mac "$mac" 'first(.[] | select(.mac == $mac)) // empty' "$TMP_DIR/all-clients.json")
    if [[ -z $client ]]; then
        client=$(jq -nc --arg name "$name" --arg mac "$mac" --argjson state "$(jq -c '.after' <<< "$entry")" \
            '{name:$name, ip:"N/A", mac:$mac, online:false, policy:$state.policy, deny:$state.deny}')
    fi
    current=$(history_state "$client")
    target_label=$(client_policy_label "$before")
    if $DRY_RUN; then
        printf 'Would restore %s (%s) to "%s" from the %s change recorded at %s.\n' \
            "$name" "$mac" "$target_label" "$(jq -r '.action' <<< "$entry")" "$(jq -r '.timestamp' <<< "$entry")"
        return 0
    fi
    if [[ $current == "$before" ]]; then
        unchanged "$name already has the recorded previous state."
    else
        if jq -e '.deny' <<< "$before" >/dev/null; then
            payload=$(jq -nc --arg mac "$mac" --argjson state "$before" \
                '{mac:$mac, policy:$state.policy, schedule:false, deny:true}')
        else
            payload=$(jq -nc --arg mac "$mac" --argjson state "$before" \
                '{mac:$mac, policy:$state.policy, permit:true, schedule:false}')
        fi
        http_request POST /rci/ip/hotspot/host "$TMP_DIR/undo-result.json" "$payload"
        [[ $HTTP_STATUS == 200 ]] || response_error 'failed to restore rollback state' "$TMP_DIR/undo-result.json"
        verify_client_state "$mac" "$before" "$target_label"
        success "Restored and verified \"$target_label\" for $name."
    fi
    remove_history_entry "$index"
    success 'Removed the restored change from rollback history.'
}


main() {
    local answer
    parse_args "$@"
    init_colors

    if $DISCOVER; then
        discover_router
        return 0
    fi

    require_command curl
    require_command jq
    command -v md5sum >/dev/null 2>&1 || command -v md5 >/dev/null 2>&1 \
        || fail 'required MD5 tool not found: install md5sum or md5'
    command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 \
        || fail 'required SHA-256 tool not found: install sha256sum or shasum'
    create_temp_dir

    if $INIT_CONFIG; then
        init_config
        return 0
    fi

    load_config
    authenticate
    fetch_router_state
    detect_current_client

    if $UNDO; then
        undo_last_action
    elif $JSON_OUTPUT; then
        list_clients_json
    elif $INTERACTIVE; then
        select_any_client || return 0
        choose_policy_interactively "$SELECTED_CLIENT" || return 0
        if [[ $SELECTED_POLICY_ID == __block__ ]]; then
            ACTION=block
            if ! $DRY_RUN && [[ $(client_policy_id "$SELECTED_CLIENT") != __block__ ]]; then
                printf 'Block Internet access for %s? [y/N]: ' "$(jq -r '.name' <<< "$SELECTED_CLIENT")" >&2
                IFS= read -r answer || fail 'confirmation input ended unexpectedly'
                [[ ${answer,,} == y || ${answer,,} == yes ]] || {
                    unchanged 'No changes made.'
                    return 0
                }
            fi
        else
            ACTION=policy
        fi
        apply_client_action "$SELECTED_CLIENT" "$ACTION"
    elif [[ -n $ACTION ]]; then
        [[ $ACTION != policy ]] || resolve_policy "$POLICY_QUERY"
        preflight_clients
        run_selected_actions
    elif ((${#CLIENT_SELECTORS[@]} == 1)); then
        resolve_client "${CLIENT_SELECTORS[0]}" "${CLIENT_VALUES[0]}" true || return 0
        choose_policy_interactively "$SELECTED_CLIENT" || return 0
        if [[ $SELECTED_POLICY_ID == __block__ ]]; then
            ACTION=block
            if ! $DRY_RUN && [[ $(client_policy_id "$SELECTED_CLIENT") != __block__ ]]; then
                printf 'Block Internet access for %s? [y/N]: ' "$(jq -r '.name' <<< "$SELECTED_CLIENT")" >&2
                IFS= read -r answer || fail 'confirmation input ended unexpectedly'
                [[ ${answer,,} == y || ${answer,,} == yes ]] || {
                    unchanged 'No changes made.'
                    return 0
                }
            fi
        else
            ACTION=policy
        fi
        apply_client_action "$SELECTED_CLIENT" "$ACTION"
    else
        list_clients_table
    fi
}

main "$@"
