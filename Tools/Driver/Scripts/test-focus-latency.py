#!/usr/bin/env python3
"""Ensure timing uncertainty, missing evidence, and skips cannot pass the budget."""
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('focus_latency', Path(__file__).with_name('measure-focus-latency.py'))
measurement = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measurement)


MISSING = object()


def log(lower=8200, upper=8500, tier=None, identities=(0, 1, 0), restore_call=4_000_000):
    tier = tier or {'status': 'passed', 'executed': 1, 'skipped': 0, 'reported': 1}
    timing = {'detectedAtUptimeNanoseconds': 1300,
              'requestFinishedNanoseconds': 9000, 'activationNanoseconds': 20}
    if restore_call is not MISSING:
        timing['restoreCallNanoseconds'] = restore_call
        timing['restoreCallControlNanoseconds'] = 41
    # A shorter identity tuple reproduces a sampler that missed later transitions.
    bounds = [(0, 500), (1000, 1200), (lower, upper)]
    return '\n'.join([
        'TIER_RESULT ' + json.dumps(tier),
        'FOCUS_CLOCK_CONTROL_NS 5',
        'FOCUS_VALIDATION ' + json.dumps({'no_physical_input': True, 'cursor_unchanged': True}),
        'FOCUS_TIMING ' + json.dumps(timing),
        'FOCUS_SERVER ' + json.dumps({'transitions': [
            {'identity': identity, 'lower_ns': bound[0], 'at_ns': bound[1]}
            for identity, bound in zip(identities, bounds)]}),
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

    def test_full_call_under_at_and_over_the_limit(self):
        for nanoseconds, verdict in ((0, 'passed'), (7_999_999, 'passed'),
                                     (8_000_000, 'passed'), (8_000_001, 'failed')):
            trial = measurement.parse_trial(log(restore_call=nanoseconds), 8000)
            self.assertEqual(trial['full_call'], verdict)
            self.assertEqual(trial['restore_call_ns'], nanoseconds)
            self.assertEqual(trial['full_call_limit_ns'], 8_000_000)

    def test_full_call_uses_raw_data_without_control_subtraction(self):
        trial = measurement.parse_trial(log(restore_call=8_000_003), 8000)
        self.assertEqual(trial['full_call'], 'failed')
        self.assertEqual(trial['restore_call_ns'], 8_000_003)
        self.assertEqual(trial['restore_call_control_ns'], 41)
        self.assertNotIn('restoreCallNanoseconds', trial['control_adjusted_phases'])
        self.assertNotIn('restoreCallControlNanoseconds', trial['control_adjusted_phases'])

    def test_missing_or_invalid_full_call_is_neither_zero_nor_passed(self):
        for restore_call in (MISSING, None, -1, 'fast', True, 4.5):
            trial = measurement.parse_trial(log(restore_call=restore_call), 8000)
            self.assertIsNone(trial['restore_call_ns'])
            self.assertEqual(trial['full_call'], 'missing')
            report = measurement.summarize([trial], 8000)
            self.assertIsNone(report['full_call_max_ns'])
            self.assertEqual(report['full_call_missing_trials'], 1)
            self.assertEqual(report['full_call_measured_trials'], 0)
            self.assertEqual(report['full_call_criterion'], 'not_qualified')

    def test_historical_record_keeps_its_own_metrics_and_verdicts(self):
        trial = measurement.parse_trial(log(restore_call=MISSING), 8000)
        self.assertEqual(trial['budget'], 'passed')
        self.assertEqual(trial['functional'], 'passed')
        self.assertEqual(trial['control_adjusted_phases']['activationNanoseconds'], 15)
        self.assertEqual(trial['server_interval_upper_ns'], 7500)

    def test_mixed_samples_keep_missing_and_overruns_distinguishable(self):
        trials = [measurement.parse_trial(log(restore_call=value), 8000)
                  for value in (1_000_000, 9_500_000, MISSING)]
        report = measurement.summarize(trials, 8000)
        self.assertEqual(report['full_call_measured_trials'], 2)
        self.assertEqual(report['full_call_missing_trials'], 1)
        self.assertEqual(report['full_call_overrun_trials'], 1)
        self.assertEqual(report['full_call_max_ns'], 9_500_000)
        self.assertEqual(report['full_call_criterion'], 'not_qualified')
        self.assertEqual(report['completed_trials'], 3)
        self.assertEqual(report['functional_passed_trials'], 3)
        self.assertNotIn('restoreCallNanoseconds', report['control_adjusted_phases'])

    def test_measured_zero_qualifies_the_new_criterion_across_trials(self):
        trials = [measurement.parse_trial(log(restore_call=value), 8000)
                  for value in (0, 8_000_000)]
        report = measurement.summarize(trials, 8000)
        self.assertEqual(report['full_call_criterion'], 'passed')
        self.assertEqual(report['full_call_max_ns'], 8_000_000)
        self.assertEqual(report['full_call_missing_trials'], 0)
        self.assertEqual(report['full_call_limit_ms'], 8.0)

    def test_sampler_miss_keeps_its_measured_full_call_overrun(self):
        refused = log(identities=(0, 1), restore_call=9_000_000,
                      tier={'status': 'failed', 'executed': 1, 'skipped': 0, 'reported': 1})
        with self.assertRaises(ValueError):
            measurement.parse_trial(refused, 8000)
        salvaged = measurement.full_call_from_log(refused)
        self.assertEqual(salvaged, 9_000_000)
        trials = [measurement.parse_trial(log(restore_call=1_000_000), 8000)]
        report = measurement.summarize(trials, 8000, [salvaged])
        self.assertEqual(report['full_call_max_ns'], 9_000_000)
        self.assertEqual(report['full_call_overrun_trials'], 1)
        self.assertEqual(report['full_call_criterion'], 'not_qualified')
        self.assertEqual(report['completed_trials'], 1)
        self.assertEqual(report['full_call_measured_trials'], 1)
        self.assertEqual(report['full_call_salvaged_measurements'], 1)

    def test_refused_attempt_without_a_measurement_stays_missing(self):
        for text in ('', 'TIER_RESULT {}', log(restore_call=MISSING), log(restore_call=-3)):
            self.assertIsNone(measurement.full_call_from_log(text))
        trials = [measurement.parse_trial(log(restore_call=1_000_000), 8000)]
        report = measurement.summarize(trials, 8000, [None])
        self.assertEqual(report['full_call_unmeasured_incomplete_attempts'], 1)
        self.assertEqual(report['full_call_missing_trials'], 0)
        self.assertEqual(report['full_call_criterion'], 'not_qualified')

    def test_salvaged_measurement_within_the_limit_does_not_invent_an_overrun(self):
        trials = [measurement.parse_trial(log(restore_call=1_000_000), 8000)]
        report = measurement.summarize(trials, 8000, [8_000_000])
        self.assertEqual(report['full_call_overrun_trials'], 0)
        self.assertEqual(report['full_call_max_ns'], 8_000_000)
        self.assertEqual(report['full_call_observed_measurements'], 2)
        self.assertEqual(report['full_call_criterion'], 'passed')

    def test_full_call_summary_without_completed_trials_is_not_a_pass(self):
        report = measurement.full_call_summary([], [9_000_000, None])
        self.assertEqual(report['full_call_max_ns'], 9_000_000)
        self.assertEqual(report['full_call_overrun_trials'], 1)
        self.assertEqual(report['full_call_measured_trials'], 0)
        self.assertEqual(report['full_call_criterion'], 'not_qualified')
        self.assertEqual(measurement.full_call_summary([], [])['full_call_criterion'], 'not_qualified')

    def test_full_call_verdict_is_separate_from_the_functional_outcome(self):
        trial = measurement.parse_trial(log(restore_call=1_000,
            tier={'status': 'failed', 'executed': 1, 'skipped': 0, 'reported': 1}), 8000)
        self.assertEqual(trial['full_call'], 'passed')
        self.assertEqual(trial['functional'], 'failed')
        self.assertFalse(trial['qualifies'])
        report = measurement.summarize([trial], 8000)
        self.assertEqual(report['full_call_criterion'], 'passed')
        self.assertFalse(report['all_trials_qualify'])
        self.assertEqual(report['functional_passed_trials'], 0)


if __name__ == '__main__':
    unittest.main()
