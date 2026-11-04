"""Select the oldest available iPhone runtime supported by the app."""

import json
import re
import sys


def select_simulator(data):
    candidates = []
    for runtime, devices in data.get("devices", {}).items():
        version = re.search(r"iOS-(\d+)-(\d+)", runtime)
        if version is None:
            continue
        major, minor = map(int, version.groups())
        if major < 26:
            continue
        for device in devices:
            if device.get("isAvailable") and device.get("name", "").startswith("iPhone"):
                candidates.append(((major, minor), device["udid"]))
    if not candidates:
        raise ValueError("No available iPhone simulator with iOS 26 or newer. Install an iOS 26+ simulator runtime.")
    return min(candidates, key=lambda candidate: candidate[0])[1]


if __name__ == "__main__":
    try:
        print(select_simulator(json.load(sys.stdin)))
    except (ValueError, KeyError, TypeError) as error:
        sys.exit(str(error))
