# mux.fish — multiplexer abstraction for clxd
#
# clxd drives a terminal multiplexer to host agent sessions. This file defines
# the backend-agnostic contract and a thin router; each backend lives in its own
# lib/mux-<backend>.fish and implements the five operations below.
#
# Contract — every backend provides these functions:
#
#   _clxd_mux_<backend>_open   <slug> <cmd> [cwd]
#       Idempotently ensure a session named <slug> exists running <cmd>
#       (optionally started in <cwd>). No-op if it already exists.
#
#   _clxd_mux_<backend>_launch_here <slug> <cmd>
#       Run <cmd> in the session/tab clxd was invoked from, titling it <slug>,
#       rather than spawning a fresh one. If a live session named <slug>
#       already exists, focus that instead of clobbering the current tab.
#       Used by `clxd launch` so an interactive launch reuses your tab.
#
#   _clxd_mux_<backend>_focus  <slug>
#       Bring the session named <slug> to the foreground within the multiplexer.
#
#   _clxd_mux_<backend>_list
#       Print the slugs of all live sessions, one per line.
#
#   _clxd_mux_<backend>_attach [slug]
#       Attach to / foreground the multiplexer, optionally focusing <slug>.
#
#   _clxd_mux_<backend>_active_slug
#       Print the slug of the currently-focused session (empty if none / n/a).
#       Used to suppress notifications for the session the user is looking at.
#
#   _clxd_mux_<backend>_name_self <title>
#       Title the session/window clxd is currently running in (used by dash).
#
# Add a new backend by dropping in lib/mux-<name>.fish with these five
# functions and teaching _clxd_detect_mux about it.

function _clxd_detect_mux
    # Selection order:
    #   1. $CLXD_MUX explicit override (tmux | konsole | ...)
    #   2. Auto-detect from the environment we were invoked in
    #   3. Fallback: tmux
    if test -n "$CLXD_MUX"
        echo $CLXD_MUX
        return
    end
    if test -n "$KONSOLE_DBUS_SERVICE"
        echo konsole
        return
    end
    echo tmux
end

function _clxd_mux
    # Router: _clxd_mux <op> [args...] → _clxd_mux_<backend>_<op> [args...]
    set op $argv[1]
    set fn _clxd_mux_{$CLXD_MUX}_$op
    if not functions -q $fn
        echo "clxd: multiplexer backend '$CLXD_MUX' has no operation '$op'" >&2
        return 1
    end
    $fn $argv[2..]
end
