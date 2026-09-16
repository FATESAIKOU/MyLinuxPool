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
