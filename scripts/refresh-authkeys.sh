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
#   Output: one key line per stdout line, de-duplicated (sorted -u).
#   Both sides absent -> prints nothing and exits 0 — an empty tunnel
#   list is a legal state (KEY-DESIGN items 5/6 have not landed yet), and
#   the caller decides whether writing an empty file is safe (it is not:
#   it would evict every provider currently dialing in).
#   Wrong input shape or an unparseable NODE_* value -> non-zero, no
#   output (a provider whose var cannot be read must not silently lose
#   its tunnel key).
refresh_collect_tunnel_keys() {
    local vars_json="${1:-}" workers_json="${2:-}"
    local list bad node_keys worker_keys

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

    printf '%s\n%s\n' "$node_keys" "$worker_keys" \
        | sed '/^[[:space:]]*$/d' | sort -u
    return 0
}

# refresh_build_install_cmd <remote_path> <content> [--sudo]
#   Builds the shell command string to hand to pool-ssh (which runs it on
#   the Gateway). Atomic install: write a temp file in the same directory,
#   chmod 600, chown to the right owner, then mv over the target — a
#   reader can never see a half-written authorized_keys. Content travels
#   as base64 (one line, no quoting traps). With --sudo every step goes
#   through sudo and the owner is root-corrected to the target's parent
#   user name; without it the file is owned by whoever ssh connects as
#   (fatesaikou for the login list).
refresh_build_install_cmd() {
    local remote_path="$1" content="$2" sudo=0
    if [[ "${3:-}" == "--sudo" ]]; then
        sudo=1
    fi

    local content_b64
    content_b64="$(printf '%s\n' "$content" | base64)"

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
        "echo \"installed $(basename "$remote_path") (\$(wc -l < \"${remote_path}\") key(s))\""
}
