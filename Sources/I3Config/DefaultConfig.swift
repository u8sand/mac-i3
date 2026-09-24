// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 mac-i3 contributors

import Foundation

public enum DefaultConfig {
    /// The built-in default, used when there is no ~/.config/mac-i3/config.
    public static let text = """
    # mac-i3 default configuration (i3 syntax).
    #
    # To customise, save a copy as ~/.config/mac-i3/config and reload with Control+Option+C.
    # `mac-i3 default-config stock` prints i3's own stock key bindings instead.

    # ---- Modifier ------------------------------------------------------------------------
    # $super is a text variable used in the bindings below. Option and Mod1 are the same key,
    # Command is Mod4; combine keys with + (for example Mod1+Shift).
    set $super Option

    # ---- Look ----------------------------------------------------------------------------
    # Gap between windows (inner) and around the edge of each display (outer), in pixels.
    gaps inner 10
    gaps outer 2

    # ---- Window rules --------------------------------------------------------------------
    # Float every new window (each keeps the size and position its app gave it):
    # for_window [class=".*"] floating enable

    # ---- Workspaces and displays ---------------------------------------------------------
    # `output 1` is the primary display, `output 2` the next one, and so on from left to right
    # (see `mac-i3 outputs`). A workspace whose display is not connected lives on the primary
    # display and moves to its own when that display is plugged in.
    workspace 1 output 1
    workspace 2 output 2
    workspace 3 output 1
    workspace 4 output 2
    workspace 5 output 1
    workspace 6 output 2
    workspace 7 output 1
    workspace 8 output 2
    workspace 9 output 1
    workspace 10 output 2

    # ---- Applications --------------------------------------------------------------------
    # Terminal, VS Code and Chrome, each in a new window. Edit to taste.
    bindsym $super+t exec open -na Terminal
    bindsym $super+c exec code -n
    bindsym $super+w exec open -na "Google Chrome"

    # ---- Windows -------------------------------------------------------------------------
    # Close the focused window / float or tile it.
    bindsym $super+q kill
    bindsym $super+z floating toggle

    # Move focus.
    bindsym $super+Left focus left
    bindsym $super+Down focus down
    bindsym $super+Up focus up
    bindsym $super+Right focus right

    # Move the focused window.
    bindsym $super+Shift+Left move left
    bindsym $super+Shift+Down move down
    bindsym $super+Shift+Up move up
    bindsym $super+Shift+Right move right

    # ---- Workspaces ----------------------------------------------------------------------
    # Switch to a workspace.
    bindsym $super+1 workspace number 1
    bindsym $super+2 workspace number 2
    bindsym $super+3 workspace number 3
    bindsym $super+4 workspace number 4
    bindsym $super+5 workspace number 5
    bindsym $super+6 workspace number 6
    bindsym $super+7 workspace number 7
    bindsym $super+8 workspace number 8
    bindsym $super+9 workspace number 9
    bindsym $super+0 workspace number 10

    # Move the focused window to a workspace.
    bindsym $super+Shift+1 move container to workspace number 1
    bindsym $super+Shift+2 move container to workspace number 2
    bindsym $super+Shift+3 move container to workspace number 3
    bindsym $super+Shift+4 move container to workspace number 4
    bindsym $super+Shift+5 move container to workspace number 5
    bindsym $super+Shift+6 move container to workspace number 6
    bindsym $super+Shift+7 move container to workspace number 7
    bindsym $super+Shift+8 move container to workspace number 8
    bindsym $super+Shift+9 move container to workspace number 9
    bindsym $super+Shift+0 move container to workspace number 10

    # ---- Layout (Control+Option) -----------------------------------------------------------
    # Fullscreen; split so the next window opens below (v) or beside (h); tabbed; toggle split.
    bindsym Control+$super+Enter fullscreen toggle
    bindsym Control+$super+Down split v
    bindsym Control+$super+Right split h
    bindsym Control+$super+Tab layout tabbed
    bindsym Control+$super+Up layout toggle split
    bindsym Control+$super+Left layout toggle split

    # ---- mac-i3 (Control+Option) -----------------------------------------------------------
    bindsym Control+$super+c reload
    bindsym Control+$super+r restart
    bindsym Control+$super+e exit

    # ---- Not bound by default (remove the # to use) -----------------------------------------
    # Move focus with the home row too (i3's j k l ;):
    # bindsym $super+j focus left
    # bindsym $super+k focus down
    # bindsym $super+l focus up
    # bindsym $super+semicolon focus right
    #
    # Stacked layout, focus the parent container, jump between tiled and floating windows:
    # bindsym Control+$super+s layout stacking
    # bindsym $super+a focus parent
    # bindsym $super+space focus mode_toggle
    #
    # Send the focused workspace to the display on its right:
    # bindsym Control+$super+o move workspace to output right
    #
    # Resize from the keyboard: Control+Option+X enters resize mode, the arrows resize,
    # Return or Escape leave it.
    # bindsym Control+$super+x mode "resize"
    # mode "resize" {
    #     bindsym Left resize shrink width 10 px or 10 ppt
    #     bindsym Down resize grow height 10 px or 10 ppt
    #     bindsym Up resize shrink height 10 px or 10 ppt
    #     bindsym Right resize grow width 10 px or 10 ppt
    #     bindsym Return mode "default"
    #     bindsym Escape mode "default"
    # }

    # ---- Options (the defaults are shown; remove the # to change one) ------------------------
    # The cursor follows keyboard focus: window (jump to the focused window unless the cursor is
    # already over it), center (always to its middle), output (only when focus changes display), none.
    # mouse_warping window
    #
    # Drag a window edge to resize, drag a title bar to move. Dropping on the middle of a
    # window joins its group (group) or swaps the two windows (swap).
    # mouse_gestures yes
    # mouse_drop_center group
    #
    # A menu bar item listing the workspaces. Icons: all, active (only on showing workspaces), none.
    # workspace_bar yes
    # workspace_bar_icons all
    # Each workspace's windows as i3-style containers, e.g. h[icon icon] t[icon v[icon icon]]
    # (h v t s = horizontal, vertical, tabbed, stacked; f[...] = floating), or flat: just the app icons.
    # workspace_bar_layout tree
    #
    # Wrap around at the edge of a container when moving focus.
    # focus_wrapping yes
    #
    # Remember your splits, tabs and stacks (~/.config/mac-i3/state.json) so `restart` (Control+Option+R
    # in the default bindings) restores them instead of re-tiling every window into a plain row.
    # layout_persistence yes
    #
    # Detailed logging (~/Library/Logs/mac-i3.log when launched as an app, otherwise the terminal) -- the
    # same detail as the -v command-line flag, for when there is no command line to pass it on. Takes
    # effect immediately on `reload`.
    # verbose no
    """

    /// i3's own stock key bindings (home-row focus, resize mode...), with Option as $mod.
    /// `mac-i3 default-config stock`; the integration tests run on it.
    public static let stock = """
    # i3's own stock key bindings, with Option as $mod (`mac-i3 default-config stock`).
    # The integration tests run on this preset.
    set $mod Mod1

    # Mouse cursor follows keyboard focus: window (default: jump to the focused window's centre unless the
    # cursor is already over it), center (always), output (only when focus changes display), none.
    # mouse_warping window

    # Workspace bar: a menu bar item listing the workspaces (numbers + app icons, the showing one per display
    # highlighted). Click to switch, right-click for a list of windows.
    # workspace_bar yes
    # workspace_bar_icons all       # all | active (icons only on showing workspaces) | none

    # Which display a workspace lives on. `output 1` is the primary display, `output 2`, `3`... the others
    # from left to right (see `mac-i3 outputs`). A workspace whose output is not connected lives on the
    # primary display, and moves to its output when it is plugged in.
    # workspace 1 output 1
    # workspace 2 output 2

    # start a terminal / launcher
    bindsym $mod+Return exec open -a Terminal ~
    bindsym $mod+d exec open -a Spotlight

    # kill focused window
    bindsym $mod+Shift+q kill

    # change focus
    bindsym $mod+j focus left
    bindsym $mod+k focus down
    bindsym $mod+l focus up
    bindsym $mod+semicolon focus right
    bindsym $mod+Left focus left
    bindsym $mod+Down focus down
    bindsym $mod+Up focus up
    bindsym $mod+Right focus right

    # move focused window
    bindsym $mod+Shift+j move left
    bindsym $mod+Shift+k move down
    bindsym $mod+Shift+l move up
    bindsym $mod+Shift+semicolon move right
    bindsym $mod+Shift+Left move left
    bindsym $mod+Shift+Down move down
    bindsym $mod+Shift+Up move up
    bindsym $mod+Shift+Right move right

    # split in horizontal / vertical orientation
    bindsym $mod+h split h
    bindsym $mod+v split v

    # enter fullscreen mode for the focused container
    bindsym $mod+f fullscreen toggle

    # change container layout (stacked, tabbed, toggle split)
    bindsym $mod+s layout stacking
    bindsym $mod+w layout tabbed
    bindsym $mod+e layout toggle split

    # toggle tiling / floating
    bindsym $mod+Shift+space floating toggle

    # change focus between tiling / floating windows
    bindsym $mod+space focus mode_toggle

    # focus the parent container
    bindsym $mod+a focus parent

    # switch to workspace
    bindsym $mod+1 workspace number 1
    bindsym $mod+2 workspace number 2
    bindsym $mod+3 workspace number 3
    bindsym $mod+4 workspace number 4
    bindsym $mod+5 workspace number 5
    bindsym $mod+6 workspace number 6
    bindsym $mod+7 workspace number 7
    bindsym $mod+8 workspace number 8
    bindsym $mod+9 workspace number 9
    bindsym $mod+0 workspace number 10

    # move focused container to workspace
    bindsym $mod+Shift+1 move container to workspace number 1
    bindsym $mod+Shift+2 move container to workspace number 2
    bindsym $mod+Shift+3 move container to workspace number 3
    bindsym $mod+Shift+4 move container to workspace number 4
    bindsym $mod+Shift+5 move container to workspace number 5
    bindsym $mod+Shift+6 move container to workspace number 6
    bindsym $mod+Shift+7 move container to workspace number 7
    bindsym $mod+Shift+8 move container to workspace number 8
    bindsym $mod+Shift+9 move container to workspace number 9
    bindsym $mod+Shift+0 move container to workspace number 10

    # reload the configuration file / restart / exit
    bindsym $mod+Shift+c reload
    bindsym $mod+Shift+r restart
    bindsym $mod+Shift+e exit

    # resize window (you can also use the mouse for that)
    mode "resize" {
        bindsym j resize shrink width 10 px or 10 ppt
        bindsym k resize grow height 10 px or 10 ppt
        bindsym l resize shrink height 10 px or 10 ppt
        bindsym semicolon resize grow width 10 px or 10 ppt

        bindsym Left resize shrink width 10 px or 10 ppt
        bindsym Down resize grow height 10 px or 10 ppt
        bindsym Up resize shrink height 10 px or 10 ppt
        bindsym Right resize grow width 10 px or 10 ppt

        bindsym Return mode "default"
        bindsym Escape mode "default"
        bindsym $mod+r mode "default"
    }

    bindsym $mod+r mode "resize"
    """
}
