# profiles/worker/default/Dockerfile — spec: docs/POOL_RUNTIME_SPEC.md §10.2,
# docs/LAYOUT.md §2 (profiles/worker/<name>/)
#
# Build from the REPO ROOT, not this directory:
#   docker build -f profiles/worker/default/Dockerfile -t mylinuxpool-worker-default .
# This COPYs pool-tunnel and pool-resolve straight from the pool-runtime
# shared-configs unit so the worker runs the exact same tunnel supervisor a
# provider does — not a duplicated copy — which needs a build context wide
# enough to reach shared-configs/.
#
# No secret ever gets baked in here (spec §7). WORKER_KEY,
# POOL_GATEWAY_PORT, POOL_NODE_NAME and GH_TOKEN / GH_WORKER_TOKEN all
# arrive at `docker run` time via -e / mounts — see entrypoint.sh. The
# list of who may log in arrives as a read-only mount, not an env var, so
# that it can keep changing after the container has started.

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server \
        ca-certificates \
        curl \
        git \
        jq \
        netcat-openbsd \
        rclone \
        gh \
        sudo \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/bash --groups sudo worker \
    && echo 'worker ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/worker \
    && chmod 440 /etc/sudoers.d/worker \
    && passwd -l root \
    && passwd -l worker

# Key-only auth, same hardening as the Gateway (POOL_RUNTIME_SPEC.md §9.2).
#
# AuthorizedKeysCommand reads the client list the provider bind-mounts at
# /run/mlp-clients, so a client added or REVOKED on GitHub reaches this
# worker on the provider's next pool-sync tick instead of being frozen at
# whatever was true when the container started. sshd requires the command
# to be root-owned and not group/world-writable — both guaranteed by the
# COPY below, which lands as root:root 0755.
COPY profiles/worker/default/worker-authkeys /usr/local/bin/worker-authkeys
RUN chmod 0755 /usr/local/bin/worker-authkeys \
    && mkdir -p /etc/ssh/sshd_config.d && { \
        echo 'PasswordAuthentication no'; \
        echo 'PermitRootLogin no'; \
        echo 'KbdInteractiveAuthentication no'; \
        echo 'AuthorizedKeysCommand /usr/local/bin/worker-authkeys'; \
        echo 'AuthorizedKeysCommandUser root'; \
    } > /etc/ssh/sshd_config.d/10-mylinuxpool.conf

COPY shared-configs/pool-runtime/files/pool-tunnel shared-configs/pool-runtime/files/pool-resolve \
     shared-configs/pool-runtime/files/tunnel-identity.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/pool-tunnel /usr/local/bin/pool-resolve

COPY profiles/worker/default/entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 22

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
