#!/usr/bin/env bash
# scripts/delete-worker.sh — business logic for the Delete Worker flow
# (spec: docs/POOL_RUNTIME_SPEC.md §10.4).
#
# A function library, sourced by .github/workflows/delete-worker.yml.
# Every remote command still goes through .github/actions/pool-ssh — this
# file only validates input and picks the matching claim out of already-
# fetched JSON; it never runs anything on a remote node itself, and never
# calls gh / references ${{ }} / touches $GITHUB_OUTPUT (docs/LAYOUT.md §3).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"

# delete_worker_validate_inputs <port_in> <name_in>
#   Either port or name is required; whichever is given must be well-formed.
delete_worker_validate_inputs() {
    local port_in="$1" name_in="$2"
    if [[ -z "$port_in" && -z "$name_in" ]]; then
        log ERROR "give either 'port' or 'name'"
        return 1
    fi
    if [[ -n "$port_in" ]] && ! [[ "$port_in" =~ ^[0-9]+$ ]]; then
        log ERROR "'port' must be numeric, got '${port_in}'"
        return 1
    fi
    if [[ -n "$name_in" ]] && ! [[ "$name_in" =~ ^[A-Za-z0-9._-]+$ ]]; then
        log ERROR "'name' must match ^[A-Za-z0-9._-]+\$, got '${name_in}'"
        return 1
    fi
}

# delete_worker_find_claim <claims_json> <port_in> <name_in>
#   The real state of a port is `ss` on the Gateway, not this placeholder
#   ledger (spec §10.1) — but it's needed regardless, to learn WHICH
#   provider and container to reach, since neither port nor name alone
#   tells us that. Prints port=/provider=/container= on a match.
delete_worker_find_claim() {
    local claims_json="$1" port_in="$2" name_in="$3"
    local match

    if [[ -n "$port_in" ]]; then
        match="$(jq -c --argjson p "$port_in" '[.[] | select(.port == $p)] | first // empty' <<<"$claims_json")"
    else
        local container="mlp-${name_in}"
        match="$(jq -c --arg c "$container" '[.[] | select(.container == $c)] | first // empty' <<<"$claims_json")"
    fi

    if [[ -z "$match" ]]; then
        log ERROR "no worker port claim found for '${port_in}${name_in}' — check pool-port-alloc --list on the Gateway"
        return 1
    fi

    printf 'port=%s\n' "$(jq -r '.port' <<<"$match")"
    printf 'provider=%s\n' "$(jq -r '.provider' <<<"$match")"
    printf 'container=%s\n' "$(jq -r '.container // empty' <<<"$match")"
}
