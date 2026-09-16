"""Acceptance stays strict while explicitly optional experiments remain visible."""

import importlib.util
import json
import pathlib
import unittest

path = pathlib.Path(__file__).with_name("compat-report.py")
spec = importlib.util.spec_from_file_location("compat_report", path)
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


class TierEvidenceTests(unittest.TestCase):
    def verdict(self, skips, status="passed"):
        result = {
            "executed": 13,
            "skipped": len(skips),
            "reported": 13 + len(skips),
            "status": status,
            "skip_details": skips,
        }
        return report.tier_verdict({"live": "TIER_RESULT " + json.dumps(result)}, "live")

    def test_explicit_optional_experiments_do_not_block_unattended_run(self):
        skips = [
            'Test "experiment" skipped: "AGENTSEAT_STASHED_ADOPTION=1 is required: '
            'this optional calibration is disabled by default."',
            'Test "the person\'s own held modifier stays out of the kit\'s events" '
            'skipped: "needs AGENTSEAT_MANUAL_TESTS=1 and a person at the keyboard"',
        ]
        self.assertEqual(self.verdict(skips), "passed")

    def test_missing_fixture_remains_incomplete(self):
        self.assertEqual(self.verdict(['Test "matrix" skipped: "AGENTSEAT_FIXTURE_APP is not set"']),
                         "incomplete")

    def test_arbitrary_manual_skip_remains_incomplete(self):
        self.assertEqual(self.verdict([
            'Test "matrix" skipped: "needs AGENTSEAT_MANUAL_TESTS=1 and a person at the keyboard"'
        ]), "incomplete")

    def test_failed_runner_cannot_be_rescued_by_skip_policy(self):
        self.assertEqual(self.verdict([], status="failed"), "failed")


if __name__ == "__main__":
    unittest.main()
