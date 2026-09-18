#!/usr/bin/env python3
"""Measure Chrome Print recovery; a successful action is separate from its latency budget."""
import argparse
import json
import math
import os
import re
import signal
from pathlib import Path
import statistics
import subprocess
import tempfile


# ASI-D-039: 8 ms per measured entry-to-exit restore call, inclusive, on raw data.
FULL_CALL_LIMIT_NS = 8_000_000
FULL_CALL_KEYS = ('restoreCallNanoseconds', 'restoreCallControlNanoseconds')


def unsigned_nanoseconds(value):
    """The recorded duration, or None when it is absent or not a usable count."""
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        return None
    return value


def full_call_verdict(nanoseconds, limit_ns=FULL_CALL_LIMIT_NS):
    """Missing stays missing: an unrecorded call is neither zero nor a pass."""
    if nanoseconds is None:
        return 'missing'
    return 'passed' if nanoseconds <= limit_ns else 'failed'


def full_call_from_log(log):
    """Salvage the raw entry-to-exit duration from an attempt the trial parser refused."""
    try:
        timing = prefixed_json(log, 'FOCUS_TIMING ')
    except ValueError:
        return None
    if not isinstance(timing, dict):
        return None
    return unsigned_nanoseconds(timing.get('restoreCallNanoseconds'))


def salvaged_full_call(path):
    """A missing or unreadable log stays missing; it never becomes a zero."""
    try:
        return full_call_from_log(Path(path).read_text())
    except OSError:
        return None


def prefixed_json(log, prefix):
    values = [json.loads(line[len(prefix):]) for line in log.splitlines() if line.startswith(prefix)]
    if len(values) != 1:
        raise ValueError(f'Expected exactly one {prefix.strip()} record, found {len(values)}')
    return values[0]


def parse_trial(log, budget_ns):
    tier = prefixed_json(log, 'TIER_RESULT ')
    if (tier['executed'], tier['skipped'], tier['reported']) != (1, 0, 1):
        raise ValueError('The functional runner did not report exactly one executed row')
    validation = None
    if any(line.startswith('FOCUS_VALIDATION ') for line in log.splitlines()):
        validation = prefixed_json(log, 'FOCUS_VALIDATION ')
        valid_input = validation.get('no_physical_input') is True and validation.get('cursor_unchanged') is True
    else:
        # Historical rows retain their independent evidence, with its provenance.
        physical = re.findall(r'^FOCUS .* cursor=(\(.*?\))->(\(.*?\)) HID=(\d+)$', log, re.M)
        valid_input = len(physical) == 1 and physical[0][0] == physical[0][1] and physical[0][2] == '0'
    if not valid_input:
        raise ValueError('Physical input evidence is missing or contaminated')
    timing = prefixed_json(log, 'FOCUS_TIMING ')
    server = prefixed_json(log, 'FOCUS_SERVER ')
    transitions = server['transitions']
    if [row['identity'] for row in transitions] != [0, 1, 0]:
        raise ValueError('The sampler did not observe exactly user, target, user')
    lost, restored = transitions[1:]
    if not (0 < lost['lower_ns'] <= lost['at_ns'] <= restored['at_ns']
            and lost['lower_ns'] <= restored['lower_ns'] <= restored['at_ns']):
        raise ValueError('Invalid transition intervals')
    lower = max(0, restored['lower_ns'] - lost['at_ns'])
    upper = restored['at_ns'] - lost['lower_ns']
    controls = [int(line.split()[-1]) for line in log.splitlines()
                if line.startswith('FOCUS_CLOCK_CONTROL_NS ')]
    if len(controls) != 1:
        raise ValueError('Missing or duplicate measurement control')
    control = controls[0]
    # The full-call keys stay out of the adjusted view: their criterion is raw.
    adjusted = {key: max(0, value - control) for key, value in timing.items()
                if key.endswith('Nanoseconds') and key not in
                ('detectedAtUptimeNanoseconds', 'notificationReceivedAtUptimeNanoseconds',
                 'requestFinishedNanoseconds') + FULL_CALL_KEYS}
    restore_call = unsigned_nanoseconds(timing.get('restoreCallNanoseconds'))
    ax = prefixed_json(log, 'FOCUS_AX ') if 'FOCUS_AX ' in log else []
    receipt = timing.get('notificationReceivedAtUptimeNanoseconds')
    return {
        'functional': tier['status'],
        'tier': tier,
        'validation': validation,
        'physical_evidence': 'structured' if validation else 'legacy_focus_line',
        'ax': ax,
        'activation_source': timing.get('activationSource', 'unrecorded'),
        'notification_delivery_lower_ns': receipt - lost['at_ns'] if receipt else None,
        'notification_delivery_upper_ns': receipt - lost['lower_ns'] if receipt else None,
        'observer_to_handler_ns': timing['detectedAtUptimeNanoseconds'] - receipt if receipt else None,
        'measurement_uncertainty_ns': upper - lower,
        'precision': 'passed' if upper - lower <= 500_000 else 'inconclusive',
        'qualifies': tier['status'] == 'passed' and upper <= budget_ns and validation is not None
                     and all(validation.get(key) is True for key in (
                         'cursor_unchanged', 'no_physical_input', 'same_user_app', 'same_user_window',
                         'recovered', 'target_virtual', 'no_uncertain_commands')),
        'server_interval_lower_ns': lower,
        'server_interval_upper_ns': upper,
        'detection_delay_lower_ns': timing['detectedAtUptimeNanoseconds'] - lost['at_ns'],
        'detection_delay_upper_ns': timing['detectedAtUptimeNanoseconds'] - lost['lower_ns'],
        'budget': 'passed' if upper <= budget_ns else ('failed' if lower > budget_ns else 'inconclusive'),
        'restore_call_ns': restore_call,
        'restore_call_control_ns': unsigned_nanoseconds(timing.get('restoreCallControlNanoseconds')),
        'full_call_limit_ns': FULL_CALL_LIMIT_NS,
        'full_call': full_call_verdict(restore_call),
        'clock_control_ns': control,
        'raw_timing': timing,
        'control_adjusted_phases': adjusted,
        'server': server,
    }


def full_call_summary(trials, unparsed=()):
    """The raw full-call criterion, independent of the functional verdict of each attempt.

    An attempt the parser refused (sampler miss, contaminated evidence, timeout) still
    contributes the duration it did record; only genuinely absent data counts as missing.
    Overruns and the maximum span every observed measurement, parsed or salvaged.
    """
    measured = [trial['restore_call_ns'] for trial in trials if trial['restore_call_ns'] is not None]
    salvaged = [nanoseconds for nanoseconds in unparsed if nanoseconds is not None]
    observed = measured + salvaged
    missing = (len(trials) - len(measured)) + (len(unparsed) - len(salvaged))
    overruns = sum(full_call_verdict(nanoseconds) == 'failed' for nanoseconds in observed)
    return {
        'full_call_limit_ms': FULL_CALL_LIMIT_NS / 1e6,
        'full_call_measured_trials': len(measured),
        'full_call_missing_trials': len(trials) - len(measured),
        'full_call_salvaged_measurements': len(salvaged),
        'full_call_unmeasured_incomplete_attempts': len(unparsed) - len(salvaged),
        'full_call_observed_measurements': len(observed),
        'full_call_overrun_trials': overruns,
        'full_call_max_ns': max(observed) if observed else None,
        'full_call_max_ms': max(observed) / 1e6 if observed else None,
        'full_call_criterion': 'passed' if observed and not missing and not overruns else 'not_qualified',
    }


def summarize(trials, budget_ns, unparsed=()):
    if not trials:
        raise ValueError('No trials completed')
    # Mixed samples keep only the phases every trial recorded; nothing is imputed.
    keys = [key for key in trials[0]['control_adjusted_phases']
            if all(key in trial['control_adjusted_phases'] for trial in trials)]
    phases = {}
    for key in keys:
        values = [trial['control_adjusted_phases'][key] / 1e6 for trial in trials]
        phases[key] = {'min_ms': min(values), 'median_ms': statistics.median(values), 'max_ms': max(values)}
    upper = [trial['server_interval_upper_ns'] / 1e6 for trial in trials]
    report = dict(full_call_summary(trials, unparsed))
    report.update({
        'budget_ms': budget_ns / 1e6,
        'completed_trials': len(trials),
        'functional_passed_trials': sum(trial['functional'] == 'passed' for trial in trials),
        'qualified_trials': sum(trial['qualifies'] for trial in trials),
        'all_trials_qualify': all(trial['qualifies'] for trial in trials),
        'precision_passed_trials': sum(trial['precision'] == 'passed' for trial in trials),
        'budget_failed_trials': sum(trial['budget'] == 'failed' for trial in trials),
        'budget_inconclusive_trials': sum(trial['budget'] == 'inconclusive' for trial in trials),
        'hypothetical_iid_95pct_probability_lower_bound': .05 ** (1 / len(trials))
            if all(trial['qualifies'] for trial in trials) else None,
        'budget_passed_trials': sum(trial['budget'] == 'passed' for trial in trials),
        'all_trials_within_budget': all(trial['budget'] == 'passed' for trial in trials),
        'server_upper_bound_ms': {'min': min(upper), 'median': statistics.median(upper), 'max': max(upper)},
        'control_adjusted_phases': phases,
        'trials': trials,
    })
    return report


def campaign_plan(runs, matrix, sample_us):
    if not matrix:
        return [{'scenario': 'cold', 'key_records': False, 'sample_us': sample_us} for _ in range(runs)]
    # Counterbalance the order within each scenario. Fresh Chrome/profile each cell.
    return [{'scenario': scenario, 'key_records': mode, 'sample_us': sample_us}
            for repetition in range(2)
            for scenario in ('cold', 'warm-menu', 'cpu-load')
            for mode in ((False, True) if repetition == 0 else (True, False))]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runs', type=int, default=5)
    parser.add_argument('--matrix', action='store_true', help='12 counterbalanced diagnostic cells')
    parser.add_argument('--sample-us', type=int, default=100)
    parser.add_argument('--skip-build', action='store_true')
    parser.add_argument('--budget-ms', type=float, default=8)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.runs <= 300 or not math.isfinite(args.budget_ms) or args.budget_ms <= 0:
        parser.error('Use 1..300 runs and a finite positive budget')
    if not 50 <= args.sample_us <= 1000:
        parser.error('Sample period must be 50..1000 microseconds')
    build = subprocess.check_output(['sw_vers', '-buildVersion'], text=True).strip()
    if build != '26A5425a':
        parser.error(f'The read-only private sampler ABI has not been checked on {build}')
    root = Path(__file__).resolve().parent.parent
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    trials, incomplete = [], []
    plan = campaign_plan(args.runs, args.matrix, args.sample_us)
    def refuse(cell, reason, log_path):
        # A refused attempt keeps whatever full call it did measure, for the raw criterion.
        incomplete.append({'cell': cell, 'reason': reason, 'log': str(log_path),
                           'restore_call_ns': salvaged_full_call(log_path)})
    def save():
        unparsed = [entry['restore_call_ns'] for entry in incomplete]
        report = (summarize(trials, args.budget_ms * 1e6, unparsed) if trials
                  else dict(full_call_summary([], unparsed), completed_trials=0))
        report.update(build=build, plan=plan, planned_trials=len(plan), attempted_trials=len(trials)+len(incomplete),
                      incomplete=incomplete, protocol='diagnostic, not a statistical qualification')
        report['status'] = ('passed' if len(trials) == len(plan) and report['all_trials_qualify']
                            else 'not_qualified')
        output.write_text(json.dumps(report, indent=2) + '\n')
        return report
    with tempfile.TemporaryDirectory(prefix='agentseat-focus-latency-') as temporary:
        sampler = Path(temporary) / 'focus-sampler'
        subprocess.run(['xcrun', 'clang', '-O2', str(root / 'Scripts/FocusLatencyProbe.c'),
                        '-o', str(sampler)], check=True)
        environment = dict(os.environ, AGENTSEAT_LIVE_TESTS='1', AGENTSEAT_FOCUS_SAMPLER=str(sampler))
        environment.pop('AGENTSEAT_FOCUS_BUDGET', None)
        for index, cell in enumerate(plan):
            log_path = output.with_suffix(f'.trial-{index + 1}.log')
            environment.update(AGENTSEAT_FOCUS_KEY_RECORDS=str(int(cell['key_records'])),
                               AGENTSEAT_FOCUS_SCENARIO=cell['scenario'],
                               AGENTSEAT_FOCUS_SAMPLE_US=str(cell['sample_us']))
            command = ['bash', 'Scripts/run-tier.sh', 'focus-latency', '1', 'xcrun', 'swift', 'test',
                       '--filter', 'UserFocusRecoveryLiveTests', '--no-parallel']
            if index or args.skip_build:
                command.append('--skip-build')
            workers = []
            try:
                if cell['scenario'] == 'cpu-load':
                    for _ in range(2):
                        workers.append(subprocess.Popen(['/usr/bin/yes'], stdout=subprocess.DEVNULL))
                with log_path.open('w') as log:
                    result = subprocess.Popen(command, cwd=root, env=environment, stdout=log,
                                              stderr=subprocess.STDOUT, start_new_session=True)
                    try:
                        result.wait(timeout=90)
                    except subprocess.TimeoutExpired:
                        refuse(cell, 'runner exceeded 90 seconds', log_path)
                        save()
                        return 2
                    finally:
                        if result.poll() is None:
                            os.killpg(result.pid, signal.SIGTERM)
                            try:
                                result.wait(timeout=5)
                            except subprocess.TimeoutExpired:
                                os.killpg(result.pid, signal.SIGKILL)
                                result.wait()
            finally:
                for worker in workers:
                    worker.terminate()
                for worker in workers:
                    worker.wait(timeout=5)
            try:
                trial = parse_trial(log_path.read_text(), args.budget_ms * 1e6)
                trial.update(cell=cell, log=str(log_path), runner_exit=result.returncode)
                if result.returncode != 0:
                    trial['qualifies'] = False
            except (ValueError, KeyError) as error:
                refuse(cell, str(error), log_path)
                salvage = incomplete[-1]['restore_call_ns']
                save()
                print(f'INCOMPLETE {index + 1}: {error}; {log_path}; full call '
                      f"{salvage if salvage is not None else 'missing'} ns", flush=True)
                return 2
            trials.append(trial)
            save()
            print(f'Trial {index + 1}/{len(plan)} {cell}: '
                  f"{trial['server_interval_lower_ns']/1e6:.3f}..{trial['server_interval_upper_ns']/1e6:.3f} ms; "
                  f"budget {trial['budget']}; full call {trial['full_call']} "
                  f"({trial['restore_call_ns'] if trial['restore_call_ns'] is not None else 'missing'} ns); "
                  f"functional {trial['functional']}; "
                  f"source {trial['activation_source']}", flush=True)
    report = save()
    print(json.dumps({key: value for key, value in report.items()
                      if key not in ('trials', 'control_adjusted_phases', 'plan')}, indent=2))
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
