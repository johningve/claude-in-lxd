#!/bin/bash
# Example profile setup script — copy and adapt for your project.
#
# Usage:
#   clxd build-image myprofile --from /path/to/this/dir
#
# This script runs INSIDE a container that already has the base image
# (docker.io, nvidia-container-toolkit, claude CLI, Node.js) installed.
# Add project-specific tooling here.
#
# Guidelines:
#   - Install as root; chown everything you put in /home/agent/ to 1000:1000
#   - Keep installs idempotent (apt handles this naturally)
#   - Clean up apt caches at the end to keep the image small

set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

# ── Example: add a custom apt repository and install packages ─────────────────
#
# curl -fsSL https://example.com/gpg | gpg --dearmor -o /usr/share/keyrings/example.gpg
# echo "deb [signed-by=/usr/share/keyrings/example.gpg] https://example.com/apt stable main" \
#   > /etc/apt/sources.list.d/example.list
# apt-get update -q
# apt-get install -y --no-install-recommends example-package

# ── Example: install a specific LLVM version ──────────────────────────────────
#
# curl -fsSL https://apt.llvm.org/llvm.sh | bash -s -- 21 all

# ── Example: install Python tooling as the agent user ─────────────────────────
#
# su -l agent -c 'pip install --user build twine'

# ── Clean up ──────────────────────────────────────────────────────────────────
apt-get clean
rm -rf /var/lib/apt/lists/*
