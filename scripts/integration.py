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
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.environ.get("MAC_I3", os.path.join(ROOT, ".build/debug/mac-i3"))
TOL = 3


def run(*args, timeout=10):
    return subprocess.run([BIN, *args], capture_output=True, text=True, timeout=timeout)


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


def cleanup_leftovers():
    subprocess.run(["pkill", "-f", "mac-i3 test-window"], capture_output=True)
    subprocess.run(["pkill", "-f", "mac-i3 run --only"], capture_output=True)
    time.sleep(0.3)
    try:
        os.unlink(os.path.expanduser("~/.config/mac-i3/ipc.sock"))
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


SCENARIOS = [(n[2:], f) for n, f in sorted(globals().items()) if n.startswith("s_") and callable(f)]


def main():
    wanted = sys.argv[1:]
    failures = 0
    for name, fn in SCENARIOS:
        if wanted and not any(w in name for w in wanted):
            continue
        args = ["-v"] if os.environ.get("VERBOSE") else []
        cfg = getattr(fn, "config", None)
        if cfg:
            import subprocess as sp
            path = "/tmp/mac-i3-integration.conf"
            with open(path, "w") as fh:
                fh.write(sp.run([BIN, "default-config"], capture_output=True, text=True).stdout + "\n" + cfg)
            args += ["--config", path]
        d = Daemon(args, only=getattr(fn, "only", "mac-i3"))
        t0 = time.time()
        try:
            d.start()
            r = fn(d)
            print(f"{'SKIP' if r else 'PASS'}  {name:24s} ({time.time() - t0:.1f}s){'  ' + r if r else ''}")
        except Exception as e:  # noqa: BLE001
            failures += 1
            print(f"FAIL  {name:24s} ({time.time() - t0:.1f}s)\n      {str(e).replace(chr(10), chr(10) + '      ')}")
        finally:
            d.stop()
    print("\n%s" % ("all scenarios passed" if not failures else f"{failures} scenario(s) failed"))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
