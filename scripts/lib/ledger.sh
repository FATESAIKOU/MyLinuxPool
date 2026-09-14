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
# `[]`, never an error (STATE_CONTRACT.md §5.3).

# _ledger_normalize <workers_json>
#   Compact JSON array; `[]` for empty/unparseable/non-array input.
#   A single bare record (e.g. the output of a fresh ledger_add into an
#   empty ledger) is wrapped into a one-element array.
_ledger_normalize() {
    local out
    out="$(printf '%s' "${1:-}" | jq -c 'if type == "array" then . elif type == "object" then [.] else [] end' 2>/dev/null)"
    printf '%s\n' "${out:-[]}"
}

# ledger_add <workers_json> <port> <provider> <image> <container> <created_at>
#   Replaces the entry for <port>, or appends one; prints the array sorted
#   by port. The port is the unique key (STATE_CONTRACT §1).
#   Adding into an EMPTY ledger prints the bare record, not a one-element
#   array — that is the contract shape for a fresh ledger (a later add
#   re-wraps it via _ledger_normalize).
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
        'if length == 0 then
            {port: $port, provider: $provider, image: $image,
             container: $container, created_at: $created_at}
         else
            ([.[] | objects | select(.port != $port)]
              + [{port: $port, provider: $provider, image: $image,
                  container: $container, created_at: $created_at}])
            | sort_by(.port)
         end'
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
