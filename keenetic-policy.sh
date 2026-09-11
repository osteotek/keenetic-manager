#!/usr/bin/env bash

set -Eeuo pipefail

PROGRAM=${0##*/}
CONFIG_FILE=${KEENETIC_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/keenetic-policy/config}
ROUTER_URL=
ROUTER_USERNAME=
ROUTER_PASSWORD=
HTTP_STATUS=
ROUTER_LOCAL_IP=
TMP_DIR=
CLIENT_NAME=
POLICY_QUERY=
INTERACTIVE=false
JSON_OUTPUT=false
INIT_CONFIG=false
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
declare -a MENU_OPTIONS=()
declare -a POLICY_IDS=()
declare -a POLICY_LABELS=()

usage() {
    cat <<EOF
Usage:
  $PROGRAM                         List connected clients
  $PROGRAM --json                  List connected clients as JSON
  $PROGRAM --interactive           Select a client and policy interactively
  $PROGRAM CLIENT_NAME             Select a policy for a named client
  $PROGRAM --client NAME --policy POLICY
                                   Apply a policy non-interactively
  $PROGRAM --init                  Create and test the configuration

Options:
  -i, --interactive                Select both client and policy
      --client NAME                Select a client by exact name
      --policy POLICY              Policy ID, description, or "Default"
      --json                       Emit the client list as JSON
      --init                       Configure router credentials securely
      --color[=WHEN]               Colorize output: auto, always, or never
      --no-color                   Disable colors
  -h, --help                       Show this help

Interactive controls: Up/Down arrows move, Enter selects, Esc or q cancels.

Configuration: $CONFIG_FILE
Override it with the KEENETIC_CONFIG environment variable.
EOF
}

fail() {
    printf '%sError:%s %s\n' "$RED" "$RESET" "$*" >&2
    exit 1
}

warn() {
    printf '%sWarning:%s %s\n' "$YELLOW" "$RESET" "$*" >&2
}

success() {
    printf '%s%s%s\n' "$GREEN" "$*" "$RESET"
}

unchanged() {
    printf '%s%s%s\n' "$YELLOW" "$*" "$RESET"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

parse_args() {
    local -a positional=()
    while (($#)); do
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            -i|--interactive)
                INTERACTIVE=true
                ;;
            --client)
                (($# >= 2)) || fail '--client requires a name'
                [[ -n $2 ]] || fail '--client requires a non-empty name'
                CLIENT_NAME=$2
                shift
                ;;
            --client=*)
                CLIENT_NAME=${1#*=}
                [[ -n $CLIENT_NAME ]] || fail '--client requires a non-empty name'
                ;;
            --policy)
                (($# >= 2)) || fail '--policy requires a policy ID or description'
                [[ -n $2 ]] || fail '--policy requires a non-empty policy ID or description'
                POLICY_QUERY=$2
                shift
                ;;
            --policy=*)
                POLICY_QUERY=${1#*=}
                [[ -n $POLICY_QUERY ]] || fail '--policy requires a non-empty policy ID or description'
                ;;
            --json)
                JSON_OUTPUT=true
                ;;
            --init)
                INIT_CONFIG=true
                ;;
            --color)
                COLOR_MODE=always
                ;;
            --color=auto|--color=always|--color=never)
                COLOR_MODE=${1#*=}
                ;;
            --color=*)
                fail '--color must be auto, always, or never'
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
                fail "unknown option: $1"
                ;;
            *)
                positional+=("$1")
                ;;
        esac
        shift
    done

    ((${#positional[@]} <= 1)) || fail 'only one client name may be provided'
    if ((${#positional[@]} == 1)); then
        [[ -z $CLIENT_NAME ]] || fail 'use either CLIENT_NAME or --client, not both'
        [[ -n ${positional[0]} ]] || fail 'client name cannot be empty'
        CLIENT_NAME=${positional[0]}
    fi
    if $INIT_CONFIG && { $INTERACTIVE || $JSON_OUTPUT || [[ -n $CLIENT_NAME || -n $POLICY_QUERY ]]; }; then
        fail '--init cannot be combined with a client, policy, --interactive, or --json'
    fi
    if $JSON_OUTPUT && { $INTERACTIVE || [[ -n $CLIENT_NAME || -n $POLICY_QUERY ]]; }; then
        fail '--json is only valid when listing clients'
    fi
    [[ -z $POLICY_QUERY || -n $CLIENT_NAME ]] || fail '--policy requires --client NAME'
    if $INTERACTIVE && [[ -n $CLIENT_NAME || -n $POLICY_QUERY ]]; then
        fail '--interactive selects the client itself; do not combine it with --client or --policy'
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

validate_router_settings() {
    [[ -n $ROUTER_URL ]] || fail 'router URL cannot be empty'
    [[ -n $ROUTER_USERNAME ]] || fail 'router username cannot be empty'
    [[ -n $ROUTER_PASSWORD ]] || fail 'router password cannot be empty'
    [[ $ROUTER_URL == http://* || $ROUTER_URL == https://* ]] \
        || fail 'router URL must start with http:// or https://'
    ROUTER_URL=${ROUTER_URL%/}
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
            *) fail "$CONFIG_FILE:$line_number: unknown setting: $key" ;;
        esac
    done < "$CONFIG_FILE"

    [[ -n $ROUTER_URL ]] || fail "ROUTER_URL is missing from $CONFIG_FILE"
    [[ -n $ROUTER_USERNAME ]] || fail "ROUTER_USERNAME is missing from $CONFIG_FILE"
    [[ -n $ROUTER_PASSWORD ]] || fail "ROUTER_PASSWORD is missing from $CONFIG_FILE"
    validate_router_settings

    if command -v stat >/dev/null 2>&1 && permissions=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null); then
        if [[ $permissions =~ ^[0-7]+$ ]] && (((8#$permissions & 077) != 0)); then
            warn "$CONFIG_FILE is readable by other users; run: chmod 600 '$CONFIG_FILE'"
        fi
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
    local answer password_confirmation config_dir config_temp
    if [[ -e $CONFIG_FILE ]]; then
        printf 'Configuration already exists at %s. Overwrite it? [y/N]: ' "$CONFIG_FILE" >&2
        IFS= read -r answer || fail 'configuration input ended unexpectedly'
        [[ ${answer,,} == y || ${answer,,} == yes ]] || {
            unchanged 'No changes made.'
            return 0
        }
    fi

    printf 'Configure Keenetic router access. Credentials are tested before being saved.\n'
    ROUTER_URL=$(prompt_value 'Router URL' 'http://192.168.1.1')
    ROUTER_USERNAME=$(prompt_value 'Username' 'admin')
    printf 'Password: ' >&2
    IFS= read -rs ROUTER_PASSWORD || fail 'configuration input ended unexpectedly'
    printf '\nConfirm password: ' >&2
    IFS= read -rs password_confirmation || fail 'configuration input ended unexpectedly'
    printf '\n' >&2
    [[ $ROUTER_PASSWORD == "$password_confirmation" ]] || fail 'passwords do not match'
    validate_router_settings

    printf 'Testing connection to %s...\n' "$ROUTER_URL"
    authenticate

    if [[ $CONFIG_FILE == */* ]]; then
        config_dir=${CONFIG_FILE%/*}
    else
        config_dir=.
    fi
    mkdir -p -m 700 -- "$config_dir"
    config_temp=$(mktemp "$config_dir/.keenetic-policy.XXXXXX")
    chmod 600 "$config_temp"
    printf '%s\n' \
        '# Generated by keenetic-policy.sh --init. Values are literal.' \
        "ROUTER_URL=$ROUTER_URL" \
        "ROUTER_USERNAME=$ROUTER_USERNAME" \
        "ROUTER_PASSWORD=$ROUTER_PASSWORD" > "$config_temp"
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
    local display_name

    printf '%-28s %-15s %s\n' 'NAME' 'IP' 'POLICY'
    printf '%-28s %-15s %s\n' '----------------------------' '---------------' '------'
    while IFS=$'\t' read -r name ip policy; do
        if [[ -n $ROUTER_LOCAL_IP && $ip == "$ROUTER_LOCAL_IP" ]]; then
            display_name="* $name (this device)"
            printf '%s%-28s %-15s %s%s\n' "$GREEN" "$display_name" "$ip" "$policy" "$RESET"
        else
            printf '%-28s %-15s %s\n' "$name" "$ip" "$policy"
        fi
    done < <(
        jq -r --slurpfile policies "$TMP_DIR/policies.json" \
            "sort_by(.name | ascii_downcase)[] | [.name, .ip, ($policy_label_filter)] | @tsv" \
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
    local candidates=$1 heading=$2 count name ip policy option display_name index=0
    count=$(jq 'length' <<< "$candidates")
    ((count > 0)) || fail 'no connected clients found'

    MENU_OPTIONS=()
    MENU_CURRENT_INDEX=-1
    while IFS=$'\t' read -r name ip policy; do
        display_name=$name
        if [[ -n $ROUTER_LOCAL_IP && $ip == "$ROUTER_LOCAL_IP" ]]; then
            display_name+=" (this device)"
            MENU_CURRENT_INDEX=$index
        fi
        printf -v option '%-28s %-15s %s' "$display_name" "$ip" "$policy"
        MENU_OPTIONS+=("$option")
        index=$((index + 1))
    done < <(
        jq -r --slurpfile policies "$TMP_DIR/policies.json" \
            "sort_by([(.name | ascii_downcase), .ip])[] | [.name, .ip, ($policy_label_filter)] | @tsv" \
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
    local target_name=$1 allow_prompt=$2 matches count
    matches=$(jq --arg name "$target_name" \
        '[.[] | select((.name | ascii_downcase) == ($name | ascii_downcase))]' \
        "$TMP_DIR/connected.json")
    count=$(jq 'length' <<< "$matches")

    if ((count == 0)); then
        fail "no connected client is named '$target_name'
Run '$PROGRAM' to list clients or '$PROGRAM --interactive' to select one."
    elif ((count == 1)); then
        SELECTED_CLIENT=$(jq -c '.[0]' <<< "$matches")
    elif $allow_prompt; then
        select_client_from_candidates "$matches" "Multiple connected clients are named '$target_name':" || return 1
    else
        printf 'Multiple connected clients are named %s:\n' "$target_name" >&2
        jq -r 'sort_by(.ip)[] | "  \(.ip)"' <<< "$matches" >&2
        fail "client name is ambiguous; use '$PROGRAM --interactive' to select one"
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
    local client=$1 name ip current_id current_label index option
    name=$(jq -r '.name' <<< "$client")
    ip=$(jq -r '.ip' <<< "$client")
    current_id=$(client_policy_id "$client")
    current_label=$(client_policy_label "$client")
    load_policy_options

    MENU_OPTIONS=()
    MENU_CURRENT_INDEX=-1
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
        fail "unknown policy: $query"
    elif ((count > 1)); then
        fail "policy description is ambiguous: $query; use its policy ID instead"
    fi

    SELECTED_POLICY_ID=$(jq -r '.[0].key' <<< "$matches")
    SELECTED_POLICY_LABEL=$(jq -r '.[0].value.description // .[0].key' <<< "$matches")
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
    success "Applied policy \"$SELECTED_POLICY_LABEL\" to $name."
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

    if $JSON_OUTPUT; then
        list_clients_json
    elif $INTERACTIVE; then
        select_any_client || return 0
        choose_policy_interactively "$SELECTED_CLIENT" || return 0
        apply_selected_policy "$SELECTED_CLIENT"
    elif [[ -n $CLIENT_NAME && -n $POLICY_QUERY ]]; then
        resolve_client "$CLIENT_NAME" false
        resolve_policy "$POLICY_QUERY"
        apply_selected_policy "$SELECTED_CLIENT"
    elif [[ -n $CLIENT_NAME ]]; then
        resolve_client "$CLIENT_NAME" true || return 0
        choose_policy_interactively "$SELECTED_CLIENT" || return 0
        apply_selected_policy "$SELECTED_CLIENT"
    else
        list_clients_table
    fi
}

main "$@"
