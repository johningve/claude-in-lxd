# claude-in-lxd

Run Claude Code (and similar agents) in `--permission-mode bypassPermissions` inside isolated LXD system containers, with full Docker-in-Docker and NVIDIA CUDA support.

Each git worktree gets its own LXD container. A shared byobu session provides a live dashboard and per-session windows for parallel agents.

## How it works

- **LXD system containers** (not VMs) give you a full init system, so Docker's daemon runs natively inside — no `--privileged` on the host.
- **`security.nesting=true`** enables nested Docker without host privilege escalation.
- **`nvidia.runtime=true`** injects the host's NVIDIA userspace libs into the container. `no-cgroups=true` inside the container allows `docker run --gpus all` to work in the nested, unprivileged context.
- **Same-path bind mounts** keep absolute symlinks (created by `gwt`) valid inside the container.
- **Claude hooks** write agent state to a host-visible file so `clxd status` reflects real activity.

## Host prerequisites

These must be set up once on your host before using `clxd`:

1. **LXD ≥ 5.21**
   ```bash
   snap install lxd
   lxd init --auto   # accept defaults; uses ZFS by default
   ```
   Verify: `lxc version`

2. **NVIDIA host driver** installed and working:
   ```bash
   nvidia-smi
   ```

3. **nvidia-container-toolkit on the host** (LXD's `nvidia.runtime` hook calls this):
   ```bash
   sudo apt-get install -y nvidia-container-toolkit
   ```
   If not in the Ubuntu repos, install from NVIDIA's apt repo (see [NVIDIA docs](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html)).

4. **byobu + tmux** on the host:
   ```bash
   sudo apt-get install -y byobu tmux
   ```

5. **jq** (used by `clxd status`):
   ```bash
   sudo apt-get install -y jq
   ```

6. **LXD profile** (one time):
   ```bash
   cd ~/src/claude-in-lxd
   lxc profile create claude-in-lxd
   lxc profile edit claude-in-lxd < profile.yaml
   ```

> **Note on storage pool:** The setup assumes ZFS or btrfs. If your LXD pool is `dir`-type, add these to `profile.yaml` before applying it:
> ```yaml
> config:
>   security.syscalls.intercept.mknod: "true"
>   security.syscalls.intercept.setxattr: "true"
> ```

## Installation

```bash
cd ~/src/claude-in-lxd

# Add bin/clxd to PATH (e.g. in ~/.config/fish/config.fish):
fish_add_path ~/src/claude-in-lxd/bin
```

## Build the base image

```bash
clxd build-image
```

This takes ~10 minutes (downloads Docker, NVIDIA toolkit, Node.js, claude). The resulting image is named `claude-in-lxd`.

### Build a project-specific image layer

For project-specific tooling (compilers, libraries, etc.), create a `setup.sh` and layer it on top:

```bash
# Use a private profile directory
clxd build-image zivid --from ~/.config/clxd/profiles/zivid
```

See `image/profiles/example/setup.sh` for a documented template.

To select the image for a repository automatically, place a `.clxd-image` file at the **main worktree root**:

```bash
echo claude-in-lxd-zivid > ~/src/zivid-sdk/.clxd-image
```

All worktrees created by `gwt` inherit this automatically (the main worktree is mounted read-only inside every linked-worktree container).

## Daily usage

### With gwt

Add this to your fish config for the full one-command workflow:

```fish
function gwtc
    gwt $argv; and clxd
end
```

Then:
```bash
gwtc ZIVID-12345-my-feature
# → worktree created, cd'd in, container launched, Claude running in auto mode
```

### Manual

```bash
gwt ZIVID-12345-my-feature
clxd                        # launches agent in the current worktree

# Or explicitly:
clxd launch ~/src/zivid-sdk/ZIVID-12345-my-feature
```

### View all sessions

```bash
# Status dashboard (one-shot):
clxd status

# Attach to byobu (dashboard is window 0, agents in subsequent windows):
byobu attach-session -t clxd

# Navigate between windows: Ctrl+a w   or   F3/F4
```

### Other commands

```bash
clxd shell                  # bash shell in current worktree's container
clxd exec . -- nvidia-smi  # run a command in the container
clxd exec . -- docker run --rm --gpus all nvidia/cuda:12.6.0-base-ubuntu24.04 nvidia-smi

clxd stop                   # stop container (fast restart later)
clxd destroy                # stop + delete container
clxd gc                     # remove containers whose worktree has been rm -rf'd
clxd gc --dry-run           # preview what gc would remove

clxd list-images            # show available claude-in-lxd* images
```

## Authentication

On every `clxd launch`, the tool copies your host Claude credentials into the container:

- `$CLAUDE_CONFIG_DIR/.credentials.json` → `/home/agent/.claude/.credentials.json`
- `$CLAUDE_CONFIG_DIR/.claude.json` → `/home/agent/.claude/.claude.json`

This mirrors what [`code-on-incus`](https://github.com/mensfeld/code-on-incus) does. Your host login state is reused; each container has its own independent copy (no shared-file races between parallel agents). Credentials are re-synced on each launch, so they stay fresh.

If no credentials file is found on the host, `ANTHROPIC_API_KEY` is forwarded from the host env if set. Otherwise, a warning is printed and you can run `claude` interactively inside the container's byobu window to log in.

The container is configured with `CLAUDE_CONFIG_DIR=/home/agent/.claude` to match this layout.

## Claude hooks and status

The base image ships hook scripts in `/opt/clxd/hooks/`. On first launch, a `~/.claude/settings.json` is seeded inside the container wiring these hooks to Claude Code events:

| Hook event | Agent state |
|---|---|
| `PreToolUse` | `working` |
| `Stop` | `idle` |
| `Notification` | `waiting` |

Hook scripts write to `/var/run/clxd/` inside the container, which is bind-mounted to `~/.cache/clxd/status/<container-name>/` on the host. `clxd status` reads these files directly — no `lxc exec` needed for the dashboard.

## Permission mode

`clxd` launches Claude with `--permission-mode bypassPermissions` by default (fully automated, appropriate for isolated containers). To change this, edit `CLXD_PERMISSION_MODE` near the top of `bin/clxd`:

```fish
set -g CLXD_PERMISSION_MODE acceptEdits   # auto-approve file edits, prompt for shell
```

## Worktree / gwt integration details

The `gwt` function creates worktrees as siblings of the main worktree and symlinks files from the main worktree using absolute host paths. To keep these symlinks valid inside the container, `clxd launch`:

- Bind-mounts the worktree at **the same host path** inside the container (e.g. `/home/johnio/src/zivid-sdk/ZIVID-12345-feature`).
- Bind-mounts the **main worktree** read-only at its host path (e.g. `/home/johnio/src/zivid-sdk/master`).

As a result, `git status`, paths in error messages, and compiler output all show the same paths inside and outside the container.

## Cleanup

When you're done with a branch:

```bash
rm -rf ~/src/zivid-sdk/ZIVID-12345-feature  # remove the worktree
clxd gc                                        # remove the now-orphan container
```

Or in one step: `clxd destroy` before removing the worktree.

## Known issues

- **Driver version**: LXD's `nvidia.runtime` hook binds the host's NVIDIA userspace into the container — driver versions automatically stay in sync.
- **First launch delay**: Docker takes a few seconds to start inside the container after boot. `clxd launch` polls up to 30s.
- **Parallel token refresh**: each container has its own copy of `.credentials.json`. Concurrent refreshes are independent. If Anthropic rotates the refresh token on use (rare), the second container to refresh may need to re-authenticate. Just run `clxd launch` again to re-push the host credentials.
- **byobu nesting**: if you run `clxd` from inside an existing tmux/byobu session, it prints the `select-window` command instead of nesting.
- **Dash window respawn**: `clxd dash` runs as a persistent window. If it crashes, select the window in byobu and it will restart.
