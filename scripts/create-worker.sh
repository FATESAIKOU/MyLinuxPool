#!/usr/bin/env bash
# scripts/create-worker.sh — business logic for the Create Worker flow
# (spec: docs/POOL_RUNTIME_SPEC.md §10.4, docs/ARCHITECTURE.md §5).
#
# A function library, sourced by .github/workflows/create-worker.yml.
# Every remote command still goes through .github/actions/pool-ssh (which
# itself uses scripts/lib/ssh.sh) — this file only builds the command
# STRINGS and does the pure decision-making; it never runs anything on a
# remote node itself, and never calls gh / references ${{ }} / touches
# $GITHUB_OUTPUT (docs/LAYOUT.md §3).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"
# shellcheck source=lib/profile.sh
source "${SCRIPT_DIR}/lib/profile.sh"
# shellcheck source=lib/ledger.sh
source "${SCRIPT_DIR}/lib/ledger.sh"

# A copy of this file may be sourced from an injected location where the
# relative lib/ paths no longer resolve (e.g. a test that sed-mutates the
# file and sources it from a temp dir). Without this fallback, log() would
# be undefined and an ERROR call would hit macOS's /usr/bin/log with the
# level word as a subcommand ("Unknown subcommand 'ERROR'"). Only defines
# when the lib source above actually provided nothing.
declare -F log >/dev/null 2>&1 || log() { printf '[%s] %s\n' "$1" "${*:2}" >&2; }

# create_worker_validate_name <value> <field-name>
#   image/name feed straight into remote command text and file paths
#   elsewhere — constrain the character set at this one boundary so every
#   later use is safe by construction (no quotes, `$`, `/`, etc.).
create_worker_validate_name() {
    local value="$1" field="$2"
    if [[ -n "$value" ]] && ! [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]]; then
        log ERROR "'${field}' must match ^[A-Za-z0-9._-]+\$, got '${value}'"
        return 1
    fi
}

# create_worker_compute_identity <provider> <image> <run_id> <name_input>
#   Prints name=/image_tag=/container= lines.
create_worker_compute_identity() {
    local provider="$1" image="$2" run_id="$3" name_input="$4"
    local name="$name_input"
    [[ -n "$name" ]] || name="${provider}-${image}-${run_id}"
    printf 'name=%s\n' "$name"
    printf 'image_tag=mlp-worker-%s\n' "$image"
    printf 'container=mlp-%s\n' "$name"
}

# create_worker_read_pubkey_cmd <container> [tries]
#   Builds the command that reads the worker's OWN tunnel public key back
#   off the provider. The worker mints its key inside the container
#   (profiles/worker/*/entrypoint.sh) so the private half never travels —
#   this is the only thing that crosses back, and it is public.
#
#   Waits rather than reading once: the key is minted during container
#   startup, so a read issued immediately after `docker run -d` races it.
#
#   The path is NOT written here. tunnel-identity.sh inside the container
#   is the one definition of which file holds the tunnel key, and this
#   sources it exactly like pool-tunnel does (RUNBOOK §7.12). HOME is set
#   explicitly because `docker exec` does not reliably inherit the target
#   user's home, and tunnel-identity.sh builds its paths from it.
create_worker_read_pubkey_cmd() {
    local container="$1" tries="${2:-30}"
    local container_q; container_q="$(printf '%q' "$container")"
    printf '%s' "for i in \$(seq 1 ${tries}); do \
k=\"\$(docker exec -e HOME=/home/worker -u worker ${container_q} \
bash -c '. /usr/local/bin/tunnel-identity.sh; cat \"\${TUNNEL_KEY}.pub\"' 2>/dev/null || true)\"; \
case \"\$k\" in ssh-*) printf '%s\\n' \"\$k\"; exit 0;; esac; \
sleep 1; done; \
echo 'worker never produced a tunnel public key' >&2; exit 1"
}

# dispatch_refresh_and_wait lives in scripts/lib/refresh-wait.sh — the
# SINGLE implementation of "dispatch refresh-authorized-keys.yml and wait
# for it to actually complete" (RUNBOOK §7.12, fourth incident: the same
# wait logic existed in create-worker.sh and register-client, only one of
# them fixed). create_worker_dispatch_refresh_and_wait below is kept as a
# thin alias so existing callers/tests keep working.
# shellcheck source=lib/refresh-wait.sh
source "${SCRIPT_DIR}/lib/refresh-wait.sh"

# create_worker_dispatch_refresh_and_wait [<timeout_seconds>]
#   Thin alias of dispatch_refresh_and_wait (scripts/lib/refresh-wait.sh).
#   Dispatches refresh-authorized-keys.yml and waits until the run is
#   ACTUALLY completed. Returns 0 iff the run finished with conclusion ==
#   "success"; non-zero on dispatch failure, timeout, or a non-success
#   conclusion — with timeout and failure messages distinguishable.
#   GH_REPO comes from the calling workflow's env (docs/LAYOUT.md §3:
#   the workflow is the thin caller).
create_worker_dispatch_refresh_and_wait() {
    dispatch_refresh_and_wait "$@"
}

# create_worker_missing_secrets <profile_json> <all_secrets_json>
#   Prints the name of every profile-declared secret NOT present in
#   all_secrets_json, one per line. No values are ever printed — only
#   presence is checked (a %q-quoted secret value must never cross a
#   step-output boundary; see create_worker_build_run_cmd for where the
#   actual values get used, in the same step that has them).
create_worker_missing_secrets() {
    local profile_json="$1" all_secrets_json="$2"
    local container_var secret_name val
    while IFS=$'\t' read -r container_var secret_name; do
        [[ -z "$container_var" ]] && continue
        val="$(jq -r --arg n "$secret_name" '.[$n] // empty' <<<"$all_secrets_json")"
        [[ -z "$val" ]] && printf '%s\n' "$secret_name"
    done < <(profile_secrets "$profile_json")
}

# create_worker_ledger_add <workers_json> <port> <provider> <image>
#     <container> <created_at> <tunnel_public_key> <profile_json>
#   Prints the new POOL_WORKERS array: ledger_add, plus the image profile's
#   capabilities copied into the entry (CAPABILITY-DESIGN.md §3 — consumers
#   reading POOL_WORKERS do not have to read the profile; a profile without
#   the field yields `{}`, the "declared no capabilities" object, never
#   null). A non-object capabilities is rejected rather than coerced.
#   Worker capabilities are **not verified** here (spec.md:75) — this runs on
#   an Actions runner, where a real check would call the GitHub API for a
#   worker. So it copies the declaration and does not touch the runner.
create_worker_ledger_add() {
    local workers_json="$1" port="$2" provider="$3" image="$4"
    local container="$5" created_at="$6" tunnel_public_key="$7" profile_json="$8"
    local caps
    # profile_capabilities 做形狀檢查：非 object 就回 1 並印 'is not an object'。
    caps="$(profile_capabilities "$profile_json")" || return 1
    ledger_add "$workers_json" "$port" "$provider" "$image" "$container" \
        "$created_at" "$tunnel_public_key" "$caps"
}

# create_worker_build_claim_cmd <port_lo> <port_hi> <provider> <image>
#   Prints the command to run on the Gateway to claim a worker port.
#   pool-port-alloc is installed at ~/.mylinuxpool/bin/ there
#   (shared-configs/pool-runtime's install.sh, called from
#   provision-gateway.sh) — called directly rather than shipping the
#   script's own text over as a `bash -c` string: under `-c`,
#   $BASH_SOURCE isn't a real path, which broke pool-port-alloc's own
#   SCRIPT_DIR-relative lookup of pool-resolve (2026-09-14 incident). The
#   Gateway holds no GitHub credential of its own (spec §10.2b), so the
#   (non-secret) port range is handed in via POOL_WORKER_PORT_RANGE
#   instead of letting pool-port-alloc call pool-resolve/gh remotely —
#   it can't, there either.
create_worker_build_claim_cmd() {
    local port_lo="$1" port_hi="$2" provider="$3" image="$4"
    local range_q provider_q image_q
    range_q="$(printf '%q' "${port_lo} ${port_hi}")"
    provider_q="$(printf '%q' "$provider")"
    image_q="$(printf '%q' "$image")"
    printf 'POOL_WORKER_PORT_RANGE=%s ~/.mylinuxpool/bin/pool-port-alloc --claim %s %s\n' \
        "$range_q" "$provider_q" "$image_q"
}

# create_worker_build_run_cmd <container> <image_tag> <port> <gw_host> \
#     <tunnel_user> <node_name> <authorized_keys_content> \
#     <profile_json> <all_secrets_json>
#   Prints the assembled `docker run ...` command line to stdout.
#
#   Everything that touches a secret VALUE happens in here — worker_key,
#   and every profile-declared secret from all_secrets_json — precisely
#   so no already-%q-quoted secret ever has to cross a step-output
#   boundary: a %q-quoted value handed across `${{ steps.X.outputs.Y }}`
#   gets re-interpreted as literal shell source by whatever step reads it
#   (GH Actions substitutes that text before bash parses it), which would
#   mangle anything containing real escapes (a multi-line key, say) and
#   can corrupt $GITHUB_OUTPUT itself. Only the caller's OWN step may
#   call this function — its stdout must never be echoed back through a
#   second step boundary un-consumed.
#
#   WORKER_AUTHORIZED_KEYS is the assembled login list for the worker's
#   `worker` account (the same list every machine takes from CLIENT_* via
#   authkeys_assemble — KEY-DESIGN §3.2, no static encrypted bundles since
#   §8). It is the interactive-login list, never something derived from
#   the tunnel identity — sshproxy is the tunnel identity, not an
#   interactive-login one (2026-09-14 incident: workers came up with only
#   that key authorized, so the tunnel worked but nobody could actually
#   log in).
create_worker_build_run_cmd() {
    local container="$1" image_tag="$2" port="$3" gw_host="$4"
    local tunnel_user="$5" node_name="$6"
    local authorized_keys_content="$7" profile_json="$8" all_secrets_json="$9"

    if [[ -z "$authorized_keys_content" ]]; then
        log ERROR "the assembled client list is empty — refusing to start a worker nobody can log into"
        return 1
    fi

    local container_q image_q port_q host_q tunnel_user_q node_name_q
    container_q="$(printf '%q' "$container")"
    image_q="$(printf '%q' "$image_tag")"
    port_q="$(printf '%q' "$port")"
    host_q="$(printf '%q' "$gw_host")"
    tunnel_user_q="$(printf '%q' "$tunnel_user")"
    node_name_q="$(printf '%q' "$node_name")"

    # The client list travels as base64: `base64` on a Linux runner wraps
    # at 76 columns and `-w0` is GNU-only, so the newlines come off with
    # tr — a wrapped value silently truncates at the first line when it
    # lands in a single-line context (RUNBOOK §7.13).
    local ak_b64
    ak_b64="$(printf '%s\n' "$authorized_keys_content" | base64 | tr -d '\n')"

    local cmd
    # Create the mount sources first. Docker creates a missing bind-mount
    # source itself, as root — and then the provider's pool-tunnel, which
    # runs as the user, cannot write the file the worker is waiting for.
    cmd="mkdir -p \$HOME/.mylinuxpool/gateway \$HOME/.mylinuxpool/clients; "
    # Who may log in arrives as a FILE the provider keeps current, not as
    # an env var frozen at creation time. pool-sync rewrites it from the
    # CLIENT_* vars every tick, so revoking a client actually reaches the
    # workers already running here. Seeded now so the mount is correct
    # from the container's first second, before the next sync tick.
    cmd+="printf '%s' ${ak_b64} | base64 -d > \$HOME/.mylinuxpool/clients/authorized_keys; "
    cmd+="chmod 600 \$HOME/.mylinuxpool/clients/authorized_keys; "
    cmd+="docker rm -f ${container_q} >/dev/null 2>&1; docker run -d --restart unless-stopped --name ${container_q}"
    # The provider's own pool-tunnel publishes the Gateway it is currently
    # attached to into ~/.mylinuxpool/gateway/. Mount that directory
    # read-only and point the container at it, so the worker follows a
    # rotate instead of freezing at the address it was started with — and
    # still carries no GitHub credential of its own.
    #
    # The DIRECTORY is mounted, not the file: publish_gateway writes a temp
    # file and renames it, which replaces the inode. A file bind-mount
    # would keep pointing at the old one and the worker would never see an
    # update.
    #
    # HOST/USER are still passed as a fallback for the first moments before
    # the file exists, and for a provider running an older pool-runtime.
    cmd+=" -v \$HOME/.mylinuxpool/gateway:/run/mlp-gateway:ro"
    cmd+=" -v \$HOME/.mylinuxpool/clients:/run/mlp-clients:ro"
    cmd+=" -e POOL_GATEWAY_FILE=/run/mlp-gateway/gateway.json"
    cmd+=" -e POOL_GATEWAY_PORT=${port_q} -e POOL_GATEWAY_HOST=${host_q} -e POOL_GATEWAY_USER=${tunnel_user_q}"
    cmd+=" -e POOL_NODE_NAME=${node_name_q}"
    # No key of any kind on this command line. The container mints its
    # own tunnel identity at startup and only its public half ever leaves
    # (create_worker_read_pubkey_cmd) — so nothing here shows up in the
    # provider's `ps`, in `docker inspect`, or in a workflow log.

    local container_var secret_name val literal_val
    while IFS=$'\t' read -r container_var secret_name; do
        [[ -z "$container_var" ]] && continue
        val="$(jq -r --arg n "$secret_name" '.[$n] // empty' <<<"$all_secrets_json")"
        cmd+=" -e $(printf '%q' "${container_var}=${val}")"
    done < <(profile_secrets "$profile_json")

    while IFS=$'\t' read -r container_var literal_val; do
        [[ -z "$container_var" ]] && continue
        cmd+=" -e $(printf '%q' "${container_var}=${literal_val}")"
    done < <(profile_env "$profile_json")

    cmd+=" ${image_q}"
    printf '%s\n' "$cmd"
}

# create_worker_verify_reachable <gw_user> <gw_ip> <port> [max_tries]
#   A bare SSH banner only proves *something* is listening and speaking
#   SSH — it doesn't prove anyone can actually get in (2026-09-14
#   incident: this reported success on a worker whose authorized_keys
#   held only the tunnel identity, so the banner was real but every human
#   login failed). Same lesson as pool-tunnel's own health check upgrade
#   from `nc -z` to reading the banner (spec §3.2) — verify all the way to
#   the thing that's actually being relied on: a real authenticated
#   connection through the Gateway, running a command. Assumes the
#   caller's ssh-agent already holds whatever identity is needed.
create_worker_verify_reachable() {
    local gw_user="$1" gw_ip="$2" port="$3" max_tries="${4:-30}"
    # The Gateway's own SSH port, for the -J hop. Defaults to 22; note that
    # -J takes the port inside the destination spec (user@host:port), NOT
    # via -p — -p belongs to the final hop, the worker's loopback port.
    local gw_port="${5:-22}"
    local i out
    for (( i = 1; i <= max_tries; i++ )); do
        if out="$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes \
                -J "${gw_user}@${gw_ip}:${gw_port}" -p "$port" worker@127.0.0.1 whoami 2>&1)"; then
            if [[ "$out" == "worker" ]]; then
                log INFO "authenticated ok (whoami=${out}) after ${i} attempt(s)"
                return 0
            fi
            log INFO "connected but got unexpected output from whoami: ${out}"
        fi
        sleep 2
    done
    log ERROR "could not authenticate as worker@127.0.0.1:${port} via ${gw_user}@${gw_ip}:${gw_port} after ${max_tries} attempts"
    return 1
}
