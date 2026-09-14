#!/usr/bin/env bash
# scripts/rotate-gateway.sh — business logic for the Rotate Gateway flow
# (spec: docs/POOL_RUNTIME_SPEC.md §9.4, docs/ARCHITECTURE.md §5).
#
# A function library, sourced by .github/workflows/rotate-gateway.yml —
# not a single top-to-bottom script, because the workflow needs to react
# between steps (branch on dry_run, decide when to roll back, write
# ::notice::/::error::, read/write NODE_GATEWAY). Every function here:
#   - takes node info via arguments/env vars, never reads a GH secret or
#     var directly
#   - reports success/failure via exit code, progress via stdout/stderr
#   - when it computes something the workflow needs to persist (a new
#     NODE_GATEWAY value), prints it to stdout for the CALLER to
#     `gh variable set` — this file never calls gh itself
#
# No $GITHUB_OUTPUT, no ::error::/::notice::, no ${{ }}, no `gh variable
# set`/`gh api .../variables` — anywhere in this file (docs/LAYOUT.md §3).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"

# rotate_render_cloud_config <template> <fatesaikou_pubkey> <sshproxy_pubkey>
#   Prints the rendered cloud-config to stdout. envsubst itself is assumed
#   present (a runner-environment concern, not business logic).
rotate_render_cloud_config() {
    local template="$1" fatesaikou_pubkey="$2" sshproxy_pubkey="$3"
    FATESAIKOU_PUBKEY="$fatesaikou_pubkey" SSHPROXY_PUBKEY="$sshproxy_pubkey" \
        envsubst < "$template"
}

# rotate_create_preview_linode <region> <type> <image> <rendered_cloud_config_path>
#   Prints `preview_id=<id>` and `preview_ip=<ip>` on success (one per
#   line, KEY=value — the caller parses these into $GITHUB_OUTPUT itself).
rotate_create_preview_linode() {
    local region="$1" type="$2" image="$3" rendered="$4"
    local root_pass create_json preview_id preview_ip

    # A random password thrown away at the end of this function meant the
    # documented LISH break-glass path stopped working the moment a rotate
    # finished — the recorded password belonged to a machine that no longer
    # existed, and nobody knew the new one. Take it from the environment so
    # the same password survives every rotate and stays worth recording;
    # fall back to random only when the caller hasn't provided one, which
    # keeps the console path unusable but is no worse than before.
    if [[ -n "${GATEWAY_ROOT_PASS:-}" ]]; then
        root_pass="$GATEWAY_ROOT_PASS"
        log INFO "using the caller-supplied root password (LISH rescue stays valid)"
    else
        root_pass="$(openssl rand -base64 24 | tr -d '\n')"
        log WARN "GATEWAY_ROOT_PASS not set — generating a throwaway root password; LISH console rescue will NOT be possible on this machine"
    fi
    create_json="$(linode-cli linodes create \
        --no-defaults \
        --label fws-preview \
        --region "$region" \
        --type "$type" \
        --image "$image" \
        --root_pass "$root_pass" \
        --metadata.user_data "$(base64 -w0 < "$rendered")" \
        --json)"

    preview_id="$(jq -r '.[0].id' <<<"$create_json")"
    preview_ip="$(jq -r '.[0].ipv4[0]' <<<"$create_json")"

    if [[ -z "$preview_id" || "$preview_id" == "null" || -z "$preview_ip" || "$preview_ip" == "null" ]]; then
        log ERROR "linode-cli did not return an id/ip for the preview machine"
        return 1
    fi

    # >&2: this function's stdout is meant to be captured as KEY=value
    # pairs by the caller (often straight into $GITHUB_OUTPUT) — a log
    # line mixed into that stream would corrupt it.
    log INFO "created preview Linode ${preview_id} (${preview_ip})" >&2
    printf 'preview_id=%s\n' "$preview_id"
    printf 'preview_ip=%s\n' "$preview_ip"
}

# rotate_wait_for_ssh <user> <ip> [max_tries] [sleep_secs]
rotate_wait_for_ssh() {
    local user="$1" ip="$2" max_tries="${3:-60}" sleep_secs="${4:-5}"
    local i
    for (( i = 1; i <= max_tries; i++ )); do
        if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes \
                "${user}@${ip}" true 2>/dev/null; then
            log INFO "ssh reachable after ${i} attempt(s)"
            return 0
        fi
        sleep "$sleep_secs"
    done
    log ERROR "preview machine never became reachable over ssh"
    return 1
}

# rotate_wait_for_cloud_init <user> <ip> [timeout_secs]
#   ssh coming up only means sshd is alive — cloud-init can still be
#   installing packages (fail2ban included) in the background at that
#   point. provision-gateway.sh has failed against a still-provisioning
#   box for exactly this reason.
#
#   Prints the raw cloud-init output, then one of:
#     "STATUS=clean"     exit 0 — finished with no errors
#     "STATUS=degraded"  exit 0 — finished with recoverable errors, not
#                                 the same as a hard failure; caller may
#                                 want to surface this as a warning, but
#                                 it isn't fatal
#     "STATUS=timeout"   exit 1 — did not finish within timeout_secs
#     "STATUS=failed"    exit 1 — hard failure
rotate_wait_for_cloud_init() {
    local user="$1" ip="$2" timeout_secs="${3:-600}"
    local out rc

    log INFO "waiting for cloud-init to finish (up to ${timeout_secs}s)..."
    out="$(ssh -o StrictHostKeyChecking=accept-new "${user}@${ip}" \
        "sudo timeout ${timeout_secs} cloud-init status --wait --long" 2>&1)"
    rc=$?

    printf '%s\n' "$out"

    case "$rc" in
        0)
            log INFO "cloud-init finished cleanly"
            echo "STATUS=clean"
            return 0
            ;;
        2)
            log WARN "cloud-init finished in a degraded state (recoverable errors) — see output above"
            echo "STATUS=degraded"
            return 0
            ;;
        124)
            log ERROR "cloud-init did not finish within ${timeout_secs}s"
            ssh -o StrictHostKeyChecking=accept-new "${user}@${ip}" 'sudo cloud-init status --long' 2>&1 || true
            echo "STATUS=timeout"
            return 1
            ;;
        *)
            log ERROR "cloud-init failed (exit ${rc}) — see output above"
            echo "STATUS=failed"
            return 1
            ;;
    esac
}

# rotate_deploy_repo_bundle <user> <ip>
#   Ships shared-configs/ + scripts/ (still encrypted, decryption happens
#   per-unit on the Gateway inside provision-gateway.sh's own unit-install
#   calls) to the path provision-gateway.sh expects. Run from the repo
#   root — REPO_ROOT is derived from this file's own location.
rotate_deploy_repo_bundle() {
    local user="$1" ip="$2"
    local repo_root stage

    repo_root="$(cd "${SCRIPT_DIR}/.." && pwd)"
    stage="$(mktemp -d)"
    trap 'rm -rf "$stage"' RETURN

    cp -a "${repo_root}/shared-configs" "$stage/"
    cp -a "${repo_root}/scripts" "$stage/"

    scp -o StrictHostKeyChecking=accept-new -r "$stage" "${user}@${ip}:/tmp/mlp-repo"
    ssh -o StrictHostKeyChecking=accept-new "${user}@${ip}" \
        'sudo mkdir -p /home/fatesaikou/.mylinuxpool/repo && sudo cp -a /tmp/mlp-repo/. /home/fatesaikou/.mylinuxpool/repo/ && sudo rm -rf /tmp/mlp-repo'
}

# rotate_run_provision <user> <ip> <trusted_ips> <file_crypto_key>
#   The key never gets logged: no -x here, and the caller (a GH Actions
#   step) has both values masked in its own log regardless.
rotate_run_provision() {
    local user="$1" ip="$2" trusted_ips="$3" file_crypto_key="$4"
    local repo_root
    repo_root="$(cd "${SCRIPT_DIR}/.." && pwd)"

    ssh -o StrictHostKeyChecking=accept-new "${user}@${ip}" \
        "sudo env POOL_TRUSTED_IPS=$(printf '%q' "$trusted_ips") FILE_CRYPTO_KEY=$(printf '%q' "$file_crypto_key") bash -s" \
        < "${repo_root}/scripts/provision-gateway.sh"
}

# rotate_compute_new_gateway_json <old_json> <new_ip> <new_generation> <rotated_at>
#   Prints the new NODE_GATEWAY value to stdout — the caller writes it.
rotate_compute_new_gateway_json() {
    local old_json="$1" new_ip="$2" new_generation="$3" rotated_at="$4"
    jq -n \
        --argjson existing "$old_json" \
        --arg ip "$new_ip" \
        --argjson generation "$new_generation" \
        --arg rotated_at "$rotated_at" \
        '$existing * {ip: $ip, generation: $generation, rotated_at: $rotated_at}'
}

# rotate_wait_for_providers <gw_user> <gw_ip> <deadline_secs> <port...>
#   Polls each port's SSH banner over the new Gateway's own loopback,
#   exactly like pool-tunnel's own health check — a bare open port
#   doesn't prove the tunnel is actually there (spec §3.2).
rotate_wait_for_providers() {
    local gw_user="$1" gw_ip="$2" deadline_secs="$3"; shift 3
    local ports=("$@")

    if (( ${#ports[@]} == 0 )); then
        log WARN "no provider ports given — nothing to wait for"
        return 0
    fi

    log INFO "waiting for providers on port(s): ${ports[*]}"
    local deadline pending still_pending port banner
    deadline=$(( $(date +%s) + deadline_secs ))
    pending=("${ports[@]}")

    while (( ${#pending[@]} > 0 )) && (( $(date +%s) < deadline )); do
        still_pending=()
        for port in "${pending[@]}"; do
            banner="$(timeout 5 ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=3 \
                "${gw_user}@${gw_ip}" "timeout 1 nc 127.0.0.1 ${port} </dev/null | head -c 4" 2>/dev/null || true)"
            [[ "$banner" == SSH-* ]] || still_pending+=("$port")
        done
        pending=("${still_pending[@]}")
        (( ${#pending[@]} > 0 )) && sleep 5
    done

    if (( ${#pending[@]} > 0 )); then
        log ERROR "providers never came back on port(s): ${pending[*]}"
        return 1
    fi
    log INFO "all providers reconnected"
}

# rotate_promote_preview <old_label> <preview_id>
#   Deletes the distinct old Linode (if found) and relabels the preview.
#   Prints nothing the caller needs — it only needs the exit code.
rotate_promote_preview() {
    local old_label="$1" preview_id="$2"
    local old_id

    old_id="$(linode-cli linodes list --json | jq -r --arg l "$old_label" '.[] | select(.label == $l) | .id' | head -n1)"
    if [[ -n "$old_id" && "$old_id" != "$preview_id" ]]; then
        linode-cli linodes rm "$old_id"
        log INFO "deleted old Gateway linode ${old_id} (label ${old_label})"
    else
        log WARN "could not find a distinct old Linode labeled '${old_label}' to delete"
    fi

    linode-cli linodes update "$preview_id" --label "$old_label"
}

# rotate_cleanup_preview <preview_id>
rotate_cleanup_preview() {
    local preview_id="$1"
    if linode-cli linodes rm "$preview_id"; then
        log INFO "deleted preview linode ${preview_id}"
    else
        log WARN "could not delete preview linode ${preview_id} — the orphan sweep will catch it after 2h"
        return 1
    fi
}

# rotate_orphan_sweep [max_age_secs]
#   Deletes any Linode labeled '*-preview' older than max_age_secs
#   (default 2h) — cost protection for anything the two steps above
#   missed (a killed job, a crashed runner).
rotate_orphan_sweep() {
    local max_age_secs="${1:-7200}"
    local now_epoch label id created created_epoch age

    now_epoch=$(date +%s)
    linode-cli linodes list --json | jq -c '.[] | select(.label | endswith("-preview"))' | while read -r row; do
        label="$(jq -r '.label' <<<"$row")"
        id="$(jq -r '.id' <<<"$row")"
        created="$(jq -r '.created' <<<"$row")"
        created_epoch="$(date -u -d "$created" +%s)"
        age=$(( now_epoch - created_epoch ))
        if (( age > max_age_secs )); then
            log INFO "deleting orphan '${label}' (id ${id}), age ${age}s"
            linode-cli linodes rm "$id" || log WARN "failed to delete orphan '${label}' (id ${id})"
        fi
    done
}
