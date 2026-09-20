# mac-i3

i3 window management for macOS, as a single CLI. Run `mac-i3`, and it listens for i3's default key
bindings (with **Option** as `$mod`) and tiles, focuses and moves your windows the way i3 does.

It implements i3's real container tree (arbitrary nesting, per-container layouts, `focus parent`,
focus stacks, `split`, tabbed/stacked with title bars, floating, fullscreen, workspaces, multiple
outputs), rather than a simplified grid.

## Build & run

```sh
swift build -c release          # binary: .build/release/mac-i3
.build/release/mac-i3 doctor    # check permissions
.build/release/mac-i3           # run (foreground); Ctrl-C restores parked windows
```

**Permissions** (System Settings → Privacy & Security): grant **Accessibility** and **Input Monitoring**
to the app that launches `mac-i3` (Terminal, iTerm, VS Code...). Quit AeroSpace/yabai first — two window
managers will fight.

### Trying it safely

`mac-i3 --only Terminal` manages **only** the named apps (name or bundle id, repeatable). Everything
else on your desktop is left alone.

```sh
mac-i3 --only Terminal -v       # then press Option+Return a few times
mac-i3 test-window A            # a labelled window that is handy for experiments
```

If a run ever ends badly (e.g. `kill -9`), `mac-i3 restore` pulls parked windows back on-screen; a new
daemon also does this on start.

## Key bindings (i3 defaults, `$mod` = Option)

(`$mod` is configurable, e.g. Control+Option; see [Modifier keys](#modifier-keys).)

| Keys | Action |
|---|---|
| `$mod+Return` | new Terminal window (`open -a Terminal ~`) |
| `$mod+d` | launcher (opens Spotlight; configurable) |
| `$mod+Shift+q` | close focused window |
| `$mod+j` `k` `l` `;` (or arrows) | focus left / down / up / right |
| `$mod+Shift+j` `k` `l` `;` (or arrows) | move window left / down / up / right |
| `$mod+h` / `$mod+v` | split horizontal / vertical |
| `$mod+s` / `$mod+w` / `$mod+e` | stacking / tabbed / toggle split |
| `$mod+f` | fullscreen |
| `$mod+Shift+Space` / `$mod+Space` | toggle floating / switch tiling↔floating focus |
| `$mod+a` | focus parent container |
| `$mod+1..0` / `$mod+Shift+1..0` | switch workspace / move window to workspace |
| `$mod+r` | resize mode: `j k l ;` or arrows resize, `Return`/`Esc` leave |
| `$mod+Shift+c` / `r` / `e` | reload config / restart / exit |

Windows open next to the focused one; `split` decides the direction of the *next* window, exactly as
in i3. Clicking a tab in a title bar focuses that window; clicking a window focuses it in the tree.

### Mouse

* **Click** a window: it becomes the focused window, so `$mod+j/k/l/;` continue from it.
* **Drag a window edge or corner** (tiled windows): the boundary moves and the neighbours reflow. An edge on
  the outer border of the screen cannot move; the window snaps back.
* **Drag a window by its title bar** and drop it on another window; a translucent preview shows where it will go:
  * on the **outer quarter of an edge**: it goes beside that window on that side (splitting the slot if the
    layout runs the other way),
  * in the **middle**: the two windows swap places,
  * on **another display**: it joins the window under the cursor there, or that display's workspace if it is empty,
  * dropped on its own slot, a floating window, or nothing: it snaps back.
* **Floating windows** are moved and resized freely and never affect the tiled layout.

Whether a drag moves or resizes is decided by *where you grabbed* (title bar/content vs. border), never by
the size afterwards, because macOS resizes a window that no longer fits when you drop it on a smaller display.
`mouse_gestures no` in the config turns all of this off. Turn off macOS's own *Tile by dragging windows to screen
edges* (System Settings → Desktop & Dock → Windows) so it does not compete with drop-to-move.

## Configuration

`~/.config/mac-i3/config` uses i3 syntax (`mac-i3 default-config` prints the built-in one):
`set`, `bindsym` (incl. `--release`), `mode "name" { ... }`, `exec`, `gaps inner|outer N`,
`focus_wrapping`, `mouse_gestures yes|no`, `for_window`, `assign` (see below).
Keys are physical (layout independent).

### Window rules

`for_window [criteria] <command>` runs an i3 command on every new window; `assign [criteria] → <workspace>`
sends it to a workspace. Criteria values are **regular expressions matched anywhere** in the property
(case-insensitive here; anchor with `^…$` for an exact match). `class`, `instance`, `app` and `app_name`
all mean the application's name; `title` is the window title; several terms must all match; `[]` matches
everything. Rules run in file order, so a later rule can undo an earlier one.

```
# float everything by default (windows keep the position and size the app gave them)...
for_window [class=".*"] floating enable
# ...except these, which tile
for_window [app="^(Terminal|iTerm2)$"] floating disable
```

With this, `$mod+Shift+Space` floats or tiles the focused window on demand. Note that
`focus left/right/up/down` only navigates between *tiled* windows; floating windows are reached with the
mouse or `$mod+Space` (`focus mode_toggle`), and `move <dir>` nudges them by 10px.

### Modifier keys

i3 names its modifiers after X11's modifier slots. On a Mac they map like this (names are
case-insensitive):

| Name in config | i3 (X11) meaning | On macOS |
|---|---|---|
| `Mod1`, `Alt`, `Option` | Alt | **Option** |
| `Mod4`, `Super`, `Win`, `Cmd`, `Command` | Super / Windows key | **Command** |
| `Shift` | Shift | **Shift** |
| `Control`, `Ctrl` | Control | **Control** |
| `Mod2` | NumLock | not supported |
| `Mod3` | usually unused (sometimes Hyper) | not supported |
| `Mod5` | AltGr | not supported |

Using `Mod2`, `Mod3` or `Mod5` is reported as a config error. Use `Control` where you might have
reached for `Mod3`.

`$mod` is plain text substitution, so it can stand for several modifiers at once. To use
**Control+Option** as the mod key, change one line at the top of your config:

```
set $mod Mod1+Control
```

Every `$mod+…` binding then becomes `Ctrl+Option+…` (and `$mod+Shift+q` becomes
`Ctrl+Option+Shift+q`). Chords that are not bound are passed through to the focused app untouched, so with
Ctrl+Option as `$mod`, a plain Option+d or Option+f still works in your shell. Reload with
`$mod+Shift+c`, or restart the daemon.

## Talking to a running daemon

```sh
mac-i3 msg 'split v; layout tabbed'   # any i3 command, `;`-separated
mac-i3 shape                          # H[1 V[2 3*]]-style one-liner per output (* = focus)
mac-i3 tree                           # full JSON tree
mac-i3 state                          # tree + the window frames macOS reports right now
mac-i3 inject Mod1+Shift+j            # synthesize a key press (sent like a keyboard: modifiers pressed and released)
mac-i3 mouse drag 240 51 1750 600     # synthesize a mouse drag (screen coordinates, top-left origin)
mac-i3 modifiers                      # which modifier keys macOS thinks are held: should print "none"
mac-i3 release-modifiers              # clear stuck modifiers (an Option stuck down turns clicks into hide-app clicks)
```

Commands: `focus left|right|up|down|parent|child|mode_toggle|output <dir>`, `move <dir>`,
`move [container to] workspace <n|next|prev>`, `move container|workspace to output <dir>`,
`workspace <n|next|prev|back_and_forth>`, `split h|v`, `layout splith|splitv|stacking|tabbed|toggle split`,
`fullscreen`, `floating toggle|enable|disable`, `resize grow|shrink width|height N px or N ppt`,
`kill`, `mode`, `exec`, `reload`, `restart`, `exit`.

## How it works

* `Sources/I3Core` — pure Swift model of i3's tree, layout solver and command interpreter (no AppKit).
* `Sources/I3Config` — i3 config parser and the embedded default config.
* `Sources/I3Mac` — Accessibility API window control, global key tap (`CGEventTap`), display geometry,
  title-bar overlays, IPC socket (`~/.config/mac-i3/ipc.sock`).
* `Sources/mac-i3` — the CLI.

**Workspaces are virtual.** macOS has no public API for switching Spaces, so inactive workspaces (and
inactive tabs) are parked at the bottom-right corner of the right-most display, leaving a 1px sliver.

## Testing

```sh
scripts/test.sh                         # unit tests, incl. a 12k-session randomized fuzz of the tree
FUZZ_SEEDS=6000 scripts/test.sh         # longer soak
scripts/integration.py [name...]        # end-to-end scenarios (mouse ones: `scripts/integration.py mouse`)
```

The integration suite starts a scoped daemon, opens labelled windows, **injects real key presses**, and
asserts on the frames and focus that macOS reports through the Accessibility API (tiling, splits,
focus/move, workspaces, tabbed/stacked, kill, resize mode, floating, fullscreen, multi-monitor, rules, mouse
click/resize/drag-to-move (incl. across displays),
restart, crash recovery, and real Terminal.app windows — skipped if Terminal is already running).
It needs no other window manager running, and **refuses to start while another `mac-i3` daemon is running**
(e.g. the one you use day to day). It talks to its daemons over a private socket (`MAC_I3_SOCKET`), so it never
touches a real daemon's `~/.config/mac-i3/ipc.sock`. Synthetic mouse presses are refused unless the topmost window
under the cursor belongs to a test window (`MAC_I3_MOUSE_GUARD`), and every scenario asserts that no modifier keys
were left held down system-wide.

## Known limitations

* Windows on other native macOS Spaces are invisible to the Accessibility API: stay on one Space and
  use i3 workspaces instead.
* Apps that snap or enforce minimum sizes (Terminal snaps to its character grid) may end a few pixels
  off their tile.
* Option+key chords that are bound are swallowed, so apps that use Option as Meta lose those chords.
* `restart` re-reads all windows; the layout tree is rebuilt (windows are re-tiled in creation order).
* Multi-display: workspace-per-output works; hot-plugging is handled, but is less tested than the rest.
