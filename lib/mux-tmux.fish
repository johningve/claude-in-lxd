# mux-tmux.fish — tmux/byobu backend for the clxd multiplexer abstraction.
#
# Uses a single managed byobu session ($CLXD_TMUX_SESSION) with one window per
# agent slug, plus a pinned 'dash' window. Sessions persist across detach.
# Relies on globals from bin/clxd: CLXD_TMUX_SESSION, _CLXD_BIN.

function _clxd_mux_tmux__ensure_session
    # Lazily create the managed session with its pinned dash window.
    if not tmux has-session -t $CLXD_TMUX_SESSION 2>/dev/null
        # byobu new-session so byobu's tmux config loads from the start.
        # Absolute path so the non-interactive shell finds clxd regardless of PATH.
        byobu new-session -d -s $CLXD_TMUX_SESSION -n dash "$_CLXD_BIN dash"
        tmux set-option -t $CLXD_TMUX_SESSION:dash remain-on-exit on
        tmux set-hook -t $CLXD_TMUX_SESSION \
            'after-select-window' \
            "if-shell \"[ #\{window_name\} = dash ]\" \"respawn-window -k\""
    else
        if not tmux list-windows -t $CLXD_TMUX_SESSION -F '#{window_name}' 2>/dev/null \
                | grep -qx dash
            tmux new-window -t $CLXD_TMUX_SESSION: -n dash "$_CLXD_BIN dash"
            tmux set-option -t $CLXD_TMUX_SESSION:dash remain-on-exit on
        end
    end
end

function _clxd_mux_tmux_open
    set slug $argv[1]
    set exec_cmd $argv[2]
    set cwd ""
    if test (count $argv) -ge 3
        set cwd $argv[3]
    end

    _clxd_mux_tmux__ensure_session

    if not tmux list-windows -t $CLXD_TMUX_SESSION -F '#{window_name}' 2>/dev/null \
            | grep -qx $slug
        if test -n "$cwd"
            tmux new-window -t $CLXD_TMUX_SESSION: -n $slug -c $cwd $exec_cmd
        else
            tmux new-window -t $CLXD_TMUX_SESSION: -n $slug $exec_cmd
        end
        # Byobu enables automatic-rename globally; lock the name to the slug.
        tmux set-window-option -t "$CLXD_TMUX_SESSION:{end}" allow-rename off
    end
end

function _clxd_mux_tmux_launch_here
    # tmux has no "current tab" to take over the way konsole does (launch is
    # normally invoked from outside the managed session), so fall back to the
    # spawn-a-window-then-attach behaviour.
    _clxd_mux_tmux_open $argv
    _clxd_mux_tmux_attach $argv[1]
end

function _clxd_mux_tmux_focus
    set slug $argv[1]
    tmux select-window -t "$CLXD_TMUX_SESSION:$slug" 2>/dev/null
end

function _clxd_mux_tmux_list
    tmux list-windows -t $CLXD_TMUX_SESSION -F '#{window_name}' 2>/dev/null \
        | grep -vx dash
end

function _clxd_mux_tmux_attach
    set slug ""
    if test (count $argv) -gt 0
        set slug $argv[1]
    end

    if set -q TMUX
        echo "Already inside tmux. To switch to this session:"
        echo "  tmux switch-client -t $CLXD_TMUX_SESSION"
        if test -n "$slug"
            echo "  tmux select-window -t '$CLXD_TMUX_SESSION:$slug'"
        end
    else if test -n "$slug"
        byobu attach-session -t $CLXD_TMUX_SESSION \; select-window -t $slug
    else
        byobu attach-session -t $CLXD_TMUX_SESSION
    end
end

function _clxd_mux_tmux_name_self
    # Rename the current window and lock the name against byobu auto-rename.
    tmux rename-window $argv[1] 2>/dev/null
    tmux set-window-option allow-rename off 2>/dev/null
end

function _clxd_mux_tmux_active_slug
    tmux list-windows -t $CLXD_TMUX_SESSION \
        -F '#{window_active}#{window_name}' 2>/dev/null \
        | string replace -rf '^1' ''
end
