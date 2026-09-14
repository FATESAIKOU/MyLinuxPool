#!/usr/bin/env bash
# workers/base/entrypoint.sh — spec: docs/POOL_RUNTIME_SPEC.md §10.2/§10.3
# Runs as root (sshd needs root to bind :22, and pool-tunnel's reverse
# forward target is hardcoded to localhost:22 — same as a provider).
# Starts sshd, then hands off to pool-tunnel running as the unprivileged
# `worker` user.
#
# Everything here arrives via `docker run -e` / mounts, never baked into
# the image (spec §7):
#   WORKER_KEY             private key for pool-tunnel's reverse tunnel,
#                          written to ~worker/.ssh/id_pool (600)
#   WORKER_AUTHORIZED_KEYS (optional) public key(s) allowed to log in as
#                          `worker`, one per line
#   POOL_GATEWAY_PORT      this worker's assigned Gateway port (§10.3)
#   POOL_NODE_NAME         (optional) throwaway node name, for logs only
#   GH_WORKER_TOKEN        read-only PAT; mapped to GH_TOKEN below since
#                          that's the name gh/pool-resolve actually read

set -euo pipefail

WORKER_HOME="/home/worker"

if [[ -n "${GH_WORKER_TOKEN:-}" && -z "${GH_TOKEN:-}" ]]; then
    export GH_TOKEN="$GH_WORKER_TOKEN"
fi

mkdir -p "${WORKER_HOME}/.ssh"
chmod 700 "${WORKER_HOME}/.ssh"

if [[ -n "${WORKER_KEY:-}" ]]; then
    printf '%s\n' "$WORKER_KEY" > "${WORKER_HOME}/.ssh/id_pool"
    chmod 600 "${WORKER_HOME}/.ssh/id_pool"
else
    echo "WARNING: WORKER_KEY not set — pool-tunnel has no key to reverse-tunnel with" >&2
fi

if [[ -n "${WORKER_AUTHORIZED_KEYS:-}" ]]; then
    printf '%s\n' "$WORKER_AUTHORIZED_KEYS" > "${WORKER_HOME}/.ssh/authorized_keys"
    chmod 600 "${WORKER_HOME}/.ssh/authorized_keys"
fi

chown -R worker:worker "${WORKER_HOME}/.ssh"

ssh-keygen -A

/usr/sbin/sshd

# Plain `su` (no `-`/login) updates HOME/USER for the target user but,
# unlike `su -`, does not reset the rest of the environment — so
# POOL_GATEWAY_PORT / POOL_NODE_NAME / GH_TOKEN set above still reach
# pool-tunnel.
exec su worker -c 'exec /usr/local/bin/pool-tunnel'
