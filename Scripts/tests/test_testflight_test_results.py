import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "testflight_test_results", Path(__file__).resolve().parents[1] / "testflight-test-results.py",
)
results = importlib.util.module_from_spec(spec)
spec.loader.exec_module(results)


def report(cases):
    tree = {"testNodes": [{
        "nodeType": "UI test bundle", "name": "MalyshUITests",
        "children": [{
            "nodeType": "Test Case", "nodeIdentifier": f"LiveActivityUITests/{method}()", "result": result,
        } for method, result in cases],
    }]}
    summary = {
        "result": "Failed" if any(result == "Failed" for _, result in cases) else "Passed",
        "totalTestCount": len(cases),
        "passedTests": sum(result == "Passed" for _, result in cases),
        "failedTests": sum(result == "Failed" for _, result in cases),
        "skippedTests": sum(result == "Skipped" for _, result in cases),
        "expectedFailures": 0,
    }
    return summary, tree


class TargetedRetryTests(unittest.TestCase):
    def run_cli(self, reports, *args):
        with (
            patch.object(sys, "argv", ["testflight-test-results.py", "Test.xcresult", *args]),
            patch.object(results, "read_report", side_effect=reports),
        ):
            results.main()

    def test_selects_failed_method_only(self):
        summary, tree = report([("testSleep", "Failed"), ("testWidget", "Passed"), ("testOptIn", "Skipped")])
        with patch("builtins.print") as output:
            self.run_cli([summary, tree, {"status": "succeeded", "errors": []}])
        output.assert_called_once_with("MalyshUITests/LiveActivityUITests/testSleep", sep="\n")

    def test_rejects_build_failure_or_incomplete_results(self):
        summary, tree = report([("testSleep", "Failed")])
        for report_summary, build in (
            (summary, {"status": "failed", "errors": ["build error"]}),
            ({**summary, "totalTestCount": 2}, {"status": "succeeded", "errors": []}),
        ):
            with self.subTest(summary=report_summary, build=build), self.assertRaises(SystemExit):
                self.run_cli([report_summary, tree, build])

    def test_retry_must_pass_exactly_the_requested_method(self):
        target = "MalyshUITests/LiveActivityUITests/testSleep"
        self.run_cli(report([("testSleep", "Passed")]), "--verify", target)
        for cases in (
            [("testSleep", "Skipped")],
            [("testWidget", "Passed")],
            [("testSleep", "Passed"), ("testWidget", "Passed")],
        ):
            with self.subTest(cases=cases), self.assertRaises(SystemExit):
                self.run_cli(report(cases), "--verify", target)
