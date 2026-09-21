#!/usr/bin/env python3
"""Measure Chrome Print recovery; a successful action is separate from its latency budget.

The supervisor refuses before it starts anything when the running system is not one
the ABI record covers, keeps the identity and the provenance of every resource each
trial creates, and stops the plan on the first residue it cannot account for.
"""
import argparse
import json
import math
import os
import re
import signal
from pathlib import Path
import stat
import statistics
import subprocess
import tempfile
import time
import uuid


# ASI-D-039: 8 ms per measured entry-to-exit restore call, inclusive, on raw data.
FULL_CALL_LIMIT_NS = 8_000_000
FULL_CALL_KEYS = ('restoreCallNanoseconds', 'restoreCallControlNanoseconds')

# ASI-D-054: two ABI records, kept apart on purpose.
#
# The historic one attests a build and an architecture (the 2026-09-10 SkyLight
# arm64 read) and no image identity: it is not relabelled as the newer evidence
# and it grants nothing on another image. The research one covers exactly one
# identified image on 26A428, is off by default, and needs an opt in on the
# invocation itself. Neither is a runtime qualification and neither is consent
# to run anything live: that stays a separate, human decision recorded elsewhere.
HISTORIC_PROFILE = {
    'name'        : 'historic-26A5425a',
    'build'       : '26A5425a',
    'architecture': 'arm64',
}
RESEARCH_PROFILE = {
    'name'                : 'research-26A428',
    'build'               : '26A428',
    'hardware_model'      : 'Mac16,1',
    'architecture'        : 'arm64',
    'skylight_uuid'       : '8A3B348E-4637-3685-92D0-6CBC2F36A234',
    'launch_services_uuid': '00ED6A89-5E67-37AA-9342-51EB93F68EE5',
}
RUNTIME_QUALIFICATION = 'not_acquired'
IDENTITY_KEYS = ('build', 'hardware_model', 'architecture', 'skylight_uuid', 'launch_services_uuid')

# The per subprocess trial budget, its escalation and the sampler's own loop.
# None of the three renews: a trial that exceeds its budget ends the plan.
TRIAL_TIMEOUT_SECONDS = 90
ESCALATION_SECONDS = 5
SAMPLER_LOOP_SECONDS = 4
SAMPLE_PERIOD_RANGE_US = (50, 1000)
DEFAULT_SAMPLE_PERIOD_US = 100

CLEANUP_COMPLETED = 'completed_verified'
CLEANUP_FAILED = 'failed'
CLEANUP_UNKNOWN = 'unknown_incomplete'


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


def optional_prefixed_json(log, prefix):
    """The single record, None when the child never wrote one, and a refusal when
    it wrote several: two disagreeing records are not evidence."""
    try:
        return prefixed_json(log, prefix)
    except ValueError:
        if any(line.startswith(prefix) for line in log.splitlines()):
            raise
        return None


# MARK: The admission guard

def _present(value):
    return isinstance(value, str) and value != ''


def _matches(detected, key, profile):
    return _present(detected.get(key)) and detected[key] == profile[key]


def admission_verdict(detected, research_opt_in, image_identity_pending=False):
    """The preflight, as three facts that are never collapsed into one.

    `static_abi_evidence` says which record identifies the running image,
    `research_admission` says what happened to the per invocation opt in, and
    `runtime_qualification` is always `not_acquired` here. `admitted` is the only
    permission, and it is false unless a whole profile matched.

    This mirrors `probeAdmission` in FocusLatencyProbe.c, reason by reason, so the
    runner and a direct launch of the sampler refuse the same identities. With
    `image_identity_pending` the image UUIDs are not yet readable by this process:
    that state is reported as pending and never as an admission.
    """
    verdict = {
        'static_abi_evidence'  : 'absent',
        'research_admission'   : 'refused' if research_opt_in else 'not_requested',
        'runtime_qualification': RUNTIME_QUALIFICATION,
        'profile'              : 'none',
        'admitted'             : False,
        'experimental_opt_in'  : bool(research_opt_in),
        'operator_consent'     : 'not_evidenced_by_this_preflight',
        'reason'               : '',
        'detected'             : {key: detected.get(key) for key in IDENTITY_KEYS},
    }
    if not all(_present(detected.get(key)) for key in ('build', 'hardware_model', 'architecture')):
        verdict['reason'] = ('incomplete identity: build, hardware model and host '
                             'architecture must all be detected')
        return verdict

    if detected['build'] == RESEARCH_PROFILE['build']:
        if not all(_present(detected.get(key)) for key in ('skylight_uuid', 'launch_services_uuid')):
            if image_identity_pending:
                verdict['research_admission'] = 'pending_image_identity'
                verdict['reason'] = ('the image UUIDs are read by the sampler preflight, '
                                     'which has not run yet')
                return verdict
            verdict['reason'] = ('incomplete identity: the SkyLight and LaunchServices '
                                 'image UUIDs were not read')
            return verdict
        if not _matches(detected, 'hardware_model', RESEARCH_PROFILE):
            verdict['reason'] = 'hardware model outside the admitted 26A428 profile'
            return verdict
        if not _matches(detected, 'architecture', RESEARCH_PROFILE):
            verdict['reason'] = 'host architecture outside the admitted 26A428 profile'
            return verdict
        if not _matches(detected, 'skylight_uuid', RESEARCH_PROFILE):
            verdict['reason'] = 'the SkyLight image is not the audited one'
            return verdict
        if not _matches(detected, 'launch_services_uuid', RESEARCH_PROFILE):
            verdict['reason'] = 'the LaunchServices delegate image is not the audited one'
            return verdict
        verdict['static_abi_evidence'] = 'research_26A428'
        if not research_opt_in:
            verdict['reason'] = ('the static record identifies this image and the '
                                 'experimental research admission was not requested '
                                 'for this invocation')
            return verdict
        verdict['research_admission'] = 'granted'
        verdict['profile'] = RESEARCH_PROFILE['name']
        verdict['admitted'] = True
        verdict['reason'] = ('admitted for one bounded research probe; no runtime '
                             'qualification and no live consent follow from it')
        return verdict

    if detected['build'] == HISTORIC_PROFILE['build']:
        if not _matches(detected, 'architecture', HISTORIC_PROFILE):
            verdict['reason'] = ('the 26A5425a record was read from an arm64 image and '
                                 'covers no other architecture')
            return verdict
        verdict['static_abi_evidence'] = 'historic_26A5425a'
        if research_opt_in:
            verdict['reason'] = ('the experimental admission names the 26A428 profile '
                                 'and does not transfer to the 26A5425a record')
            return verdict
        verdict['profile'] = HISTORIC_PROFILE['name']
        verdict['admitted'] = True
        verdict['reason'] = ('the historic 26A5425a record, which attests a build and '
                             'an architecture and no image identity')
        return verdict

    verdict['reason'] = 'no ABI record covers this build'
    return verdict


def _read_line(command):
    try:
        completed = subprocess.run(command, capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    return (completed.stdout.strip() or None) if completed.returncode == 0 else None


def detect_local_identity(read=_read_line):
    """Build, hardware model and host architecture as the running system reports them.

    The image UUIDs are absent here by construction: only a process that maps
    SkyLight and LaunchServices can read them, which is the sampler's preflight.
    A translated process is reported as such and is not the audited arm64 host.
    """
    translated = read(['sysctl', '-n', 'sysctl.proc_translated'])
    machine = read(['uname', '-m'])
    return {
        'build'               : read(['sw_vers', '-buildVersion']),
        'hardware_model'      : read(['sysctl', '-n', 'hw.model']),
        'architecture'        : 'x86_64-translated' if translated == '1' else machine,
        'skylight_uuid'       : None,
        'launch_services_uuid': None,
    }


def sampler_preflight(sampler, research_opt_in, run=subprocess.run, trial='preflight'):
    """Runs the sampler's own guard with `--preflight`: it maps the images, reads their
    UUIDs and exits before resolving or calling any SPI. Its report is evidence of the
    identity it detected, not a permission this runner takes on trust.
    """
    command = [str(sampler), '--preflight', f'--trial={trial}']
    if research_opt_in:
        command.append('--experimental-research-admission')
    try:
        completed = run(command, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as error:
        return {'command': command, 'exit': None, 'record': None, 'error': str(error), 'raw': ''}
    output = completed.stdout or ''
    try:
        record = optional_prefixed_json(output, 'FOCUS_ADMISSION ')
    except ValueError as error:
        return {'command': command, 'exit': completed.returncode, 'record': None,
                'error': str(error), 'raw': output}
    return {'command': command, 'exit': completed.returncode, 'record': record,
            'error': None, 'raw': output}


def reconciled_admission(local, preflight, research_opt_in):
    """The verdict this runner computes itself from the identities actually detected.

    The sampler's own answer is compared, never adopted: a missing record, a field
    the two processes disagree on, or a different permission refuses. A CLI flag
    declares an intent and never an identity.
    """
    record = preflight.get('record')
    if not isinstance(record, dict):
        verdict = admission_verdict(local, research_opt_in)
        verdict['admitted'] = False
        verdict['research_admission'] = 'refused' if research_opt_in else 'not_requested'
        verdict['profile'] = 'none'
        verdict['reason'] = ('the sampler preflight reported no admission record: '
                             f"{preflight.get('error') or 'no FOCUS_ADMISSION line'}")
        return verdict
    reported = record.get('detected') if isinstance(record.get('detected'), dict) else {}
    inconsistent = [key for key in IDENTITY_KEYS
                    if _present(local.get(key)) and _present(reported.get(key))
                    and local[key] != reported[key]]
    detected = {key: reported.get(key) or local.get(key) for key in IDENTITY_KEYS}
    verdict = admission_verdict(detected, research_opt_in)
    if inconsistent:
        verdict['admitted'] = False
        verdict['profile'] = 'none'
        verdict['research_admission'] = 'refused' if research_opt_in else 'not_requested'
        verdict['reason'] = ('inconsistent identity between this runner and the sampler: '
                             + ', '.join(sorted(inconsistent)))
        return verdict
    if bool(record.get('admitted')) != verdict['admitted']:
        verdict['admitted'] = False
        verdict['profile'] = 'none'
        verdict['research_admission'] = 'refused' if research_opt_in else 'not_requested'
        verdict['reason'] = ('the sampler and this runner disagree on the admission; '
                             'the refusal wins')
        return verdict
    if verdict['admitted'] and preflight.get('exit') != 0:
        verdict['admitted'] = False
        verdict['profile'] = 'none'
        verdict['reason'] = f"the sampler preflight exited with {preflight.get('exit')}"
    return verdict


# MARK: Ownership and cleanup

def trial_identity(index, cell, token=None, clock=time.monotonic):
    """The identity every resource of one trial is recorded against."""
    return {
        'trial'               : f"trial-{index + 1}-{token or uuid.uuid4().hex[:12]}",
        'index'               : index + 1,
        'cell'                : cell,
        'started_at_monotonic': clock(),
    }


def owned_process_record(kind, trial, pid, command, owns_descendants=True, clock=time.monotonic):
    """A process this runner started itself, in its own session, with the command
    it started it with. The pid alone is recyclable and is never the attestation.

    `owns_descendants` says whether ending this process leaves other resources
    behind: a leaf that this runner reaped is verifiably gone, while the trial
    subprocess owns a browser, a sampler, a profile and a display that its own
    exit says nothing about.
    """
    return {
        'kind'                : kind,
        'trial'               : trial['trial'],
        'pid'                 : pid,
        'process_group'       : pid,
        'command'             : list(command),
        'owns_descendants'    : owns_descendants,
        'started_at_monotonic': clock(),
        'provenance'          : 'started by this runner in its own session',
    }


def owned_path_record(kind, trial, path, marker, clock=time.monotonic):
    """A directory this runner created, with the marker it wrote inside it."""
    return {
        'kind'                : kind,
        'trial'               : trial['trial'],
        'path'                : str(path),
        'marker'              : marker,
        'created_by_this_run' : True,
        'created_at_monotonic': clock(),
        'provenance'          : 'created by this runner',
    }


def observation_of(popen, record):
    """What can be attested about a child while this runner still holds its handle.

    An unreaped child cannot have its pid recycled, so the handle, and not the
    number, is what authorises a signal.
    """
    return {
        'pid'                       : popen.pid,
        'running'                   : popen.poll() is None,
        'attested_by_launch_handle' : popen.pid == record['pid'],
        'command'                   : list(popen.args),
    }


def signal_decision(record, observed):
    """Whether this runner may signal the process it recorded, with the reason."""
    if not isinstance(observed, dict):
        return {'authorized': False, 'already_exited': False,
                'reason': 'the process could not be observed at all'}
    if observed.get('pid') != record['pid']:
        return {'authorized': False, 'already_exited': False,
                'reason': f"the handle holds pid {observed.get('pid')}, not the recorded "
                          f"{record['pid']}"}
    if not observed.get('attested_by_launch_handle'):
        return {'authorized': False, 'already_exited': False,
                'reason': f"pid {record['pid']} is no longer attested by the launch handle, "
                          'so reuse cannot be excluded'}
    if list(observed.get('command') or []) != record['command']:
        return {'authorized': False, 'already_exited': False,
                'reason': 'the handle does not carry the command this trial started'}
    if not observed.get('running'):
        return {'authorized': False, 'already_exited': True,
                'reason': 'the process this trial started has already exited'}
    return {'authorized': True, 'already_exited': False,
            'reason': 'started by this trial and still held by its launch handle'}


def deletion_decision(record, observed):
    """Whether this runner may remove the directory it recorded.

    A shared prefix, a name or a symbolic link pointing at one is not ownership:
    the exact path this runner created, carrying the marker it wrote, is.
    """
    if not record.get('created_by_this_run'):
        return {'authorized': False, 'already_absent': False,
                'reason': 'the directory was not created by this run'}
    if not isinstance(observed, dict) or not observed.get('exists'):
        return {'authorized': False, 'already_absent': True,
                'reason': 'the directory this run created is no longer there'}
    if observed.get('path') != record['path']:
        return {'authorized': False, 'already_absent': False,
                'reason': f"{observed.get('path')} is not the recorded {record['path']}"}
    if observed.get('is_symlink'):
        return {'authorized': False, 'already_absent': False,
                'reason': 'a symbolic link is not the directory this run created'}
    if not observed.get('is_directory'):
        return {'authorized': False, 'already_absent': False,
                'reason': 'the recorded path is no longer a directory'}
    if observed.get('marker') != record['marker']:
        return {'authorized': False, 'already_absent': False,
                'reason': 'the ownership marker inside the directory does not match'}
    return {'authorized': True, 'already_absent': False,
            'reason': 'created by this run and still carrying its marker'}


def observed_directory(path, marker_name='.agentseat-owner'):
    """Reads the filesystem once, without following a link into somebody else's tree."""
    path = Path(path)
    try:
        status = path.lstat()
    except OSError:
        return {'path': str(path), 'exists': False, 'is_symlink': False,
                'is_directory': False, 'marker': None}
    is_symlink = stat.S_ISLNK(status.st_mode)
    is_directory = stat.S_ISDIR(status.st_mode)
    marker = None
    if is_directory and not is_symlink:
        try:
            marker = (path / marker_name).read_text().strip()
        except OSError:
            marker = None
    return {'path': str(path), 'exists': True, 'is_symlink': is_symlink,
            'is_directory': is_directory, 'marker': marker}


def cleanup_record(kind, trial, status, detail, identity=None):
    """One resource, one outcome: concluded and verified, failed, or unknown."""
    assert status in (CLEANUP_COMPLETED, CLEANUP_FAILED, CLEANUP_UNKNOWN)
    return {'kind': kind, 'trial': trial, 'status': status, 'detail': detail,
            'identity': identity}


def stop_owned_child(popen, record, signaller=os.killpg, escalation_seconds=ESCALATION_SECONDS):
    """SIGTERM to the session this runner started, then SIGKILL after 5 s.

    Neither signal proves that the browser, the sampler, the temporary profile or
    the virtual display the child owned are gone, so anything but a teardown the
    child itself reported stays `unknown_incomplete`. The waits are bounded: no
    step here blocks indefinitely in order to call a cleanup finished.
    """
    kind, trial = record['kind'], record['trial']
    identity = {'pid': record['pid'], 'process_group': record['process_group']}
    owns_descendants = record.get('owns_descendants', True)
    decision = signal_decision(record, observation_of(popen, record))
    if decision['already_exited']:
        return cleanup_record(kind, trial, CLEANUP_COMPLETED,
                              f'exited with status {popen.returncode} without a signal',
                              identity)
    if not decision['authorized']:
        return cleanup_record(kind, trial, CLEANUP_UNKNOWN, decision['reason'], identity)
    try:
        signaller(record['process_group'], signal.SIGTERM)
    except OSError as error:
        return cleanup_record(kind, trial, CLEANUP_FAILED, f'SIGTERM failed: {error}', identity)
    try:
        popen.wait(timeout=escalation_seconds)
        if owns_descendants:
            return cleanup_record(kind, trial, CLEANUP_UNKNOWN,
                                  'ended after SIGTERM, which does not prove the windows, '
                                  'processes and displays it owned are gone', identity)
        return cleanup_record(kind, trial, CLEANUP_COMPLETED,
                              'signalled and reaped by this runner, and it owned nothing else',
                              identity)
    except subprocess.TimeoutExpired:
        pass
    try:
        signaller(record['process_group'], signal.SIGKILL)
    except OSError as error:
        return cleanup_record(kind, trial, CLEANUP_FAILED, f'SIGKILL failed: {error}', identity)
    try:
        popen.wait(timeout=escalation_seconds)
    except subprocess.TimeoutExpired:
        return cleanup_record(kind, trial, CLEANUP_UNKNOWN,
                              f'not reaped within {escalation_seconds} s of SIGKILL', identity)
    if owns_descendants:
        return cleanup_record(kind, trial, CLEANUP_UNKNOWN,
                              'SIGKILL ended it without running its own teardown', identity)
    return cleanup_record(kind, trial, CLEANUP_COMPLETED,
                          'killed and reaped by this runner, and it owned nothing else', identity)


def child_teardown_records(trial, log_text):
    """The teardown the child test recorded for its own resources, or an explicit
    unknown when it recorded none: a silent child is not a clean one."""
    try:
        report = optional_prefixed_json(log_text, 'FOCUS_CLEANUP ')
    except ValueError as error:
        return [cleanup_record('child_test_teardown', trial, CLEANUP_UNKNOWN, str(error))]
    if not isinstance(report, dict):
        return [cleanup_record('child_test_teardown', trial, CLEANUP_UNKNOWN,
                               'the child recorded no FOCUS_CLEANUP: its defer and catch '
                               'may never have run')]
    rows = report.get('resources')
    if not isinstance(rows, list) or not rows:
        return [cleanup_record('child_test_teardown', trial, CLEANUP_UNKNOWN,
                               'the child recorded a teardown with no resource in it')]
    records = []
    for row in rows:
        status = row.get('status')
        records.append(cleanup_record(
            f"child:{row.get('kind', 'unnamed')}", trial,
            status if status in (CLEANUP_COMPLETED, CLEANUP_FAILED, CLEANUP_UNKNOWN)
            else CLEANUP_UNKNOWN,
            row.get('detail', ''), row.get('identity')))
    return records


def trial_cleanup_verdict(trial, records):
    """Whether the next cell may start.

    Any residue, unverifiable ownership or incomplete teardown stops the plan and
    asks for a targeted intervention on the exact resources listed. Nothing here
    sweeps by name, by prefix or by pid.
    """
    residues = [record for record in records if record['status'] != CLEANUP_COMPLETED]
    return {
        'trial'                  : trial['trial'],
        'cell'                   : trial['cell'],
        'resources'              : list(records),
        'residues'               : residues,
        'next_cell_allowed'      : not residues,
        'intervention_required'  : bool(residues),
        'global_cleanup_attempted': False,
        'sweep'                  : 'none: residues are reported for targeted intervention',
    }


# MARK: Parsing

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
        # Reported, never a reason to pass: an admission is not a qualification.
        'sampler_admission': optional_prefixed_json(log, 'FOCUS_ADMISSION '),
        'child_teardown': optional_prefixed_json(log, 'FOCUS_CLEANUP '),
    }


def trial_is_admitted(trial):
    """A trial counts only when its own sampler recorded an admission for it."""
    admission = trial.get('sampler_admission')
    return isinstance(admission, dict) and admission.get('admitted') is True


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


def proposed_pilot():
    """The perimeter proposed for a future, separately authorised consent: one cold
    activation-only trial, key records off, 100 microseconds. No matrix, no CPU load
    and no automatic extension. Nothing in this module launches it."""
    return {
        'plan': [{'scenario': 'cold', 'key_records': False,
                  'sample_us': DEFAULT_SAMPLE_PERIOD_US, 'activation_only': True}],
        'trials': 1,
        'matrix': False,
        'cpu_load': False,
        'authorisation': 'not granted: proposed perimeter, not a run',
        'operator_consent': 'to be recorded separately from any preflight',
    }


def status_of(report):
    """`passed` needs every planned trial completed, qualified, admitted and cleaned
    up. An admission or a clean teardown never turns anything else into a pass."""
    if report.get('completed_trials', 0) != report.get('planned_trials'):
        return 'not_qualified'
    if not report.get('all_trials_qualify'):
        return 'not_qualified'
    if report.get('residual_resources'):
        return 'not_qualified'
    if not report.get('all_trials_admitted'):
        return 'not_qualified'
    return 'passed'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runs', type=int, default=5)
    parser.add_argument('--matrix', action='store_true', help='12 counterbalanced diagnostic cells')
    parser.add_argument('--sample-us', type=int, default=DEFAULT_SAMPLE_PERIOD_US)
    parser.add_argument('--skip-build', action='store_true')
    parser.add_argument('--budget-ms', type=float, default=8)
    parser.add_argument('--experimental-research-admission', action='store_true',
                        help='opt in, for this invocation only, to the 26A428 research '
                             'profile of ASI-D-054. Off by default. It is not consent to '
                             'run anything live and it is not a runtime qualification.')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.runs <= 300 or not math.isfinite(args.budget_ms) or args.budget_ms <= 0:
        parser.error('Use 1..300 runs and a finite positive budget')
    if not SAMPLE_PERIOD_RANGE_US[0] <= args.sample_us <= SAMPLE_PERIOD_RANGE_US[1]:
        parser.error('Sample period must be 50..1000 microseconds')
    opt_in = args.experimental_research_admission
    root = Path(__file__).resolve().parent.parent
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    plan = campaign_plan(args.runs, args.matrix, args.sample_us)
    trials, incomplete, cleanups, residues = [], [], [], []
    identity = detect_local_identity()
    admission = admission_verdict(identity, opt_in, image_identity_pending=True)

    def save():
        unparsed = [entry['restore_call_ns'] for entry in incomplete]
        report = (summarize(trials, args.budget_ms * 1e6, unparsed) if trials
                  else dict(full_call_summary([], unparsed), completed_trials=0))
        report.update(build=identity.get('build'), identity=identity, admission=admission,
                      plan=plan, planned_trials=len(plan),
                      attempted_trials=len(trials) + len(incomplete),
                      incomplete=incomplete, cleanup=cleanups, residual_resources=residues,
                      trials_admitted=sum(trial_is_admitted(trial) for trial in trials),
                      all_trials_admitted=bool(trials) and all(map(trial_is_admitted, trials)),
                      proposed_pilot=proposed_pilot(),
                      limits={'trial_timeout_s': TRIAL_TIMEOUT_SECONDS,
                              'escalation_s': ESCALATION_SECONDS,
                              'sampler_loop_s': SAMPLER_LOOP_SECONDS,
                              'sample_period_us': list(SAMPLE_PERIOD_RANGE_US),
                              'default_sample_period_us': DEFAULT_SAMPLE_PERIOD_US,
                              'renewal': 'none: no budget or timeout renews implicitly'},
                      protocol='diagnostic, not a statistical qualification')
        report['status'] = status_of(report)
        output.write_text(json.dumps(report, indent=2) + '\n')
        return report

    def refuse_admission():
        report = save()
        print(f"REFUSED {admission['static_abi_evidence']}/{admission['research_admission']}: "
              f"{admission['reason']}", flush=True)
        return 2

    # Nothing is compiled, no SPI is reached and no GUI row starts until the
    # identity this runner detected is one an ABI record covers.
    if not admission['admitted'] and admission['research_admission'] != 'pending_image_identity':
        return refuse_admission()

    setup = trial_identity(-1, None, token='setup')
    with tempfile.TemporaryDirectory(prefix='agentseat-focus-latency-') as temporary:
        workspace = owned_path_record('runner_workspace', setup, temporary,
                                      f'agentseat-focus-{os.getpid()}-{setup["trial"]}')
        Path(temporary, '.agentseat-owner').write_text(workspace['marker'])
        sampler = Path(temporary) / 'focus-sampler'
        subprocess.run(['xcrun', 'clang', '-O2', str(root / 'Scripts/FocusLatencyProbe.c'),
                        '-o', str(sampler)], check=True)
        admission = reconciled_admission(identity, sampler_preflight(sampler, opt_in), opt_in)
        identity.update({key: value for key, value in admission['detected'].items()
                         if value is not None})
        if not admission['admitted']:
            return refuse_admission()
        environment = dict(os.environ, AGENTSEAT_LIVE_TESTS='1', AGENTSEAT_FOCUS_SAMPLER=str(sampler))
        environment.pop('AGENTSEAT_FOCUS_BUDGET', None)
        environment.pop('AGENTSEAT_FOCUS_RESEARCH_ADMISSION', None)
        if opt_in:
            environment['AGENTSEAT_FOCUS_RESEARCH_ADMISSION'] = '1'
        for index, cell in enumerate(plan):
            trial = trial_identity(index, cell)
            log_path = output.with_suffix(f".trial-{trial['index']}.log")
            environment.update(AGENTSEAT_FOCUS_KEY_RECORDS=str(int(cell['key_records'])),
                               AGENTSEAT_FOCUS_SCENARIO=cell['scenario'],
                               AGENTSEAT_FOCUS_SAMPLE_US=str(cell['sample_us']),
                               AGENTSEAT_FOCUS_TRIAL=trial['trial'])
            command = ['bash', 'Scripts/run-tier.sh', 'focus-latency', '1', 'xcrun', 'swift', 'test',
                       '--filter', 'UserFocusRecoveryLiveTests', '--no-parallel']
            if index or args.skip_build:
                command.append('--skip-build')
            resources, workers, timed_out = [], [], False
            with log_path.open('w') as log:
                child = subprocess.Popen(command, cwd=root, env=environment, stdout=log,
                                         stderr=subprocess.STDOUT, start_new_session=True)
                child_record = owned_process_record('runner_subprocess', trial, child.pid, command)
                try:
                    if cell['scenario'] == 'cpu-load':
                        for _ in range(2):
                            worker = subprocess.Popen(['/usr/bin/yes'], stdout=subprocess.DEVNULL,
                                                      start_new_session=True)
                            workers.append((worker, owned_process_record(
                                'cpu_load_worker', trial, worker.pid, ['/usr/bin/yes'],
                                owns_descendants=False)))
                    # The 90 s belongs to this trial alone and does not renew.
                    child.wait(timeout=TRIAL_TIMEOUT_SECONDS)
                except subprocess.TimeoutExpired:
                    timed_out = True
                finally:
                    resources.append(stop_owned_child(child, child_record))
                    for worker, record in workers:
                        resources.append(stop_owned_child(worker, record))
            log_text = log_path.read_text()
            resources.extend(child_teardown_records(trial['trial'], log_text))
            verdict = trial_cleanup_verdict(trial, resources)
            cleanups.append(verdict)
            residues.extend(verdict['residues'])
            if timed_out:
                incomplete.append({'cell': cell, 'trial': trial['trial'],
                                   'reason': f'runner exceeded {TRIAL_TIMEOUT_SECONDS} seconds',
                                   'log': str(log_path),
                                   'restore_call_ns': salvaged_full_call(log_path)})
                save()
                print(f"TIMEOUT {trial['trial']}: residues "
                      f"{[row['kind'] for row in verdict['residues']]}; {log_path}", flush=True)
                return 2
            try:
                parsed = parse_trial(log_text, args.budget_ms * 1e6)
                parsed.update(cell=cell, trial=trial['trial'], log=str(log_path),
                              runner_exit=child.returncode, cleanup=verdict)
                if child.returncode != 0:
                    parsed['qualifies'] = False
            except (ValueError, KeyError) as error:
                incomplete.append({'cell': cell, 'trial': trial['trial'], 'reason': str(error),
                                   'log': str(log_path),
                                   'restore_call_ns': salvaged_full_call(log_path)})
                salvage = incomplete[-1]['restore_call_ns']
                save()
                print(f"INCOMPLETE {trial['index']}: {error}; {log_path}; full call "
                      f"{salvage if salvage is not None else 'missing'} ns", flush=True)
                return 2
            trials.append(parsed)
            save()
            print(f"Trial {trial['index']}/{len(plan)} {cell}: "
                  f"{parsed['server_interval_lower_ns']/1e6:.3f}..{parsed['server_interval_upper_ns']/1e6:.3f} ms; "
                  f"budget {parsed['budget']}; full call {parsed['full_call']} "
                  f"({parsed['restore_call_ns'] if parsed['restore_call_ns'] is not None else 'missing'} ns); "
                  f"functional {parsed['functional']}; "
                  f"source {parsed['activation_source']}", flush=True)
            # A residue is reported and the plan stops: the next cell would run on
            # a machine whose previous resources are unaccounted for.
            if not verdict['next_cell_allowed']:
                print(f"RESIDUE after {trial['trial']}: "
                      f"{[row['kind'] for row in verdict['residues']]}; targeted intervention "
                      'is required, nothing was swept', flush=True)
                return 2
    # The workspace is checked after its context removed it, not promised before.
    removal = deletion_decision(workspace, observed_directory(workspace['path']))
    workspace_cleanup = cleanup_record(
        'runner_workspace', setup['trial'],
        CLEANUP_COMPLETED if removal['already_absent'] else CLEANUP_UNKNOWN,
        'the workspace this runner created is gone' if removal['already_absent']
        else f"still present: {removal['reason']}", {'path': workspace['path']})
    cleanups.append(trial_cleanup_verdict(setup, [workspace_cleanup]))
    if workspace_cleanup['status'] != CLEANUP_COMPLETED:
        residues.append(workspace_cleanup)
    report = save()
    print(json.dumps({key: value for key, value in report.items()
                      if key not in ('trials', 'control_adjusted_phases', 'plan')}, indent=2))
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
