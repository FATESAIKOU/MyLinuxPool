#!/usr/bin/env bash
# .github/actions/pool-ssh/run.sh — spec: docs/POOL_RUNTIME_SPEC.md §9.3
#
# Contract with the calling workflow:
#   - this repo must already be checked out (pool-resolve is read from
#     $GITHUB_WORKSPACE/pool/bin/, not assumed to be on PATH)
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

POOL_RESOLVE="${GITHUB_WORKSPACE:-.}/pool/bin/pool-resolve"
if [[ ! -x "$POOL_RESOLVE" ]]; then
    POOL_RESOLVE="$(command -v pool-resolve || true)"
fi
if [[ -z "$POOL_RESOLVE" || ! -x "$POOL_RESOLVE" ]]; then
    log ERROR "pool-resolve not found under \$GITHUB_WORKSPACE/pool/bin or on PATH"
    log ERROR "did the workflow check out this repo (actions/checkout) before calling pool-ssh?"
    exit 1
fi

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

cleanup() {
    ssh-agent -k >/dev/null 2>&1 || true
}
trap cleanup EXIT

jump_specs=()
final_host="" final_port="22" final_user=""

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

    if (( i < hop_count - 1 )); then
        jump_specs+=("${user}@${host}:${port}")
    else
        final_host="$host"
        final_port="$port"
        final_user="$user"
    fi
done

ssh_args=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout="$TIMEOUT" -o BatchMode=yes)

if (( ${#jump_specs[@]} > 0 )); then
    jump_str="$(IFS=,; echo "${jump_specs[*]}")"
    ssh_args+=(-J "$jump_str")
fi

log INFO "running command on ${final_user}@${final_host}:${final_port} (${#jump_specs[@]} jump(s))"

# Deliberately not captured/wrapped: stdout/stderr flow straight to the
# step's log, and set -e lets ssh's own exit code end this script (the
# EXIT trap above still fires to kill the agent either way).
ssh "${ssh_args[@]}" -p "$final_port" "${final_user}@${final_host}" -- "$COMMAND"
