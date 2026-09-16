#!/usr/bin/env bash
# profiles/worker/<name>/entrypoint.sh — spec: docs/POOL_RUNTIME_SPEC.md §10.2/§10.3
# Runs as root (sshd needs root to bind :22, and pool-tunnel's reverse
# forward target is hardcoded to localhost:22 — same as a provider).
# Starts sshd, then hands off to pool-tunnel running as the unprivileged
# `worker` user.
#
# Everything here arrives via `docker run -e` / mounts, never baked into
# the image (spec §7). The tunnel private key is NOT in that list: this
# container mints its own (see below) so the private half never travels.
#   /run/mlp-clients       (read-only mount) the provider's assembled
#                          client list; sshd reads it through
#                          AuthorizedKeysCommand on every login
#   POOL_GATEWAY_PORT      this worker's assigned Gateway port (§10.3)
#   POOL_GATEWAY_HOST      Gateway IP — injected directly, no pool-resolve
#   POOL_GATEWAY_USER      Gateway tunnel_user (sshproxy) — same reason
#   POOL_NODE_NAME         (optional) throwaway node name, for logs only
#
# With all three POOL_GATEWAY_* set, pool-tunnel never calls pool-resolve
# and this container needs no GitHub credential at all for the tunnel
# (spec §10.2b/§10.3). Anything the workload itself needs (e.g. a GH
# token for an AI agent to push commits) comes from this image's own
# profiles/worker/<name>/profile.json, injected by create-worker.yml as whatever
# container env name the profile declares — entrypoint.sh has no
# involvement in that and no special-casing for any particular name.

set -euo pipefail

WORKER_HOME="/home/worker"

mkdir -p "${WORKER_HOME}/.ssh"
chmod 700 "${WORKER_HOME}/.ssh"

# The key path has ONE definition, shared with pool-tunnel — writing it
# here by hand is how the container ended up on id_pool while the host had
# moved to id_tunnel (KEY-DESIGN §8).
HOME="$WORKER_HOME" . /usr/local/bin/tunnel-identity.sh

# The tunnel key is MINTED HERE, in the container that will use it, and
# never leaves it — the same invariant every provider already follows
# (KEY-DESIGN §3.2). Before this it was minted by the create-worker
# workflow and handed over as `docker run -e WORKER_KEY=<private key>`,
# which put the private half in the provider's process listing, in
# `docker inspect` for the life of the container, and on the wire.
#
# Only the PUBLIC half leaves: create-worker reads ${TUNNEL_KEY}.pub back
# with `docker exec` and records it in POOL_WORKERS, which is what the
# Gateway refresh then authorizes. The tunnel therefore fails for the few
# seconds between this container starting and that refresh landing —
# pool-tunnel retries every 2s, so it connects as soon as the key is
# authorized, and `docker logs` shows the retries plainly.
#
# Only when absent: a restart (--restart unless-stopped) must keep the
# identity the Gateway has already authorized, or the worker would lock
# itself out of its own tunnel on every reboot of the provider.
if [[ ! -f "$TUNNEL_KEY" ]]; then
    ssh-keygen -t ed25519 -N "" -C "${POOL_NODE_NAME:-worker}" -f "$TUNNEL_KEY" >/dev/null \
        || { echo "FATAL: could not mint the worker tunnel key" >&2; exit 1; }
fi
chmod 600 "$TUNNEL_KEY"
chmod 644 "${TUNNEL_KEY}.pub"

# Who may log in is NOT written here any more. sshd asks
# /usr/local/bin/worker-authkeys, which reads the provider's read-only
# /run/mlp-clients mount on every login attempt — so adding or revoking a
# client reaches this container without recreating it.
#
# Removing a leftover static file matters as much as not writing one:
# sshd consults AuthorizedKeysFile *as well as* AuthorizedKeysCommand, so
# a file written by an older image would keep authorising a revoked key
# for the life of the container — the exact bug the mount replaces.
rm -f "${WORKER_HOME}/.ssh/authorized_keys"

if [[ ! -r /run/mlp-clients/authorized_keys ]]; then
    echo "WARNING: /run/mlp-clients/authorized_keys is not readable — nobody" \
         "will be able to log in as worker. The provider mounts it; a" \
         "provider running an older pool-runtime does not." >&2
fi

chown -R worker:worker "${WORKER_HOME}/.ssh"

# sshd's privilege-separation directory lives on tmpfs (/run) and does
# NOT survive from image build to container start — creating it in the
# Dockerfile is a no-op (2026-09-14 incident: container exited
# immediately with "Missing privilege separation directory: /run/sshd").
# /var/run is a compatibility symlink to /run on any Debian/Ubuntu-derived
# image; mkdir -p is harmless either way (real dir or through the symlink).
mkdir -p /run/sshd /var/run/sshd
chmod 0755 /run/sshd /var/run/sshd

# Host keys likewise aren't guaranteed to survive from build to a fresh
# container — ssh-keygen -A only (re)generates whichever are missing.
ssh-keygen -A

if ! /usr/sbin/sshd; then
    echo "FATAL: sshd failed to start — see the message above for why" >&2
    exit 1
fi

# Plain `su` (no `-`/login) updates HOME/USER for the target user but,
# unlike `su -`, does not reset the rest of the environment — so
# POOL_GATEWAY_PORT/HOST/USER, POOL_NODE_NAME, and anything profile.json
# injected all still reach pool-tunnel (and whatever workload runs here).
# `exec` replaces this script as PID 1, so if pool-tunnel itself ever
# exits, that exit code becomes the container's own — visible in
# `docker logs`/`docker inspect`, not swallowed.
exec su worker -c 'exec /usr/local/bin/pool-tunnel'
