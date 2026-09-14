#!/usr/bin/env bash
# .github/actions/pool-ssh/run.sh — spec: docs/POOL_RUNTIME_SPEC.md §9.3
#
# Contract with the calling workflow:
#   - this repo must already be checked out (pool-resolve is read from
#     $GITHUB_WORKSPACE/shared-configs/pool-runtime/files/, not assumed to
#     be on PATH)
#   - GH_TOKEN must be exported (secrets.GITHUB_TOKEN or GH_POOL_TOKEN) so
#     pool-resolve can read NODE_* vars
#   - for every key_secret that could appear anywhere in the resolved hop
#     chain, an env var of that exact name must be exported with the
#     private key's contents (e.g. SSH_KEY_FH_L=${{ secrets.SSH_KEY_FH_L }}
#     at the job's `env:` level) — this action only ever consumes secrets
#     that are already in its process environment, it never references
#     `secrets.*` itself (composite actions can't).

set -euo pipefail

log() {
    local level="$1"; shift
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '[%s] %s %s\n' "$ts" "$level" "$*" >&2
}

NODE="${POOL_SSH_NODE:?POOL_SSH_NODE not set}"
COMMAND="${POOL_SSH_COMMAND:?POOL_SSH_COMMAND not set}"
TIMEOUT="${POOL_SSH_TIMEOUT:-10}"
export SSH_CONNECT_TIMEOUT="$TIMEOUT"

POOL_RESOLVE="${GITHUB_WORKSPACE:-.}/shared-configs/pool-runtime/files/pool-resolve"
if [[ ! -x "$POOL_RESOLVE" ]]; then
    POOL_RESOLVE="$(command -v pool-resolve || true)"
fi
if [[ -z "$POOL_RESOLVE" || ! -x "$POOL_RESOLVE" ]]; then
    log ERROR "pool-resolve not found under \$GITHUB_WORKSPACE/shared-configs/pool-runtime/files or on PATH"
    log ERROR "did the workflow check out this repo (actions/checkout) before calling pool-ssh?"
    exit 1
fi

SSH_LIB="${GITHUB_WORKSPACE:-.}/scripts/lib/ssh.sh"
if [[ ! -f "$SSH_LIB" ]]; then
    log ERROR "${SSH_LIB} not found — did the workflow check out this repo before calling pool-ssh?"
    exit 1
fi
# shellcheck source=../../../scripts/lib/ssh.sh
source "$SSH_LIB"

log INFO "resolving jump chain for node '${NODE}'"
hops_json="$("$POOL_RESOLVE" "$NODE" --expand-hops)"
rc=$?
if [[ $rc -ne 0 ]]; then
    log ERROR "pool-resolve ${NODE} --expand-hops failed (exit ${rc})"
    exit "$rc"
fi

hop_count="$(printf '%s' "$hops_json" | jq 'length')"
if [[ "$hop_count" -lt 1 ]]; then
    log ERROR "no hops resolved for node '${NODE}'"
    exit 1
fi

# Temporary ssh-agent for this step only — keys live in agent memory and
# are handed over via `ssh-add -` (stdin), so none of them ever touch disk.
eval "$(ssh-agent -s)" >/dev/null

STDOUT_FILE="$(mktemp)"
cleanup() {
    ssh-agent -k >/dev/null 2>&1 || true
    rm -f "$STDOUT_FILE"
}
trap cleanup EXIT

# Key loading is this script's own job (Actions-specific: each hop names
# an env var by key_secret, injected from secrets.* by the calling
# workflow) — scripts/lib/ssh.sh never loads keys itself, it only
# assembles and runs the chain once every needed identity is already in
# this agent.
final_user="" final_host="" final_port="22"
for (( i = 0; i < hop_count; i++ )); do
    hop="$(printf '%s' "$hops_json" | jq -c ".[$i]")"
    host="$(printf '%s' "$hop" | jq -r '.host')"
    port="$(printf '%s' "$hop" | jq -r '.port // 22')"
    user="$(printf '%s' "$hop" | jq -r '.user')"
    key_secret="$(printf '%s' "$hop" | jq -r '.key_secret')"

    key_value="${!key_secret:-}"
    if [[ -z "$key_value" ]]; then
        log ERROR "no env var named '${key_secret}' is set for hop #$((i + 1)) (${user}@${host}:${port})"
        log ERROR "the calling workflow must export every key_secret in the chain as an env var containing the private key"
        exit 1
    fi

    if ! printf '%s\n' "$key_value" | ssh-add - >/dev/null 2>&1; then
        log ERROR "ssh-add failed for key_secret '${key_secret}'"
        exit 1
    fi

    (( i == hop_count - 1 )) && { final_user="$user"; final_host="$host"; final_port="$port"; }
done

log INFO "running command on ${final_user}@${final_host}:${final_port} (${hop_count} hop(s), uniform trust)"

# stderr flows straight to the step's log, untouched. stdout is teed so it
# still shows up live in the log AND gets captured for callers that need
# the value programmatically (e.g. a port number printed by
# pool-port-alloc) — PIPESTATUS keeps `tee`'s own exit code from masking
# ssh's under `pipefail`.
set +e
ssh_jump_chain "$hops_json" "$COMMAND" | tee "$STDOUT_FILE"
rc="${PIPESTATUS[0]}"
set -e

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
        echo "stdout<<POOL_SSH_STDOUT_EOF"
        cat "$STDOUT_FILE"
        echo "POOL_SSH_STDOUT_EOF"
    } >> "$GITHUB_OUTPUT"
fi

exit "$rc"
