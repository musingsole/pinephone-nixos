import importlib.util
import pathlib
import tempfile
import unittest


MODULE_PATH = pathlib.Path(__file__).parents[1] / "power_button.py"
SPEC = importlib.util.spec_from_file_location("power_button", MODULE_PATH)
power_button = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(power_button)


class PowerButtonTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.brightness = pathlib.Path(self.temporary.name) / "brightness"
        self.brightness.write_text("80\n", encoding="ascii")
        self.locks = 0
        self.poweroffs = 0
        self.controller = power_button.ButtonController(
            self.brightness,
            dim_brightness=0,
            lock_sessions=self.lock,
            poweroff=self.poweroff,
        )

    def tearDown(self):
        self.temporary.cleanup()

    def lock(self):
        self.locks += 1
        return True

    def poweroff(self):
        self.poweroffs += 1

    def press(self, started=1.0, released=1.1):
        self.controller.handle(power_button.EV_KEY, power_button.KEY_POWER, 1, started)
        self.controller.handle(power_button.EV_KEY, power_button.KEY_POWER, 0, released)

    def test_short_presses_lock_blank_then_restore_without_dpms(self):
        self.press()
        self.assertEqual(self.locks, 1)
        self.assertEqual(self.brightness.read_text().strip(), "0")
        self.assertTrue(self.controller.blanked)

        self.press(2.0, 2.1)
        self.assertEqual(self.locks, 1)
        self.assertEqual(self.brightness.read_text().strip(), "80")
        self.assertFalse(self.controller.blanked)

    def test_default_lock_only_mode_never_writes_brightness(self):
        controller = power_button.ButtonController(
            self.brightness,
            lock_sessions=self.lock,
            poweroff=self.poweroff,
        )
        controller.handle(power_button.EV_KEY, power_button.KEY_POWER, 1, 1.0)
        controller.handle(power_button.EV_KEY, power_button.KEY_POWER, 0, 1.1)
        self.assertEqual(self.locks, 1)
        self.assertEqual(self.brightness.read_text().strip(), "80")
        self.assertFalse(controller.blanked)

    def test_rapid_second_press_is_debounced(self):
        self.press(1.0, 1.1)
        self.press(1.2, 1.3)
        self.assertEqual(self.brightness.read_text().strip(), "0")
        self.assertTrue(self.controller.blanked)
        self.press(2.0, 2.1)
        self.assertEqual(self.brightness.read_text().strip(), "80")
        self.assertFalse(self.controller.blanked)

    def test_sync_repeat_and_duplicate_press_do_not_toggle(self):
        self.controller.handle(0, 0, 0, 1.0)
        self.controller.handle(power_button.EV_KEY, power_button.KEY_POWER, 1, 2.0)
        self.controller.handle(power_button.EV_KEY, power_button.KEY_POWER, 2, 2.1)
        self.controller.handle(power_button.EV_KEY, power_button.KEY_POWER, 1, 2.2)
        self.controller.handle(power_button.EV_KEY, power_button.KEY_POWER, 0, 2.3)
        self.assertEqual(self.locks, 1)

    def test_long_press_requests_orderly_poweroff(self):
        self.press(1.0, 4.5)
        self.assertEqual(self.poweroffs, 1)
        self.assertEqual(self.locks, 0)
        self.assertEqual(self.brightness.read_text().strip(), "80")

    def test_failed_lock_keeps_display_on(self):
        self.controller.lock_sessions = lambda: False
        self.press()
        self.assertEqual(self.brightness.read_text().strip(), "80")
        self.assertFalse(self.controller.blanked)


if __name__ == "__main__":
    unittest.main()
