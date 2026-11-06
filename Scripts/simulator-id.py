"""Select a compatible local simulator or the known CI configuration."""

import argparse
import json
import re
import sys


CI_RUNTIME = (27, 2)
CI_DEVICE = "iPhone 18 Pro"


def select_simulator(data, *, ci=False):
    candidates = []
    for runtime, devices in data.get("devices", {}).items():
        version = re.search(r"iOS-(\d+)-(\d+)", runtime)
        if version is None:
            continue
        major, minor = map(int, version.groups())
        if (major, minor) < (27, 0):
            continue
        for device in devices:
            if ci and ((major, minor) != CI_RUNTIME or device.get("name") != CI_DEVICE):
                continue
            if device.get("isAvailable") and device.get("name", "").startswith("iPhone"):
                candidates.append(((major, minor), device["udid"]))
    if not candidates and ci:
        raise ValueError("CI requires an available iPhone 18 Pro simulator on iOS 27.2.")
    if not candidates:
        raise ValueError("No available iPhone simulator with iOS 27.0 or newer. Install a compatible simulator runtime.")
    return min(candidates, key=lambda candidate: candidate[0])[1]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ci", action="store_true", help="require the release simulator configuration")
    args = parser.parse_args()
    try:
        print(select_simulator(json.load(sys.stdin), ci=args.ci))
    except (ValueError, KeyError, TypeError) as error:
        sys.exit(str(error))
