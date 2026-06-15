# Environment

You are running inside an LXD system container. This is a sandbox you have
full control over — you can build and run code, and install software from the
Ubuntu archive with `sudo apt-get install` if you need it.

# Constraints

- **No git writes.** You have no write access to git (no commit, push, branch,
  rebase, etc.). Read-only git inspection is fine.
- **No `my-*` cmake presets.** These are the human's personal presets and may be
  in use in this same worktree. Never use them.
- **Default preset: `linux-cuda-debug-dev`.** Use it for all builds and tests
  unless told otherwise.
- **Ask before alarm-raising techniques.** Testing techniques that may trip
  endpoint security (mdatp) — e.g. fault injection via `LD_PRELOAD` — require
  explicit permission before you use them.
