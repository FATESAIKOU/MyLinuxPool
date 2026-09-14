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
