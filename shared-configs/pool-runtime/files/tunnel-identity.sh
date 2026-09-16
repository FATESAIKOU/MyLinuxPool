#!/usr/bin/env bash
# shared-configs/pool-runtime/files/tunnel-identity.sh — THE single
# definition of "which key a provider uses to dial the tunnel".
#
# WHY THIS FILE EXISTS (RUNBOOK §7.12, third time): the tunnel identity
# path was defined twice — pool-tunnel used ~/.ssh/id_tunnel while the
# rotate tunnel probe hard-coded ~/.ssh/id_pool, and the second rotate
# after KEY-DESIGN §8 failed with "Permission denied (publickey)" because
# the shared key had been deleted but the probe still asked for it. One
# rule, two implementations, only one got migrated.
#
# Every consumer of the tunnel identity sources THIS file and reads
# TUNNEL_KEY. Consumers: pool-tunnel (the real tunnel), pool-sync (mints
# and publishes the key), rotate-gateway's tunnel probe (must connect
# exactly like the real tunnel or the probe proves nothing). A grep for
# "id_tunnel" across the repo should find exactly one definition: here.

# Per-machine tunnel key (KEY-DESIGN §3.2): generated and published by
# pool-sync; the ONLY identity since the shared legacy key was deleted in
# §8 (MIGRATION completed — providers proved they connect with id_tunnel
# alone before the shared key was removed).
TUNNEL_KEY="${HOME}/.ssh/id_tunnel"

# CLIENT_KEY — the key an OPERATOR machine authenticates with as the admin
#   user. `mlp register client` creates ~/.ssh/id_mlp and publishes it as
#   CLIENT_<NAME>; id_rsa is the fallback for a client registered before
#   that flow existed.
#
#   ssh's built-in candidates (id_rsa, id_ed25519, ...) do NOT include
#   id_mlp, so anything connecting as the admin user must pass -i
#   explicitly. Leaving that to ssh's defaults is how `mlp` and
#   `pool-status` both started reporting Permission denied while a direct
#   `ssh -i ~/.ssh/id_mlp` worked fine — the fifth and sixth time one rule
#   had several implementations (RUNBOOK §7.12).
#
#   Empty when neither exists: a provider or worker has no client identity,
#   and callers fall back to their own behaviour.
CLIENT_KEY=""
for _mlp_client_key in "${HOME}/.ssh/id_mlp" "${HOME}/.ssh/id_rsa"; do
    if [[ -f "$_mlp_client_key" ]]; then
        CLIENT_KEY="$_mlp_client_key"
        break
    fi
done
unset _mlp_client_key
