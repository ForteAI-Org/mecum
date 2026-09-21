#!/usr/bin/env python3
"""Ensure timing uncertainty, missing evidence, and skips cannot pass the budget.

The admission, ownership and cleanup rows here are offline: the clock, the
processes, the filesystem and the native identity reads are all controlled
doubles. The one binary these tests build is the sampler's guard compiled with
`FOCUS_PROBE_SELFTEST`, which evaluates the admission table and loads, resolves
and calls nothing. No SPI is invoked, no window server is read and no GUI row
runs from this file.
"""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('focus_latency', Path(__file__).with_name('measure-focus-latency.py'))
measurement = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measurement)


MISSING = object()

GUARD_SOURCE = Path(__file__).with_name('FocusLatencyProbe.c')
GUARD_WORKSPACE = None
GUARD_BINARY = None
GUARD_ERROR = None

RESEARCH_SKYLIGHT = measurement.RESEARCH_PROFILE['skylight_uuid']
RESEARCH_LAUNCH_SERVICES = measurement.RESEARCH_PROFILE['launch_services_uuid']


def setUpModule():
    """Builds the guard-only entry point of the sampler, without its SPI path."""
    global GUARD_WORKSPACE, GUARD_BINARY, GUARD_ERROR
    xcrun, clang = shutil.which('xcrun'), shutil.which('clang')
    if xcrun:
        command = [xcrun, 'clang']
    elif clang:
        command = [clang]
    else:
        return
    GUARD_WORKSPACE = tempfile.TemporaryDirectory(prefix='focus-guard-check-')
    binary = Path(GUARD_WORKSPACE.name) / 'focus-guard'
    try:
        subprocess.run(command + ['-O1', '-DFOCUS_PROBE_SELFTEST', str(GUARD_SOURCE),
                                  '-o', str(binary)],
                       check=True, capture_output=True, text=True, timeout=180)
    except subprocess.CalledProcessError as error:
        # A compiler that is there and refuses the source is a failure to report,
        # not a reason to skip the admission table.
        GUARD_ERROR = error.stderr or str(error)
        GUARD_WORKSPACE.cleanup()
        GUARD_WORKSPACE = None
        return
    except (OSError, subprocess.SubprocessError) as error:
        GUARD_ERROR = str(error)
        GUARD_WORKSPACE.cleanup()
        GUARD_WORKSPACE = None
        return
    GUARD_BINARY = binary


def tearDownModule():
    global GUARD_WORKSPACE, GUARD_BINARY
    GUARD_BINARY = None
    if GUARD_WORKSPACE is not None:
        GUARD_WORKSPACE.cleanup()
        GUARD_WORKSPACE = None


def identity(build='26A428', model='Mac16,1', architecture='arm64',
             skylight=RESEARCH_SKYLIGHT, launch_services=RESEARCH_LAUNCH_SERVICES):
    return {'build': build, 'hardware_model': model, 'architecture': architecture,
            'skylight_uuid': skylight, 'launch_services_uuid': launch_services}


# Identities, the opt in they were invoked with, and what the guard must answer.
ADMISSION_TABLE = [
    ('audited image with its opt in', identity(), True, True, 'research-26A428'),
    ('audited image without an opt in', identity(), False, False, 'none'),
    ('historic build, no opt in', identity(build='26A5425a', model='MacBookPro18,2',
                                           skylight=None, launch_services=None),
     False, True, 'historic-26A5425a'),
    ('historic build with the 26A428 opt in', identity(build='26A5425a', model='MacBookPro18,2',
                                                       skylight=None, launch_services=None),
     True, False, 'none'),
    ('historic build on x86_64', identity(build='26A5425a', model='MacBookPro16,1',
                                          architecture='x86_64', skylight=None,
                                          launch_services=None),
     False, False, 'none'),
    ('historic build carrying the newer image UUIDs', identity(build='26A5425a',
                                                               model='MacBookPro18,2'),
     False, True, 'historic-26A5425a'),
    ('unknown build', identity(build='26B99'), True, False, 'none'),
    ('unknown build without an opt in', identity(build='26B99'), False, False, 'none'),
    ('absent build', identity(build=None), True, False, 'none'),
    ('absent hardware model', identity(model=None), True, False, 'none'),
    ('absent architecture', identity(architecture=None), True, False, 'none'),
    ('absent image UUIDs', identity(skylight=None, launch_services=None), True, False, 'none'),
    ('absent LaunchServices UUID', identity(launch_services=None), True, False, 'none'),
    ('another Mac model', identity(model='Mac15,3'), True, False, 'none'),
    ('a translated host', identity(architecture='x86_64-translated'), True, False, 'none'),
    ('another SkyLight image', identity(skylight='11111111-2222-3333-4444-555555555555'),
     True, False, 'none'),
    ('an incoherent delegate image',
     identity(launch_services='99999999-8888-7777-6666-555555555555'), True, False, 'none'),
    ('the two UUIDs swapped', identity(skylight=RESEARCH_LAUNCH_SERVICES,
                                       launch_services=RESEARCH_SKYLIGHT), True, False, 'none'),
]


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


class AdmissionTests(unittest.TestCase):
    """The preflight table: known, unknown, absent and incoherent identities."""

    def test_table_is_decided_the_same_way_for_every_identity(self):
        for name, detected, opt_in, admitted, profile in ADMISSION_TABLE:
            with self.subTest(name):
                verdict = measurement.admission_verdict(detected, opt_in)
                self.assertEqual(verdict['admitted'], admitted, verdict['reason'])
                self.assertEqual(verdict['profile'], profile)
                self.assertEqual(verdict['runtime_qualification'], 'not_acquired')
                self.assertTrue(verdict['reason'])

    def test_three_states_are_reported_separately(self):
        granted = measurement.admission_verdict(identity(), True)
        self.assertEqual(granted['static_abi_evidence'], 'research_26A428')
        self.assertEqual(granted['research_admission'], 'granted')
        self.assertEqual(granted['runtime_qualification'], 'not_acquired')
        without = measurement.admission_verdict(identity(), False)
        self.assertEqual(without['static_abi_evidence'], 'research_26A428')
        self.assertEqual(without['research_admission'], 'not_requested')
        self.assertFalse(without['admitted'])
        unknown = measurement.admission_verdict(identity(build='26B99'), True)
        self.assertEqual(unknown['static_abi_evidence'], 'absent')
        self.assertEqual(unknown['research_admission'], 'refused')

    def test_historic_evidence_is_not_relabelled_by_the_newer_image(self):
        verdict = measurement.admission_verdict(
            identity(build='26A5425a', model='MacBookPro18,2'), False)
        self.assertEqual(verdict['static_abi_evidence'], 'historic_26A5425a')
        self.assertEqual(verdict['profile'], 'historic-26A5425a')
        self.assertNotIn('26A428', verdict['reason'])

    def test_the_opt_in_does_not_transfer_between_profiles(self):
        verdict = measurement.admission_verdict(identity(build='26A5425a'), True)
        self.assertFalse(verdict['admitted'])
        self.assertEqual(verdict['research_admission'], 'refused')
        self.assertIn('does not transfer', verdict['reason'])

    def test_pending_image_identity_is_never_an_admission(self):
        pending = measurement.admission_verdict(
            identity(skylight=None, launch_services=None), True, image_identity_pending=True)
        self.assertFalse(pending['admitted'])
        self.assertEqual(pending['research_admission'], 'pending_image_identity')
        self.assertEqual(pending['profile'], 'none')

    def test_detection_uses_the_running_system_and_not_a_declaration(self):
        answers = {('sw_vers', '-buildVersion'): '26A428',
                   ('sysctl', '-n', 'hw.model'): 'Mac16,1',
                   ('sysctl', '-n', 'sysctl.proc_translated'): '0',
                   ('uname', '-m'): 'arm64'}
        detected = measurement.detect_local_identity(lambda command: answers[tuple(command)])
        self.assertEqual(detected['build'], '26A428')
        self.assertEqual(detected['architecture'], 'arm64')
        self.assertIsNone(detected['skylight_uuid'])
        answers[('sysctl', '-n', 'sysctl.proc_translated')] = '1'
        self.assertEqual(measurement.detect_local_identity(
            lambda command: answers[tuple(command)])['architecture'], 'x86_64-translated')
        missing = measurement.detect_local_identity(lambda command: None)
        self.assertFalse(measurement.admission_verdict(missing, True)['admitted'])

    def test_a_sampler_that_reports_nothing_refuses(self):
        preflight = {'record': None, 'error': 'no such file', 'exit': None}
        verdict = measurement.reconciled_admission(identity(), preflight, True)
        self.assertFalse(verdict['admitted'])
        self.assertIn('no admission record', verdict['reason'])

    def test_identities_that_disagree_refuse(self):
        local = identity(skylight=None, launch_services=None)
        reported = dict(identity(build='26A5425a'))
        preflight = {'record': {'admitted': True, 'detected': reported}, 'exit': 0}
        verdict = measurement.reconciled_admission(local, preflight, True)
        self.assertFalse(verdict['admitted'])
        self.assertIn('inconsistent identity', verdict['reason'])

    def test_a_sampler_that_admits_what_the_runner_refuses_still_refuses(self):
        local = identity(model='Mac15,3', skylight=None, launch_services=None)
        preflight = {'record': {'admitted': True, 'detected': identity(model='Mac15,3')}, 'exit': 0}
        verdict = measurement.reconciled_admission(local, preflight, True)
        self.assertFalse(verdict['admitted'])

    def test_the_admitted_path_needs_both_answers_and_a_clean_exit(self):
        local = identity(skylight=None, launch_services=None)
        record = {'admitted': True, 'detected': identity()}
        verdict = measurement.reconciled_admission(local, {'record': record, 'exit': 0}, True)
        self.assertTrue(verdict['admitted'])
        self.assertEqual(verdict['profile'], 'research-26A428')
        refused = measurement.reconciled_admission(local, {'record': record, 'exit': 9}, True)
        self.assertFalse(refused['admitted'])

    def test_preflight_command_carries_the_opt_in_only_when_it_was_given(self):
        seen = {}

        def run(command, **keywords):
            seen['command'] = command
            return type('Completed', (), {'returncode': 0, 'stdout': ''})()

        measurement.sampler_preflight('/tmp/sampler', False, run=run)
        self.assertIn('--preflight', seen['command'])
        self.assertNotIn('--experimental-research-admission', seen['command'])
        measurement.sampler_preflight('/tmp/sampler', True, run=run)
        self.assertIn('--experimental-research-admission', seen['command'])


@unittest.skipUnless(GUARD_SOURCE.exists(), 'the sampler source is required')
class SamplerGuardTests(unittest.TestCase):
    """The sampler's own guard, invoked directly, with no image and no SPI."""

    def guard(self, detected, opt_in):
        if GUARD_ERROR is not None:
            self.fail(f'the sampler guard did not compile: {GUARD_ERROR}')
        if GUARD_BINARY is None:
            self.skipTest('no C toolchain is available to build the guard')
        arguments = [detected.get(key) or '-' for key in
                     ('build', 'hardware_model', 'architecture',
                      'skylight_uuid', 'launch_services_uuid')]
        completed = subprocess.run([str(GUARD_BINARY), *arguments, '1' if opt_in else '0'],
                                   capture_output=True, text=True, timeout=60)
        return completed, measurement.prefixed_json(completed.stdout, 'FOCUS_ADMISSION ')

    def test_direct_invocation_refuses_the_same_identities_as_the_runner(self):
        for name, detected, opt_in, admitted, profile in ADMISSION_TABLE:
            with self.subTest(name):
                completed, record = self.guard(detected, opt_in)
                expected = measurement.admission_verdict(detected, opt_in)
                self.assertEqual(record['admitted'], admitted)
                self.assertEqual(record['profile'], profile)
                self.assertEqual(record['static_abi_evidence'], expected['static_abi_evidence'])
                self.assertEqual(record['research_admission'], expected['research_admission'])
                self.assertEqual(record['reason'], expected['reason'])
                self.assertEqual(record['runtime_qualification'], 'not_acquired')
                self.assertEqual(completed.returncode, 0 if admitted else 9)

    def test_the_guard_reports_what_it_was_given_and_claims_no_qualification(self):
        completed, record = self.guard(identity(), True)
        self.assertEqual(record['detected']['skylight_uuid'], RESEARCH_SKYLIGHT)
        self.assertEqual(record['detected']['launch_services_uuid'], RESEARCH_LAUNCH_SERVICES)
        self.assertEqual(record['operator_consent'], 'not_evidenced_by_this_preflight')
        self.assertEqual(record['runtime_qualification'], 'not_acquired')
        self.assertEqual(completed.returncode, 0)

    def test_an_absent_field_is_not_a_wildcard(self):
        for key in ('build', 'hardware_model', 'architecture',
                    'skylight_uuid', 'launch_services_uuid'):
            with self.subTest(key):
                detected = identity()
                detected[key] = None
                completed, record = self.guard(detected, True)
                self.assertFalse(record['admitted'])
                self.assertEqual(completed.returncode, 9)

    def test_the_source_keeps_both_profiles_apart(self):
        source = GUARD_SOURCE.read_text()
        self.assertIn('26A5425a', source)
        self.assertIn('26A428', source)
        self.assertIn(RESEARCH_SKYLIGHT, source)
        self.assertIn(RESEARCH_LAUNCH_SERVICES, source)


class FakeChild:
    """A controlled stand-in for a subprocess handle. It starts nothing."""

    def __init__(self, pid, args, exits_on_wait=None, returncode=0, running=True):
        self.pid = pid
        self.args = list(args)
        self.returncode = None if running else returncode
        self._exit_code = returncode
        self._running = running
        self._waits = 0
        self._exits_on_wait = exits_on_wait

    def poll(self):
        return None if self._running else self.returncode

    def wait(self, timeout=None):
        self._waits += 1
        if self._running and self._waits == self._exits_on_wait:
            self._running = False
            self.returncode = self._exit_code
        if self._running:
            raise subprocess.TimeoutExpired(self.args, timeout)
        return self.returncode


class RecordingSignaller:

    def __init__(self, failure=None):
        self.calls = []
        self.failure = failure

    def __call__(self, group, number):
        self.calls.append((group, number))
        if self.failure:
            raise self.failure


class OwnershipTests(unittest.TestCase):
    """Only resources this runner started or created, and only by attestation."""

    def setUp(self):
        self.trial = measurement.trial_identity(0, {'scenario': 'cold'}, token='abcdef',
                                                clock=lambda: 10.0)
        self.record = measurement.owned_process_record(
            'runner_subprocess', self.trial, 4242, ['bash', 'run-tier.sh'], clock=lambda: 10.0)

    def test_a_trial_and_its_resources_share_one_identity(self):
        self.assertEqual(self.trial['trial'], 'trial-1-abcdef')
        self.assertEqual(self.record['trial'], 'trial-1-abcdef')
        self.assertEqual(self.record['process_group'], 4242)
        self.assertEqual(self.record['started_at_monotonic'], 10.0)

    def test_a_recycled_pid_is_never_signalled(self):
        signaller = RecordingSignaller()
        handle = FakeChild(4242, ['bash', 'run-tier.sh'])
        observed = measurement.observation_of(handle, self.record)
        observed['attested_by_launch_handle'] = False
        decision = measurement.signal_decision(self.record, observed)
        self.assertFalse(decision['authorized'])
        self.assertIn('reuse', decision['reason'])
        other = measurement.owned_process_record('runner_subprocess', self.trial, 9999,
                                                 ['bash', 'run-tier.sh'])
        outcome = measurement.stop_owned_child(handle, other, signaller=signaller)
        self.assertEqual(outcome['status'], 'unknown_incomplete')
        self.assertEqual(signaller.calls, [])

    def test_a_different_command_on_the_same_pid_is_refused(self):
        signaller = RecordingSignaller()
        handle = FakeChild(4242, ['bash', 'something-else.sh'])
        outcome = measurement.stop_owned_child(handle, self.record, signaller=signaller)
        self.assertEqual(outcome['status'], 'unknown_incomplete')
        self.assertEqual(signaller.calls, [])

    def test_an_unobservable_process_is_refused(self):
        decision = measurement.signal_decision(self.record, None)
        self.assertFalse(decision['authorized'])
        self.assertFalse(decision['already_exited'])

    def test_a_child_that_exited_on_its_own_is_verified(self):
        signaller = RecordingSignaller()
        handle = FakeChild(4242, ['bash', 'run-tier.sh'], running=False)
        outcome = measurement.stop_owned_child(handle, self.record, signaller=signaller)
        self.assertEqual(outcome['status'], 'completed_verified')
        self.assertEqual(signaller.calls, [])

    def test_sigterm_does_not_prove_the_resources_it_owned_are_gone(self):
        signaller = RecordingSignaller()
        handle = FakeChild(4242, ['bash', 'run-tier.sh'], exits_on_wait=1)
        outcome = measurement.stop_owned_child(handle, self.record, signaller=signaller)
        self.assertEqual(outcome['status'], 'unknown_incomplete')
        self.assertIn('SIGTERM', outcome['detail'])
        self.assertEqual([number for _, number in signaller.calls], [15])

    def test_escalation_stops_after_sigkill_and_does_not_wait_forever(self):
        signaller = RecordingSignaller()
        handle = FakeChild(4242, ['bash', 'run-tier.sh'])
        outcome = measurement.stop_owned_child(handle, self.record, signaller=signaller)
        self.assertEqual([number for _, number in signaller.calls], [15, 9])
        self.assertEqual(outcome['status'], 'unknown_incomplete')
        self.assertIn('SIGKILL', outcome['detail'])

    def test_a_kill_that_reaps_still_proves_nothing_about_descendants(self):
        handle = FakeChild(4242, ['bash', 'run-tier.sh'], exits_on_wait=2)
        outcome = measurement.stop_owned_child(handle, self.record,
                                               signaller=RecordingSignaller())
        self.assertEqual(outcome['status'], 'unknown_incomplete')
        self.assertIn('teardown', outcome['detail'])

    def test_a_leaf_this_runner_reaped_is_verified(self):
        worker = measurement.owned_process_record('cpu_load_worker', self.trial, 77,
                                                  ['/usr/bin/yes'], owns_descendants=False)
        handle = FakeChild(77, ['/usr/bin/yes'], exits_on_wait=1)
        outcome = measurement.stop_owned_child(handle, worker, signaller=RecordingSignaller())
        self.assertEqual(outcome['status'], 'completed_verified')

    def test_a_signal_that_fails_is_a_failure_and_not_an_unknown(self):
        signaller = RecordingSignaller(failure=OSError('no such process group'))
        handle = FakeChild(4242, ['bash', 'run-tier.sh'])
        outcome = measurement.stop_owned_child(handle, self.record, signaller=signaller)
        self.assertEqual(outcome['status'], 'failed')

    def test_only_the_exact_directory_with_its_marker_may_be_removed(self):
        record = measurement.owned_path_record('runner_workspace', self.trial,
                                               '/tmp/agentseat-focus-abc', 'marker-1',
                                               clock=lambda: 10.0)
        present = {'path': '/tmp/agentseat-focus-abc', 'exists': True, 'is_symlink': False,
                   'is_directory': True, 'marker': 'marker-1'}
        self.assertTrue(measurement.deletion_decision(record, present)['authorized'])
        for name, observed in (
            ('a link', dict(present, is_symlink=True)),
            ('a file', dict(present, is_directory=False)),
            ('a sibling with the same prefix', dict(present, path='/tmp/agentseat-focus-abcd')),
            ('another trial marker', dict(present, marker='marker-2')),
            ('no marker at all', dict(present, marker=None)),
        ):
            with self.subTest(name):
                decision = measurement.deletion_decision(record, observed)
                self.assertFalse(decision['authorized'])
                self.assertFalse(decision['already_absent'])
        absent = measurement.deletion_decision(record, dict(present, exists=False))
        self.assertFalse(absent['authorized'])
        self.assertTrue(absent['already_absent'])
        foreign = dict(record, created_by_this_run=False)
        self.assertFalse(measurement.deletion_decision(foreign, present)['authorized'])

    def test_the_directory_reader_does_not_follow_a_link(self):
        with tempfile.TemporaryDirectory(prefix='focus-ownership-check-') as workspace:
            owned = Path(workspace) / 'owned'
            owned.mkdir()
            (owned / '.agentseat-owner').write_text('marker-1')
            link = Path(workspace) / 'link'
            link.symlink_to(owned)
            self.assertTrue(measurement.observed_directory(owned)['is_directory'])
            self.assertEqual(measurement.observed_directory(owned)['marker'], 'marker-1')
            seen = measurement.observed_directory(link)
            self.assertTrue(seen['is_symlink'])
            self.assertFalse(seen['is_directory'])
            self.assertIsNone(seen['marker'])
            missing = measurement.observed_directory(Path(workspace) / 'absent')
            self.assertFalse(missing['exists'])


class SupervisorTests(unittest.TestCase):
    """Residues, blocked cells and evidence kept when the child never tore down."""

    def setUp(self):
        self.trial = measurement.trial_identity(0, {'scenario': 'cold'}, token='abcdef',
                                                clock=lambda: 0.0)

    def test_a_child_that_recorded_nothing_leaves_an_unknown(self):
        records = measurement.child_teardown_records(self.trial['trial'], 'TIER_RESULT {}')
        self.assertEqual([row['status'] for row in records], ['unknown_incomplete'])
        self.assertIn('defer', records[0]['detail'])

    def test_two_teardown_records_are_not_evidence(self):
        log = 'FOCUS_CLEANUP {"resources": []}\nFOCUS_CLEANUP {"resources": []}'
        records = measurement.child_teardown_records(self.trial['trial'], log)
        self.assertEqual([row['status'] for row in records], ['unknown_incomplete'])

    def test_the_child_outcomes_are_kept_one_by_one(self):
        log = 'FOCUS_CLEANUP ' + json.dumps({'trial': 'trial-1-abcdef', 'complete': False,
            'resources': [
                {'kind': 'browser_process', 'status': 'completed_verified', 'detail': 'exited',
                 'identity': 'pid 5 token t'},
                {'kind': 'temporary_profile_directory', 'status': 'failed', 'detail': 'errno 1',
                 'identity': '/tmp/x'},
                {'kind': 'virtual_display', 'status': 'unknown_incomplete', 'detail': 'unmatched',
                 'identity': 'display 7'}]})
        records = measurement.child_teardown_records(self.trial['trial'], log)
        self.assertEqual([row['kind'] for row in records],
                         ['child:browser_process', 'child:temporary_profile_directory',
                          'child:virtual_display'])
        self.assertEqual([row['status'] for row in records],
                         ['completed_verified', 'failed', 'unknown_incomplete'])
        self.assertEqual(records[1]['identity'], '/tmp/x')

    def test_an_unknown_status_from_the_child_is_not_taken_as_complete(self):
        log = 'FOCUS_CLEANUP ' + json.dumps({'resources': [{'kind': 'seat_turn', 'status': 'ok'}]})
        records = measurement.child_teardown_records(self.trial['trial'], log)
        self.assertEqual(records[0]['status'], 'unknown_incomplete')

    def test_a_residue_blocks_the_next_cell_without_a_sweep(self):
        clean = measurement.trial_cleanup_verdict(self.trial, [
            measurement.cleanup_record('runner_subprocess', self.trial['trial'],
                                       'completed_verified', 'exited')])
        self.assertTrue(clean['next_cell_allowed'])
        self.assertFalse(clean['intervention_required'])
        blocked = measurement.trial_cleanup_verdict(self.trial, [
            measurement.cleanup_record('runner_subprocess', self.trial['trial'],
                                       'completed_verified', 'exited'),
            measurement.cleanup_record('child:virtual_display', self.trial['trial'],
                                       'unknown_incomplete', 'unmatched')])
        self.assertFalse(blocked['next_cell_allowed'])
        self.assertTrue(blocked['intervention_required'])
        self.assertEqual([row['kind'] for row in blocked['residues']], ['child:virtual_display'])
        self.assertFalse(blocked['global_cleanup_attempted'])

    def test_several_failures_in_one_trial_are_all_kept(self):
        signaller = RecordingSignaller()
        record = measurement.owned_process_record('runner_subprocess', self.trial, 4242,
                                                  ['bash', 'run-tier.sh'])
        killed = measurement.stop_owned_child(FakeChild(4242, ['bash', 'run-tier.sh']),
                                              record, signaller=signaller)
        log_text = 'FOCUS_CLEANUP ' + json.dumps({'resources': [
            {'kind': 'browser_process', 'status': 'failed', 'detail': 'errno 3',
             'identity': 'pid 5 token t'},
            {'kind': 'temporary_profile_directory', 'status': 'unknown_incomplete',
             'detail': 'still present', 'identity': '/tmp/x'}]})
        records = [killed] + measurement.child_teardown_records(self.trial['trial'], log_text)
        verdict = measurement.trial_cleanup_verdict(self.trial, records)
        self.assertEqual(len(verdict['residues']), 3)
        self.assertEqual(sorted({row['status'] for row in verdict['residues']}),
                         ['failed', 'unknown_incomplete'])
        self.assertFalse(verdict['next_cell_allowed'])

    def test_an_empty_cleanup_verdict_does_not_authorise_anything_either(self):
        verdict = measurement.trial_cleanup_verdict(self.trial, [])
        self.assertTrue(verdict['next_cell_allowed'])
        self.assertEqual(verdict['residues'], [])

    def test_a_killed_child_keeps_the_measurement_it_did_record(self):
        killed = log(restore_call=9_500_000, identities=(0, 1))
        with self.assertRaises(ValueError):
            measurement.parse_trial(killed, 8000)
        self.assertEqual(measurement.full_call_from_log(killed), 9_500_000)
        records = measurement.child_teardown_records('trial-1-abcdef', killed)
        self.assertEqual(records[0]['status'], 'unknown_incomplete')
        report = measurement.full_call_summary([], [measurement.full_call_from_log(killed)])
        self.assertEqual(report['full_call_max_ns'], 9_500_000)
        self.assertEqual(report['full_call_overrun_trials'], 1)
        self.assertEqual(report['full_call_criterion'], 'not_qualified')

    def test_the_historic_limits_are_unchanged(self):
        self.assertEqual(measurement.TRIAL_TIMEOUT_SECONDS, 90)
        self.assertEqual(measurement.ESCALATION_SECONDS, 5)
        self.assertEqual(measurement.SAMPLER_LOOP_SECONDS, 4)
        self.assertEqual(measurement.SAMPLE_PERIOD_RANGE_US, (50, 1000))
        self.assertEqual(measurement.DEFAULT_SAMPLE_PERIOD_US, 100)
        source = GUARD_SOURCE.read_text()
        self.assertIn('4000000000ULL', source)
        self.assertIn('blocked_native_call_interrupted', source)

    def test_the_proposed_pilot_is_one_cold_cell_and_is_not_authorised(self):
        pilot = measurement.proposed_pilot()
        self.assertEqual(pilot['plan'], [{'scenario': 'cold', 'key_records': False,
                                          'sample_us': 100, 'activation_only': True}])
        self.assertEqual(pilot['trials'], 1)
        self.assertFalse(pilot['matrix'])
        self.assertFalse(pilot['cpu_load'])
        self.assertIn('not granted', pilot['authorisation'])

    def test_neither_an_admission_nor_a_clean_teardown_makes_a_report_pass(self):
        trial = measurement.parse_trial(log(), 8000)
        self.assertIsNone(trial['sampler_admission'])
        base = measurement.summarize([trial], 8000)
        base.update(planned_trials=1, residual_resources=[], all_trials_admitted=True)
        self.assertEqual(measurement.status_of(base), 'not_qualified')
        required = {key: True for key in ('cursor_unchanged', 'no_physical_input', 'same_user_app',
                    'same_user_window', 'recovered', 'target_virtual', 'no_uncertain_commands')}
        admitted = log().replace(
            'FOCUS_VALIDATION ' + json.dumps({'no_physical_input': True, 'cursor_unchanged': True}),
            'FOCUS_VALIDATION ' + json.dumps(required))
        admitted += '\nFOCUS_ADMISSION ' + json.dumps({'admitted': True, 'profile': 'research-26A428'})
        qualified = measurement.parse_trial(admitted, 8000)
        self.assertTrue(measurement.trial_is_admitted(qualified))
        report = measurement.summarize([qualified], 8000)
        report.update(planned_trials=1, residual_resources=[], all_trials_admitted=True)
        self.assertEqual(measurement.status_of(report), 'passed')
        report.update(residual_resources=[{'kind': 'child:virtual_display'}])
        self.assertEqual(measurement.status_of(report), 'not_qualified')
        report.update(residual_resources=[], all_trials_admitted=False)
        self.assertEqual(measurement.status_of(report), 'not_qualified')

    def test_a_trial_without_an_admission_record_is_not_admitted(self):
        self.assertFalse(measurement.trial_is_admitted(measurement.parse_trial(log(), 8000)))
        refused = log() + '\nFOCUS_ADMISSION ' + json.dumps({'admitted': False})
        self.assertFalse(measurement.trial_is_admitted(measurement.parse_trial(refused, 8000)))

    def test_an_incomplete_attempt_keeps_its_trial_and_its_log(self):
        entry = {'cell': {'scenario': 'cold'}, 'trial': 'trial-1-abcdef',
                 'reason': 'runner exceeded 90 seconds', 'log': '/tmp/x.log',
                 'restore_call_ns': 4_000_000}
        report = measurement.full_call_summary([], [entry['restore_call_ns']])
        self.assertEqual(report['full_call_observed_measurements'], 1)
        self.assertEqual(report['full_call_criterion'], 'passed')
        self.assertEqual(entry['trial'], 'trial-1-abcdef')


if __name__ == '__main__':
    unittest.main()
