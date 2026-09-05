import importlib.util
import json
import pathlib
import tempfile
import unittest
from unittest import mock


MODULE_PATH = pathlib.Path(__file__).parents[1] / "power_monitor.py"
SPEC = importlib.util.spec_from_file_location("power_monitor", MODULE_PATH)
power_monitor = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(power_monitor)


def put(root, relative, value):
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(str(value) + "\n", encoding="ascii")


class PowerMonitorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.power = self.root / "power"
        self.cpu = self.root / "cpu"
        self.gpu = self.root / "gpu"
        self.thermal = self.root / "thermal"
        put(self.power, "rk818-battery/type", "Battery")
        put(self.power, "rk818-battery/status", "Discharging")
        put(self.power, "rk818-battery/capacity", 42)
        put(self.power, "rk818-battery/voltage_now", 3_900_000)
        put(self.power, "rk818-battery/current_now", -500_000)
        put(self.power, "rk818-battery/charge_full", 2_900_000)
        put(self.power, "rk818-battery/charge_full_design", 3_000_000)
        put(self.power, "usb/type", "USB")
        put(self.power, "usb/online", 0)

    def tearDown(self):
        self.temp.cleanup()

    def sample(self):
        return power_monitor.collect_sample(
            power_monitor.DEFAULT_CONFIG,
            "balanced",
            power_supply_root=self.power,
            cpufreq_root=self.cpu,
            devfreq_root=self.gpu,
            thermal_root=self.thermal,
        )

    def test_discovers_battery_and_derives_signed_power(self):
        sample = self.sample()
        self.assertEqual(sample["battery"], "rk818-battery")
        self.assertEqual(sample["current_ua"], 500_000)
        self.assertEqual(sample["power_uw"], 1_950_000)
        self.assertFalse(sample["external_power"])

    def test_charging_power_is_negative(self):
        put(self.power, "rk818-battery/status", "Charging")
        put(self.power, "rk818-battery/current_now", 1_000_000)
        put(self.power, "usb/online", 1)
        sample = self.sample()
        self.assertEqual(sample["power_uw"], -3_900_000)
        self.assertTrue(sample["external_power"])

    def test_health_and_remaining_energy_fallback(self):
        sample = self.sample()
        summary = power_monitor.health_summary(sample)
        self.assertEqual(summary["learnedCapacityPercent"], 96.7)
        self.assertGreater(summary["estimatedRemainingEnergyUwh"], 0)
        self.assertGreater(summary["instantaneousHoursRemaining"], 0)

    def test_safety_requires_confirmations_and_resets_on_power(self):
        config = dict(power_monitor.DEFAULT_CONFIG)
        config.update({"shutdownPercent": 5, "shutdownConfirmations": 3})
        guard = power_monitor.SafetyGuard(config)
        low = {"status": "Discharging", "external_power": False, "capacity_percent": 4, "voltage_uv": 3_300_000}
        self.assertFalse(guard.check(low)[0])
        self.assertFalse(guard.check(low)[0])
        self.assertTrue(guard.check(low)[0])
        low["external_power"] = True
        self.assertFalse(guard.check(low)[0])
        self.assertEqual(guard.unsafe_count, 0)

    def test_safety_rejects_false_empty_gauge_at_charged_voltage(self):
        config = dict(power_monitor.DEFAULT_CONFIG)
        guard = power_monitor.SafetyGuard(config)
        false_empty = {
            "status": "Discharging",
            "external_power": False,
            "capacity_percent": 0,
            "voltage_uv": 4_126_000,
        }
        for _ in range(config["shutdownConfirmations"] + 2):
            self.assertFalse(guard.check(false_empty)[0])
        self.assertEqual(guard.unsafe_count, 0)

    def test_auto_profile_thresholds(self):
        config = power_monitor.DEFAULT_CONFIG
        self.assertEqual(power_monitor.selected_auto_profile({"status": "Charging", "capacity_percent": 2}, config), "balanced")
        self.assertEqual(power_monitor.selected_auto_profile({"status": "Discharging", "capacity_percent": 7}, config), "critical")
        self.assertEqual(power_monitor.selected_auto_profile({"status": "Discharging", "capacity_percent": 12}, config), "powersave")
        self.assertEqual(power_monitor.selected_auto_profile({"status": "Discharging", "capacity_percent": 60}, config), "balanced")

    def test_auto_profile_rejects_false_empty_gauge_at_charged_voltage(self):
        config = power_monitor.DEFAULT_CONFIG
        false_empty = {
            "status": "Discharging",
            "external_power": False,
            "capacity_percent": 0,
            "voltage_uv": 4_126_000,
        }
        self.assertEqual(power_monitor.selected_auto_profile(false_empty, config), "powersave")
        false_empty["voltage_uv"] = 3_300_000
        self.assertEqual(power_monitor.selected_auto_profile(false_empty, config), "critical")

    def test_profile_uses_supported_frequency_steps(self):
        put(self.cpu, "policy0/cpuinfo_min_freq", 408_000)
        put(self.cpu, "policy0/cpuinfo_max_freq", 1_008_000)
        put(self.cpu, "policy0/scaling_min_freq", 408_000)
        put(self.cpu, "policy0/scaling_max_freq", 1_008_000)
        put(self.cpu, "policy0/scaling_available_frequencies", "408000 600000 816000 1008000")
        put(self.cpu, "policy0/scaling_available_governors", "powersave performance schedutil")
        put(self.cpu, "policy0/scaling_governor", "performance")
        put(self.gpu, "ff9a0000.gpu/name", "ff9a0000.gpu")
        put(self.gpu, "ff9a0000.gpu/min_freq", 200_000_000)
        put(self.gpu, "ff9a0000.gpu/max_freq", 600_000_000)
        put(self.gpu, "ff9a0000.gpu/available_frequencies", "200000000 297000000 400000000 500000000 600000000")
        put(self.gpu, "ff9a0000.gpu/available_governors", "powersave performance simple_ondemand")
        put(self.gpu, "ff9a0000.gpu/governor", "performance")
        power_monitor.apply_profile(
            "balanced", power_monitor.DEFAULT_CONFIG,
            cpufreq_root=self.cpu, devfreq_root=self.gpu,
        )
        self.assertEqual((self.cpu / "policy0/scaling_max_freq").read_text().strip(), "600000")
        self.assertEqual((self.cpu / "policy0/scaling_governor").read_text().strip(), "schedutil")
        self.assertEqual((self.gpu / "ff9a0000.gpu/max_freq").read_text().strip(), "400000000")

        power_monitor.apply_profile(
            "gateway", power_monitor.DEFAULT_CONFIG,
            cpufreq_root=self.cpu, devfreq_root=self.gpu,
        )
        self.assertEqual((self.cpu / "policy0/scaling_max_freq").read_text().strip(), "816000")

    def test_gateway_mode_is_reversible_and_preserves_radios(self):
        config = json.loads(json.dumps(power_monitor.DEFAULT_CONFIG))
        state = self.root / "state"
        state.mkdir()
        cpu_root = self.root / "hotplug"
        backlight_root = self.root / "backlight"
        for cpu in range(1, 6):
            put(cpu_root, f"cpu{cpu}/online", 1)
        put(backlight_root, "panel/brightness", 37)
        put(backlight_root, "panel/max_brightness", 51)
        commands = []

        def run(command, **_kwargs):
            commands.append(command)

        changes = power_monitor.apply_operating_mode(
            "gateway", config, state,
            cpu_root=cpu_root, backlight_root=backlight_root, command_runner=run,
        )
        self.assertEqual((backlight_root / "panel/brightness").read_text().strip(), "0")
        self.assertEqual((cpu_root / "cpu4/online").read_text().strip(), "0")
        self.assertEqual((cpu_root / "cpu5/online").read_text().strip(), "0")
        self.assertEqual((cpu_root / "cpu3/online").read_text().strip(), "1")
        self.assertEqual(commands[0], ["systemctl", "stop", "phosh.service"])
        self.assertNotIn("bluetooth.service", " ".join(commands[0]))
        self.assertIn("backlight=0", changes)

        power_monitor.apply_operating_mode(
            "balanced", config, state,
            cpu_root=cpu_root, backlight_root=backlight_root, command_runner=run,
        )
        self.assertEqual((cpu_root / "cpu4/online").read_text().strip(), "1")
        self.assertEqual((cpu_root / "cpu5/online").read_text().strip(), "1")
        self.assertEqual((backlight_root / "panel/brightness").read_text().strip(), "37")
        self.assertEqual(commands[-1], ["systemctl", "start", "phosh.service"])

    def test_interactive_startup_does_not_race_display_manager(self):
        config = json.loads(json.dumps(power_monitor.DEFAULT_CONFIG))
        state = self.root / "fresh-state"
        state.mkdir()
        backlight_root = self.root / "fresh-backlight"
        put(backlight_root, "panel/brightness", 23)
        put(backlight_root, "panel/max_brightness", 51)
        commands = []

        power_monitor.apply_operating_mode(
            "balanced", config, state,
            cpu_root=self.root / "fresh-cpu",
            backlight_root=backlight_root,
            command_runner=lambda command, **_kwargs: commands.append(command),
        )

        self.assertEqual(commands, [])
        self.assertEqual((backlight_root / "panel/brightness").read_text().strip(), "23")
        self.assertEqual((state / "operating_mode").read_text().strip(), "interactive")

    def test_cycle_can_collect_without_rewriting_frequency_policy(self):
        config = json.loads(json.dumps(power_monitor.DEFAULT_CONFIG))
        config["manageFrequencies"] = False
        config["interactiveServices"] = []
        state = self.root / "monitor-state"
        sample = {
            "status": "Discharging",
            "external_power": False,
            "capacity_percent": 42,
            "voltage_uv": 3_900_000,
            "power_uw": 500_000,
            "profile": "balanced",
        }
        monitor = power_monitor.Monitor(config, state)

        with (
            mock.patch.object(power_monitor, "collect_sample", return_value=sample.copy()),
            mock.patch.object(power_monitor, "apply_operating_mode", return_value=[]),
            mock.patch.object(power_monitor, "apply_profile") as apply_profile,
        ):
            result = monitor.cycle()

        apply_profile.assert_not_called()
        self.assertEqual(result["profile"], "balanced")


if __name__ == "__main__":
    unittest.main()
