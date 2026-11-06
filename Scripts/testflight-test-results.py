"""Read XCTest method results for the one targeted retry in release CI."""

import argparse
import json
import re
import subprocess
import sys


def read_report(bundle, *command):
    return json.loads(subprocess.check_output([
        "xcrun", "xcresulttool", "get", *command, "--path", bundle, "--compact",
    ]))


def test_cases(nodes, target=None):
    for node in nodes:
        kind = node["nodeType"]
        if kind == "Test Case":
            identifier = f"{target}/{node['nodeIdentifier'].removesuffix('()')}"
            if target is None or not re.fullmatch(r"\w+/\w+/\w+", identifier, flags=re.ASCII):
                raise ValueError(f"Unsupported XCTest identifier: {identifier}")
            yield identifier, node["result"]
        else:
            child_target = node["name"] if kind in ("Unit test bundle", "UI test bundle") else target
            yield from test_cases(node.get("children", []), child_target)


def completed_cases(report, summary):
    cases = list(test_cases(report["testNodes"]))
    results = dict(cases)
    if not cases or len(cases) != len(results) or len(cases) != summary["totalTestCount"]:
        raise ValueError("XCTest report does not contain one result per test method")
    for status, count in (
        ("Passed", "passedTests"), ("Failed", "failedTests"),
        ("Skipped", "skippedTests"), ("Expected Failure", "expectedFailures"),
    ):
        if sum(result == status for _, result in cases) != summary[count]:
            raise ValueError(f"XCTest report disagrees with summary for {status} tests")
    if any(result not in {"Passed", "Failed", "Skipped", "Expected Failure"} for result in results.values()):
        raise ValueError("XCTest report contains an unfinished test")
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle")
    parser.add_argument("--verify", nargs="+", metavar="TEST", help="require these exact methods to pass")
    args = parser.parse_args()
    try:
        summary = read_report(args.bundle, "test-results", "summary")
        report = read_report(args.bundle, "test-results", "tests")
        results = completed_cases(report, summary)
        if args.verify:
            if summary["result"] != "Passed" or results != dict.fromkeys(args.verify, "Passed"):
                raise ValueError("Retry did not pass exactly the requested test methods")
            return

        build = read_report(args.bundle, "build-results")
        failed = [identifier for identifier, result in results.items() if result == "Failed"]
        if build.get("status") != "succeeded" or build["errors"] or summary["result"] != "Failed" or not failed:
            raise ValueError("Initial run did not finish with retryable test failures")
        print(*failed, sep="\n")
    except (KeyError, TypeError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(f"Cannot confirm XCTest results: {error}")


if __name__ == "__main__":
    main()
