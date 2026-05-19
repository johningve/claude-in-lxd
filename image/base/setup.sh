#!/bin/bash
# Base image setup — runs inside a fresh ubuntu:26.04 LXD container.
# Installs: user `agent` (UID 1000), Docker, nvidia-container-toolkit,
# Node.js LTS, claude CLI, common dev tools, and clxd hook scripts.

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

# ── Docker snap (bundles engine, CLI, containerd, nvidia-container-toolkit) ────

# Wait for snapd to finish seeding before installing snaps
snap wait system seed.loaded

# The docker snap includes the NVIDIA container runtime — no separate toolkit install needed
# Create the docker group manually before starting the snap (snap does not create it automatically)
addgroup --system docker
adduser agent docker

snap install docker
snap start docker

# CRITICAL for unprivileged LXD containers: the outer LXD gpu device already
# handles cgroup access; the inner nvidia-container-runtime must NOT try to
# write cgroup device files itself.
# Try both the system path and common snap-internal paths.
for config in \
    /etc/nvidia-container-runtime/config.toml \
    /var/snap/docker/current/etc/nvidia-container-runtime/config.toml; do
    if [ -f "$config" ]; then
        sed -i 's/^#\?\s*no-cgroups\s*=.*/no-cgroups = true/' "$config"
        grep -q 'no-cgroups' "$config" || echo 'no-cgroups = true' >> "$config"
    fi
done

# Set nvidia as the default Docker runtime so --runtime=nvidia is not required.
DOCKER_DAEMON_JSON=/var/snap/docker/current/config/daemon.json
mkdir -p "$(dirname "$DOCKER_DAEMON_JSON")"
if [ -f "$DOCKER_DAEMON_JSON" ]; then
    jq '. + {"default-runtime": "nvidia"}' "$DOCKER_DAEMON_JSON" > "$DOCKER_DAEMON_JSON.tmp"
    mv "$DOCKER_DAEMON_JSON.tmp" "$DOCKER_DAEMON_JSON"
else
    echo '{"default-runtime": "nvidia"}' > "$DOCKER_DAEMON_JSON"
fi

# ── Node.js LTS (snap) ────────────────────────────────────────────────────────

snap install node --classic

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

# Hook scripts and settings were pushed to /opt/clxd-build/ by build.fish
if [ -d /opt/clxd-build/hooks ]; then
    cp -r /opt/clxd-build/hooks/. /opt/clxd/hooks/
    chmod +x /opt/clxd/hooks/*
fi

if [ -f /opt/clxd-build/claude-settings.json ]; then
    cp /opt/clxd-build/claude-settings.json /opt/clxd/claude-settings.json
fi

# The ~/.claude dir is created at first launch (per-container), not baked in.
# The settings.json template at /opt/clxd/claude-settings.json is seeded into
# ~/.claude/settings.json by clxd on first boot.

# ── Cleanup ───────────────────────────────────────────────────────────────────

apt-get clean
rm -rf /var/lib/apt/lists/* /opt/clxd-build /tmp/*

echo "Base image setup complete."
