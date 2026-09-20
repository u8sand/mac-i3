#!/usr/bin/env python3
"""End-to-end tests for mac-i3.

Starts the daemon scoped to its own test windows (`--only mac-i3`, so nothing else on your desktop is
touched), opens labelled windows, drives the WM with *real synthesized key presses*, and asserts on
the window frames and focus that macOS itself reports through the Accessibility API.

    scripts/integration.py                # run everything
    scripts/integration.py tabbed kill    # run scenarios whose name contains one of these words

Requires: Accessibility + Input Monitoring for the app running this script, and no other
window manager (AeroSpace, yabai...) running.
"""
import json
import os
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.environ.get("MAC_I3", os.path.join(ROOT, ".build/debug/mac-i3"))
TOL = 3
# A private socket: the tests must never read, replace or delete a real daemon's socket.
# Synthetic presses are only allowed on test windows: a mistake must never grab one of your own windows.
os.environ["MAC_I3_MOUSE_GUARD"] = "mac-i3"
os.environ["MAC_I3_SOCKET"] = os.path.join(tempfile.gettempdir(), f"mac-i3-test-{os.getpid()}.sock")


def run(*args, timeout=10, env=None):
    return subprocess.run([BIN, *args], capture_output=True, text=True, timeout=timeout,
                          env={**os.environ, **env} if env else None)


class Daemon:
    def __init__(self, extra=(), only="mac-i3"):
        self.extra = list(extra)
        self.only = only
        self.procs = {}
        self.proc = None

    def start(self, clean=True):
        if clean:
            cleanup_leftovers()
        self.proc = subprocess.Popen([BIN, "run", "--only", self.only, *self.extra],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        _ours.add(self.proc.pid)
        for _ in range(50):
            if run("ping").stdout.strip() == "pong":
                return
            time.sleep(0.1)
        raise RuntimeError("daemon did not start: " + (self.proc.stderr.read().decode() if self.proc.poll() is not None else ""))

    def stop(self):
        for p in self.procs.values():
            if p.poll() is None:
                p.terminate()
        self.procs.clear()
        if self.proc and self.proc.poll() is None:
            run("msg", "exit")
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        cleanup_leftovers()

    # -- driving ----------------------------------------------------------------------------
    def state(self, retry=False):
        out = run("state").stdout
        if not out.strip() and retry:
            return None
        return json.loads(out)

    def spawn(self, title):
        before = {w["title"] for w in self.state()["windows"]}
        assert title not in before, f"{title} already exists"
        self.procs[title] = subprocess.Popen([BIN, "test-window", title], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        _ours.add(self.procs[title].pid)
        self.wait(lambda s: any(w["title"] == title for w in s["windows"]), f"window {title} to appear")
        self.settle()

    def key(self, chord, settle=True):
        assert run("inject", chord).returncode == 0, f"bad chord {chord}"
        if settle:
            self.settle()

    def msg(self, cmd):
        r = run("msg", cmd)
        assert r.stdout.strip() == "ok", f"msg {cmd!r}: {r.stdout}{r.stderr}"
        self.settle()

    def settle(self, t=0.45):
        time.sleep(t)

    def wait(self, pred, what, timeout=5):
        end = time.time() + timeout
        s = None
        while time.time() < end:
            try:
                s = self.state(retry=True)
            except (ValueError, subprocess.SubprocessError):
                s = None
            if s is not None and pred(s):
                return s
            time.sleep(0.15)
        raise AssertionError(f"timed out waiting for {what}\nstate: {json.dumps(s, indent=1)[:1500]}")

    # -- mouse ------------------------------------------------------------------------------
    def click(self, pt, settle=0.6, also=None):
        """`also`: another app whose window may be under the press (e.g. the menu bar item, which macOS hosts in Control Center)."""
        env = {"MAC_I3_MOUSE_GUARD": os.environ["MAC_I3_MOUSE_GUARD"] + "," + also} if also else None
        r = run("mouse", "click", str(pt[0]), str(pt[1]), env=env)
        assert r.returncode == 0, r.stderr.strip()
        time.sleep(settle)

    def drag(self, a, b, settle=1.0):
        r = run("mouse", "drag", str(a[0]), str(a[1]), str(b[0]), str(b[1]), timeout=20)
        assert r.returncode == 0, r.stderr.strip()
        time.sleep(settle)

    def titlebar(self, title):
        f = self.frame(title)
        return (f[0] + f[2] / 2 - 60, f[1] + 12)

    def body(self, title):
        f = self.frame(title)
        return (f[0] + f[2] / 2, f[1] + f[3] / 2 + 60)

    def zone(self, title, zone):
        """A point inside window `title` that selects the given drop zone."""
        f = self.frame(title)
        cx, cy = f[0] + f[2] / 2, f[1] + f[3] / 2
        return {"left": (f[0] + f[2] * 0.08, cy), "right": (f[0] + f[2] * 0.92, cy),
                "top": (cx, f[1] + f[3] * 0.08), "bottom": (cx, f[1] + f[3] * 0.92), "center": (cx, cy)}[zone]

    def tree_focus(self, s=None):
        s = s or self.state()
        return next((w["title"] for w in s["windows"] if w["focused"]), None)

    # -- queries ----------------------------------------------------------------------------
    def win(self, title, s=None):
        s = s or self.state()
        for w in s["windows"]:
            if w["title"] == title:
                return w
        raise AssertionError(f"no window {title}")

    def output(self, i=0):
        return self.state()["outputs"][i]

    def frame(self, title):
        f = self.win(title)["frame"]
        return (f["x"], f["y"], f["w"], f["h"])

    def is_parked(self, title):
        w = self.win(title)
        return w["parked"] and w["frame"]["x"] >= 3000 or w["parked"]

    def expect_frame(self, title, want, msg="", tol=TOL):
        got = self.frame(title)
        ok = all(abs(g - w) <= tol for g, w in zip(got, want))
        assert ok, f"{msg}{title}: expected {tuple(round(v) for v in want)}, OS reports {tuple(round(v) for v in got)}"

    def expect_focus(self, title, msg=""):
        want = self.win(title)["id"]
        try:  # OS focus can lag a moment behind the request
            self.wait(lambda s: s["osFocus"] == want, "focus", timeout=1.5)
        except AssertionError:
            s = self.state()
            raise AssertionError(f"{msg}expected OS focus on {title} ({want}), got {s['osFocus']} (tree focus {[w['title'] for w in s['windows'] if w['focused']]})") from None

    def expect_shape(self, sub):
        s = self.state()
        assert any(sub in line for line in s["shape"]), f"expected shape containing {sub!r}, got {s['shape']}"


def foreign_daemons():
    """PIDs of mac-i3 window-manager daemons that are not ours (e.g. the one you use day to day)."""
    out = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
    found = []
    for line in out.splitlines():
        pid, _, cmd = line.strip().partition(" ")
        argv = cmd.split()
        if not argv or os.path.basename(argv[0]) != "mac-i3" or int(pid) == os.getpid():
            continue
        if len(argv) == 1 or argv[1] == "run" or argv[1].startswith("-"):
            found.append(int(pid))
    return found


_ours = set()


def cleanup_leftovers():
    """Stop only the processes this script started, and only remove its own socket."""
    for pid in list(_ours):
        try:
            os.kill(pid, 9)
        except ProcessLookupError:
            pass
        _ours.discard(pid)
    time.sleep(0.3)
    try:
        os.unlink(os.environ["MAC_I3_SOCKET"])
    except FileNotFoundError:
        pass


# ------------------------------------------------------------------------------------------------
# Scenarios. Each receives a fresh daemon. O = the first display's usable area (the primary one).
# ------------------------------------------------------------------------------------------------
def s_tiling_and_split(d):
    """Two windows tile side by side; split v + a third window stacks it under the second."""
    O = d.output()
    d.spawn("A"); d.spawn("B")
    d.expect_frame("A", (O["x"], O["y"], O["w"] / 2, O["h"]))
    d.expect_frame("B", (O["x"] + O["w"] / 2, O["y"], O["w"] / 2, O["h"]))
    d.key("Mod1+v")
    d.spawn("C")
    d.expect_frame("A", (O["x"], O["y"], O["w"] / 2, O["h"]))
    d.expect_frame("B", (O["x"] + O["w"] / 2, O["y"], O["w"] / 2, O["h"] / 2))
    d.expect_frame("C", (O["x"] + O["w"] / 2, O["y"] + O["h"] / 2, O["w"] / 2, O["h"] / 2))
    d.expect_focus("C")


def s_focus_keys(d):
    """Option+j/k/l/; move OS focus like i3 (j=left k=down l=up ;=right)."""
    d.spawn("A"); d.spawn("B"); d.key("Mod1+v"); d.spawn("C")     # A | B over C
    d.key("Mod1+l"); d.expect_focus("B", "up: ")
    d.key("Mod1+j"); d.expect_focus("A", "left: ")
    d.key("Mod1+semicolon"); d.expect_focus("B", "right (last focused in the right column): ")
    d.key("Mod1+k"); d.expect_focus("C", "down: ")
    d.key("Mod1+Left"); d.expect_focus("A", "arrow left: ")


def s_move_keys(d):
    """Option+Shift+direction moves the window through the tree."""
    O = d.output()
    d.spawn("A"); d.spawn("B"); d.spawn("C")                        # A B C
    w3 = O["w"] / 3
    d.key("Mod1+Shift+j")                                            # C moves left: A C B
    d.expect_frame("C", (O["x"] + w3, O["y"], w3, O["h"]))
    d.expect_frame("B", (O["x"] + 2 * w3, O["y"], w3, O["h"]))
    d.key("Mod1+Shift+semicolon")                                    # back: A B C
    d.expect_frame("C", (O["x"] + 2 * w3, O["y"], w3, O["h"]))
    d.key("Mod1+Shift+k")                                            # move down: wraps into V[H[A B] C]
    d.expect_frame("C", (O["x"], O["y"] + O["h"] / 2, O["w"], O["h"] / 2))
    d.expect_frame("A", (O["x"], O["y"], O["w"] / 2, O["h"] / 2))


def s_workspaces(d):
    """Inactive workspaces are parked off-screen; moving containers between workspaces."""
    O = d.output()
    d.spawn("A"); d.spawn("B")
    d.key("Mod1+3")
    assert d.is_parked("A") and d.is_parked("B"), "A/B should be parked on workspace 3"
    d.spawn("D")
    d.expect_frame("D", (O["x"], O["y"], O["w"], O["h"]), "fresh workspace: ")
    d.key("Mod1+1")
    d.expect_frame("A", (O["x"], O["y"], O["w"] / 2, O["h"]))
    assert d.is_parked("D"), "D should be parked when ws1 is shown"
    d.expect_focus("B")
    d.key("Mod1+Shift+3")                                            # B -> ws3
    d.expect_frame("A", (O["x"], O["y"], O["w"], O["h"]), "A should reflow to full width: ")
    assert d.is_parked("B")
    d.key("Mod1+3")
    d.expect_frame("D", (O["x"], O["y"], O["w"] / 2, O["h"]))
    d.expect_frame("B", (O["x"] + O["w"] / 2, O["y"], O["w"] / 2, O["h"]))


def s_tabbed_stacked(d):
    """Tabbed shows only the active window below a title bar; stacked reserves one row per window."""
    O = d.output()
    d.spawn("A"); d.spawn("B"); d.spawn("C")
    d.key("Mod1+w")
    bar = 22
    d.expect_frame("C", (O["x"], O["y"] + bar, O["w"], O["h"] - bar), "tabbed: ")
    assert d.is_parked("A") and d.is_parked("B")
    d.key("Mod1+j")                                                  # focus left -> previous tab
    d.expect_frame("B", (O["x"], O["y"] + bar, O["w"], O["h"] - bar), "tab switch: ")
    d.expect_focus("B")
    assert d.is_parked("C")
    d.key("Mod1+s")
    d.expect_frame("B", (O["x"], O["y"] + 3 * bar, O["w"], O["h"] - 3 * bar), "stacked: ")
    d.key("Mod1+e")                                                  # back to a split layout
    d.expect_frame("A", (O["x"], O["y"], O["w"] / 3, O["h"]), "toggle split from stacked: ")


def s_kill_reflows(d):
    """Option+Shift+q closes the focused window (its process exits) and the rest reflow."""
    O = d.output()
    d.spawn("A"); d.spawn("B"); d.spawn("C")
    d.key("Mod1+j")                                                  # focus B
    d.expect_focus("B")
    d.key("Mod1+Shift+q", settle=False)
    d.wait(lambda s: all(w["title"] != "B" for w in s["windows"]), "B to disappear")
    d.settle()
    d.expect_frame("A", (O["x"], O["y"], O["w"] / 2, O["h"]))
    d.expect_frame("C", (O["x"] + O["w"] / 2, O["y"], O["w"] / 2, O["h"]))
    assert d.procs["B"].wait(timeout=3) is not None


def s_resize_mode(d):
    """Option+r enters resize mode; ; grows width by 10ppt; Return leaves the mode."""
    O = d.output()
    d.spawn("A"); d.spawn("B")
    d.key("Mod1+r")
    assert d.state()["mode"] == "resize"
    d.key("semicolon")                                               # grow width (B is last: A shrinks)
    d.expect_frame("A", (O["x"], O["y"], O["w"] * 0.4, O["h"]), "after grow: ")
    d.expect_frame("B", (O["x"] + O["w"] * 0.4, O["y"], O["w"] * 0.6, O["h"]))
    d.key("j")                                                       # shrink width
    d.expect_frame("A", (O["x"], O["y"], O["w"] * 0.5, O["h"]), "after shrink: ")
    d.key("Return")
    assert d.state()["mode"] == "default"


def s_floating_fullscreen(d):
    """Floating windows leave the tiling; fullscreen covers the output."""
    O = d.output()
    d.spawn("A"); d.spawn("B"); d.spawn("C")
    d.key("Mod1+Shift+space")                                        # C floats
    d.expect_frame("A", (O["x"], O["y"], O["w"] / 2, O["h"]))
    d.expect_frame("B", (O["x"] + O["w"] / 2, O["y"], O["w"] / 2, O["h"]))
    assert d.win("C")["floating"]
    d.key("Mod1+Shift+space")                                        # back to tiling
    d.expect_frame("C", (O["x"] + 2 * O["w"] / 3, O["y"], O["w"] / 3, O["h"]))
    d.key("Mod1+f")
    d.expect_frame("C", (O["x"], O["y"], O["w"], O["h"]), "fullscreen: ")
    d.key("Mod1+f")
    d.expect_frame("C", (O["x"] + 2 * O["w"] / 3, O["y"], O["w"] / 3, O["h"]), "unfullscreen: ")


def s_focus_parent(d):
    """Option+a focuses the parent container; new windows then open inside that container's level."""
    O = d.output()
    d.spawn("A"); d.spawn("B"); d.key("Mod1+v"); d.spawn("C")        # A | (B / C)
    d.key("Mod1+a")                                                  # focus the V container
    d.key("Mod1+h")                                                  # split h: wraps it
    d.spawn("D")                                                     # D opens inside the new wrapper, next to V
    d.expect_frame("A", (O["x"], O["y"], O["w"] / 2, O["h"]))
    assert d.frame("D")[0] > d.frame("B")[0], "D should be right of B/C"


def s_multi_monitor(d):
    """Moving a window past the edge sends it to the next display; focus follows across outputs."""
    outs = d.state()["outputs"]
    if len(outs) < 2:
        return "SKIP (single display)"
    O0, O1 = outs[0], outs[1]
    d.spawn("A"); d.spawn("B")
    d.key("Mod1+Shift+semicolon")                                    # B leaves display 1's workspace
    d.expect_frame("A", (O0["x"], O0["y"], O0["w"], O0["h"]), "A alone on display 1: ")
    d.expect_frame("B", (O1["x"], O1["y"], O1["w"], O1["h"]), "B on display 2: ")
    d.expect_focus("B")
    d.key("Mod1+j"); d.expect_focus("A", "focus left across displays: ")
    d.key("Mod1+semicolon"); d.expect_focus("B", "focus right across displays: ")
    d.spawn("C")                                                     # opens on the focused (display 2) workspace
    d.expect_frame("C", (O1["x"] + O1["w"] / 2, O1["y"], O1["w"] / 2, O1["h"]), "C tiles next to B on display 2: ")


def s_restart_keeps_managing(d):
    """Option+Shift+r re-executes the daemon; windows are picked up and tiled again."""
    O = d.output()
    d.spawn("A"); d.spawn("B")
    run("msg", "restart")
    d.wait(lambda s: len(s["windows"]) == 2, "daemon to come back after restart", timeout=8)
    d.settle(0.8)
    d.expect_frame("A", (O["x"], O["y"], O["w"] / 2, O["h"]), "after restart: ")
    d.expect_frame("B", (O["x"] + O["w"] / 2, O["y"], O["w"] / 2, O["h"]))
    d.key("Mod1+3")                                                  # key bindings work again
    assert d.is_parked("A")


def s_crash_restore(d):
    """SIGKILL leaves windows parked; `mac-i3 restore` (and the next start) bring them back."""
    O = d.output()
    d.spawn("A"); d.spawn("B")
    d.key("Mod1+3")
    assert d.is_parked("A") and d.is_parked("B")
    d.proc.kill(); d.proc.wait()
    time.sleep(0.4)
    out = run("restore").stdout
    assert "restored 2" in out, f"restore said: {out!r}"
    d.start(clean=False)                                             # new daemon adopts the rescued windows
    d.wait(lambda s: len(s["windows"]) == 2, "windows to be re-adopted")
    d.settle(0.8)
    for t in ("A", "B"):
        f = d.frame(t)
        assert f[0] < O["x"] + O["w"], f"{t} still off-screen at {f}"


def s_rules(d):
    """for_window / assign rules from the config file."""
    O = d.output()
    d.spawn("Plain")
    d.spawn("Float")                                                 # for_window [title="Float"] floating enable
    assert d.win("Float")["floating"], "Float should have been made floating by the rule"
    d.expect_frame("Plain", (O["x"], O["y"], O["w"], O["h"]), "floating window must not take tiling space: ")
    d.spawn("Ws4")                                                   # assign [title="Ws4"] -> 4
    assert d.win("Ws4")["workspace"] == "4" and d.is_parked("Ws4"), "Ws4 should be assigned to workspace 4"
    assert d.state()["workspace"] == "1", "assign must not switch workspaces"
    d.expect_focus("Float", "focus should stay where it was: ")
    d.key("Mod1+4")
    d.expect_frame("Ws4", (O["x"], O["y"], O["w"], O["h"]), "workspace 4: ")
s_rules.config = 'for_window [title="Float"] floating enable\nassign [title="Ws4"] → 4\n'


def s_terminal(d):
    """Real Terminal.app windows: Option+Return opens one, they tile, Option+Shift+q closes them."""
    if subprocess.run(["pgrep", "-x", "Terminal"], capture_output=True).returncode == 0:
        return "SKIP (Terminal is already running; won't touch your windows)"
    O = d.output()
    try:
        for i in range(3):
            d.key("Mod1+Return", settle=False)
            d.wait(lambda s, n=i + 1: len(s["windows"]) == n, f"terminal #{i + 1}", timeout=8)
            d.settle(0.8)
        titles = [w["title"] for w in d.state()["windows"]]
        third = O["w"] / 3
        for i, w in enumerate(sorted(d.state()["windows"], key=lambda w: w["id"])):
            f = w["frame"]
            # Terminal snaps to its character grid, so allow a few cells of slack.
            assert abs(f["x"] - (O["x"] + i * third)) <= 14 and abs(f["w"] - third) <= 14 and abs(f["h"] - O["h"]) <= 20, \
                f"terminal {i}: {f} vs column {i} of {O}"
        for _ in range(3):
            d.key("Mod1+Shift+q", settle=False)
            time.sleep(1.0)
        d.wait(lambda s: len(s["windows"]) == 0, "all terminals closed")
    finally:
        subprocess.run(["pkill", "-x", "Terminal"], capture_output=True)
s_terminal.only = "Terminal"


def s_default_floating(d):
    """`for_window [class=".*"] floating enable` floats every window in place; a later rule can opt one back in."""
    O = d.output()
    d.spawn("A"); d.spawn("B")
    for t in ("A", "B"):
        assert d.win(t)["floating"], f"{t} should float by default"
    fa, fb = d.frame("A"), d.frame("B")
    for f in (fa, fb):
        assert abs(f[2] - 420) <= 6 and abs(f[3] - 332) <= 6, f"floating window should keep its own size (420x332 incl. title bar), got {f}"
    d.spawn("Tiled")                                               # [title="Tiled"] floating disable
    assert not d.win("Tiled")["floating"], "later rule should have tiled this window"
    d.expect_frame("Tiled", (O["x"], O["y"], O["w"], O["h"]), "the only tiled window fills the output: ")
    assert d.frame("A") == fa and d.frame("B") == fb, "floating windows must not move when a tiled one arrives"
    d.key("Mod1+Shift+space")                                      # Tiled is focused: it floats too
    assert d.win("Tiled")["floating"]
    d.key("Mod1+Shift+space")                                      # ...and Option+Shift+Space tiles it again
    assert not d.win("Tiled")["floating"]
s_default_floating.config = '''for_window [class=".*"] floating enable
for_window [title="^Tiled$"] floating disable
'''


def s_mouse_click_focus(d):
    """Clicking a window makes it the focused one in the tree, so keyboard navigation continues from it."""
    d.spawn("A"); d.spawn("B"); d.spawn("C")
    d.click(d.body("A"))
    d.wait(lambda s: d.tree_focus(s) == "A", "tree focus to follow a click on A")
    d.key("Mod1+semicolon")
    d.expect_focus("B", "keyboard navigation should continue from the clicked window: ")
    # A click right after a keyboard focus change must not be swallowed by the settle window.
    d.key("Mod1+semicolon", settle=False)
    time.sleep(0.12)
    d.click(d.body("A"), settle=0.2)
    d.wait(lambda s: d.tree_focus(s) == "A", "click made right after a key press to be adopted", timeout=3)
    d.expect_focus("A")


def s_mouse_resize(d):
    """Dragging a window edge moves the boundary and the neighbours reflow."""
    O = d.output()
    d.spawn("A"); d.spawn("B")
    a = d.frame("A"); edge = a[0] + a[2]; my = a[1] + a[3] / 2
    d.drag((edge - 1, my), (edge + 149, my))                         # A's right edge, 150px right
    d.expect_frame("A", (O["x"], O["y"], O["w"] / 2 + 150, O["h"]), "right edge: ", tol=4)
    d.expect_frame("B", (O["x"] + O["w"] / 2 + 150, O["y"], O["w"] / 2 - 150, O["h"]), tol=4)
    b = d.frame("B")
    d.drag((b[0] + 1, my), (b[0] - 149, my))                         # B's left edge, back 150px left
    d.expect_frame("A", (O["x"], O["y"], O["w"] / 2, O["h"]), "left edge (same boundary): ", tol=4)
    d.expect_frame("B", (O["x"] + O["w"] / 2, O["y"], O["w"] / 2, O["h"]), tol=4)
    # a screen-border edge cannot move: the window snaps back
    d.drag((O["x"] + 1, my), (O["x"] + 101, my))
    d.expect_frame("A", (O["x"], O["y"], O["w"] / 2, O["h"]), "screen-border edge must snap back: ", tol=4)
    # a vertical boundary inside a column
    d.click(d.body("B"))
    d.key("Mod1+v"); d.spawn("C")                                    # A | (B / C)
    b = d.frame("B"); bx = b[0] + b[2] / 2
    d.drag((bx, b[1] + b[3] - 1), (bx, b[1] + b[3] + 99))            # B's bottom edge, 100px down
    d.expect_frame("B", (b[0], b[1], b[2], b[3] + 100), "bottom edge: ", tol=4)
    d.expect_frame("C", (b[0], b[1] + b[3] + 100, b[2], O["h"] - b[3] - 100), tol=4)
    d.expect_frame("A", (O["x"], O["y"], O["w"] / 2, O["h"]), "A must not change: ", tol=4)


def s_mouse_move(d):
    """Dragging a window by its title bar and dropping it puts it where it was dropped."""
    O = d.output()
    d.spawn("A"); d.spawn("B"); d.spawn("C")                         # A B C
    w3 = O["w"] / 3
    d.drag(d.titlebar("A"), d.zone("C", "right"))                    # right edge of C -> B C A
    d.expect_frame("B", (O["x"], O["y"], w3, O["h"]), "drop on right edge: ", tol=4)
    d.expect_frame("C", (O["x"] + w3, O["y"], w3, O["h"]), tol=4)
    d.expect_frame("A", (O["x"] + 2 * w3, O["y"], w3, O["h"]), tol=4)
    d.drag(d.titlebar("C"), d.zone("B", "top"))                      # top of B -> [C over B] | A
    d.expect_frame("C", (O["x"], O["y"], O["w"] / 2, O["h"] / 2), "drop on top edge: ", tol=4)
    d.expect_frame("B", (O["x"], O["y"] + O["h"] / 2, O["w"] / 2, O["h"] / 2), tol=4)
    d.expect_frame("A", (O["x"] + O["w"] / 2, O["y"], O["w"] / 2, O["h"]), tol=4)
    d.drag(d.titlebar("A"), d.zone("B", "center"))                   # middle of B -> A joins B's group: [C B A] stacked
    h3 = O["h"] / 3
    d.expect_frame("C", (O["x"], O["y"], O["w"], h3), "drop in the middle joins the group: ", tol=4)
    d.expect_frame("B", (O["x"], O["y"] + h3, O["w"], h3), tol=4)
    d.expect_frame("A", (O["x"], O["y"] + 2 * h3, O["w"], h3), tol=4)
    # dropped back inside its own slot: nothing changes, the window snaps back
    b = d.frame("B")
    d.drag(d.titlebar("B"), (d.titlebar("B")[0] + 150, d.titlebar("B")[1] + 200))
    d.expect_frame("B", b, "a drag that ends on its own slot must snap back: ", tol=4)
    assert d.tree_focus() == "B"


def s_mouse_floating(d):
    """Dragging a floating window just moves it; the tiled layout is left alone."""
    d.spawn("A"); d.spawn("B"); d.spawn("C")
    d.key("Mod1+Shift+space")                                        # C floats
    fa, fb, fc = d.frame("A"), d.frame("B"), d.frame("C")
    d.drag(d.titlebar("C"), (d.titlebar("C")[0] - 200, d.titlebar("C")[1] + 80))
    got = d.frame("C")
    assert abs(got[0] - (fc[0] - 200)) <= 8 and abs(got[1] - (fc[1] + 80)) <= 8, f"floating window should follow the drag: {fc} -> {got}"
    assert d.win("C")["floating"]
    d.expect_frame("A", fa, "tiled A must not move: ", tol=4)
    d.expect_frame("B", fb, "tiled B must not move: ", tol=4)
    d.settle(1.0)
    assert all(abs(x - y) <= 8 for x, y in zip(d.frame("C"), got)), "floating window must stay where it was dropped"


def s_mouse_multi_monitor(d):
    """Dropping a window on another display's empty workspace or on one of its windows moves it there."""
    outs = d.state()["outputs"]
    if len(outs) < 2:
        return "SKIP (single display)"
    O0, O1 = outs[0], outs[1]
    d.spawn("A"); d.spawn("B")
    d.drag(d.titlebar("B"), (O1["x"] + O1["w"] / 2, O1["y"] + O1["h"] / 2))
    d.expect_frame("A", (O0["x"], O0["y"], O0["w"], O0["h"]), "A alone on display 1: ", tol=4)
    d.expect_frame("B", (O1["x"], O1["y"], O1["w"], O1["h"]), "B moved to display 2: ", tol=4)
    d.drag(d.titlebar("B"), d.zone("A", "right"))
    d.expect_frame("A", (O0["x"], O0["y"], O0["w"] / 2, O0["h"]), "B dropped back onto A's right edge: ", tol=4)
    d.expect_frame("B", (O0["x"] + O0["w"] / 2, O0["y"], O0["w"] / 2, O0["h"]), tol=4)


def _tabbed_group_setup(d):
    """H[A T[B C]]: A on the left, a tabbed pair (C active) on the right."""
    d.spawn("A"); d.spawn("B")
    d.key("Mod1+v"); d.spawn("C")
    d.key("Mod1+w")
    O = d.output()
    d.expect_frame("A", (O["x"], O["y"], O["w"] / 2, O["h"]), "setup: ")
    d.expect_frame("C", (O["x"] + O["w"] / 2, O["y"] + 22, O["w"] / 2, O["h"] - 22), "setup: ")
    assert d.is_parked("B")
    return O


def _expect_joined_tabs(d, O):
    """A is now a tab of the group that used to hold B and C: it is active and fills the output under the bar."""
    d.expect_frame("A", (O["x"], O["y"] + 22, O["w"], O["h"] - 22), "A should be the active tab: ", tol=4)
    assert d.is_parked("B") and d.is_parked("C"), "the other tabs should be hidden"
    d.expect_shape("H[T[")
    assert d.tree_focus() == "A"


def s_mouse_drop_into_tab_bar(d):
    """Dropping a window on a tabbed group's title bar adds it as a tab."""
    O = _tabbed_group_setup(d)
    d.drag(d.titlebar("A"), (O["x"] + 3 * O["w"] / 4, O["y"] + 10))
    _expect_joined_tabs(d, O)


def s_mouse_drop_into_tabbed_window(d):
    """Dropping a window on the middle of a tabbed group's visible window adds it as a tab (no swap)."""
    O = _tabbed_group_setup(d)
    d.drag(d.titlebar("A"), d.zone("C", "center"))
    _expect_joined_tabs(d, O)


def s_mouse_drop_swap(d):
    """`mouse_drop_center swap` restores the swap behaviour for a drop on the middle of a window."""
    O = d.output()
    d.spawn("A"); d.spawn("B")
    d.drag(d.titlebar("A"), d.zone("B", "center"))
    d.expect_frame("B", (O["x"], O["y"], O["w"] / 2, O["h"]), "swapped: ", tol=4)
    d.expect_frame("A", (O["x"] + O["w"] / 2, O["y"], O["w"] / 2, O["h"]), tol=4)
s_mouse_drop_swap.config = "mouse_drop_center swap\n"


def s_workspace_output(d):
    """`workspace N output M` puts workspaces on displays (1 = primary, 2 = the other one); `move workspace to output`
    moves one by hand; a reload puts it back."""
    outs = d.state()["outputs"]
    if len(outs) < 2:
        return "SKIP (single display)"
    O0, O1 = outs[0], outs[1]                                        # sorted left to right; display 1 is the primary
    assert outs[0]["primary"], "this scenario assumes the primary display is the left one"
    d.spawn("A")                                                     # workspace 1 is assigned to output 2 (the right display)
    d.expect_frame("A", (O1["x"], O1["y"], O1["w"], O1["h"]), "ws 1 should live on output 2: ", tol=4)
    d.msg("workspace 2")                                             # workspace 2 is assigned to output 1 (the primary)
    d.spawn("B")
    d.expect_frame("B", (O0["x"], O0["y"], O0["w"], O0["h"]), "ws 2 should live on output 1: ", tol=4)
    d.msg("move workspace to output 2")                              # by hand: ws 2 joins the right display, hiding ws 1
    d.expect_frame("B", (O1["x"], O1["y"], O1["w"], O1["h"]), "after move workspace to output 2: ", tol=4)
    assert d.is_parked("A"), "ws 1 should now be hidden behind ws 2"
    d.msg("reload")                                                  # assignments are re-applied: ws 2 goes back
    d.expect_frame("B", (O0["x"], O0["y"], O0["w"], O0["h"]), "reload should put ws 2 back on output 1: ", tol=4)
    d.expect_frame("A", (O1["x"], O1["y"], O1["w"], O1["h"]), "and ws 1 shows again on output 2: ", tol=4)
s_workspace_output.config = "workspace 1 output 2\nworkspace 2 output 1\n"


def _cursor():
    x, y = run("mouse", "pos").stdout.split()
    return (int(x), int(y))


def _place_cursor(x, y):
    run("mouse", "move", str(x), str(y))
    time.sleep(0.25)


def _expect_cursor(want, msg="", tol=4):
    got = _cursor()
    assert abs(got[0] - want[0]) <= tol and abs(got[1] - want[1]) <= tol, f"{msg}expected cursor near {tuple(round(v) for v in want)}, got {got}"


def _centre(d, title):
    f = d.frame(title)
    return (f[0] + f[2] / 2, f[1] + f[3] / 2)


def s_mouse_warp_center(d):
    """mouse_warping center: keyboard focus changes put the cursor in the middle of the focused window."""
    O = d.output()
    d.spawn("A"); d.spawn("B")
    _place_cursor(O["x"] + O["w"] * 0.9, O["y"] + O["h"] * 0.9)                # inside B, off-centre
    d.key("Mod1+j")                                                            # focus A
    _expect_cursor(_centre(d, "A"), "after focus left: ")
    d.key("Mod1+semicolon")                                                    # focus B
    _expect_cursor(_centre(d, "B"), "after focus right: ")
    # a click is not a keyboard focus move: the cursor stays exactly where you clicked
    a = d.frame("A")
    spot = (a[0] + 100, a[1] + 300)
    d.click(spot, settle=1.0)
    _expect_cursor(spot, "a click must not warp the cursor: ", tol=3)
    # closing the focused window moves focus to a neighbour later: the cursor follows then
    d.key("Mod1+semicolon")                                                    # focus B (cursor -> B centre)
    _place_cursor(a[0] + 100, a[1] + 300)                                      # park the cursor over A
    d.key("Mod1+Shift+q", settle=False)
    d.wait(lambda s: all(w["title"] != "B" for w in s["windows"]), "B to close")
    d.settle(0.8)
    _expect_cursor(_centre(d, "A"), "after the focused window closed: ")


def s_mouse_warp_window(d):
    """mouse_warping window (the default): only jump when the cursor is not already over the focused window."""
    O = d.output()
    d.spawn("A"); d.spawn("B")
    d.key("Mod1+w")                                                            # tabbed: A and B share one frame
    spot = (O["x"] + 100, O["y"] + 300)
    _place_cursor(*spot)
    d.key("Mod1+j")                                                            # focus A (other tab, same frame)
    _expect_cursor(spot, "cursor already over the focused window must stay put: ", tol=3)
    d.key("Mod1+e")                                                            # back to a split: A | B
    _place_cursor(*spot)                                                       # over A (left half)
    d.key("Mod1+semicolon")                                                    # focus B: cursor is outside it
    _expect_cursor(_centre(d, "B"), "cursor outside the newly focused window: ")
s_mouse_warp_window.config = "mouse_warping window\n"


def s_mouse_warp_none(d):
    """mouse_warping none: the cursor is never moved."""
    O = d.output()
    d.spawn("A"); d.spawn("B")
    spot = (O["x"] + O["w"] * 0.9, O["y"] + O["h"] * 0.9)
    _place_cursor(*spot)
    d.key("Mod1+j"); d.key("Mod1+semicolon"); d.key("Mod1+j")
    _expect_cursor(spot, "mouse_warping none must not move the cursor: ", tol=3)


def s_mouse_warp_output(d):
    """mouse_warping output (i3's default): only a change of display moves the cursor."""
    outs = d.state()["outputs"]
    if len(outs) < 2:
        return "SKIP (single display)"
    O0, O1 = outs[0], outs[1]
    d.spawn("A"); d.spawn("B")
    spot = (O0["x"] + O0["w"] * 0.9, O0["y"] + O0["h"] * 0.9)
    _place_cursor(*spot)
    d.key("Mod1+j"); d.key("Mod1+semicolon")                                   # focus A, then B: same display, no warp
    _expect_cursor(spot, "focus within a display must not warp: ", tol=3)
    d.key("Mod1+Shift+semicolon")                                              # B is the right-most window: it moves to display 2
    _expect_cursor(_centre(d, "B"), "focus changed display: ")
    assert _cursor()[0] >= O1["x"], "the cursor should now be on the second display"
s_mouse_warp_output.config = "mouse_warping output\n"
s_mouse_warp_center.config = "mouse_warping center\n"


def _bar():
    return json.loads(run("bar").stdout)


def _bar_workspaces(b, output=0):
    """Workspaces the bar lists for one display (0 = the primary)."""
    return {w["name"]: w for w in b["outputs"][output]["workspaces"]}


def s_workspace_bar(d):
    """The menu bar item lists workspaces with windows, marks showing/focused, shows the binding mode, and
    switches workspace when a cell is clicked."""
    b = d.wait(lambda s: True, "daemon") and _bar()
    assert b["enabled"], "the workspace bar should be enabled by this scenario's config"
    d.spawn("A"); d.spawn("B")
    b = _bar()
    assert b.get("visible"), f"the bar item is not visible on screen (hidden by the notch / a full menu bar?): {b.get('frame')}"
    ws = _bar_workspaces(b)
    assert list(ws) == ["1"] and ws["1"]["showing"] and ws["1"]["focused"] and ws["1"]["windows"] == 2, ws
    if len(b["outputs"]) > 1:                                        # a second display lists its own showing workspace
        other = _bar_workspaces(b, 1)
        assert len(other) == 1 and next(iter(other.values()))["showing"] and not next(iter(other.values()))["focused"], other
    d.key("Mod1+3")                                                  # empty, but showing
    ws = _bar_workspaces(_bar())
    assert sorted(ws) == ["1", "3"] and ws["3"]["focused"] and ws["3"]["showing"] and not ws["1"]["showing"], ws
    d.spawn("C")
    d.key("Mod1+4"); d.key("Mod1+3")                                 # workspace 4 was empty and hidden again: gone
    ws = _bar_workspaces(_bar())
    assert sorted(ws) == ["1", "3"] and ws["3"]["windows"] == 1, ws
    d.key("Mod1+r")
    assert _bar()["mode"] == "resize", "binding mode should show in the bar"
    d.key("Return")
    assert _bar()["mode"] == "default"
    b = _bar()
    cell = next(c for c in b["cells"] if c["workspace"] == "1")
    pt = (cell["x"] + cell["w"] / 2, cell["y"] + cell["h"] / 2)
    f = b["frame"]
    assert f["x"] <= pt[0] <= f["x"] + f["w"] and f["y"] <= pt[1] <= f["y"] + f["h"], "the cell must lie inside the item's own frame"
    d.click(pt, settle=0.8, also="Control Center")                   # a real click on the "1" cell (macOS hosts menu bar items in Control Center)
    assert d.state()["workspace"] == "1", "clicking the cell for workspace 1 should switch to it"
    assert _bar_workspaces(_bar())["1"]["focused"]
s_workspace_bar.config = "workspace_bar yes\n"


def s_workspace_bar_off(d):
    """workspace_bar no: no menu bar item at all."""
    assert _bar()["enabled"] is False


SCENARIOS = [(n[2:], f) for n, f in sorted(globals().items()) if n.startswith("s_") and callable(f)]


def main():
    others = foreign_daemons()
    if others:
        sys.exit(f"Refusing to run: another mac-i3 daemon is running (pid {', '.join(map(str, others))}). It would tile the "
                 "test windows and fight with the test daemon.\nStop it first (Ctrl-C in its terminal), then rerun.")
    wanted = sys.argv[1:]
    failures = 0
    for name, fn in SCENARIOS:
        if wanted and not any(w in name for w in wanted):
            continue
        args = ["-v"] if os.environ.get("VERBOSE") else []
        # Always run on the built-in default config (+ the scenario's extra lines), never on the
        # user's ~/.config/mac-i3/config, whose $mod or bindings would change what the keystrokes do.
        path = os.path.join(tempfile.gettempdir(), f"mac-i3-test-{os.getpid()}.conf")
        with open(path, "w") as fh:
            fh.write(run("default-config", "stock").stdout + "\nmouse_warping none\nworkspace_bar no\n" + (getattr(fn, "config", None) or ""))
        args += ["--config", path]
        d = Daemon(args, only=getattr(fn, "only", "mac-i3"))
        t0 = time.time()
        try:
            d.start()
            r = fn(d)
            held = run("modifiers").stdout.strip()
            assert held == "none", f"the test left modifier keys held down system-wide: {held} (would turn real clicks into Option-clicks)"
            print(f"{'SKIP' if r else 'PASS'}  {name:24s} ({time.time() - t0:.1f}s){'  ' + r if r else ''}")
        except Exception as e:  # noqa: BLE001
            failures += 1
            run("release-modifiers")
            print(f"FAIL  {name:24s} ({time.time() - t0:.1f}s)\n      {str(e).replace(chr(10), chr(10) + '      ')}")
        finally:
            d.stop()
    print("\n%s" % ("all scenarios passed" if not failures else f"{failures} scenario(s) failed"))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
