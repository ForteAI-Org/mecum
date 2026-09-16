#!/usr/bin/env python3
"""Ensure timing uncertainty, missing evidence, and skips cannot pass the budget."""
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('focus_latency', Path(__file__).with_name('measure-focus-latency.py'))
measurement = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measurement)


def log(lower=8200, upper=8500, tier=None, identities=(0, 1, 0)):
    tier = tier or {'status': 'passed', 'executed': 1, 'skipped': 0, 'reported': 1}
    return '\n'.join([
        'TIER_RESULT ' + json.dumps(tier),
        'FOCUS_CLOCK_CONTROL_NS 5',
        'FOCUS_VALIDATION ' + json.dumps({'no_physical_input': True, 'cursor_unchanged': True}),
        'FOCUS_TIMING ' + json.dumps({'detectedAtUptimeNanoseconds': 1300,
                                      'requestFinishedNanoseconds': 9000, 'activationNanoseconds': 20}),
        'FOCUS_SERVER ' + json.dumps({'transitions': [
            {'identity': identities[0], 'lower_ns': 0, 'at_ns': 500},
            {'identity': identities[1], 'lower_ns': 1000, 'at_ns': 1200},
            {'identity': identities[2], 'lower_ns': lower, 'at_ns': upper}]}),
    ])


class FocusLatencyTests(unittest.TestCase):
    def test_pass_uses_upper_bound(self):
        trial = measurement.parse_trial(log(), 8000)
        self.assertEqual(trial['budget'], 'passed')
        self.assertEqual(trial['server_interval_upper_ns'], 7500)

    def test_exact_boundary_is_inclusive(self):
        self.assertEqual(measurement.parse_trial(log(upper=9000), 8000)['budget'], 'passed')

    def test_uncertainty_crossing_budget_is_inconclusive(self):
        self.assertEqual(measurement.parse_trial(log(lower=9000, upper=9500), 8000)['budget'], 'inconclusive')

    def test_lower_bound_over_budget_proves_failure(self):
        self.assertEqual(measurement.parse_trial(log(lower=9400, upper=9500), 8000)['budget'], 'failed')

    def test_skip_cannot_produce_latency(self):
        with self.assertRaises(ValueError):
            measurement.parse_trial(log(tier={'status': 'passed', 'executed': 0, 'skipped': 1, 'reported': 1}), 8000)

    def test_failed_ax_retains_independent_latency_failure(self):
        trial = measurement.parse_trial(log(lower=9400, upper=9500,
            tier={'status': 'failed', 'executed': 1, 'skipped': 0, 'reported': 1}), 8000)
        self.assertEqual(trial['budget'], 'failed')
        self.assertEqual(trial['functional'], 'failed')
        self.assertFalse(trial['qualifies'])

    def test_failed_function_cannot_qualify_even_if_latency_passes(self):
        trial = measurement.parse_trial(log(tier={'status': 'failed', 'executed': 1, 'skipped': 0, 'reported': 1}), 8000)
        self.assertEqual(trial['budget'], 'passed')
        self.assertFalse(measurement.summarize([trial], 8000)['all_trials_qualify'])

    def test_contaminated_or_missing_physical_evidence_refuses_measurement(self):
        for data in (log().replace('"no_physical_input": true', '"no_physical_input": false'),
                     '\n'.join(row for row in log().splitlines() if not row.startswith('FOCUS_VALIDATION'))):
            with self.assertRaises(ValueError):
                measurement.parse_trial(data, 8000)

    def test_qualification_requires_every_independent_oracle(self):
        trial = measurement.parse_trial(log(), 8000)
        self.assertFalse(trial['qualifies'])
        required = {key: True for key in ('cursor_unchanged', 'no_physical_input', 'same_user_app',
                    'same_user_window', 'recovered', 'target_virtual', 'no_uncertain_commands')}
        data = log().replace('FOCUS_VALIDATION ' + json.dumps({'no_physical_input': True, 'cursor_unchanged': True}),
                             'FOCUS_VALIDATION ' + json.dumps(required))
        self.assertTrue(measurement.parse_trial(data, 8000)['qualifies'])

    def test_matrix_balances_modes_in_every_scenario(self):
        plan = measurement.campaign_plan(5, True, 100)
        self.assertEqual(len(plan), 12)
        for scenario in ('cold', 'warm-menu', 'cpu-load'):
            self.assertEqual([p['key_records'] for p in plan if p['scenario'] == scenario], [False, True, True, False])

    def test_missing_target_or_user_switch_is_not_a_zero_latency(self):
        for identities in ((0, 0, 0), (0, 1, 2)):
            with self.assertRaises(ValueError):
                measurement.parse_trial(log(identities=identities), 8000)

    def test_no_trials_is_not_a_pass(self):
        with self.assertRaises(ValueError):
            measurement.summarize([], 8000)

    def test_control_subtraction_does_not_shrink_the_focus_interval(self):
        trial = measurement.parse_trial(log(), 8000)
        self.assertEqual(trial['control_adjusted_phases']['activationNanoseconds'], 15)
        self.assertEqual(trial['server_interval_upper_ns'], 7500)
        self.assertNotIn('detectedAtUptimeNanoseconds', trial['control_adjusted_phases'])


if __name__ == '__main__':
    unittest.main()
