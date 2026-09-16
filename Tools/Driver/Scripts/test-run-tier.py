import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent

class TierTests(unittest.TestCase):
    def run_tier(self, output, expected='2', status=0):
        with tempfile.TemporaryDirectory() as directory:
            emitter = pathlib.Path(directory) / 'emit.py'
            emitter.write_text('import sys\nprint(' + repr(output) + ')\nsys.exit(' + str(status) + ')\n')
            result = subprocess.run(['bash', str(ROOT / 'run-tier.sh'), 'sample', expected,
                                     'python3', str(emitter)], text=True, capture_output=True,
                                    env={**__import__('os').environ, 'TMPDIR': directory})
            log = (pathlib.Path(directory) / 'agentseat-tier-sample.log').read_text()
            return result, log

    def test_skipped_tests_are_not_executed(self):
        result, log = self.run_tier('◇ Test one() started.\n✔ Test one() passed after 0.1 seconds.\n'
            '➜ Test two() skipped: "opt-in disabled".\n'
            '✔ Test run with 2 tests in 1 suite passed after 0.1 seconds.')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('1 executed, 1 skipped, 2 reported', result.stdout)
        self.assertIn('TIER_RESULT ', log)

    def test_all_skipped_is_explicit(self):
        result, _ = self.run_tier('➜ Test one() skipped.\n➜ Test two() skipped.\n'
            '✔ Test run with 2 tests in 1 suite passed after 0.001 seconds.')
        self.assertEqual(result.returncode, 0)
        self.assertIn('0 executed, 2 skipped, 2 reported', result.stdout)

    def test_missing_summary_fails(self):
        result, _ = self.run_tier('◇ Test one() started.')
        self.assertNotEqual(result.returncode, 0)

    def test_wrong_count_fails(self):
        result, _ = self.run_tier('✔ Test run with 1 test passed after 0.1 seconds.')
        self.assertNotEqual(result.returncode, 0)

    def test_failure_summary_with_zero_exit_fails(self):
        result, _ = self.run_tier('✘ Test run with 2 tests failed after 0.1 seconds.')
        self.assertNotEqual(result.returncode, 0)

    def test_nonzero_exit_fails(self):
        result, _ = self.run_tier('✔ Test run with 2 tests passed after 0.1 seconds.', status=1)
        self.assertNotEqual(result.returncode, 0)

class ReportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import runpy
        cls.report = runpy.run_path(str(ROOT / 'compat-report.py'))

    def verdict(self, result):
        import json
        return self.report['tier_verdict']({'live': 'TIER_RESULT ' + json.dumps(result)}, 'live')

    def test_unvalidated_summary_is_not_evidence(self):
        self.assertEqual(self.report['tier_verdict'](
            {'live': '✔ Test run with 8 tests passed after 0.1 seconds.'}, 'live'), 'not run')

    def test_all_skipped_is_not_evidence(self):
        self.assertEqual(self.verdict(dict(executed=0, skipped=8, reported=8, status='passed')), 'not run')

    def test_skipped_required_test_is_incomplete(self):
        self.assertEqual(self.verdict(dict(executed=7, skipped=1, reported=8, status='passed',
                                          skip_details=['fixture missing'])), 'incomplete')

    def test_opted_out_calibration_is_not_a_required_test(self):
        result = dict(executed=5, skipped=3, reported=8, status='passed', skip_details=[
            'AGENTSEAT_TEXT_DELIVERY=1 is required: this optional calibration is disabled by default.',
            'AGENTSEAT_TEXT_DELIVERY=1 is required: this optional calibration is disabled by default.',
            'AGENTSEAT_TYPING_SWEEP=1 is required: this optional calibration is disabled by default.'])
        self.assertEqual(self.verdict(result), 'passed')

    def test_matrix_ignores_unrelated_old_logs(self):
        self.assertEqual(self.report['matrix_rows']({
            'live': '| target | action |\n| Chrome | drag |\n',
            'drag-baseline': '| target | action |\n| old | drag |\n'
        }), ['| target | action |', '| Chrome | drag |'])

    def test_wrapper_failure_survives_green_summary(self):
        self.assertEqual(self.verdict(dict(executed=8, skipped=0, reported=8, status='failed')), 'failed')

if __name__ == '__main__':
    unittest.main()
