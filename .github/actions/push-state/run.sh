#!/usr/bin/env bash
# .github/actions/push-state/run.sh — spec: docs/STATE_CONTRACT.md §2/§4
#
# Reads every NODE_* variable plus POOL_WORKERS from GitHub, merges them
# with the state.json currently on the Gateway (for the serial), validates
# the result against the contract, and installs it atomically at
# /var/lib/mylinuxpool/state.json — owned by root, mode 644, so the
# sshproxy reader can see it.
#
# Contract with the calling workflow:
#   - this repo must already be checked out ($GITHUB_WORKSPACE) — the
#     state.sh library and pool-resolve are read from there
#   - GH_TOKEN must be exported (the workflow's env: level), the same
#     token pool-resolve uses elsewhere
#   - an ssh-agent must already hold the identity that can log in as
#     <gateway-user>@<gateway-ip> (e.g. the workflow's "Start ssh-agent"
#     step); this script never loads keys itself
#   - the login user must be able to sudo to root without a password
#     (profiles/gateway/default/cloud-config.yaml grants this)
#
# Push failure = step failure, by design (contract §4): readers trust this
# cache unconditionally, so a half-written copy must never look like a
# successful push.

set -euo pipefail

log() {
    local level="$1"; shift
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '[%s] %s %s\n' "$ts" "$level" "$*" >&2
}

WS="${GITHUB_WORKSPACE:-.}"
GH_REPO="${GH_REPO:-${GITHUB_REPOSITORY:-}}"
GH_TOKEN="${GH_TOKEN:-}"

GW_IP="${PUSH_GATEWAY_IP:?PUSH_GATEWAY_IP not set}"
GW_USER="${PUSH_GATEWAY_USER:-fatesaikou}"
HOST_KEY="${PUSH_HOST_KEY:-}"
SOURCE="${PUSH_SOURCE:?PUSH_SOURCE not set}"

STATE_LIB="${WS}/scripts/lib/state.sh"
if [[ ! -f "$STATE_LIB" ]]; then
    log ERROR "scripts/lib/state.sh not found under \$GITHUB_WORKSPACE — did the workflow check out this repo before calling push-state?"
    exit 1
fi
# shellcheck source=../../../scripts/lib/state.sh
source "$STATE_LIB"

if [[ -z "$GH_REPO" ]]; then
    log ERROR "GH_REPO / GITHUB_REPOSITORY not set — cannot read variables"
    exit 1
fi
if [[ -z "$GH_TOKEN" ]]; then
    log ERROR "GH_TOKEN is not set — cannot read GitHub variables"
    exit 1
fi

# --- host key handling: pin it when given, otherwise trust-on-first-use ---
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout="${SSH_CONNECT_TIMEOUT:-10}")
if [[ -n "$HOST_KEY" ]]; then
    KH="$(mktemp)"
    trap 'rm -f "$KH"' EXIT
    printf '%s %s\n' "$GW_IP" "$HOST_KEY" > "$KH"
    SSH_OPTS+=(-o UserKnownHostsFile="$KH" -o StrictHostKeyChecking=yes)
else
    SSH_OPTS+=(-o StrictHostKeyChecking=accept-new)
fi

# --- 1. all NODE_* variables -> nodes object, keys hyphenated ---
# The var-name -> node-name conversion happens HERE (contract §2 invariant
# 2): NODE_FH_PROXY is a GitHub variable name, "fh-proxy" is the node name.
NODE_VARS=""
while IFS= read -r name; do
    [[ -n "$name" ]] && NODE_VARS="${NODE_VARS}${name}"$'\n'
done < <(gh api "repos/${GH_REPO}/actions/variables" --paginate --jq \
    '.variables[] | select(.name | startswith("NODE_")) | .name' 2>/dev/null || true)

NODES_JSON="{}"
if [[ -n "$NODE_VARS" ]]; then
    NODES_JSON="$(gh api "repos/${GH_REPO}/actions/variables" --paginate --jq \
        '[.variables[]
          | select(.name | startswith("NODE_"))
          | {key: (.name[5:] | ascii_downcase | gsub("_"; "-")), value: (.value | fromjson)}]
         | from_entries' 2>/dev/null || true)"
fi
if ! printf '%s' "$NODES_JSON" | jq empty >/dev/null 2>&1; then
    log ERROR "could not assemble nodes object from NODE_* variables"
    exit 1
fi
if [[ -z "$NODES_JSON" || "$(printf '%s' "$NODES_JSON" | jq 'keys | length' 2>/dev/null)" == "0" ]]; then
    log ERROR "no NODE_* variables found in ${GH_REPO} — refusing to push an empty state"
    exit 1
fi

# --- 2. POOL_WORKERS -> workers array, [] when the variable is absent ---
WORKERS_JSON="[]"
if workers="$(gh api "repos/${GH_REPO}/actions/variables/POOL_WORKERS" --jq .value 2>/dev/null)" \
   && [[ -n "$workers" ]] \
   && printf '%s' "$workers" | jq empty >/dev/null 2>&1; then
    WORKERS_JSON="$(printf '%s' "$workers" | jq -c 'if type == "array" then . else [] end')"
else
    log WARN "POOL_WORKERS missing or unparseable — workers will be []"
fi

# --- 3. current state.json on the Gateway -> next serial ---
CURRENT_STATE=""
if current="$(ssh "${SSH_OPTS[@]}" "${GW_USER}@${GW_IP}" 'cat /var/lib/mylinuxpool/state.json 2>/dev/null' 2>/dev/null || true)" \
   && printf '%s' "$current" | jq empty >/dev/null 2>&1; then
    CURRENT_STATE="$current"
fi
if [[ -n "$CURRENT_STATE" ]]; then
    log INFO "read current state.json (serial $(printf '%s' "$CURRENT_STATE" | jq -r '.serial // "?"')) from ${GW_IP}"
else
    log WARN "no readable state.json on ${GW_IP} — starting serial at 1"
fi
SERIAL="$(state_next_serial "$CURRENT_STATE")"

# --- 4. build ---
PAYLOAD="$(state_build "$SERIAL" "$SOURCE" "$NODES_JSON" "$WORKERS_JSON")"

# --- 5. validate — never push a payload that violates the contract ---
if ! state_validate "$PAYLOAD"; then
    log ERROR "state_validate rejected the payload — nothing was pushed"
    exit 1
fi

# --- 6. install atomically on the Gateway ---
# The install snippet is a shell script (builtins like `umask`, `&&`
# short-circuiting), so it must run inside a shell: `sudo bash -c` runs
# the whole thing as root (profiles/gateway/default/cloud-config.yaml
# grants passwordless sudo) while stdin still flows to `cat >` inside the
# snippet. Plain `sudo umask ...` would only elevate the first word.
INSTALL_CMD="$(state_install_cmd "/var/lib/mylinuxpool/state.json")"
log INFO "pushing state (schema 1, serial ${SERIAL}, source ${SOURCE}) to ${GW_IP}"
if ! printf '%s\n' "$PAYLOAD" \
        | ssh "${SSH_OPTS[@]}" "${GW_USER}@${GW_IP}" "sudo bash -c $(printf '%q' "$INSTALL_CMD")"; then
    log ERROR "failed to install state.json on ${GW_IP} — readers trust this cache, so the workflow must fail"
    exit 1
fi
log INFO "state.json installed on ${GW_IP} (/var/lib/mylinuxpool/state.json, serial ${SERIAL})"
