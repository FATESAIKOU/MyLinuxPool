#!/usr/bin/env bash
# scripts/lib/ssh.sh — jump-chain assembly and execution.
#
# Runs anywhere bash+ssh+jq exist, Mac included — sourced by
# ops-scripts/mlp (human operator, interactive) and
# .github/actions/pool-ssh/run.sh (CI runner) so neither writes its own
# copy of this. Key loading is NOT this file's job: mlp uses existing
# local key files, pool-ssh loads secret values into a temporary
# ssh-agent — those differ too much to share, so every function here
# assumes whatever identity a hop needs is already reachable (an
# ssh-agent at $SSH_AUTH_SOCK, or an -i the caller adds itself).
#
# TRUST MODEL for ssh_gateway_only / ssh_via_gateway (mlp's 2026-09-14
# fix, preserved here verbatim):
#   - The Gateway is a stable identity between rotates — verified against
#     a caller-supplied DEDICATED known_hosts file, never the operator's
#     own ~/.ssh/known_hosts. Rotating the Gateway changes its host key on
#     purpose; polluting the real known_hosts would make a future rotate
#     look like a MITM attack right when the operator most needs in.
#   - 127.0.0.1:<port> (anything past the Gateway — provider or worker)
#     is NOT a stable identity: ports get reused for a different
#     container, and it's always 127.0.0.1 regardless of who's actually
#     listening. Recording a host key for it would be pure false
#     confidence, so it's never checked, on purpose.
#   - This is why the second hop uses `-o ProxyCommand=...` wrapping a
#     fully separate ssh invocation for the Gateway leg, not `-J`: `-J`
#     applies the SAME options to every hop, which can't express "verify
#     the Gateway, don't verify past it".

# ssh_gateway_only <known_hosts> <user> <host> <port> [remote_cmd...]
#   Direct connection to the Gateway itself — the node being reached IS
#   the Gateway, no second hop. With no remote_cmd, connects interactively.
ssh_gateway_only() {
    local known_hosts="$1" user="$2" host="$3" port="$4"; shift 4
    ssh -o UserKnownHostsFile="$known_hosts" -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout="${SSH_CONNECT_TIMEOUT:-10}" -o BatchMode="${SSH_BATCH_MODE:-yes}" \
        -p "$port" "${user}@${host}" "$@"
}

# ssh_via_gateway <known_hosts> <gw_user> <gw_host> <gw_port> <dst_user> <dst_host> <dst_port> [remote_cmd...]
#   One hop past the Gateway (provider/worker at 127.0.0.1:<port>), mixed
#   trust as described above. With no remote_cmd, connects interactively.
ssh_via_gateway() {
    local known_hosts="$1" gw_user="$2" gw_host="$3" gw_port="$4"
    local dst_user="$5" dst_host="$6" dst_port="$7"; shift 7
    ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR \
        -o ConnectTimeout="${SSH_CONNECT_TIMEOUT:-10}" -o BatchMode="${SSH_BATCH_MODE:-yes}" \
        -o ProxyCommand="ssh -o UserKnownHostsFile=${known_hosts} -o StrictHostKeyChecking=accept-new -o ConnectTimeout=${SSH_CONNECT_TIMEOUT:-10} -p ${gw_port} -W %h:%p ${gw_user}@${gw_host}" \
        -p "$dst_port" "${dst_user}@${dst_host}" "$@"
}

# ssh_jump_chain <hops_json> [remote_cmd...]
#   Arbitrary-depth chain with UNIFORM trust (every hop accept-new, no
#   dedicated known_hosts) — right for an ephemeral CI runner reaching
#   into the cluster, wrong for the mixed-trust human-operator case above
#   (never use this for an interactive human session). Builds `ssh -J
#   hop1,hop2,...,hopN-1 <hopN>` from hops_json — an array of
#   {host,port,user} objects, e.g. from `pool-resolve <node>
#   --expand-hops`. Assumes every needed identity is already in the
#   ssh-agent at $SSH_AUTH_SOCK (this library never loads keys itself).
ssh_jump_chain() {
    local hops_json="$1"; shift
    local hop_count
    hop_count="$(printf '%s' "$hops_json" | jq 'length')"
    if [[ -z "$hop_count" || "$hop_count" -lt 1 ]]; then
        echo "ssh_jump_chain: empty or malformed hop chain" >&2
        return 1
    fi

    local jump_specs=() final_host="" final_port="22" final_user=""
    local i hop host port user
    for (( i = 0; i < hop_count; i++ )); do
        hop="$(printf '%s' "$hops_json" | jq -c ".[$i]")"
        host="$(printf '%s' "$hop" | jq -r '.host')"
        port="$(printf '%s' "$hop" | jq -r '.port // 22')"
        user="$(printf '%s' "$hop" | jq -r '.user')"
        if (( i < hop_count - 1 )); then
            jump_specs+=("${user}@${host}:${port}")
        else
            final_host="$host"; final_port="$port"; final_user="$user"
        fi
    done

    local ssh_args=(-o StrictHostKeyChecking=accept-new -o BatchMode=yes
                     -o ConnectTimeout="${SSH_CONNECT_TIMEOUT:-10}")
    if (( ${#jump_specs[@]} > 0 )); then
        local jump_str
        jump_str="$(IFS=,; echo "${jump_specs[*]}")"
        ssh_args+=(-J "$jump_str")
    fi

    ssh "${ssh_args[@]}" -p "$final_port" "${final_user}@${final_host}" -- "$@"
}
