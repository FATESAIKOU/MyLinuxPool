#!/usr/bin/env bash
# scripts/lib/profile.sh — small jq-based readers for
# profiles/<role>/<name>/profile.json, so callers ask "what does this
# profile declare" through one shared place instead of hand-rolling jq
# filters at every call site.

# profile_shared_config <profile.json>   -> one unit name per line
profile_shared_config() {
    jq -r '.shared_config[]?' "$1"
}

# profile_secrets <profile.json>   -> TSV: container_var<TAB>secret_name
# ("secrets" declares container-env-name -> GitHub secret name, never a
# value — spec §10.2b).
profile_secrets() {
    jq -r '.secrets // {} | to_entries[] | [.key, .value] | @tsv' "$1"
}

# profile_env <profile.json>   -> TSV: container_var<TAB>literal_value
profile_env() {
    jq -r '.env // {} | to_entries[] | [.key, .value] | @tsv' "$1"
}

# profile_systemd_user_services <profile.json>   -> one unit name per line
profile_systemd_user_services() {
    jq -r '.systemd_user_services[]?' "$1"
}

# profile_linger <profile.json>   -> "true" or "false"
profile_linger() {
    jq -r '.linger // false' "$1"
}

# profile_sudoers_rules <profile.json>   -> one rule per line (may be empty)
profile_sudoers_rules() {
    jq -r '.sudoers_rules[]?' "$1"
}

# profile_capabilities <profile.json>   -> compact JSON object, `{}` when
# absent. A worker's capabilities come from its image profile, not from each
# container (CAPABILITY-DESIGN.md §3); create-worker copies this value into
# the POOL_WORKERS entry so consumers do not have to read the profile.
# An old-style array (or any non-object) is refused with a non-zero exit:
# the contract is key:object and a guess here would corrupt the ledger.
profile_capabilities() {
    local caps
    caps="$(jq -c '.capabilities // {}' "$1" 2>/dev/null)" || return 1
    if [[ "$(jq -r 'type' <<< "$caps" 2>/dev/null)" != "object" ]]; then
        printf 'profile_capabilities: %s.capabilities is not an object — the contract is key:object (CAPABILITY-DESIGN.md §1)\n' "$1" >&2
        return 1
    fi
    printf '%s\n' "$caps"
}

# profile_declares_capability <profile.json> <key> — 0 when the profile
# declares that capability key (whatever its value).
profile_declares_capability() {
    jq -e --arg k "$2" '.capabilities // {} | has($k)' "$1" >/dev/null 2>&1
}

# profile_validate_no_github <profile.json> — guard for the standing rule in
# CAPABILITY-DESIGN.md §2: until the worker credential-injection design is
# done, no worker profile may declare `github` (the injection does not
# exist yet, and a declared capability that cannot hold is exactly the
# silent lie this design exists to prevent). Prints nothing; returns 1 and
# explains on stderr when violated.
profile_validate_no_github() {
    if profile_declares_capability "$1" "github"; then
        printf 'profile_validate_no_github: %s declares "github", but worker credential injection is not implemented yet — remove it until that design lands (CAPABILITY-DESIGN.md §2)\n' "$1" >&2
        return 1
    fi
    return 0
}
