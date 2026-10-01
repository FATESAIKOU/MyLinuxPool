#!/usr/bin/env bash
# scripts/lib/tunnel-key.sh — THE single implementation of "this machine
# mints its own tunnel identity and publishes the public half".
#
# WHY THIS FILE EXISTS (RUNBOOK §7.12, seventh incident): the rule lived
# only inside pool-sync's main(), so register-provider never got it. The
# consequence was not cosmetic — registering a NEW provider could not
# work at all:
#
#   step 7 starts pool-tunnel, which looks for ~/.ssh/id_tunnel
#     → a brand-new machine has no such file, so the tunnel never comes up
#   step 9 verifies the tunnel with ~/.ssh/id_pool
#     → the shared key deleted in KEY-DESIGN §8, so it fails regardless
#   step 9.5 enables pool-sync.timer, which WOULD have minted the key
#     → never reached: step 9 exits 1 first
#
# Both callers now use these functions. Failures return non-zero and the
# CALLER decides how fatal that is: pool-sync logs WARN and keeps
# converging (a running machine must never be broken by a bad tick),
# register-provider aborts (a registration that "succeeded" without a
# tunnel identity is a lie).
#
# Requires: TUNNEL_KEY (sourced from tunnel-identity.sh if unset), a `log`
# function, `gh` authenticated via GH_TOKEN in the environment.

# tunnel_key_identity_path — resolve TUNNEL_KEY without restating it.
#   The installed copy first, then the repo's; the path itself has exactly
#   one definition and it is not here.
tunnel_key_identity_path() {
    [[ -n "${TUNNEL_KEY:-}" ]] && return 0
    local ti
    for ti in "${HOME}/.mylinuxpool/bin/tunnel-identity.sh" \
              "${TUNNEL_KEY_REPO_DIR:-.}/shared-configs/pool-runtime/files/tunnel-identity.sh"; do
        if [[ -f "$ti" ]]; then
            # shellcheck source=/dev/null
            . "$ti"
            break
        fi
    done
    [[ -n "${TUNNEL_KEY:-}" ]]
}

# tunnel_key_mint <node_name>
#   Mints the tunnel key when absent and sets TUNNEL_KEY_PUB to its public
#   half. Deliberately NOT printed on stdout: pool-sync's `log` writes to
#   stdout (journald reads it), so a `$(tunnel_key_mint)` would capture log
#   lines and publish one of them as the public key — which is exactly what
#   happened the first time this was written.
#   Idempotent: an existing key is never regenerated — doing so would
#   invalidate the authorization the Gateway already holds and take the
#   machine's tunnel down until the next refresh.
tunnel_key_mint() {
    local node_name="${1:-unknown}"
    TUNNEL_KEY_PUB=""
    tunnel_key_identity_path || { log ERROR "cannot determine the tunnel key path (tunnel-identity.sh not found)"; return 1; }

    if [[ ! -f "$TUNNEL_KEY" ]]; then
        mkdir -p "$(dirname "$TUNNEL_KEY")"
        chmod 700 "$(dirname "$TUNNEL_KEY")" 2>/dev/null || true
        if ! ssh-keygen -t ed25519 -N "" -C "mlp-tunnel-${node_name}" -f "$TUNNEL_KEY" >/dev/null 2>&1; then
            log ERROR "could not generate ${TUNNEL_KEY}"
            return 1
        fi
        chmod 600 "$TUNNEL_KEY" 2>/dev/null || true
        log INFO "generated per-machine tunnel key ${TUNNEL_KEY}"
    fi

    TUNNEL_KEY_PUB="$(tr -d '\r\n' < "${TUNNEL_KEY}.pub" 2>/dev/null)"
    if [[ -z "$TUNNEL_KEY_PUB" ]]; then
        log ERROR "cannot read ${TUNNEL_KEY}.pub"
        return 1
    fi

    # Explicit. Without it the return value is whatever the `if` above
    # happens to leave behind, so adding a line below (a flag reset, a log)
    # would silently become this function's return value. Kept last on
    # purpose — do not append anything after it.
    return 0
}

# tunnel_key_publish <var_name> <repo> <public_key>
#   MERGES tunnel_public_key into NODE_<NAME>. Never writes the whole var:
#   overwriting hops/power/capabilities would take the machine offline.
#   Returns 0 and logs nothing new when the var already holds this key.
#
#   Also reports, in the global TUNNEL_KEY_CHANGED, whether THIS call
#   actually wrote: 0 on entry and on every early return, 1 only after the
#   write landed. The return code is unchanged and stays 0 on both success
#   paths — the flag is the only way to tell them apart, because
#   register-provider.sh treats any non-zero as fatal
#   (ops-scripts/register-provider.sh:670) and pool-sync used to read the
#   0 as "go dispatch a refresh" on every single tick.
#
#   Deliberately not `local`, and deliberately reset here rather than unset
#   by callers: the two call sites wrap this in a prefix assignment
#   (GH_TOKEN=…), whose shell semantics are not worth depending on.
tunnel_key_publish() {
    local var_name="$1" repo="$2" pub="$3"
    local current merged

    TUNNEL_KEY_CHANGED=0

    current="$(gh api "repos/${repo}/actions/variables/${var_name}" --jq .value 2>/dev/null || true)"
    if [[ -z "$current" ]] || ! printf '%s' "$current" | jq empty >/dev/null 2>&1; then
        log ERROR "cannot read ${var_name} — not publishing the tunnel key"
        return 1
    fi

    if [[ "$(printf '%s' "$current" | jq -r '.tunnel_public_key // empty')" == "$pub" ]]; then
        log INFO "tunnel_public_key already published for ${var_name}"
        return 0            # TUNNEL_KEY_CHANGED stays 0
    fi

    merged="$(printf '%s' "$current" | jq -c --arg pk "$pub" '. + {tunnel_public_key: $pk}')" || {
        log ERROR "could not merge tunnel_public_key into ${var_name}"
        return 1
    }
    if ! printf '%s' "$merged" | gh variable set "$var_name" --repo "$repo" >/dev/null 2>&1; then
        log ERROR "could not write tunnel_public_key into ${var_name}"
        return 1
    fi
    log INFO "published tunnel_public_key into ${var_name}"
    TUNNEL_KEY_CHANGED=1
}

# tunnel_key_ensure_published <node_name> <var_name> <repo>
#   Mint (if needed) + publish (if changed). The Gateway still has to
#   authorize it; who dispatches the refresh, and whether they wait for
#   it, is the caller's decision — pool-sync fires and forgets, while
#   register-provider must wait or its own verification races the refresh.
#
#   Passes TUNNEL_KEY_CHANGED straight through: the publish call below is
#   the last statement, so both its exit status and the flag arrive.
#   Nothing may be appended after that call — a `return 0` here would be
#   wrong for the same reason tunnel_key_mint needs an explicit one, and
#   swallowing the publish exit status would hide a failed write.
tunnel_key_ensure_published() {
    local node_name="$1" var_name="$2" repo="$3"
    tunnel_key_mint "$node_name" || return 1
    tunnel_key_publish "$var_name" "$repo" "$TUNNEL_KEY_PUB"
}
