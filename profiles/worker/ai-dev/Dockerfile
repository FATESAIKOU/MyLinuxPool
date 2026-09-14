# profiles/worker/ai-dev/Dockerfile — spec: docs/POOL_RUNTIME_SPEC.md
# §10.2/§10.2b, docs/LAYOUT.md §2
#
# "default plus AI-agent development tools." Self-contained (not `FROM`
# the default worker image) so `docker build profiles/worker/ai-dev`
# works standalone on a provider with no cross-image build-order
# dependency — same reasoning as profiles/worker/default/Dockerfile,
# whose comments this mirrors.
#
# Build from the REPO ROOT:
#   docker build -f profiles/worker/ai-dev/Dockerfile -t mylinuxpool-worker-ai-dev .
#
# No secret ever gets baked in here (spec §7). Whatever this profile's
# profile.json declares (GH_TOKEN, ANTHROPIC_API_KEY, ...) arrives at
# `docker run` time via -e, same as WORKER_KEY / POOL_GATEWAY_* — see
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
        build-essential \
        python3 \
        python3-pip \
        python3-venv \
        nodejs \
        npm \
        ripgrep \
        vim \
        tmux \
        unzip \
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

COPY shared-configs/pool-runtime/files/pool-tunnel shared-configs/pool-runtime/files/pool-resolve /usr/local/bin/
RUN chmod +x /usr/local/bin/pool-tunnel /usr/local/bin/pool-resolve

COPY profiles/worker/ai-dev/entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 22

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
