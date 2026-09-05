#!/usr/bin/env python3
"""PinePhone battery telemetry, safety guard, and power-profile daemon."""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import http.server
import json
import math
import os
import pathlib
import signal
import subprocess
import sys
import threading
import time
import urllib.parse
from typing import Any, Iterable


DEFAULT_CONFIG = {
    "batteryPath": None,
    "backlightPath": None,
    "interactiveBrightness": 51,
    "interactiveServices": ["phosh.service"],
    "sampleInterval": 30,
    "retentionDays": 30,
    "listenAddress": "127.0.0.1",
    "port": 9095,
    "warningPercent": 20,
    "powerSavePercent": 15,
    "performanceOnExternalPower": False,
    "manageFrequencies": True,
    "criticalPercent": 8,
    "shutdownPercent": 5,
    "shutdownVoltageMicrovolts": 3_400_000,
    "voltageGuardPercent": 20,
    "shutdownConfirmations": 3,
    "defaultProfile": "auto",
    "profiles": {
        "performance": {
            "cpuMaxPercent": 100,
            "cpuGovernor": "performance",
            "gpuMaxPercent": 100,
            "gpuGovernor": "performance",
        },
        "balanced": {
            "cpuMaxPercent": 75,
            "cpuGovernor": "schedutil",
            "gpuMaxPercent": 67,
            "gpuGovernor": "simple_ondemand",
        },
        "gateway": {
            "cpuMaxPercent": 81,
            "cpuGovernor": "schedutil",
            "gpuMaxPercent": 100,
            "gpuGovernor": "simple_ondemand",
            "headless": True,
            "offlineCpus": [4, 5],
        },
        "powersave": {
            "cpuMaxPercent": 50,
            "cpuGovernor": "schedutil",
            "gpuMaxPercent": 50,
            "gpuGovernor": "simple_ondemand",
        },
        "critical": {
            "cpuMaxPercent": 35,
            "cpuGovernor": "powersave",
            "gpuMaxPercent": 35,
            "gpuGovernor": "powersave",
        },
    },
}

FIELDS = [
    "timestamp",
    "epoch",
    "battery",
    "status",
    "capacity_percent",
    "voltage_uv",
    "current_ua",
    "power_uw",
    "charge_now_uah",
    "charge_full_uah",
    "charge_full_design_uah",
    "energy_now_uwh",
    "energy_full_uwh",
    "energy_full_design_uwh",
    "temperature_decic",
    "cycle_count",
    "health",
    "external_power",
    "cpu_average_khz",
    "cpu_limit_khz",
    "cpu_temperature_mc",
    "gpu_frequency_hz",
    "gpu_limit_hz",
    "gpu_temperature_mc",
    "profile",
]

NUMERIC_FIELDS = set(FIELDS) - {
    "timestamp",
    "battery",
    "status",
    "health",
    "profile",
}


def merged_config(path: str) -> dict[str, Any]:
    config = json.loads(json.dumps(DEFAULT_CONFIG))
    try:
        with open(path, encoding="utf-8") as handle:
            supplied = json.load(handle)
    except FileNotFoundError:
        supplied = {}
    for key, value in supplied.items():
        if key == "profiles":
            for name, profile in value.items():
                config["profiles"].setdefault(name, {}).update(profile)
        else:
            config[key] = value
    return config


def read_text(path: pathlib.Path) -> str | None:
    try:
        return path.read_text(encoding="ascii").strip()
    except (FileNotFoundError, PermissionError, OSError):
        return None


def read_int(path: pathlib.Path) -> int | None:
    value = read_text(path)
    try:
        return int(value) if value not in (None, "") else None
    except ValueError:
        return None


def write_text(path: pathlib.Path, value: str | int) -> bool:
    try:
        path.write_text(f"{value}\n", encoding="ascii")
        return True
    except (FileNotFoundError, PermissionError, OSError) as error:
        print(f"power-monitor: cannot write {path}: {error}", file=sys.stderr)
        return False


def discover_battery(power_supply_root: pathlib.Path, configured: str | None) -> pathlib.Path:
    if configured:
        candidate = pathlib.Path(configured)
        if candidate.is_dir():
            return candidate
        raise RuntimeError(f"configured battery path does not exist: {candidate}")
    candidates = [
        entry
        for entry in power_supply_root.glob("*")
        if read_text(entry / "type") == "Battery"
    ]
    candidates.sort(
        key=lambda entry: (
            read_int(entry / "capacity") is not None,
            read_int(entry / "voltage_now") is not None,
        ),
        reverse=True,
    )
    if not candidates:
        raise RuntimeError(f"no Battery device found below {power_supply_root}")
    return candidates[0]


def external_power_online(power_supply_root: pathlib.Path, battery: pathlib.Path) -> bool:
    for entry in power_supply_root.glob("*"):
        if entry == battery or read_text(entry / "type") == "Battery":
            continue
        if read_int(entry / "online") == 1:
            return True
    return False


def thermal_temperature(thermal_root: pathlib.Path, wanted: str) -> int | None:
    for entry in thermal_root.glob("thermal_zone*"):
        zone_type = (read_text(entry / "type") or "").lower()
        if wanted in zone_type:
            return read_int(entry / "temp")
    return None


def policy_values(cpufreq_root: pathlib.Path) -> tuple[int | None, int | None]:
    current: list[int] = []
    limits: list[int] = []
    for policy in cpufreq_root.glob("policy*"):
        value = read_int(policy / "scaling_cur_freq")
        if value is not None:
            current.append(value)
        value = read_int(policy / "scaling_max_freq")
        if value is not None:
            limits.append(value)
    return (
        round(sum(current) / len(current)) if current else None,
        max(limits) if limits else None,
    )


def discover_gpu(devfreq_root: pathlib.Path) -> pathlib.Path | None:
    devices = list(devfreq_root.glob("*"))
    for entry in devices:
        if "gpu" in entry.name.lower() or "gpu" in (read_text(entry / "name") or "").lower():
            return entry
    return None


def normalise_flow(value: int | None, status: str) -> int | None:
    if value is None:
        return None
    magnitude = abs(value)
    if status.lower() == "charging":
        return -magnitude
    if status.lower() == "discharging":
        return magnitude
    return value


def collect_sample(
    config: dict[str, Any],
    profile: str,
    *,
    power_supply_root: pathlib.Path = pathlib.Path("/sys/class/power_supply"),
    cpufreq_root: pathlib.Path = pathlib.Path("/sys/devices/system/cpu/cpufreq"),
    devfreq_root: pathlib.Path = pathlib.Path("/sys/class/devfreq"),
    thermal_root: pathlib.Path = pathlib.Path("/sys/class/thermal"),
) -> dict[str, Any]:
    battery = discover_battery(power_supply_root, config.get("batteryPath"))
    status = read_text(battery / "status") or "Unknown"
    voltage = read_int(battery / "voltage_now")
    current = normalise_flow(read_int(battery / "current_now"), status)
    direct_power = read_int(battery / "power_now")
    if direct_power is not None:
        power = normalise_flow(direct_power, status)
    elif voltage is not None and current is not None:
        power = round(voltage * current / 1_000_000)
    else:
        power = None

    cpu_current, cpu_limit = policy_values(cpufreq_root)
    gpu = discover_gpu(devfreq_root)
    now = time.time()
    return {
        "timestamp": dt.datetime.fromtimestamp(now, dt.timezone.utc).isoformat(timespec="seconds"),
        "epoch": round(now),
        "battery": battery.name,
        "status": status,
        "capacity_percent": read_int(battery / "capacity"),
        "voltage_uv": voltage,
        "current_ua": current,
        "power_uw": power,
        "charge_now_uah": read_int(battery / "charge_now"),
        "charge_full_uah": read_int(battery / "charge_full"),
        "charge_full_design_uah": read_int(battery / "charge_full_design"),
        "energy_now_uwh": read_int(battery / "energy_now"),
        "energy_full_uwh": read_int(battery / "energy_full"),
        "energy_full_design_uwh": read_int(battery / "energy_full_design"),
        "temperature_decic": read_int(battery / "temp"),
        "cycle_count": read_int(battery / "cycle_count"),
        "health": read_text(battery / "health"),
        "external_power": external_power_online(power_supply_root, battery),
        "cpu_average_khz": cpu_current,
        "cpu_limit_khz": cpu_limit,
        "cpu_temperature_mc": thermal_temperature(thermal_root, "cpu"),
        "gpu_frequency_hz": read_int(gpu / "cur_freq") if gpu else None,
        "gpu_limit_hz": read_int(gpu / "max_freq") if gpu else None,
        "gpu_temperature_mc": thermal_temperature(thermal_root, "gpu"),
        "profile": profile,
    }


def csv_value(value: Any) -> str | int:
    if value is None:
        return ""
    if isinstance(value, bool):
        return int(value)
    return value


def append_sample(path: pathlib.Path, sample: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    new_file = not path.exists() or path.stat().st_size == 0
    with path.open("a", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS, extrasaction="ignore")
        if new_file:
            writer.writeheader()
        writer.writerow({name: csv_value(sample.get(name)) for name in FIELDS})


def atomic_json(path: pathlib.Path, value: dict[str, Any]) -> None:
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, separators=(",", ":")) + "\n", encoding="utf-8")
    os.chmod(temporary, 0o644)
    os.replace(temporary, path)


def parse_csv_value(name: str, value: str) -> Any:
    if value == "":
        return None
    if name in NUMERIC_FIELDS:
        try:
            return int(value)
        except ValueError:
            try:
                return float(value)
            except ValueError:
                return None
    return value


def load_samples(path: pathlib.Path, since: int = 0) -> list[dict[str, Any]]:
    try:
        with path.open(encoding="utf-8", newline="") as handle:
            rows = [
                {name: parse_csv_value(name, value) for name, value in row.items()}
                for row in csv.DictReader(handle)
                if int(row.get("epoch") or 0) >= since
            ]
    except FileNotFoundError:
        return []
    if len(rows) > 2000:
        stride = math.ceil(len(rows) / 2000)
        rows = rows[::stride]
    return rows


def trim_samples(path: pathlib.Path, cutoff: int) -> None:
    if not path.exists():
        return
    temporary = path.with_suffix(".retention.tmp")
    with path.open(encoding="utf-8", newline="") as source, temporary.open(
        "w", encoding="utf-8", newline=""
    ) as destination:
        reader = csv.DictReader(source)
        writer = csv.DictWriter(destination, fieldnames=FIELDS, extrasaction="ignore")
        writer.writeheader()
        for row in reader:
            if int(row.get("epoch") or 0) >= cutoff:
                writer.writerow(row)
    os.replace(temporary, path)


def available_words(path: pathlib.Path) -> list[str]:
    return (read_text(path) or "").split()


def closest_frequency(values: Iterable[int], target: int) -> int | None:
    eligible = [value for value in values if value <= target]
    return max(eligible) if eligible else min(values, default=None)


def apply_profile(
    name: str,
    config: dict[str, Any],
    *,
    cpufreq_root: pathlib.Path = pathlib.Path("/sys/devices/system/cpu/cpufreq"),
    devfreq_root: pathlib.Path = pathlib.Path("/sys/class/devfreq"),
) -> list[str]:
    profile = config["profiles"][name]
    changes: list[str] = []
    for policy in cpufreq_root.glob("policy*"):
        hardware_min = read_int(policy / "cpuinfo_min_freq")
        hardware_max = read_int(policy / "cpuinfo_max_freq")
        if hardware_max is None:
            continue
        target_ceiling = max(
            hardware_min or 0,
            round(hardware_max * int(profile["cpuMaxPercent"]) / 100),
        )
        frequencies = [
            int(value)
            for value in available_words(policy / "scaling_available_frequencies")
            if value.isdigit()
        ]
        target = closest_frequency(frequencies, target_ceiling) if frequencies else target_ceiling
        available = available_words(policy / "scaling_available_governors")
        preferred = str(profile["cpuGovernor"])
        governor = preferred if preferred in available else (
            "schedutil" if "schedutil" in available else (available[0] if available else None)
        )
        if hardware_min is not None:
            write_text(policy / "scaling_min_freq", hardware_min)
        if write_text(policy / "scaling_max_freq", target):
            changes.append(f"{policy.name}.max={target}")
        if governor and write_text(policy / "scaling_governor", governor):
            changes.append(f"{policy.name}.governor={governor}")

    gpu = discover_gpu(devfreq_root)
    if gpu:
        frequencies = [
            int(value)
            for value in available_words(gpu / "available_frequencies")
            if value.isdigit()
        ]
        hardware_max = max(frequencies, default=read_int(gpu / "max_freq") or 0)
        hardware_min = min(frequencies, default=read_int(gpu / "min_freq") or 0)
        target = closest_frequency(
            frequencies or [hardware_max],
            round(hardware_max * int(profile["gpuMaxPercent"]) / 100),
        )
        available = available_words(gpu / "available_governors")
        preferred = str(profile["gpuGovernor"])
        governor = preferred if preferred in available else (
            "simple_ondemand" if "simple_ondemand" in available else (available[0] if available else None)
        )
        if hardware_min:
            write_text(gpu / "min_freq", hardware_min)
        if target and write_text(gpu / "max_freq", target):
            changes.append(f"{gpu.name}.max={target}")
        if governor and write_text(gpu / "governor", governor):
            changes.append(f"{gpu.name}.governor={governor}")
    return changes


def discover_backlight(config: dict[str, Any], root: pathlib.Path) -> pathlib.Path | None:
    configured = config.get("backlightPath")
    if configured:
        candidate = pathlib.Path(configured)
        return candidate if candidate.is_dir() else None
    return next(iter(sorted(root.glob("*"))), None)


def managed_offline_cpus(config: dict[str, Any]) -> set[int]:
    return {
        int(cpu)
        for profile in config["profiles"].values()
        for cpu in profile.get("offlineCpus", [])
        if int(cpu) > 0
    }


def apply_operating_mode(
    name: str,
    config: dict[str, Any],
    state_dir: pathlib.Path,
    *,
    cpu_root: pathlib.Path = pathlib.Path("/sys/devices/system/cpu"),
    backlight_root: pathlib.Path = pathlib.Path("/sys/class/backlight"),
    command_runner: Any = subprocess.run,
) -> list[str]:
    """Apply reversible headless/display and CPU-hotplug parts of a profile."""
    profile = config["profiles"][name]
    headless = bool(profile.get("headless", False))
    offline_cpus = {int(cpu) for cpu in profile.get("offlineCpus", []) if int(cpu) > 0}
    services = list(config.get("interactiveServices", []))
    backlight = discover_backlight(config, backlight_root)
    brightness_path = backlight / "brightness" if backlight else None
    saved_brightness_path = state_dir / "interactive_brightness"
    operating_mode_path = state_dir / "operating_mode"
    previous_mode = read_text(operating_mode_path)
    changes: list[str] = []

    if headless:
        if services:
            command_runner(["systemctl", "stop", *services], check=False, timeout=30)
            changes.append("display-services=stopped")
        if brightness_path:
            brightness = read_int(brightness_path)
            if brightness is not None and brightness > 0:
                saved_brightness_path.write_text(f"{brightness}\n", encoding="ascii")
                os.chmod(saved_brightness_path, 0o644)
            if write_text(brightness_path, 0):
                changes.append("backlight=0")
        for cpu in sorted(offline_cpus, reverse=True):
            online_path = cpu_root / f"cpu{cpu}" / "online"
            if read_int(online_path) == 1 and write_text(online_path, 0):
                changes.append(f"cpu{cpu}=offline")
        operating_mode_path.write_text("headless\n", encoding="ascii")
        os.chmod(operating_mode_path, 0o644)
    else:
        # Restore only CPUs that one of our profiles is allowed to offline.
        for cpu in sorted(managed_offline_cpus(config)):
            online_path = cpu_root / f"cpu{cpu}" / "online"
            if read_int(online_path) == 0 and write_text(online_path, 1):
                changes.append(f"cpu{cpu}=online")
        # Only the explicit headless -> interactive transition owns display
        # state. On boot, daemon restart, or an interactive profile change,
        # graphical.target and the power-button handler already own the
        # compositor and backlight. Writing brightness here used to race DRM
        # startup and could also illuminate a screen the button handler still
        # considered blanked.
        if previous_mode == "headless":
            if brightness_path:
                brightness = read_int(saved_brightness_path)
                if brightness is None or brightness <= 0:
                    brightness = int(config.get("interactiveBrightness", 51))
                maximum = read_int(backlight / "max_brightness") if backlight else None
                if maximum is not None:
                    brightness = min(brightness, maximum)
                if write_text(brightness_path, brightness):
                    changes.append(f"backlight={brightness}")
            if services:
                command_runner(["systemctl", "start", *reversed(services)], check=False, timeout=30)
                changes.append("display-services=started")
        operating_mode_path.write_text("interactive\n", encoding="ascii")
        os.chmod(operating_mode_path, 0o644)
    return changes


def selected_auto_profile(sample: dict[str, Any], config: dict[str, Any]) -> str:
    status = str(sample.get("status") or "").lower()
    capacity = sample.get("capacity_percent")
    if status == "charging" or sample.get("external_power"):
        return "performance" if config.get("performanceOnExternalPower") else "balanced"
    if capacity is not None and capacity <= config["criticalPercent"]:
        voltage = sample.get("voltage_uv")
        voltage_limit = config.get("shutdownVoltageMicrovolts")
        # The RK818 can report 0% for several minutes after boot while its
        # voltage still contradicts an empty battery. Avoid pinning every CPU
        # to the minimum-frequency critical governor from that untrusted
        # sample; retain conservative schedutil limits until the voltage also
        # confirms the critical state.
        if (
            capacity <= config["shutdownPercent"]
            and voltage is not None
            and voltage_limit is not None
            and voltage > voltage_limit
        ):
            return "powersave"
        return "critical"
    if capacity is not None and capacity <= config["powerSavePercent"]:
        return "powersave"
    return "balanced"


class SafetyGuard:
    def __init__(self, config: dict[str, Any]):
        self.config = config
        self.unsafe_count = 0

    def check(self, sample: dict[str, Any]) -> tuple[bool, str | None]:
        if str(sample.get("status") or "").lower() != "discharging" or sample.get("external_power"):
            self.unsafe_count = 0
            return False, None
        capacity = sample.get("capacity_percent")
        voltage = sample.get("voltage_uv")
        voltage_limit = self.config.get("shutdownVoltageMicrovolts")
        # The RK818 gauge sometimes reports 0% for several minutes after boot
        # while a charged cell is still above 4 V.  Never power off from that
        # contradictory percentage.  If voltage monitoring is configured, a
        # low percentage must be corroborated by low voltage.
        capacity_low = (
            capacity is not None
            and capacity <= self.config["shutdownPercent"]
            and (voltage is None or voltage_limit is None or voltage <= voltage_limit)
        )
        voltage_low = (
            voltage_limit is not None
            and voltage is not None
            and voltage <= voltage_limit
            and (capacity is None or capacity <= self.config["voltageGuardPercent"])
        )
        if not (capacity_low or voltage_low):
            self.unsafe_count = 0
            return False, None
        self.unsafe_count += 1
        reasons = []
        if capacity_low:
            reasons.append(f"capacity {capacity}%")
        if voltage_low:
            reasons.append(f"voltage {voltage / 1_000_000:.3f} V")
        confirmed = self.unsafe_count >= self.config["shutdownConfirmations"]
        return confirmed, ", ".join(reasons)


def health_summary(sample: dict[str, Any]) -> dict[str, Any]:
    learned = sample.get("charge_full_uah") or sample.get("energy_full_uwh")
    design = sample.get("charge_full_design_uah") or sample.get("energy_full_design_uwh")
    health_percent = round(learned * 100 / design, 1) if learned and design else None
    remaining = sample.get("energy_now_uwh")
    if remaining is None and sample.get("voltage_uv") is not None:
        charge = sample.get("charge_now_uah")
        if charge is None and sample.get("charge_full_uah") and sample.get("capacity_percent") is not None:
            charge = sample["charge_full_uah"] * sample["capacity_percent"] / 100
        if charge is not None:
            remaining = round(charge * sample["voltage_uv"] / 1_000_000)
    power = sample.get("power_uw")
    hours = round(remaining / power, 2) if remaining and power and power > 0 else None
    return {
        "learnedCapacityPercent": health_percent,
        "estimatedRemainingEnergyUwh": remaining,
        "instantaneousHoursRemaining": hours,
        "powerMeaning": "positive is battery discharge; negative is net battery charging",
    }


class Monitor:
    def __init__(self, config: dict[str, Any], state_dir: pathlib.Path):
        self.config = config
        self.state_dir = state_dir
        self.samples_path = state_dir / "samples.csv"
        self.current_path = state_dir / "current.json"
        self.profile_path = state_dir / "profile"
        self.events_path = state_dir / "events.log"
        self.guard = SafetyGuard(config)
        self.stop_event = threading.Event()
        self.wake_event = threading.Event()
        self.applied_profile: str | None = None
        self.last_warning_bucket: int | None = None
        self.last_trim = 0.0
        state_dir.mkdir(parents=True, exist_ok=True)
        if not self.profile_path.exists():
            self.profile_path.write_text(config["defaultProfile"] + "\n", encoding="ascii")
            os.chmod(self.profile_path, 0o644)

    def event(self, message: str) -> None:
        stamp = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
        line = f"{stamp} {message}"
        print(f"power-monitor: {message}", flush=True)
        with self.events_path.open("a", encoding="utf-8") as handle:
            handle.write(line + "\n")

    def desired_profile(self) -> str:
        desired = read_text(self.profile_path) or self.config["defaultProfile"]
        valid = {"auto", *self.config["profiles"].keys()}
        return desired if desired in valid else "auto"

    def cycle(self) -> dict[str, Any]:
        desired = self.desired_profile()
        initial = collect_sample(self.config, self.applied_profile or "initialising")
        effective = selected_auto_profile(initial, self.config) if desired == "auto" else desired
        if effective != self.applied_profile:
            changes = apply_operating_mode(effective, self.config, self.state_dir)
            if self.config.get("manageFrequencies", True):
                changes.extend(apply_profile(effective, self.config))
            else:
                changes.append("frequency-management=disabled")
            self.applied_profile = effective
            self.event(f"profile={effective} requested={desired} {' '.join(changes)}")
        sample = collect_sample(self.config, effective)
        sample["requested_profile"] = desired
        sample["summary"] = health_summary(sample)
        append_sample(self.samples_path, sample)
        atomic_json(self.current_path, sample)

        capacity = sample.get("capacity_percent")
        warning_bucket = capacity // 5 if capacity is not None else None
        if str(sample.get("status") or "").lower() != "discharging" or (
            capacity is not None and capacity > self.config["warningPercent"]
        ):
            self.last_warning_bucket = None
        elif warning_bucket is not None and warning_bucket != self.last_warning_bucket:
            self.event(f"low battery: {capacity}% at {(sample.get('voltage_uv') or 0) / 1_000_000:.3f} V")
            self.last_warning_bucket = warning_bucket

        shutdown, reason = self.guard.check(sample)
        if shutdown:
            self.event(f"orderly poweroff: {reason}; guard confirmed {self.guard.unsafe_count} samples")
            subprocess.run(["systemctl", "poweroff", "--no-wall"], check=False)

        now = time.time()
        if now - self.last_trim >= 86400:
            trim_samples(self.samples_path, round(now - self.config["retentionDays"] * 86400))
            self.last_trim = now
        return sample

    def run(self) -> None:
        while not self.stop_event.is_set():
            self.wake_event.clear()
            started = time.monotonic()
            try:
                self.cycle()
            except Exception as error:  # Keep protection alive through transient sysfs races.
                self.event(f"sample failed: {type(error).__name__}: {error}")
            delay = max(0.1, self.config["sampleInterval"] - (time.monotonic() - started))
            self.wake_event.wait(delay)


class DashboardHandler(http.server.BaseHTTPRequestHandler):
    monitor: Monitor
    asset_dir: pathlib.Path

    def log_message(self, fmt: str, *args: Any) -> None:
        return

    def send_bytes(self, content: bytes, content_type: str, status: int = 200) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def do_GET(self) -> None:  # noqa: N802 - required by BaseHTTPRequestHandler
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/":
            try:
                content = (self.asset_dir / "dashboard.html").read_bytes()
                self.send_bytes(content, "text/html; charset=utf-8")
            except FileNotFoundError:
                self.send_bytes(b"dashboard asset missing\n", "text/plain", 404)
        elif parsed.path == "/api/current":
            try:
                content = self.monitor.current_path.read_bytes()
            except FileNotFoundError:
                content = b"{}\n"
            self.send_bytes(content, "application/json")
        elif parsed.path == "/api/samples":
            query = urllib.parse.parse_qs(parsed.query)
            try:
                hours = min(720, max(1, int(query.get("hours", ["24"])[0])))
            except ValueError:
                hours = 24
            rows = load_samples(self.monitor.samples_path, round(time.time() - hours * 3600))
            self.send_bytes(json.dumps(rows, separators=(",", ":")).encode(), "application/json")
        elif parsed.path == "/metrics":
            try:
                current = json.loads(self.monitor.current_path.read_text(encoding="utf-8"))
            except (FileNotFoundError, json.JSONDecodeError):
                current = {}
            lines = []
            for field in NUMERIC_FIELDS:
                value = current.get(field)
                if value is not None:
                    lines.append(f"pinephone_battery_{field} {value}")
            self.send_bytes(("\n".join(lines) + "\n").encode(), "text/plain; version=0.0.4")
        else:
            self.send_bytes(b"not found\n", "text/plain", 404)


def run_daemon(config: dict[str, Any], state_dir: pathlib.Path) -> None:
    monitor = Monitor(config, state_dir)
    handler = type(
        "ConfiguredDashboardHandler",
        (DashboardHandler,),
        {
            "monitor": monitor,
            "asset_dir": pathlib.Path(
                os.environ.get("POWER_MONITOR_ASSET_DIR", pathlib.Path(__file__).parent)
            ),
        },
    )
    server = None
    try:
        server = http.server.ThreadingHTTPServer((config["listenAddress"], config["port"]), handler)
        server_thread = threading.Thread(target=server.serve_forever, daemon=True)
        server_thread.start()
        monitor.event(f"dashboard=http://{config['listenAddress']}:{config['port']}/")
    except OSError as error:
        monitor.event(f"dashboard unavailable ({error}); telemetry and safety guard remain active")

    def stop(_signum: int, _frame: Any) -> None:
        monitor.stop_event.set()
        monitor.wake_event.set()

    def wake(_signum: int, _frame: Any) -> None:
        monitor.wake_event.set()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGUSR1, wake)
    monitor.run()
    if server is not None:
        server.shutdown()


def profile_command(args: argparse.Namespace, config: dict[str, Any], state_dir: pathlib.Path) -> int:
    path = state_dir / "profile"
    valid = ["auto", *config["profiles"].keys()]
    if args.mode is None or args.mode == "status":
        desired = read_text(path) or config["defaultProfile"]
        try:
            current = json.loads((state_dir / "current.json").read_text(encoding="utf-8"))
            effective = current.get("profile", "unknown")
        except (FileNotFoundError, json.JSONDecodeError):
            effective = "unknown"
        print(f"requested: {desired}\neffective: {effective}\navailable: {' '.join(valid)}")
        return 0
    if args.mode not in valid:
        print(f"invalid profile {args.mode!r}; choose: {' '.join(valid)}", file=sys.stderr)
        return 2
    try:
        state_dir.mkdir(parents=True, exist_ok=True)
        path.write_text(args.mode + "\n", encoding="ascii")
        os.chmod(path, 0o644)
    except PermissionError:
        print("changing the system power profile requires root; use sudo power-profile", file=sys.stderr)
        return 1
    subprocess.run(
        ["systemctl", "kill", "--signal=USR1", "pinephone-power-monitor.service"],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    print(f"requested profile: {args.mode}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="/etc/pinephone-power-monitor.json")
    parser.add_argument("--state-dir", default="/var/lib/pinephone-power-monitor")
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("daemon", help="collect continuously and serve the dashboard")
    subparsers.add_parser("sample", help="print one live sample as JSON")
    subparsers.add_parser("status", help="print the most recent stored sample")
    subparsers.add_parser("open", help="open the dashboard")
    profile_parser = subparsers.add_parser("profile", help="show or select a power profile")
    profile_parser.add_argument("mode", nargs="?")
    args = parser.parse_args(argv)
    config = merged_config(args.config)
    state_dir = pathlib.Path(args.state_dir)

    if args.command == "daemon":
        run_daemon(config, state_dir)
    elif args.command == "sample":
        print(json.dumps(collect_sample(config, "unmanaged"), indent=2))
    elif args.command == "status":
        try:
            print((state_dir / "current.json").read_text(encoding="utf-8"), end="")
        except FileNotFoundError:
            print("no sample has been recorded yet", file=sys.stderr)
            return 1
    elif args.command == "open":
        url = f"http://{config['listenAddress']}:{config['port']}/"
        subprocess.Popen(["xdg-open", url], start_new_session=True)
    elif args.command == "profile":
        return profile_command(args, config, state_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
