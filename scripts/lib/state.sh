#!/usr/bin/env bash
# scripts/lib/state.sh — pure functions for the Gateway state cache
# (docs/STATE_CONTRACT.md §2). No network, no `gh`, no files, no environment.
#
# The state.json at /var/lib/mylinuxpool/state.json is a cache of node
# metadata plus the worker ledger, written by rotate-gateway /
# create-worker / delete-worker / repair-gateway (contract §4). Readers
# trust it unconditionally, so installs must be atomic and owned by root.

# state_next_serial <existing_state_json_or_empty>
#   Prints the next serial: serial+1 when the input parses as JSON and has a
#   numeric serial, otherwise 1 (regenerate from scratch).
state_next_serial() {
    local input="${1:-}"
    if [[ -n "$input" ]]; then
        local serial
        serial="$(printf '%s' "$input" | jq -r '.serial? // empty' 2>/dev/null)"
        if [[ "$serial" =~ ^[0-9]+$ ]]; then
            printf '%s\n' "$((serial + 1))"
            return 0
        fi
    fi
    printf '1\n'
}

# state_build <serial> <source> <nodes_json> <workers_json>
#   Prints the complete state.json payload. Nodes keys are converted from the
#   GitHub var spelling (fh_proxy) to the hyphenated one (fh-proxy), which is
#   the one and only place that conversion happens (contract §2, invariant 2).
state_build() {
    local serial="${1:-}" source="${2:-}" nodes_json="${3:-}" workers_json="${4:-}"
    local written_at
    written_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    jq -n -c \
        --argjson serial "$(printf '%s' "$serial" | jq 'tonumber? // 0' 2>/dev/null)" \
        --arg source "$source" \
        --arg written_at "$written_at" \
        --argjson nodes "$(printf '%s' "$nodes_json" | jq -c '
            if type == "object" then
                (to_entries | map(.key = (.key | gsub("_"; "-")) | .value = (.value | if type == "object" then . else {} end)))
                | from_entries
            else {} end' 2>/dev/null)" \
        --argjson workers "$(printf '%s' "$workers_json" | jq -c '
            if type == "array" then . else [] end' 2>/dev/null)" \
        '{schema: 1, serial: $serial, written_at: $written_at, source: $source,
          nodes: $nodes, workers: $workers}'
}

# state_validate <state_json>
#   Exit 0 when the payload is contract-compliant, else print the reason(s)
#   to stderr and exit non-zero. Checks:
#     - parses as JSON, is an object
#     - schema is 1
#     - nodes keys are hyphenated, never underscore
#     - no embedded private keys, no ghp_ / ghu_ token values
state_validate() {
    local input="${1:-}"
    local clean
    if ! clean="$(printf '%s' "$input" | jq -c 'if type == "object" then . else empty end' 2>/dev/null)"; then
        printf 'state_validate: not parseable JSON or not an object\n' >&2
        return 1
    fi
    [[ -z "$clean" ]] && {
        printf 'state_validate: not parseable JSON or not an object\n' >&2
        return 1
    }

    local rc=0
    local schema
    schema="$(jq -r '.schema?' <<<"$clean" 2>/dev/null)"
    if [[ "$schema" != "1" ]]; then
        printf 'state_validate: schema is %s, expected 1\n' "${schema:-<missing>}" >&2
        rc=1
    fi

    local underscore_keys
    underscore_keys="$(jq -r '[.nodes? | keys[]? | select(test("_"))] | length' <<<"$clean" 2>/dev/null)"
    if [[ "$underscore_keys" != "0" ]]; then
        printf 'state_validate: nodes keys must be hyphenated (fh-proxy), found underscore keys\n' >&2
        rc=1
    fi

    local found=""
    local pat
    for pat in 'BEGIN OPENSSH PRIVATE KEY' 'BEGIN RSA PRIVATE KEY' 'ghp_' 'ghu_'; do
        if [[ "$input" == *"$pat"* ]]; then
            found="$pat"
            break
        fi
    done
    if [[ -n "$found" ]]; then
        printf 'state_validate: payload contains secret pattern [%s]\n' "$found" >&2
        rc=1
    fi

    return "$rc"
}

# state_install_cmd <path>
#   Prints a shell command to run on the Gateway: read the state.json
#   payload from stdin, create the parent directory, write to a temp file
#   next to the target and atomically mv it into place, mode 644. The
#   caller passes the contract path (/var/lib/mylinuxpool/state.json);
#   never $HOME, which the sshproxy reader cannot see. Owner is not
#   forced here — on the Gateway run.sh wraps the command in `sudo`, so
#   the file ends up root-owned anyway; leaving chown out keeps the
#   command runnable unprivileged too (tests install into a temp dir).
state_install_cmd() {
    local path="${1:-/var/lib/mylinuxpool/state.json}"
    printf 'umask 022 && install -d "$(dirname %s)" && cat > "%s.tmp.$$" && chmod 644 "%s.tmp.$$" && mv -f "%s.tmp.$$" "%s"\n' \
        "$path" "$path" "$path" "$path" "$path"
}
