#!/usr/bin/env python3
"""Handle KEY_POWER without putting the PinePhone Pro display into DRM DPMS."""

from __future__ import annotations

import argparse
import fcntl
import os
import pathlib
import struct
import subprocess
import time
from collections.abc import Callable


EV_KEY = 0x01
KEY_POWER = 116
KEY_RELEASE = 0
KEY_PRESS = 1
EVIOCGRAB = 0x40044590
INPUT_EVENT = struct.Struct("llHHi")


def read_int(path: pathlib.Path) -> int | None:
    try:
        return int(path.read_text(encoding="ascii").strip())
    except (FileNotFoundError, OSError, ValueError):
        return None


def write_int(path: pathlib.Path, value: int) -> bool:
    try:
        path.write_text(f"{value}\n", encoding="ascii")
        return True
    except (FileNotFoundError, OSError) as error:
        print(f"power-button: cannot write {path}: {error}", flush=True)
        return False


def discover_backlight(root: pathlib.Path) -> pathlib.Path:
    candidates = sorted(entry for entry in root.glob("*") if (entry / "brightness").exists())
    if not candidates:
        raise RuntimeError(f"no backlight found below {root}")
    return candidates[0]


class ButtonController:
    def __init__(
        self,
        brightness_path: pathlib.Path,
        *,
        fallback_brightness: int = 51,
        long_press_seconds: float = 3.0,
        lock_sessions: Callable[[], bool],
        poweroff: Callable[[], None],
    ) -> None:
        self.brightness_path = brightness_path
        self.fallback_brightness = fallback_brightness
        self.long_press_seconds = long_press_seconds
        self.lock_sessions = lock_sessions
        self.poweroff = poweroff
        current = read_int(brightness_path)
        self.blanked = current == 0
        self.saved_brightness = current if current and current > 0 else fallback_brightness
        self.press_started: float | None = None

    def handle(self, event_type: int, code: int, value: int, now: float) -> None:
        if event_type != EV_KEY or code != KEY_POWER:
            return
        if value == KEY_PRESS:
            if self.press_started is None:
                self.press_started = now
            return
        if value != KEY_RELEASE or self.press_started is None:
            return

        duration = now - self.press_started
        self.press_started = None
        if duration >= self.long_press_seconds:
            print(f"power-button: orderly poweroff after {duration:.1f}s press", flush=True)
            self.poweroff()
        elif self.blanked:
            if write_int(self.brightness_path, self.saved_brightness):
                self.blanked = False
                print(f"power-button: backlight restored to {self.saved_brightness}", flush=True)
        else:
            current = read_int(self.brightness_path)
            if current and current > 0:
                self.saved_brightness = current
            if not self.lock_sessions():
                print("power-button: lock request failed; leaving display on", flush=True)
                return
            if write_int(self.brightness_path, 0):
                self.blanked = True
                print("power-button: session locked; backlight off (DRM remains on)", flush=True)


def command_succeeds(command: list[str]) -> bool:
    try:
        return subprocess.run(command, check=False, timeout=10).returncode == 0
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"power-button: command failed: {error}", flush=True)
        return False


def read_event(fd: int) -> tuple[int, int, int] | None:
    data = b""
    while len(data) < INPUT_EVENT.size:
        chunk = os.read(fd, INPUT_EVENT.size - len(data))
        if not chunk:
            return None
        data += chunk
    _sec, _usec, event_type, code, value = INPUT_EVENT.unpack(data)
    return event_type, code, value


def run(args: argparse.Namespace) -> None:
    backlight = discover_backlight(pathlib.Path(args.backlight_root))
    brightness_path = backlight / "brightness"
    controller = ButtonController(
        brightness_path,
        fallback_brightness=args.fallback_brightness,
        long_press_seconds=args.long_press_seconds,
        lock_sessions=lambda: command_succeeds(["loginctl", "lock-sessions"]),
        poweroff=lambda: command_succeeds(["systemctl", "poweroff", "--no-wall"]),
    )

    while True:
        fd: int | None = None
        try:
            fd = os.open(args.input_device, os.O_RDONLY)
            fcntl.ioctl(fd, EVIOCGRAB, 1)
            print(
                f"power-button: exclusively grabbed {args.input_device}; "
                "using backlight-only blanking",
                flush=True,
            )
            while True:
                event = read_event(fd)
                if event is None:
                    raise OSError("input device reached EOF")
                controller.handle(*event, time.monotonic())
        except OSError as error:
            print(f"power-button: input unavailable: {error}; retrying", flush=True)
            time.sleep(1)
        finally:
            if fd is not None:
                try:
                    fcntl.ioctl(fd, EVIOCGRAB, 0)
                except OSError:
                    pass
                os.close(fd)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--input-device",
        default="/dev/input/by-path/platform-gpio-keys-event",
    )
    parser.add_argument("--backlight-root", default="/sys/class/backlight")
    parser.add_argument("--fallback-brightness", type=int, default=51)
    parser.add_argument("--long-press-seconds", type=float, default=3.0)
    run(parser.parse_args())


if __name__ == "__main__":
    main()
