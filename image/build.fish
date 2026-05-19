#!/usr/bin/env fish
# Builds the claude-in-lxd base image, and optionally a profile layer on top.
#
# Usage:
#   fish image/build.fish                     # build base image
#   fish image/build.fish <profile>           # build base, then layer profile
#   fish image/build.fish <profile> --from <dir>  # use profile dir outside repo

set -g SCRIPT_DIR (dirname (realpath (status --current-filename)))
set -g REPO_DIR (dirname $SCRIPT_DIR)

function die
    echo "Error: $argv" >&2
    exit 1
end

# ── Parse args ────────────────────────────────────────────────────────────────

set profile ""
set profile_dir ""

set i 1
while test $i -le (count $argv)
    switch $argv[$i]
        case --from
            set i (math $i + 1)
            set profile_dir $argv[$i]
        case --help -h
            echo "Usage: fish image/build.fish [<profile>] [--from <dir>]"
            echo ""
            echo "  Builds 'claude-in-lxd' base image (Ubuntu 24.04 + Docker + NVIDIA + claude)."
            echo "  With <profile>: also builds 'claude-in-lxd-<profile>' on top of the base."
            echo "  --from <dir>: use this directory as the profile dir instead of image/profiles/<profile>/."
            exit 0
        case '*'
            if test -z "$profile"
                set profile $argv[$i]
            else
                die "Unexpected argument: $argv[$i]"
            end
    end
    set i (math $i + 1)
end

# ── Resolve profile dir ───────────────────────────────────────────────────────

if test -n "$profile"
    if test -z "$profile_dir"
        set profile_dir $REPO_DIR/image/profiles/$profile
    end
    if not test -d "$profile_dir"
        die "Profile directory not found: $profile_dir"
    end
    if not test -f "$profile_dir/setup.sh"
        die "No setup.sh found in profile dir: $profile_dir"
    end
end

# ── Helpers ───────────────────────────────────────────────────────────────────

function require_lxc_profile
    if not lxc profile list | grep -q "^| claude-in-lxd "
        echo "LXD profile 'claude-in-lxd' not found. Creating it..."
        lxc profile create claude-in-lxd
        lxc profile edit claude-in-lxd < $REPO_DIR/profile.yaml
        echo "Profile created."
    end
end

function cleanup_builder
    set name $argv[1]
    echo "Cleaning up builder container $name..."
    lxc stop --force $name 2>/dev/null; or true
    lxc delete $name 2>/dev/null; or true
end

function push_dir_to_container
    # Push a host directory's contents into a container path using tar.
    # Note: compute all fish substitutions before the bash -c string, because
    # fish does NOT expand (cmd) inside double-quoted strings.
    set host_dir $argv[1]
    set container $argv[2]
    set container_path $argv[3]

    set tmptar /tmp/clxd-build-(random).tar.gz
    set tmpbase (basename $tmptar)
    set host_parent (dirname $host_dir)
    set host_base (basename $host_dir)

    tar -czf $tmptar -C $host_parent $host_base
    lxc file push $tmptar $container/tmp/$tmpbase
    lxc exec $container -- bash -c "
        set -e
        mkdir -p $container_path
        tar -xzf /tmp/$tmpbase -C $container_path --strip-components=1
        rm /tmp/$tmpbase
    "
    rm -f $tmptar
end

# ── Build base image ──────────────────────────────────────────────────────────

set base_builder clxd-build-base
set base_alias claude-in-lxd

require_lxc_profile

# Remove stale builder if exists
if lxc info $base_builder > /dev/null 2>&1
    echo "Removing stale builder $base_builder..."
    cleanup_builder $base_builder
end

# Remove stale published image (lxc image delete is a no-op if alias is absent)
lxc image delete $base_alias 2>/dev/null; or true

echo "Launching builder: $base_builder (ubuntu:26.04)..."
lxc launch ubuntu:26.04 $base_builder --profile default --profile claude-in-lxd

echo "Waiting for container to boot..."
for i in (seq 1 20)
    if lxc exec $base_builder -- test -S /run/dbus/system_bus_socket 2>/dev/null
        break
    end
    sleep 2
end

echo "Pushing base image files..."
push_dir_to_container $REPO_DIR/image/base $base_builder /opt/clxd-build

echo "Running setup.sh (this will take several minutes)..."
lxc exec $base_builder -- bash /opt/clxd-build/setup.sh

echo "Stopping builder..."
lxc stop $base_builder

echo "Publishing image as '$base_alias'..."
lxc publish $base_builder --alias $base_alias \
    description="claude-in-lxd base (Docker + NVIDIA + claude)"

echo "Removing builder container..."
lxc delete $base_builder

echo ""
echo "Base image '$base_alias' built successfully."

# ── Build profile layer (if requested) ───────────────────────────────────────

if test -z "$profile"
    exit 0
end

set profile_builder clxd-build-$profile
set profile_alias claude-in-lxd-$profile

echo ""
echo "Building profile layer '$profile' → image '$profile_alias'..."

# Remove stale builder
if lxc info $profile_builder > /dev/null 2>&1
    echo "Removing stale builder $profile_builder..."
    cleanup_builder $profile_builder
end

lxc image delete $profile_alias 2>/dev/null; or true

echo "Launching profile builder from '$base_alias'..."
lxc launch $base_alias $profile_builder --profile default --profile claude-in-lxd

echo "Waiting for container to boot..."
for i in (seq 1 20)
    if lxc exec $profile_builder -- systemctl is-system-running --quiet 2>/dev/null
        break
    end
    sleep 2
end

echo "Pushing profile files from $profile_dir..."
push_dir_to_container $profile_dir $profile_builder /opt/clxd-build

echo "Running profile setup.sh..."
lxc exec $profile_builder -- bash /opt/clxd-build/setup.sh

echo "Stopping profile builder..."
lxc stop $profile_builder

echo "Publishing image as '$profile_alias'..."
lxc publish $profile_builder --alias $profile_alias \
    description="claude-in-lxd + $profile profile"

echo "Removing profile builder container..."
lxc delete $profile_builder

echo ""
echo "Profile image '$profile_alias' built successfully."
echo ""
echo "To use: echo $profile_alias > /path/to/repo/.clxd-image"
echo "Then: clxd launch /path/to/worktree"
