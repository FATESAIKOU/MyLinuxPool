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

# create_worker_mint_tunnel_key
#   Generates a fresh ed25519 key pair for a worker (KEY-DESIGN §3.3:
#   workers get a NEW key on every create — the container dies with it,
#   no key reuse). Runs on the Actions runner, never on a provider.
#
#   Output, exactly two lines on stdout:
#     line 1: the PRIVATE key, base64-encoded
#     line 2: the PUBLIC key, one full line (type, blob, optional
#             comment — callers may overwrite the comment)
#
#   The key material is generated in a temp dir that is removed on every
#   exit path; the private key only ever leaves as base64 on stdout — it
#   is never written to a persistent file and never logged. Base64 is
#   used (rather than raw key bytes) so the caller can carry it through
#   a single step-output boundary without mangling newlines.
create_worker_mint_tunnel_key() {
    local tmp rc
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/mlp-worker-key.XXXXXX")" || return 1
    if ! ssh-keygen -t ed25519 -N "" -f "$tmp/id" >/dev/null 2>&1; then
        rm -rf "$tmp"
        log ERROR "ssh-keygen failed — cannot mint a worker tunnel key"
        return 1
    fi
    base64 < "$tmp/id"
    rc=$?
    cat "${tmp}/id.pub" || rc=1
    rm -rf "$tmp"
    return "$rc"
}

# create_worker_dispatch_refresh_and_wait [<timeout_seconds>]
#   Dispatches refresh-authorized-keys.yml and waits until the run is
#   ACTUALLY completed. Returns 0 iff the run finished with conclusion ==
#   "success"; non-zero on dispatch failure, timeout, or a non-success
#   conclusion — with timeout and failure messages distinguishable.
#
#   The poll waits for status == "completed" before ever reading the
#   conclusion. Breaking out on `status != "queued"` (the old bug) exits
#   the moment the run goes in_progress, and an in_progress run has no
#   conclusion yet — an empty value then got reported as '<unknown>' and
#   FAILED a refresh that had actually succeeded (real run 35047640983).
#   GH_REPO comes from the calling workflow's env (docs/LAYOUT.md §3:
#   the workflow is the thin caller).
create_worker_dispatch_refresh_and_wait() {
    local timeout_seconds="${1:-300}"
    # Overridable so tests can run a queued→in_progress→completed sequence
    # in seconds instead of the production default's ~10s+; the default
    # keeps production behaviour unchanged.
    local poll_interval="${POOL_REFRESH_POLL_INTERVAL:-5}"
    local repo="${GH_REPO:-}"
    local workflow="refresh-authorized-keys.yml"
    local deadline start now

    if [[ -z "$repo" ]]; then
        log ERROR "GH_REPO is not set — cannot dispatch ${workflow}"
        return 1
    fi

    start="$(date +%s)"
    deadline=$((start + timeout_seconds))

    if ! gh workflow run "$workflow" --repo "$repo" >/dev/null 2>&1; then
        log ERROR "could not dispatch ${workflow} (${repo})"
        return 1
    fi

    local run_id="" row status conclusion
    while :; do
        now="$(date +%s)"
        if (( now >= deadline )); then
            log ERROR "timed out after ${timeout_seconds}s waiting for ${workflow} to finish (still not completed)"
            return 1
        fi
        row="$(gh run list --workflow="$workflow" --repo "$repo" --limit 1 \
            --json databaseId,status --jq '.[0] | "\(.databaseId) \(.status)"' 2>/dev/null || true)"
        if [[ -z "$row" ]]; then
            # The dispatch was accepted but the run is not listed yet.
            sleep "$poll_interval"
            continue
        fi
        run_id="${row%% *}"
        status="${row#* }"
        if [[ "$status" == "completed" ]]; then
            break
        fi
        sleep "$poll_interval"
    done

    # `gh run view --json conclusion` returns an OBJECT in real gh; some
    # gh versions / test fakes return an ARRAY of the same record. Tolerate
    # both shapes so a conclusion read is never a null-by-mismatch.
    conclusion="$(gh run view "$run_id" --repo "$repo" --json conclusion --jq \
        'if type == "array" then .[0].conclusion else .conclusion end' 2>/dev/null || true)"
    if [[ "$conclusion" != "success" ]]; then
        log ERROR "refresh workflow ${run_id} finished with conclusion '${conclusion:-<unknown>}'"
        return 1
    fi
    log INFO "refresh workflow ${run_id} succeeded"
    return 0
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
#     <tunnel_user> <node_name> <worker_key> <authorized_keys_crypted> \
#     <file_crypto_key> <profile_json> <all_secrets_json>
#   Prints the assembled `docker run ...` command line to stdout.
#
#   Everything that touches a secret VALUE happens in here — worker_key,
#   the decrypted authorized_keys bundle, and every profile-declared
#   secret from all_secrets_json — precisely so no already-%q-quoted
#   secret ever has to cross a step-output boundary: a %q-quoted value
#   handed across `${{ steps.X.outputs.Y }}` gets re-interpreted as
#   literal shell source by whatever step reads it (GH Actions substitutes
#   that text before bash parses it), which would mangle anything
#   containing real escapes (a multi-line key, say) and can corrupt
#   $GITHUB_OUTPUT itself. Only the caller's OWN step may call this
#   function — its stdout must never be echoed back through a second
#   step boundary un-consumed.
#
#   WORKER_AUTHORIZED_KEYS is the SAME bundle used to log into the
#   Gateway (personal keys + SSH_KEY_ACTIONS' public half), never
#   something derived from the tunnel identity — sshproxy is the tunnel
#   identity, not an interactive-login one (2026-09-14 incident: workers
#   came up with only that key authorized, so the tunnel worked but
#   nobody could actually log in).
create_worker_build_run_cmd() {
    local container="$1" image_tag="$2" port="$3" gw_host="$4"
    local tunnel_user="$5" node_name="$6" worker_key="$7"
    local authorized_keys_crypted="$8" file_crypto_key="$9" profile_json="${10}" all_secrets_json="${11}"

    if [[ ! -f "$authorized_keys_crypted" ]]; then
        log ERROR "${authorized_keys_crypted} not found"
        return 1
    fi

    local authorized_keys_content
    authorized_keys_content="$("${SCRIPT_DIR}/lib/crypto.sh" decrypt "$file_crypto_key" < "$authorized_keys_crypted")"
    if [[ -z "$authorized_keys_content" ]]; then
        log ERROR "decrypting ${authorized_keys_crypted} produced no content — wrong FILE_CRYPTO_KEY?"
        return 1
    fi

    local container_q image_q port_q host_q tunnel_user_q node_name_q worker_key_q authorized_keys_q
    container_q="$(printf '%q' "$container")"
    image_q="$(printf '%q' "$image_tag")"
    port_q="$(printf '%q' "$port")"
    host_q="$(printf '%q' "$gw_host")"
    tunnel_user_q="$(printf '%q' "$tunnel_user")"
    node_name_q="$(printf '%q' "$node_name")"
    worker_key_q="$(printf '%q' "$worker_key")"
    authorized_keys_q="$(printf '%q' "$authorized_keys_content")"

    local cmd
    # Create the mount source first. Docker creates a missing bind-mount
    # source itself, as root — and then the provider's pool-tunnel, which
    # runs as the user, cannot write the file the worker is waiting for.
    cmd="mkdir -p \$HOME/.mylinuxpool/gateway; "
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
    cmd+=" -e POOL_GATEWAY_FILE=/run/mlp-gateway/gateway.json"
    cmd+=" -e POOL_GATEWAY_PORT=${port_q} -e POOL_GATEWAY_HOST=${host_q} -e POOL_GATEWAY_USER=${tunnel_user_q}"
    cmd+=" -e POOL_NODE_NAME=${node_name_q}"
    cmd+=" -e WORKER_KEY=${worker_key_q} -e WORKER_AUTHORIZED_KEYS=${authorized_keys_q}"

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
    local i out
    for (( i = 1; i <= max_tries; i++ )); do
        if out="$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes \
                -J "${gw_user}@${gw_ip}" -p "$port" worker@127.0.0.1 whoami 2>&1)"; then
            if [[ "$out" == "worker" ]]; then
                log INFO "authenticated ok (whoami=${out}) after ${i} attempt(s)"
                return 0
            fi
            log INFO "connected but got unexpected output from whoami: ${out}"
        fi
        sleep 2
    done
    log ERROR "could not authenticate as worker@127.0.0.1:${port} via ${gw_user}@${gw_ip} after ${max_tries} attempts"
    return 1
}
