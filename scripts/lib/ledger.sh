#!/usr/bin/env bash
# scripts/lib/ledger.sh — pure functions for POOL_WORKERS, the port ledger
# whose master copy is the GitHub repo variable (docs/STATE_CONTRACT.md §1).
#
# Every function takes the ledger JSON as its first argument and prints
# the result on stdout: no network, no `gh`, no files, no environment.
# Reading/writing the variable itself is the caller's job — a workflow
# step, per docs/LAYOUT.md §3.
#
# Empty input, an empty string, or unparseable JSON is the empty ledger
# `[]`, never an error (STATE_CONTRACT.md §5.3). So is any input that is
# not a worker-ledger shape. POOL_WORKERS is ALWAYS a JSON array
# (STATE_CONTRACT.md §1): a bare record must never be produced, and never
# be read back in either. Legal JSON that is not an array of worker
# records must never be merged in — gh's 404 error object on stdout once
# became a ledger entry, and the bare-record output shape once polluted
# the master with a non-array value (2026-09-15 incident).

# _ledger_normalize <workers_json>
#   Compact JSON array; `[]` for anything that is not a worker-ledger
#   shape. Only an array whose entries ALL look like worker records
#   (object with a numeric `port` — the unique key, STATE_CONTRACT §1)
#   is accepted. Rejected (→ `[]`): a bare object (even one with a port),
#   an array containing a string or a record without a numeric port,
#   invalid JSON, empty string.
_ledger_normalize() {
    local out
    out="$(printf '%s' "${1:-}" | jq -c '
        if type == "array" then
            if all(.[]; (type == "object") and ((.port | type) == "number")) then . else [] end
        else [] end' 2>/dev/null)"
    printf '%s\n' "${out:-[]}"
}

# ledger_add <workers_json> <port> <provider> <image> <container> <created_at>
#   Replaces the entry for <port>, or appends one; prints the array sorted
#   by port. The port is the unique key (STATE_CONTRACT §1).
#   ALWAYS prints an array — including when the ledger was empty, where
#   the old code printed a bare record and polluted the master with a
#   non-array value (STATE_CONTRACT §1; 2026-09-15 incident).
ledger_add() {
    local workers_json="${1:-}" port="${2:-}"
    local provider="${3:-}" image="${4:-}" container="${5:-}" created_at="${6:-}"

    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        printf 'ledger_add: port must be numeric, got %q\n' "$port" >&2
        return 1
    fi

    _ledger_normalize "$workers_json" | jq -c \
        --argjson port "$port" \
        --arg provider "$provider" \
        --arg image "$image" \
        --arg container "$container" \
        --arg created_at "$created_at" \
        '([.[] | objects | select(.port != $port)]
          + [{port: $port, provider: $provider, image: $image,
              container: $container, created_at: $created_at}])
         | sort_by(.port)'
}

# ledger_remove <workers_json> <port>
#   Prints the array without <port>. A port that is not there leaves the
#   ledger unchanged; exit code is always 0.
ledger_remove() {
    local workers_json="${1:-}" port="${2:-}"

    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        _ledger_normalize "$workers_json"
        return 0
    fi

    _ledger_normalize "$workers_json" | jq -c --argjson port "$port" \
        '[.[] | objects | select(.port != $port)]'
}

# ledger_find <workers_json> <port_or_name>
#   Prints the matching entry, or nothing + non-zero when there is none.
#   A name matches `container` in both spellings in circulation:
#   "mlp-fh-l-default-123" and "fh-l-default-123".
ledger_find() {
    local workers_json="${1:-}" key="${2:-}"
    local match=""

    if [[ "$key" =~ ^[0-9]+$ ]]; then
        match="$(_ledger_normalize "$workers_json" | jq -c \
            --argjson port "$key" '[.[] | objects | select(.port == $port)] | first // empty')"
    elif [[ -n "$key" ]]; then
        local bare="${key#mlp-}"
        match="$(_ledger_normalize "$workers_json" | jq -c \
            --arg c "mlp-${bare}" --arg n "$bare" \
            '[.[] | objects | select(.container == $c or .container == $n)] | first // empty')"
    fi

    if [[ -z "$match" ]]; then
        return 1
    fi
    printf '%s\n' "$match"
}

# ledger_ports <workers_json>
#   One port per line, ascending.
ledger_ports() {
    _ledger_normalize "${1:-}" | jq -r \
        '[.[] | objects | select((.port | type) == "number") | .port] | unique | .[]'
}
