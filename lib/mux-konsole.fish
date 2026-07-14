# mux-konsole.fish — konsole backend for the clxd multiplexer abstraction.
#
# clxd opens each agent as a konsole tab in the *current* window — the one clxd
# was invoked from. konsole injects that window's D-Bus coordinates into every
# session's environment ($KONSOLE_DBUS_SERVICE / $KONSOLE_DBUS_WINDOW), so tab
# creation needs no discovery. Liveness/lookup, however, sweeps *all* windows of
# the service (see __all_sessions): a user may move or open a clxd tab in another
# window, and the dashboard must still see it as alive. There is NO session
# persistence: closing a tab kills its agent, so the set of live tabs across all
# windows is authoritative.
#
# The slug is stored as the tab's title *format* (a literal with no '%' escapes),
# which doubles as a pinned display name and a lookup key we set and read back.

set -g _CLXD_QDBUS qdbus6

function _clxd_mux_konsole__require_window
    if test -z "$KONSOLE_DBUS_SERVICE" -o -z "$KONSOLE_DBUS_WINDOW"
        echo "clxd: not running inside a konsole tab (KONSOLE_DBUS_* unset)." >&2
        echo "      Launch clxd from a konsole window, or set CLXD_MUX=tmux." >&2
        return 1
    end
end

function _clxd_mux_konsole__win
    # Invoke a method on the current window object.
    $_CLXD_QDBUS $KONSOLE_DBUS_SERVICE $KONSOLE_DBUS_WINDOW $argv 2>/dev/null
end

function _clxd_mux_konsole__windows
    # All window object paths in the current konsole service. konsole exposes no
    # windowList method, so we scrape the introspected object tree for /Windows/N.
    $_CLXD_QDBUS $KONSOLE_DBUS_SERVICE 2>/dev/null | string match -r '^/Windows/[0-9]+$'
end

function _clxd_mux_konsole__all_sessions
    # Every session id across every window of the current konsole service.
    # A clxd tab may live in a different window than the dashboard, so liveness
    # detection must sweep them all — not just $KONSOLE_DBUS_WINDOW.
    for win in (_clxd_mux_konsole__windows)
        $_CLXD_QDBUS $KONSOLE_DBUS_SERVICE $win sessionList 2>/dev/null
    end
end

function _clxd_mux_konsole__session
    # Invoke a method on a session object: __session <id> <method> [args...]
    set id $argv[1]
    $_CLXD_QDBUS $KONSOLE_DBUS_SERVICE /Sessions/$id $argv[2..] 2>/dev/null
end

function _clxd_mux_konsole__slug_of
    # The clxd slug for a session id, or empty if it isn't a clxd tab.
    # We stored the slug as a literal title format; a '%' means it's a normal tab.
    set fmt (_clxd_mux_konsole__session $argv[1] tabTitleFormat 0)
    if test -n "$fmt"; and not string match -q '*%*' -- $fmt
        echo $fmt
    end
end

function _clxd_mux_konsole__locate
    # Locate the tab for slug $argv[1] across all windows.
    # Echoes the window path and session id on two lines on a match, or nothing.
    set want $argv[1]
    for win in (_clxd_mux_konsole__windows)
        for id in ($_CLXD_QDBUS $KONSOLE_DBUS_SERVICE $win sessionList 2>/dev/null)
            if test (_clxd_mux_konsole__slug_of $id) = "$want"
                printf '%s\n%s\n' $win $id
                return
            end
        end
    end
end

function _clxd_mux_konsole__id_of
    # The session id whose slug matches $argv[1], or empty.
    set found (_clxd_mux_konsole__locate $argv[1])
    test -n "$found"; and echo $found[2]
end

function _clxd_mux_konsole_open
    _clxd_mux_konsole__require_window; or return 1
    set slug $argv[1]
    set exec_cmd $argv[2]
    set cwd ""
    if test (count $argv) -ge 3
        set cwd $argv[3]
    end

    # Idempotent: bail if a tab for this slug already exists.
    set existing (_clxd_mux_konsole__id_of $slug)
    if test -n "$existing"
        return 0
    end

    # Empty profile → konsole's default profile; second arg is the start dir.
    if test -n "$cwd"
        set id (_clxd_mux_konsole__win newSession "" $cwd)
    else
        set id (_clxd_mux_konsole__win newSession)
    end
    if test -z "$id"
        echo "clxd: konsole failed to create a tab for $slug" >&2
        return 1
    end

    # Pin the slug as the tab title (both local and remote contexts) so it
    # survives shell-driven renames and serves as our lookup key.
    _clxd_mux_konsole__session $id setTabTitleFormat 0 $slug
    _clxd_mux_konsole__session $id setTabTitleFormat 1 $slug
    if not _clxd_mux_konsole__session $id runCommand $exec_cmd
        echo "clxd: konsole rejected runCommand (D-Bus API disabled)." >&2
        echo "      Enable: Settings → Configure Konsole → General →" >&2
        echo "      'Enable the security sensitive parts of the DBus API'." >&2
        return 1
    end
end

function _clxd_mux_konsole_launch_here
    # Run the agent in the tab clxd was invoked from, rather than a new tab.
    _clxd_mux_konsole__require_window; or return 1
    set slug $argv[1]
    set exec_cmd $argv[2]

    # If a live tab for this slug already exists elsewhere, focus it instead
    # of clobbering the current tab — preserves the idempotency of `open`.
    set existing (_clxd_mux_konsole__id_of $slug)
    if test -n "$existing"
        _clxd_mux_konsole__win setCurrentSession $existing
        return 0
    end

    _clxd_mux_konsole_name_self $slug
    eval $exec_cmd
end

function _clxd_mux_konsole_focus
    _clxd_mux_konsole__require_window; or return 1
    # Switch to the tab within the window that *owns* it. Calling
    # setCurrentSession on the wrong window makes konsole yank the tab into that
    # window instead of switching to it — hence we target the owning window.
    set found (_clxd_mux_konsole__locate $argv[1])
    test -z "$found"; and return 1
    $_CLXD_QDBUS $KONSOLE_DBUS_SERVICE $found[1] setCurrentSession $found[2] 2>/dev/null
end

function _clxd_mux_konsole_list
    _clxd_mux_konsole__require_window; or return 1
    for id in (_clxd_mux_konsole__all_sessions)
        set slug (_clxd_mux_konsole__slug_of $id)
        test -z "$slug"; and continue
        test "$slug" = dash; and continue   # the dashboard tab itself
        echo $slug
    end
end

function _clxd_mux_konsole_name_self
    # Pin a literal title on the tab clxd is running in (KONSOLE_DBUS_SESSION).
    _clxd_mux_konsole__require_window; or return 1
    test -z "$KONSOLE_DBUS_SESSION"; and return 1
    $_CLXD_QDBUS $KONSOLE_DBUS_SERVICE $KONSOLE_DBUS_SESSION setTabTitleFormat 0 $argv[1] 2>/dev/null
    $_CLXD_QDBUS $KONSOLE_DBUS_SERVICE $KONSOLE_DBUS_SESSION setTabTitleFormat 1 $argv[1] 2>/dev/null
end

function _clxd_mux_konsole_attach
    _clxd_mux_konsole__require_window; or return 1
    # Raising the konsole window to the foreground is deferred; for now just
    # switch to the tab within the current window if a slug is given.
    if test (count $argv) -gt 0
        _clxd_mux_konsole_focus $argv[1]
    end
end

function _clxd_mux_konsole_active_slug
    _clxd_mux_konsole__require_window; or return 1
    set id (_clxd_mux_konsole__win currentSession)
    test -z "$id"; and return
    _clxd_mux_konsole__slug_of $id
end
