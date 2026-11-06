"""REL: the release simulator must not select iPhone Duo or an older runtime."""

import importlib.util
from pathlib import Path
import unittest


SPEC = importlib.util.spec_from_file_location("simulator_id", Path(__file__).parents[1] / "simulator-id.py")
simulator_id = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(simulator_id)


class SimulatorSelectionTests(unittest.TestCase):
    def test_ci_requires_the_release_model_and_runtime(self):
        data = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
                    {"name": "iPhone 18 Pro", "udid": "old", "isAvailable": True},
                ],
                "com.apple.CoreSimulator.SimRuntime.iOS-27-2": [
                    {"name": "iPhone Duo", "udid": "duo", "isAvailable": True},
                    {"name": "iPhone 18 Pro", "udid": "release", "isAvailable": True},
                ],
            }
        }
        self.assertEqual(simulator_id.select_simulator(data), "old")
        self.assertEqual(simulator_id.select_simulator(data, ci=True), "release")
        data["devices"]["com.apple.CoreSimulator.SimRuntime.iOS-27-2"][1]["isAvailable"] = False
        with self.assertRaisesRegex(ValueError, "iPhone 18 Pro"):
            simulator_id.select_simulator(data, ci=True)
