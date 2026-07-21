#!/usr/bin/env python3
"""
DMS Dock Preview Helper — niri dynamic cast consumer.

Bypasses xdg-desktop-portal entirely. Talks to niri's
org.gnome.Mutter.ScreenCast D-Bus interface directly.
No notifications, no clipboard, no persistent processes
(after cleanup).

Architecture:
    D-Bus: CreateSession → RecordWindow(window-id=1) → Start
    IPC:   niri msg action set-dynamic-cast-window --id N
    D-Bus: PipeWireStreamAdded(node_id) signal → node_id
    Gst:   pipewiresrc path=node_id ! videorate ! jpegenc ! multifilesink
    QML:   Image reads per-window JPEGs from /dev/shm/

Commands:
    run --ids N N N...   Start session + GStreamer pipeline + burst
    stop                  Kill running instance via SIGTERM
    clean                 Delete all per-window JPEGs
"""

import argparse
import io
import json
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

import gi

gi.require_version("Gst", "1.0")
gi.require_version("GLib", "2.0")
gi.require_version("Gio", "2.0")

from gi.repository import GLib, Gio, Gst  # type: ignore  # noqa: E402


# --- Constants ---
NIRI_BUS = "org.gnome.Mutter.ScreenCast"
SCREENCAST_PATH = "/org/gnome/Mutter/ScreenCast"
IFACE_SCREENCAST = "org.gnome.Mutter.ScreenCast"
IFACE_SESSION = "org.gnome.Mutter.ScreenCast.Session"
IFACE_STREAM = "org.gnome.Mutter.ScreenCast.Stream"
DYNAMIC_CAST_WINDOW_ID = 1

CONFIG_DIR = Path.home() / ".config" / "niri" / "dms"
STATE_FILE = CONFIG_DIR / "cast-state.json"
PID_FILE = Path("/dev/shm/dms-cast-helper.pid")
NODE_FILE = Path("/dev/shm/dms-cast-nodeid")
SESSION_FILE = Path("/dev/shm/dms-cast-session")
PREVIEW_FILE = Path("/dev/shm/dms-dock-preview.jpg")
PREVIEW_DIR = Path("/dev/shm")


# --- GLib Variant helpers ---

def make_a_sv(d: dict) -> tuple:
    """Build a{sv} content (tuple of key-value pairs) from Python dict."""
    return tuple((k, v) for k, v in d.items())


def build_tuple(fmt, val):
    """Create GLib.Variant wrapping val as the inner content of a tuple format.
    E.g. build_tuple('(a{sv})', pairs) → GLib.Variant('(a{sv})', (pairs,))"""
    return GLib.Variant(fmt, (val,))


def wait_for_frame(prev_mtime: int, timeout: float = 1.0) -> tuple[bool, int]:
    """Wait for PREVIEW_FILE mtime to change. Returns (found, new_mtime)."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if PREVIEW_FILE.exists():
            mtime = PREVIEW_FILE.stat().st_mtime_ns
            if mtime > prev_mtime:
                return True, mtime
        time.sleep(0.02)
    return False, prev_mtime


# --- D-Bus ScreenCast ---

class NiriScreenCast:
    def __init__(self):
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.session_path = None
        self.stream_path = None
        self.node_id = None

    def _call_sync(self, bus_name, obj_path, iface, method, params, ret_type, timeout_ms=5000):
        return self.bus.call_sync(
            bus_name, obj_path, iface, method, params,
            GLib.VariantType(ret_type),
            Gio.DBusCallFlags.NONE, timeout_ms, None,
        )

    def create_session(self):
        r = self._call_sync(NIRI_BUS, SCREENCAST_PATH, IFACE_SCREENCAST, "CreateSession",
                           build_tuple("(a{sv})", make_a_sv({})), "(o)")
        self.session_path = r.get_child_value(0).get_string()
        print(f"[niri] session: {self.session_path}", flush=True)

    def record_window(self, window_id: int = DYNAMIC_CAST_WINDOW_ID):
        opts = make_a_sv({
            "window-id": GLib.Variant("t", window_id),
            "cursor_mode": GLib.Variant("u", 0),
        })
        r = self._call_sync(NIRI_BUS, self.session_path, IFACE_SESSION, "RecordWindow",
                           build_tuple("(a{sv})", opts), "(o)")
        self.stream_path = r.get_child_value(0).get_string()
        print(f"[niri] stream: {self.stream_path}", flush=True)

    def start_and_wait_for_node(self, target_window_id: int | None = None, timeout_s: float = 15):
        loop = GLib.MainLoop()
        result = {"node_id": None, "timed_out": False}

        def on_pipewire(_c, _s, _p, _i, member, params, *extra):
            node_id = int(params[0])
            result["node_id"] = node_id
            print(f"[niri] PipeWireStreamAdded node_id={node_id}", flush=True)
            loop.quit()

        self.PIPEWIRE_STREAM_ADDED = self.bus.signal_subscribe(
            NIRI_BUS, IFACE_STREAM, "PipeWireStreamAdded",
            self.stream_path, None, Gio.DBusSignalFlags.NONE,
            on_pipewire, None,
        )

        def on_timeout():
            result["timed_out"] = True
            loop.quit()
            return False  # don't repeat

        timer = GLib.timeout_add(int(timeout_s * 1000), on_timeout)

        def on_start_reply(_conn, res, *_args):
            try:
                self.bus.call_finish(res)
            except Exception as e:
                print(f"[niri] Start error: {e}", flush=True)
                loop.quit()
                return False
            print("[niri] Start called", flush=True)

            cmd = ["niri", "msg", "action", "set-dynamic-cast-window"]
            if target_window_id is not None:
                cmd.extend(["--id", str(target_window_id)])
            subprocess.run(cmd, capture_output=True, timeout=5)
            return False

        # Async D-Bus call so MainLoop keeps processing signals
        self.bus.call(
            NIRI_BUS, self.session_path, IFACE_SESSION, "Start",
            None, GLib.VariantType("()"),
            Gio.DBusCallFlags.NONE, -1, None,
            on_start_reply, None,
        )

        loop.run()
        GLib.source_remove(timer)
        self.bus.signal_unsubscribe(self.PIPEWIRE_STREAM_ADDED)

        if result["node_id"] is None:
            raise RuntimeError(
                f"No PipeWireStreamAdded signal "
                f"({'timeout' if result['timed_out'] else 'unknown'})"
            )
        self.node_id = result["node_id"]
        SESSION_FILE.write_text(f"{self.session_path}\n{self.stream_path}")
        return self.node_id

    def set_target(self, window_id: int | None = None):
        cmd = ["niri", "msg", "action", "set-dynamic-cast-window"]
        if window_id is not None:
            cmd.extend(["--id", str(window_id)])
        subprocess.run(cmd, capture_output=True, timeout=5)
        print(f"[niri] target set to window {window_id or 'focused'}", flush=True)
        # Query window size for QML position calculation
        if window_id is not None:
            try:
                r = subprocess.run(["niri", "msg", "--json", "windows"],
                                  capture_output=True, text=True, timeout=5)
                wins = json.loads(r.stdout)
                m = next((w for w in wins if w.get("id") == window_id), None)
                if m:
                    ws = m.get("layout", {}).get("window_size", [0, 0])
                    if ws[0] > 0 and ws[1] > 0:
                        Path("/dev/shm/dms-window-size").write_text(f"{ws[0]} {ws[1]}\n")
                        print(f"[niri] window {window_id} size: {ws[0]}x{ws[1]}", flush=True)
            except Exception as e:
                print(f"[niri] window size query: {e}", flush=True)

    def stop(self):
        if self.session_path:
            try:
                self._call_sync(NIRI_BUS, self.session_path, IFACE_SESSION,
                               "Stop", None, "()")
                print("[niri] session stopped", flush=True)
            except Exception as e:
                print(f"[niri] stop error: {e}", flush=True)
        subprocess.run(["niri", "msg", "action", "clear-dynamic-cast-target"],
                      capture_output=True, timeout=5)


# --- GStreamer pipeline ---

class PreviewPipeline:
    def __init__(self, node_id: int):
        self.pipeline = None
        self.loop = None
        self.node_id = node_id

    def start(self, output_path: str = ""):
        self.loop = GLib.MainLoop()
        out = output_path or str(PREVIEW_FILE)
        pipeline_str = (
            f"pipewiresrc path={self.node_id} ! "
            f"videoconvert ! "
            f"jpegenc quality=80 ! "
            f"multifilesink location={out}"
        )
        self.pipeline = Gst.parse_launch(pipeline_str)
        # Throttle pad probe on encoder sink: max ~5fps
        jpegenc = self.pipeline.get_by_name("jpegenc0")
        if jpegenc:
            sinkpad = jpegenc.get_static_pad("sink")
            _last = [0.0]
            def _throttle(_pad, _info):
                now = time.monotonic()
                if now - _last[0] < 0.2:
                    return Gst.PadProbeReturn.DROP
                _last[0] = now
                return Gst.PadProbeReturn.OK
            sinkpad.add_probe(Gst.PadProbeType.BUFFER, _throttle)
        self.pipeline.set_state(Gst.State.PLAYING)
        print("[gstreamer] pipeline started", flush=True)

    def stop(self):
        if self.pipeline:
            self.pipeline.set_state(Gst.State.NULL)
        if self.loop:
            self.loop.quit()
        print("[gstreamer] stopped", flush=True)


# --- Process management ---

def _find_helpers() -> list[int]:
    """Find all helper processes using pgrep."""
    pids = []
    try:
        result = subprocess.run(
            ["pgrep", "-f", "dms-cast-helper.*run"],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode == 0:
            for line in result.stdout.strip().splitlines():
                pid = int(line.strip())
                if pid != os.getpid():
                    pids.append(pid)
    except Exception:
        pass
    return pids


def stop_running():
    """Stop any running helper process."""
    old_pids = _find_helpers()
    if not old_pids:
        print("[helper] not running", flush=True)
        subprocess.run(["niri", "msg", "action", "clear-dynamic-cast-target"],
                      capture_output=True, timeout=5)
        return
    for pid in old_pids:
        try:
            os.kill(pid, signal.SIGTERM)
            print(f"[helper] sent SIGTERM to PID {pid}", flush=True)
        except ProcessLookupError:
            pass
    # Wait briefly for graceful shutdown
    for pid in old_pids:
        for _ in range(30):
            try:
                os.kill(pid, 0)
                time.sleep(0.1)
            except ProcessLookupError:
                break
    print("[helper] old instances stopped", flush=True)


# --- Multi-window burst + cycle ---

def burst_and_cycle(sc, window_ids, no_cycle=False):
    """Sequential burst capture; optionally followed by 4s cycle."""
    lm = [PREVIEW_FILE.stat().st_mtime_ns if PREVIEW_FILE.exists() else 0]

    def snap_window(wid: int, mtime_before: int, timeout_s: float = 3.0):
        """Copy PREVIEW_FILE to per-window JPEG. Returns new mtime or None."""
        for _ in range(int(timeout_s * 100)):
            time.sleep(0.01)
            if PREVIEW_FILE.exists():
                mtime = PREVIEW_FILE.stat().st_mtime_ns
                if mtime != mtime_before:
                    snap = Path(f"/dev/shm/dms-dock-preview-{wid}.jpg")
                    shutil.copy2(PREVIEW_FILE, snap)
                    print(f"[burst] window {wid} → {snap.name} ({snap.stat().st_size}B)", flush=True)
                    return mtime
        print(f"[burst] window {wid} — frame timeout ({timeout_s}s)", flush=True)
        return None

    # First window: target already set from start_and_wait_for_node
    m = snap_window(window_ids[0], 0, timeout_s=3.0)
    if m is not None:
        lm[0] = m
    elif PREVIEW_FILE.exists():
        snap = Path(f"/dev/shm/dms-dock-preview-{window_ids[0]}.jpg")
        shutil.copy2(PREVIEW_FILE, snap)
        print(f"[burst] window {window_ids[0]} — fallback copy ({snap.stat().st_size}B)", flush=True)
        lm[0] = PREVIEW_FILE.stat().st_mtime_ns

    if len(window_ids) == 1:
        print(f"[burst] single window {window_ids[0]}, done", flush=True)
        return

    for wid in window_ids[1:]:
        sc.set_target(wid)
        time.sleep(0.2)
        m = snap_window(wid, lm[0], timeout_s=3.0)
        if m is not None:
            lm[0] = m

    if no_cycle:
        print("[burst] burst complete (no-cycle mode), pipeline stays alive", flush=True)
        return

    cycle_idx = [0]
    def cycle():
        wid = window_ids[cycle_idx[0]]
        sc.set_target(wid)
        time.sleep(0.3)
        m = snap_window(wid, lm[0], timeout_s=3.0)
        if m is not None:
            lm[0] = m
        cycle_idx[0] = (cycle_idx[0] + 1) % len(window_ids)
        return True

    GLib.timeout_add(4000, cycle)
    print(f"[burst] cycle mode: {len(window_ids)} windows, 4s interval", flush=True)


# --- Main ---

def run_pipeline(window_ids: list[int] | None = None, no_cycle: bool = False):
    """Start D-Bus session + GStreamer + burst (+ optional cycle)."""
    _sc: NiriScreenCast | None = None
    _gst: PreviewPipeline | None = None

    def _cleanup(_sig, _frame):
        print("\n[helper] shutting down...", flush=True)
        if _gst:
            _gst.stop()
        if _sc:
            _sc.stop()
        for f in [PID_FILE, NODE_FILE, SESSION_FILE]:
            f.unlink(missing_ok=True)
        # Clean up per-window JPEGs
        for f in PREVIEW_DIR.glob("dms-dock-preview-*.jpg"):
            f.unlink(missing_ok=True)
        sys.exit(0)

    signal.signal(signal.SIGTERM, _cleanup)
    signal.signal(signal.SIGINT, _cleanup)

    # Kill old helper processes
    stop_running()

    ids = window_ids or []
    first_id = ids[0] if ids else None

    _sc = NiriScreenCast()
    _sc.create_session()
    _sc.record_window()
    node_id = _sc.start_and_wait_for_node(target_window_id=first_id)

    PID_FILE.write_text(str(os.getpid()))
    NODE_FILE.write_text(str(node_id))
    # Also clean per-window JPEGs for our target windows (stale content from old sessions)
    for wid in ids:
        p = PREVIEW_DIR / f"dms-dock-preview-{wid}.jpg"
        p.unlink(missing_ok=True)

    _gst = PreviewPipeline(node_id=node_id)
    _gst.start()

    if ids:
        burst_and_cycle(_sc, ids, no_cycle=no_cycle)

    print("[helper] pipeline running — Ctrl+C or SIGTERM to stop", flush=True)
    if _gst and _gst.loop:
        _gst.loop.run()


def cmd_run(args: argparse.Namespace):
    run_pipeline(args.ids, no_cycle=getattr(args, 'no_cycle', False))


def cmd_stop(args: argparse.Namespace):
    stop_running()


def cmd_snap(args: argparse.Namespace):
    """Atomically switch target, wait for fresh frame, then copy to per-window JPEG."""
    for wid in args.ids:
        prev_mtime = PREVIEW_FILE.stat().st_mtime_ns if PREVIEW_FILE.exists() else 0
        subprocess.run(
            ["niri", "msg", "action", "set-dynamic-cast-window", "--id", str(wid)],
            capture_output=True, timeout=5,
        )
        snap = PREVIEW_DIR / f"dms-dock-preview-{wid}.jpg"
        time.sleep(0.15)
        found, first_mtime = wait_for_frame(prev_mtime, timeout=3.0)
        if not found:
            time.sleep(0.2)
            if PREVIEW_FILE.exists():
                shutil.copy2(PREVIEW_FILE, snap)
                print(f"[snap] window {wid} → {snap.name} ({snap.stat().st_size}B) fallback (no frame change)", flush=True)
            else:
                print(f"[snap] window {wid} no preview file available", flush=True)
            continue
        found, second_mtime = wait_for_frame(first_mtime, timeout=0.6)
        if not found:
            time.sleep(0.12)
            shutil.copy2(PREVIEW_FILE, snap)
            print(
                f"[snap] window {wid} → {snap.name} ({snap.stat().st_size}B) "
                f"after single-frame settle from {first_mtime}",
                flush=True,
            )
            continue
        shutil.copy2(PREVIEW_FILE, snap)
        print(
            f"[snap] window {wid} → {snap.name} ({snap.stat().st_size}B) "
            f"after mtimes {first_mtime}->{second_mtime}",
            flush=True,
        )


def cmd_clean(args: argparse.Namespace):
    """Delete all per-window JPEGs from /dev/shm/."""
    count = 0
    for f in PREVIEW_DIR.glob("dms-dock-preview-*.jpg"):
        f.unlink()
        count += 1
    PREVIEW_FILE.unlink(missing_ok=True)
    print(f"[clean] removed {count} preview files", flush=True)


def main():
    Gst.init([])

    parser = argparse.ArgumentParser(description="DMS Dock Preview Helper")
    sub = parser.add_subparsers(dest="command", required=True)

    p_run = sub.add_parser("run", help="Start session + GStreamer + burst")
    p_run.add_argument("--ids", type=int, nargs="+", required=True,
                       help="Window IDs to capture")
    p_run.add_argument("--no-cycle", action="store_true",
                       help="Only do burst capture, no perpetual refresh cycle")

    p_snap = sub.add_parser("snap", help="Copy current frame to per-window JPEG(s)")
    p_snap.add_argument("--ids", type=int, nargs="+", required=True,
                        help="Window ID(s) to snap")

    sub.add_parser("stop", help="Kill running instance")
    sub.add_parser("clean", help="Delete per-window JPEGs")

    args = parser.parse_args()
    if args.command == "run":
        cmd_run(args)
    elif args.command == "snap":
        cmd_snap(args)
    elif args.command == "stop":
        cmd_stop(args)
    elif args.command == "clean":
        cmd_clean(args)


if __name__ == "__main__":
    main()
