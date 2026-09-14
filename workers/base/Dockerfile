# workers/base/Dockerfile — spec: docs/POOL_RUNTIME_SPEC.md §10.2
#
# Build from the REPO ROOT, not this directory:
#   docker build -f workers/base/Dockerfile -t mylinuxpool-worker-base .
# This COPYs pool/bin/pool-tunnel and pool/bin/pool-resolve straight from
# the repo so the worker runs the exact same tunnel supervisor a provider
# does — not a duplicated copy — which needs a build context wide enough
# to reach pool/bin/.
#
# No secret ever gets baked in here (spec §7). WORKER_KEY,
# WORKER_AUTHORIZED_KEYS, POOL_GATEWAY_PORT, POOL_NODE_NAME and GH_TOKEN /
# GH_WORKER_TOKEN all arrive at `docker run` time via -e / mounts — see
# entrypoint.sh.

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
RUN mkdir -p /etc/ssh/sshd_config.d && { \
        echo 'PasswordAuthentication no'; \
        echo 'PermitRootLogin no'; \
        echo 'KbdInteractiveAuthentication no'; \
    } > /etc/ssh/sshd_config.d/10-mylinuxpool.conf

COPY pool/bin/pool-tunnel pool/bin/pool-resolve /usr/local/bin/
RUN chmod +x /usr/local/bin/pool-tunnel /usr/local/bin/pool-resolve

COPY workers/base/entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 22

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
