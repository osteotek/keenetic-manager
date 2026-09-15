#!/usr/bin/env bash

set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
: "${KEENETIC_CONFIG:?Set KEENETIC_CONFIG to a readable router config before running make check-router}"

output=$(mktemp)
cleanup() {
    rm -f -- "$output"
}
trap cleanup EXIT

"$ROOT/keenetic" --all --json > "$output"
jq -e '
    type == "array"
    and all(.[];
        (.name | type == "string")
        and (.ip | type == "string")
        and (.mac | type == "string" and test("^([0-9a-f]{2}:){5}[0-9a-f]{2}$"))
        and (.online | type == "boolean")
        and (.blocked | type == "boolean")
        and (.policy | type == "string")
        and ((.policy_id == null) or (.policy_id | type == "string"))
    )
' "$output" >/dev/null
printf 'Keenetic read-only contract check passed for %s clients.\n' "$(jq 'length' "$output")"
