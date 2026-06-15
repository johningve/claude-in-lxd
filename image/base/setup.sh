#!/bin/bash
# Base image setup — runs inside a fresh ubuntu:26.04 LXD container.
# Installs: user `agent` (UID 1000), Docker (apt), nvidia-container-toolkit,
# claude CLI, common dev tools, and clxd hook scripts.

set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

# ── User ──────────────────────────────────────────────────────────────────────

# Remove ubuntu default user if it occupies UID 1000
if id ubuntu &>/dev/null && [ "$(id -u ubuntu)" = "1000" ]; then
    userdel -r ubuntu 2>/dev/null || true
fi

# Create agent user
if ! id agent &>/dev/null; then
    groupadd --gid 1000 agent
    useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash agent
fi

echo 'agent ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/agent
chmod 440 /etc/sudoers.d/agent

# ── Base packages ─────────────────────────────────────────────────────────────

apt-get update -q
apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    wget \
    git \
    git-lfs \
    build-essential \
    jq \
    fish \
    bash \
    sudo

# ── Docker engine + buildx + compose (Ubuntu apt repo) ───────────────────────

apt-get install -y --no-install-recommends \
    docker.io \
    docker-buildx \
    docker-compose-v2

# docker.io postinst creates the `docker` group; just add agent to it
adduser agent docker

# ── NVIDIA Container Toolkit (NVIDIA apt repo) ────────────────────────────────

curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list

apt-get update -q
apt-get install -y --no-install-recommends nvidia-container-toolkit

# Wire docker to use the nvidia runtime (writes /etc/docker/daemon.json)
nvidia-ctk runtime configure --runtime=docker

# CRITICAL for unprivileged LXD containers: the outer LXD gpu device handles
# cgroup access; the inner nvidia-container-runtime must NOT touch cgroups.
NVIDIA_RT_CONFIG=/etc/nvidia-container-runtime/config.toml
sed -i 's/^#\?\s*no-cgroups\s*=.*/no-cgroups = true/' "$NVIDIA_RT_CONFIG"
grep -q '^no-cgroups' "$NVIDIA_RT_CONFIG" || echo 'no-cgroups = true' >> "$NVIDIA_RT_CONFIG"

# Set nvidia as the default Docker runtime so --runtime=nvidia is not required.
DOCKER_DAEMON_JSON=/etc/docker/daemon.json
if [ -f "$DOCKER_DAEMON_JSON" ]; then
    jq '. + {"default-runtime": "nvidia"}' "$DOCKER_DAEMON_JSON" > "$DOCKER_DAEMON_JSON.tmp"
    mv "$DOCKER_DAEMON_JSON.tmp" "$DOCKER_DAEMON_JSON"
else
    mkdir -p "$(dirname "$DOCKER_DAEMON_JSON")"
    echo '{"default-runtime": "nvidia"}' > "$DOCKER_DAEMON_JSON"
fi

# Restart so the daemon picks up the new daemon.json (postinst already started it)
systemctl restart docker

# ── Claude CLI ────────────────────────────────────────────────────────────────

su -l agent -c 'curl -fsSL https://claude.ai/install.sh | bash'

# Make claude available system-wide via a symlink
CLAUDE_BIN=$(su -l agent -c 'which claude 2>/dev/null || ls ~/.local/bin/claude 2>/dev/null || ls ~/.npm-global/bin/claude 2>/dev/null || true')
if [ -n "$CLAUDE_BIN" ]; then
    ln -sf "$CLAUDE_BIN" /usr/local/bin/claude
fi

# ── clxd hook infrastructure ──────────────────────────────────────────────────

mkdir -p /opt/clxd/hooks
mkdir -p /opt/clxd-status          # bind-mounted from host; must exist in image

# Pre-create agent's ~/.cache so runtime bind-mounts (e.g. halide-cache) sit
# under an agent-owned parent, leaving room for other ~/.cache subdirs.
mkdir -p /home/agent/.cache
chown 1000:1000 /home/agent/.cache

# Hook scripts and settings were pushed to /opt/clxd-build/ by build.fish
if [ -d /opt/clxd-build/hooks ]; then
    cp -r /opt/clxd-build/hooks/. /opt/clxd/hooks/
    chmod +x /opt/clxd/hooks/*
fi

if [ -f /opt/clxd-build/claude-settings.json ]; then
    cp /opt/clxd-build/claude-settings.json /opt/clxd/claude-settings.json
fi

if [ -f /opt/clxd-build/CLAUDE.md ]; then
    cp /opt/clxd-build/CLAUDE.md /opt/clxd/CLAUDE.md
fi

# The ~/.claude dir is created at first launch (per-container), not baked in.
# The settings.json template at /opt/clxd/claude-settings.json is seeded into
# ~/.claude/settings.json by clxd on first boot.

# ── Cleanup ───────────────────────────────────────────────────────────────────

apt-get clean
rm -rf /var/lib/apt/lists/* /opt/clxd-build /tmp/*

echo "Base image setup complete."
