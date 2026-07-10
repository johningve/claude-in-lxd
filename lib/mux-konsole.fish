# mux-konsole.fish — konsole backend for the clxd multiplexer abstraction.
#
# Each agent is a konsole tab in the *current* window — the one clxd was invoked
# from. konsole injects the D-Bus coordinates of that window into every session's
# environment ($KONSOLE_DBUS_SERVICE / $KONSOLE_DBUS_WINDOW), so no discovery is
# needed. There is NO session persistence: closing a tab kills its agent, so the
# set of live tabs (sessionList) is authoritative.
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

function _clxd_mux_konsole__id_of
    # The session id whose slug matches $argv[1], or empty.
    set want $argv[1]
    for id in (_clxd_mux_konsole__win sessionList)
        set got (_clxd_mux_konsole__slug_of $id)
        if test "$got" = "$want"
            echo $id
            return
        end
    end
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

function _clxd_mux_konsole_focus
    _clxd_mux_konsole__require_window; or return 1
    set id (_clxd_mux_konsole__id_of $argv[1])
    test -z "$id"; and return 1
    _clxd_mux_konsole__win setCurrentSession $id
end

function _clxd_mux_konsole_list
    _clxd_mux_konsole__require_window; or return 1
    for id in (_clxd_mux_konsole__win sessionList)
        set slug (_clxd_mux_konsole__slug_of $id)
        test -n "$slug"; and echo $slug
    end
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
