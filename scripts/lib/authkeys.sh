#!/usr/bin/env bash
# scripts/lib/authkeys.sh — pure functions for assembling authorized_keys
# from CLIENT_* repo variables (docs/KEY-DESIGN.md §9, item 1).
#
# Style follows scripts/lib/ledger.sh: every function validates its input,
# always returns a consistent shape, and bad input is ALWAYS non-zero
# with no output — a partially-assembled list looks identical to a
# complete one, and a missing key in authorized_keys is indistinguishable
# from a correct file at a glance (that is exactly why contract §2 fails
# the whole batch instead of skipping the bad record).
#
# These functions are pure: no network, no `gh`, no files, no
# environment. The caller collects the CLIENT_* values via gh api and
# passes them in as a JSON array.
#
# Contract: CONTRACT.md (CLIENT_* var format + assembly rules).

# authkeys_valid_pubkey <line>
#   0 = <line> looks like a valid public key line: first field one of
#   ssh-ed25519 / ssh-rsa / ecdsa-sha2-*, second field a non-empty base64
#   blob ([A-Za-z0-9+/=]+), optional comment after. Multi-line input is
#   never valid. No output; key material never appears in messages.
authkeys_valid_pubkey() {
    local line="${1:-}"
    if [[ -z "$line" ]] || [[ "$line" == *$'\n'* ]]; then
        return 1
    fi
    local type blob
    read -r type blob _ <<< "$line" || return 1
    case "$type" in
        ssh-ed25519|ssh-rsa|ecdsa-sha2-*) ;;
        *) return 1 ;;
    esac
    [[ "$blob" =~ ^[A-Za-z0-9+/=]+$ ]] || return 1
    return 0
}

# authkeys_var_name <client-name>
#   Maps a client name to its variable name: lowercase, '-' becomes '_',
#   prefixed with CLIENT_. fatesaikou-mac -> CLIENT_FATESAIKOU_MAC.
#   Any character outside [a-z0-9-] is an error (non-zero, no output).
authkeys_var_name() {
    local name="${1:-}"
    if [[ -z "$name" ]] || ! [[ "$name" =~ ^[a-z0-9-]+$ ]]; then
        return 1
    fi
    printf 'CLIENT_%s\n' "$(printf '%s' "$name" | tr 'a-z' 'A-Z' | tr '-' '_')"
}

# authkeys_assemble <clients_json> <required_pubkey>
#   Prints the assembled authorized_keys content to stdout, one key per
#   line. clients_json is a JSON ARRAY of CLIENT_* values (the caller
#   collects them). required_pubkey is the Actions public key line whose
#   key material MUST be in the result — the self-lockout guard.
#
#   Contract requirements, all enforced:
#     1. input not an array                  -> non-zero, no output
#     2. any record's public_key invalid     -> non-zero, no output
#        (never skip a bad record: partial success looks complete)
#     3. dedupe on key material (2nd field); keep first occurrence
#     4. output sorted by key material        -> byte-stable (--check
#        compares byte-for-byte; unstable order = perpetual drift)
#     5. required_pubkey's material must be present in the result,
#        else non-zero, no output (self-lockout guard, NOT a warning)
#     6. empty result                        -> non-zero, no output
authkeys_assemble() {
    local clients_json="${1:-}" required="${2:-}"

    # 1: not an array -> fail with nothing on stdout.
    if ! printf '%s' "$clients_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
        printf 'authkeys_assemble: clients input is not a JSON array\n' >&2
        return 1
    fi

    # 2: validate every public_key BEFORE assembling anything.
    local n
    n="$(printf '%s' "$clients_json" | jq 'length' 2>/dev/null)"
    if [[ -z "$n" || "$n" -eq 0 ]]; then
        printf 'authkeys_assemble: no clients (empty result)\n' >&2
        return 1
    fi
    local i
    for (( i = 0; i < n; i++ )); do
        local name pk
        name="$(printf '%s' "$clients_json" | jq -r --argjson i "$i" '.[$i].name // empty' 2>/dev/null)"
        pk="$(printf '%s' "$clients_json" | jq -r --argjson i "$i" '.[$i].public_key // empty' 2>/dev/null)"
        if ! authkeys_valid_pubkey "$pk"; then
            printf 'authkeys_assemble: client %s (entry %d) has an invalid public_key\n' \
                "${name:-<unnamed>}" "$((i + 1))" >&2
            return 1
        fi
    done

    # 5: required_pubkey must itself be valid and present in the result.
    if ! authkeys_valid_pubkey "$required"; then
        printf 'authkeys_assemble: required_pubkey is not a valid public key line\n' >&2
        return 1
    fi
    local required_material
    required_material="$(printf '%s' "$required" | awk '{print $2}')"

    # 3+4+5+6: dedupe on material (first occurrence wins), sort by
    # material, then require the required material present and the result
    # non-empty. Empty input also lands here (out == "").
    local out
    out="$(printf '%s' "$clients_json" | jq -r \
        --arg req "$required_material" '
        [.[] | .public_key]
        | (reduce .[] as $line (
            [];
            . as $acc
            | ($line | split(" ") | .[1]) as $mat
            | if any($acc[]; split(" ")[1] == $mat) then $acc else $acc + [$line] end
          ))
        | sort_by(split(" ")[1])
        | (map(select(split(" ")[1] == $req)) | length) as $has_req
        | if $has_req == 0 then empty else .[] end
        ' 2>/dev/null)"

    if [[ -z "$out" ]]; then
        printf 'authkeys_assemble: result is empty or the required key is missing — refusing to produce a list that would lock out Actions\n' >&2
        return 1
    fi

    printf '%s\n' "$out"
}
