#!/usr/bin/env bash
# scripts/refresh-authkeys.sh — business logic for the "Refresh Authorized
# Keys" flow (docs/KEY-DESIGN.md §5, task M). A function library, sourced
# by .github/workflows/refresh-authorized-keys.yml.
#
# Pure decision-making and command-string building only: this file never
# calls gh, never references ${{ }}, never touches $GITHUB_OUTPUT, never
# runs anything on a remote node (docs/LAYOUT.md §3). The workflow fetches
# the variables via gh api and passes the raw JSON in; the resulting
# install command string goes to pool-ssh.
#
# Public key material is not a secret, but the convention here (and in
# authkeys.sh) is that messages identify entries by name/count, never by
# echoing whole key lines — the assembled content may be logged at most
# as a count.
#
# INPUT SHAPES (both are accepted everywhere a variables JSON is taken):
#   - the raw output of `gh api .../actions/variables` is an OBJECT
#     {total_count, variables} — accept it via .variables
#   - a bare ARRAY of variable objects (what --jq .variables yields) —
#     accept it directly
# A variable's .value is a JSON STRING, not an object: it is parsed back
# with fromjson, and a value that fails to parse is an ERROR for the
# whole batch — never silently skipped into a list that looks complete
# (same rationale as CONTRACT §2: a broken CLIENT_* must fail loudly).

set -uo pipefail

# refresh_collect_clients <variables_json>
#   Output: a JSON array of every CLIENT_* value, parsed back into
#   CONTRACT objects ({name, public_key, added_at}), in the order they
#   appear. No CLIENT_* variables at all -> prints `[]` and exits 0
#   (empty is a legal state; authkeys_assemble enforces the non-empty
#   guard where it matters). Wrong input shape or an unparseable
#   CLIENT_* value -> non-zero, no output.
refresh_collect_clients() {
    local vars_json="${1:-}"
    local list out rc

    list="$(printf '%s' "$vars_json" | jq -c '
        if type == "object" and (.variables | type) == "array" then .variables
        elif type == "array" then .
        else null end' 2>/dev/null)"
    [[ -n "$list" && "$list" != "null" ]] || {
        printf 'refresh-authkeys: variables input is neither an object with .variables nor an array\n' >&2
        return 1
    }

    # A CLIENT_* whose value is not a parseable JSON object fails the
    # whole batch, and the message names the offending variable.
    local bad
    bad="$(printf '%s' "$list" | jq -r '
        def coerce: if type == "string" then (try fromjson catch null) else . end;
        [.[] | select(.name | startswith("CLIENT_"))
         | select((.value | coerce | type) != "object")
         | .name] | .[0] // empty' 2>/dev/null)"
    if [[ -n "$bad" ]]; then
        printf 'refresh-authkeys: CLIENT_* variable %s has a value that is not a JSON object\n' "$bad" >&2
        return 1
    fi

    out="$(printf '%s' "$list" | jq -c '
        def coerce: if type == "string" then (try fromjson catch null) else . end;
        [.[] | select(.name | startswith("CLIENT_")) | .value | coerce]' 2>/dev/null)"
    rc=$?
    if [[ $rc -ne 0 || -z "$out" ]]; then
        printf 'refresh-authkeys: could not assemble CLIENT_* values\n' >&2
        return 1
    fi
    printf '%s\n' "$out"
}

# refresh_collect_tunnel_keys <variables_json> <pool_workers_json>
#   Gathers the tunnel public keys that the Gateway's sshproxy
#   authorized_keys is assembled from:
#     - every NODE_* whose .role == "provider", field .tunnel_public_key
#     - every POOL_WORKERS[] entry's .tunnel_public_key
#     - REPAIR_TUNNEL_PUBKEY when present (the whole family's shared
#       repair key, design D9 — a SINGLE OpenSSH public key line, NOT a
#       JSON object, so it never goes through the NODE_* fromjson path)
#   Output: one key line per stdout line, de-duplicated (sorted -u).
#   Both sides absent -> prints nothing and exits 0 — an empty tunnel
#   list is a legal state (KEY-DESIGN items 5/6 have not landed yet), and
#   the caller decides whether writing an empty file is safe (it is not:
#   it would evict every provider currently dialing in).
#   Wrong input shape or an unparseable NODE_* value -> non-zero, no
#   output (a provider whose var cannot be read must not silently lose
#   its tunnel key).
#   REPAIR_TUNNEL_PUBKEY present but not a valid public key line ->
#   non-zero, no output (same level as the CLIENT_ACTIONS self-lockout
#   guard: this key is the whole family's only door; silently dropping
#   it, or assembling without it while looking successful, is a lockout).
refresh_collect_tunnel_keys() {
    local vars_json="${1:-}" workers_json="${2:-}"
    local list bad node_keys worker_keys repair_keys

    list="$(printf '%s' "$vars_json" | jq -c '
        if type == "object" and (.variables | type) == "array" then .variables
        elif type == "array" then .
        else null end' 2>/dev/null)"
    [[ -n "$list" && "$list" != "null" ]] || {
        printf 'refresh-authkeys: variables input is neither an object with .variables nor an array\n' >&2
        return 1
    }

    bad="$(printf '%s' "$list" | jq -r '
        def coerce: if type == "string" then (try fromjson catch null) else . end;
        [.[] | select(.name | startswith("NODE_"))
         | select((.value | coerce | type) != "object")
         | .name] | .[0] // empty' 2>/dev/null)"
    if [[ -n "$bad" ]]; then
        printf 'refresh-authkeys: NODE_* variable %s has a value that is not a JSON object\n' "$bad" >&2
        return 1
    fi

    node_keys="$(printf '%s' "$list" | jq -r '
        def coerce: if type == "string" then (try fromjson catch null) else . end;
        [.[] | select(.name | startswith("NODE_"))
         | (.value | coerce)
         | select((.role // empty) == "provider")
         | .tunnel_public_key // empty] | .[]' 2>/dev/null)"
    worker_keys="$(printf '%s' "$workers_json" | jq -r '
        def coerce: if type == "string" then (try fromjson catch null) else . end;
        [(. | coerce)
         | if type == "array" then .[] else empty end
         | .tunnel_public_key // empty] | .[]' 2>/dev/null)"

    # REPAIR_TUNNEL_PUBKEY (design D9): the value IS one public key line,
    # not a JSON object — extract it raw, never fromjson it. Its name must
    # never gain a NODE_ prefix, which would route it into the object check
    # above and fail the whole batch (recon §2.2 naming constraint).
    repair_keys="$(printf '%s' "$list" | jq -r '
        [.[] | select(.name == "REPAIR_TUNNEL_PUBKEY") | .value // empty]
        | .[]' 2>/dev/null)"
    if [[ -n "$repair_keys" ]]; then
        # The validator must work wherever this collector runs. The refresh
        # workflow sources lib/authkeys.sh alongside this file, but the
        # rotate workflow only sources rotate-gateway.sh + this file (the
        # lazy source inside rotate_assemble_login_keys runs in a subshell
        # and is invisible here) — so ensure it is loaded, resolved from
        # THIS file's location rather than $PWD or SCRIPT_DIR.
        if ! declare -F authkeys_valid_pubkey >/dev/null 2>&1; then
            local _authkeys_lib
            _authkeys_lib="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)/lib/authkeys.sh"
            if [[ -f "$_authkeys_lib" ]]; then
                # shellcheck source=lib/authkeys.sh
                source "$_authkeys_lib"
            fi
        fi
        local _rk
        while IFS= read -r _rk; do
            [[ -n "$_rk" ]] || continue
            if ! authkeys_valid_pubkey "$_rk" 2>/dev/null; then
                printf 'refresh-authkeys: REPAIR_TUNNEL_PUBKEY is not a valid public key line — refusing (no output)\n' >&2
                return 1
            fi
        done <<< "$repair_keys"
    fi

    printf '%s\n%s\n%s\n' "$node_keys" "$worker_keys" "$repair_keys" \
        | sed '/^[[:space:]]*$/d' | sort -u
    return 0
}

# refresh_sync_local_authorized_keys <variables_json> [target_path]
#   Assembles the LOGIN authorized_keys for a machine from the CLIENT_*
#   variables (authkeys_assemble with CLIENT_ACTIONS as the required key)
#   and installs it at <target_path> (default $HOME/.ssh/authorized_keys).
#   A FULL REPLACE — never a union: revocation must propagate (removing the
#   var removes the key from every machine, KEY-DESIGN §3.2).
#
#   This is the ONE implementation of "converge a machine's login list from
#   the variables" — pool-sync and register-provider both call it, so there
#   is never a second copy that could drift out of sync with its guards
#   (RUNBOOK §7.12: one rule, two implementations, one without guards).
#
#   Exit 0  = the file now matches (written, or already byte-identical).
#   Non-zero = nothing was written; stderr names the reason (unparseable
#   variables, invalid public_key, missing CLIENT_ACTIONS, empty result).
#   The caller decides what non-zero means: pool-sync logs WARN and keeps
#   running (N6 — GitHub being down must not become a provider fault);
#   register-provider ABORTS, because a provider whose login list cannot
#   be assembled is a provider Actions cannot get into.
#   Requires log() (both callers define it) and refresh_collect_clients +
#   authkeys_assemble (both source this file and scripts/lib/authkeys.sh).
refresh_sync_local_authorized_keys() {
    local vars_json="${1:-}" target="${2:-${HOME}/.ssh/authorized_keys}"
    local clients actions_pk login tmp n

    clients="$(refresh_collect_clients "$vars_json")" || {
        log ERROR "cannot collect CLIENT_* variables — ${target} left untouched"
        return 1
    }

    # required_pubkey is CLIENT_ACTIONS — the self-lockout guard only works
    # if we actually have that key to require. A missing CLIENT_ACTIONS is
    # a data-state problem, not a program error: WARN here, non-zero return,
    # and let the CALLER decide how fatal that is (pool-sync keeps running,
    # register-provider aborts).
    actions_pk="$(printf '%s' "$clients" | jq -r '.[] | select(.name == "actions") | .public_key // empty' 2>/dev/null || true)"
    if [[ -z "$actions_pk" ]]; then
        log WARN "no CLIENT_ACTIONS public key found — cannot guarantee Actions stays in; ${target} left untouched"
        return 1
    fi

    login="$(authkeys_assemble "$clients" "$actions_pk")" || {
        log ERROR "authorized_keys assembly failed — ${target} left untouched"
        return 1
    }
    if [[ -z "$login" ]]; then
        log ERROR "assembled authorized_keys is empty — refusing to write"
        return 1
    fi

    if [[ -f "$target" ]] && cmp -s <(printf '%s\n' "$login") "$target"; then
        log INFO "authorized_keys already matches CLIENT_* declarations"
        return 0
    fi

    mkdir -p "$(dirname "$target")"
    tmp="$(mktemp "$(dirname "$target")/.ak.XXXXXX")"
    printf '%s\n' "$login" > "$tmp"
    chmod 600 "$tmp"
    if mv -f "$tmp" "$target" 2>/dev/null; then
        n="$(printf '%s\n' "$login" | wc -l | tr -d ' ')"
        log INFO "converged ${target} from CLIENT_* (${n} key(s))"
        return 0
    fi
    rm -f "$tmp"
    log ERROR "could not install ${target}"
    return 1
}

# refresh_build_install_cmd <remote_path> <content> [--sudo]
#   Builds the shell command string to hand to pool-ssh (which runs it on
#   the Gateway). Atomic install: write a temp file in the same directory,
#   chmod 600, chown to the right owner, then mv over the target — a
#   reader can never see a half-written authorized_keys. Content travels
#   as base64 (no quoting traps). With --sudo every step goes through sudo
#   and the owner is root-corrected to the target's parent user name;
#   without it the file is owned by whoever ssh connects as (fatesaikou
#   for the login list).
#
#   OUTPUT IS THE COMMAND STRING, BASE64-ENCODED, AS A SINGLE LINE. The
#   caller puts it straight into a `key=value` $GITHUB_OUTPUT line, which
#   rejects multi-line values: the command itself is multi-line, plain
#   `base64` wraps at 76 chars, and `-w0` is GNU-only (macOS's base64 has
#   no -w). `| base64 | tr -d '\n'` is portable to both. The consumer
#   restores it with `base64 -d` and evals the resulting command.
refresh_build_install_cmd() {
    local remote_path="$1" content="$2" sudo=0
    if [[ "${3:-}" == "--sudo" ]]; then
        sudo=1
    fi

    local content_b64
    content_b64="$(printf '%s\n' "$content" | base64 | tr -d '\n')"

    # Owner for chown: the target's parent directory name is the account
    # (e.g. /home/sshproxy/... -> sshproxy). Deriving it keeps --sudo
    # correct without a second parameter that could disagree with $1.
    local owner
    owner="$(printf '%s' "$remote_path" | sed -n 's|^/home/\([^/]*\)/.*|\1|p')"
    [[ -n "$owner" ]] || owner="$(id -un)"

    local pre
    if [[ "$sudo" -eq 1 ]]; then
        pre="sudo"
    else
        pre=""
    fi

    printf '%s\n' \
        'set -euo pipefail' \
        'd="$(mktemp -d)"' \
        'trap '"'"'rm -rf "$d"'"'"' EXIT INT TERM' \
        "printf '%s' '${content_b64}' | base64 -d > \"\$d/authorized_keys\"" \
        "${pre:+$pre }chmod 600 \"\$d/authorized_keys\"" \
        "${pre:+$pre }chown ${owner}:${owner} \"\$d/authorized_keys\"" \
        "${pre:+$pre }install -d -o ${owner} -g ${owner} \"$(dirname "$remote_path")\"" \
        "${pre:+$pre }mv -f \"\$d/authorized_keys\" \"${remote_path}\"" \
        "echo \"installed $(basename "$remote_path") (\$(wc -l < \"${remote_path}\") key(s))\"" \
        | base64 | tr -d '\n'
    printf '\n'
}
