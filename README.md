# claude-in-lxd

Run Claude Code (and similar agents) in unattended `auto` permission mode inside isolated LXD system containers, with full Docker-in-Docker and NVIDIA CUDA support.

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
clxd update-profile         # re-apply profile.yaml to the live LXD profile
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

`clxd` launches Claude with no explicit `--permission-mode` flag. The behaviour is configured in `image/base/claude-settings.json`, which is seeded into `~/.claude/settings.json` on first boot:

```json
{
  "permissions": { "defaultMode": "auto" },
  "skipAutoPermissionPrompt": true
}
```

- `defaultMode: auto` — Claude's **auto mode** screens each proposed tool call through a separate model that classifies it as safe / needs-confirmation / refuse. Safe calls run without prompting; the rest fall through to a confirmation step.
- `skipAutoPermissionPrompt: true` — suppresses the human confirmation prompt for the auto-approved cases, leaving the screening model as the sole gate.

Auto mode is **not** the same as `bypassPermissions`. It adds a useful guard against obvious-mistake commands (`rm -rf $HOME`, `git push --force origin master`, exfiltration calls to unfamiliar domains, etc.) before they execute. However, the screening model reads the same conversation context as the main agent, so adversarial content that compromises the agent can plausibly also influence the screener. Treat it as **defence in depth**, not a replacement for the container boundary described in [Security model and known limitations](#security-model-and-known-limitations).

To restore interactive prompts for non-auto-approved calls, delete the `skipAutoPermissionPrompt` line in `image/base/claude-settings.json` and rebuild the image (or edit `~/.claude/settings.json` inside an existing container).

## Worktree / gwt integration details

The `gwt` function creates worktrees as siblings of the main worktree and symlinks files from the main worktree using absolute host paths. To keep these symlinks valid inside the container, `clxd launch`:

- Bind-mounts the worktree at **the same host path** inside the container (e.g. `/home/johnio/src/zivid-sdk/ZIVID-12345-feature`).
- Bind-mounts the **main worktree** read-only at its host path (e.g. `/home/johnio/src/zivid-sdk/master`).

As a result, `git status`, paths in error messages, and compiler output all show the same paths inside and outside the container.

### Compilation caches

When present on the host, two cache directories are bind-mounted into every
container so builds reuse work across containers and the host:

- `~/.ccache` (or `$CCACHE_DIR` if set) → `/home/agent/.ccache`
- `~/.cache/halide-cache` → `/home/agent/.cache/halide-cache`

Both are mounted read-write. Mounts are skipped silently if the host directory does not exist.

## Cleanup

When you're done with a branch:

```bash
rm -rf ~/src/zivid-sdk/ZIVID-12345-feature  # remove the worktree
clxd gc                                        # remove the now-orphan container
```

Or in one step: `clxd destroy` before removing the worktree.

## Security model and known limitations

`clxd` runs an unattended coding agent on real source code. The threat model it is designed for is **trusted repository, untrusted agent**: the code in the worktree is assumed safe to read and execute, but the agent itself may be steered by adversarial inputs (prompt injection from web pages, MCP tool output, package READMEs, error messages from third-party services) or simply make mistakes. The container is the primary boundary that limits the blast radius.

This section documents what the boundary does and does not cover, so callers can make informed decisions before pointing it at sensitive workloads.

### What the container blocks

- **Host root**. The LXD container is unprivileged (`raw.idmap` user-ns, no `--privileged`). `security.nesting=true` enables nested Docker without granting host privilege; the nested daemon is confined to the container's user namespace.
- **Most of the host filesystem**. The only host paths visible inside the container are: the worktree (rw, same path), the main worktree (**read-only**), `~/.cache/clxd/status/<container>/` (rw, per-container), and optionally `~/.ccache` / `~/.cache/halide-cache` (rw, shared). There is no blanket `$HOME` mount, no `~/.ssh`, no `~/.config/gh`, no `/etc`, no host Docker socket, and no LXD socket.
- **Cross-worktree contamination**. Each worktree gets its own container with its own filesystem and its own nested Docker daemon. A compromised agent in one container cannot reach another container's worktree, processes, or status files.
- **SSH / `gh` based git push to arbitrary remotes**. Neither the SSH agent nor the `gh` config is forwarded. HTTPS push would require credentials in `.git/config`, and the main worktree's `.git` is mounted read-only.
- **Host LXD API**. The `lxc` binary and the LXD UNIX socket are not present inside the container; the agent cannot enumerate, create, or destroy sibling containers.

### Known limitations

The following are intentional trade-offs or known gaps. They are listed so users with stricter threat models can decide whether `clxd` fits, and to mark them for future work.

1. **`raw.idmap: "both 1000 1000"`** maps the host user to the container's `agent` user one-to-one. This is required for bind-mounted worktree files to have correct ownership on both sides. The practical consequence is that within the bind-mounted paths the agent has the host user's effective rights — the protection comes from *which paths are mounted*, not from UID separation.
2. **Anthropic credentials are pushed into every container.** `~/.claude/.credentials.json` and `~/.claude.json` are copied into the container at mode 600 on every `clxd launch`. A compromised agent can exfiltrate the OAuth token (which is long-lived and shared with the host and every other `clxd` container) and read any MCP server URLs or secrets in `.claude.json`. The token's blast radius extends beyond the container that leaked it.
3. **`~/.docker/config.json` is forwarded.** Docker registry auth tokens reach the container so that `docker push` works for the user's own registries. A compromised agent can push images to those registries.
4. **Compilation caches are rw-shared.** When present, `~/.ccache` and `~/.cache/halide-cache` are bind-mounted rw into every container and remain rw on the host. ccache's content-hashed keys make blind poisoning hard, but a hostile agent in one container can in principle arrange to corrupt objects served to a sibling container or to host builds.
5. **No network egress filtering.** The container has unfiltered Internet access via `lxdbr0`. For the trusted-repo / hostile-agent threat model this is the largest single gap: exfiltrating any data the agent can read (source, ccache, the Anthropic token) requires only an outbound HTTP request. The auto-mode screening LLM provides some protection here, but it is not an authoritative egress filter.
6. **Resource caps are best-effort.** The profile sets `limits.cpu=16`, `limits.memory=32GiB`, and `limits.processes=4096`. These protect against a single container saturating the host CPU/RAM or fork-bombing, but they do not bound disk I/O, network bandwidth, or nested-Docker daemon memory beyond the cgroup parent. Tune via `lxc config set <name> limits.cpu …` or by editing `profile.yaml` and running `clxd update-profile`.
7. **Auto-mode is the only in-product gate.** `permissions.defaultMode: auto` + `skipAutoPermissionPrompt: true` means a separate screening model is the only check between the agent and the tool runtime. The screener catches obvious-mistake commands but shares conversation context with the main agent, so coordinated prompt-injection can plausibly bypass it. The container boundary is the authoritative gate.
8. **`agent` has passwordless sudo inside the container.** Necessary for ergonomic use of `apt`, but it means a malicious package postinstall reaches container-root immediately and can persistently modify `/etc/docker/daemon.json`, apt keyrings, etc. Damage stays inside the container, but a long-lived container becomes a stable foothold for subsequent agent runs in the same worktree.
9. **Read-only main worktree mount is structural, not authoritative.** It blocks direct edits to tracked files and to the canonical `.git/config`, but it does not by itself prevent `git fetch` / `git push` from inside a linked worktree. What prevents pushes today is the absence of forwarded credentials (see #2 and #3 for credentials that *are* forwarded).
10. **Builder containers use the same profile.** `clxd build-image` launches a builder container with the same `claude-in-lxd` LXD profile, including GPU passthrough, and runs `setup.sh` which downloads packages from the Internet. Build-time supply-chain compromise lands inside the resulting image and is reused by every subsequent `clxd launch`.
11. **GPU isolation relies on the NVIDIA driver.** `nvidia.runtime=true` injects the host userspace; there is no MIG partitioning or per-container GPU memory quota. Cross-process VRAM isolation depends on the driver.

### Possible hardening

In rough order of value for the stated threat model:

- **Egress allowlist on `lxdbr0`** (or a per-container nftables chain) covering `anthropic.com`, `registry.npmjs.org`, distro mirrors, GitHub API endpoints, and whatever the project's build chain needs. Closes the main exfiltration channel and shrinks the impact of items 2, 3, and 4.
- **Per-container short-lived OAuth tokens** instead of copying the host `.credentials.json`. Confines the token blast radius to one container's lifetime.
- **Mount ccache copy-on-write or read-only** with a per-container overlay for writes. Eliminates the cross-container poisoning channel without losing cache hits.
- **Conditional Docker config forwarding** — only mount `~/.docker/config.json` when the worktree opts in via `.clxd-image`-style marker, instead of for every container.

These are not on the project's current roadmap; PRs welcome.

## Known issues

- **Driver version**: LXD's `nvidia.runtime` hook binds the host's NVIDIA userspace into the container — driver versions automatically stay in sync.
- **First launch delay**: Docker takes a few seconds to start inside the container after boot. `clxd launch` polls up to 30s.
- **Parallel token refresh**: each container has its own copy of `.credentials.json`. Concurrent refreshes are independent. If Anthropic rotates the refresh token on use (rare), the second container to refresh may need to re-authenticate. Just run `clxd launch` again to re-push the host credentials.
- **byobu nesting**: if you run `clxd` from inside an existing tmux/byobu session, it prints the `select-window` command instead of nesting.
- **Dash window respawn**: `clxd dash` runs as a persistent window. If it crashes, select the window in byobu and it will restart.
