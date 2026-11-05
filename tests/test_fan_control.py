import unittest

from scripts.fan_control import fan_level


class FanControlTests(unittest.TestCase):
    def test_temperature_levels(self):
        self.assertEqual(fan_level(27.9), 0)
        self.assertEqual(fan_level(28), 1)
        self.assertEqual(fan_level(37.9), 1)
        self.assertEqual(fan_level(38), 2)
        self.assertEqual(fan_level(47.9), 2)
        self.assertEqual(fan_level(48), 3)
