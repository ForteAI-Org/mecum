#!/usr/bin/env python3
"""Checks how phase-table.py pairs signposts and sums them, on synthetic log lines.

Offline: no log stream, no application, no build with the measurement condition.
"""
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('phase_table', Path(__file__).with_name('phase-table.py'))
phases = importlib.util.module_from_spec(spec)
spec.loader.exec_module(phases)


def event(kind, name, identifier, ticks, message='', process=1, path='/a/Mecum'):
    return json.dumps({
        'signpostType': kind, 'signpostName': name, 'signpostID': identifier, 'machTimestamp': ticks,
        'eventMessage': message, 'processID': process, 'processImagePath': path,
        'subsystem': phases.SUBSYSTEM,
    })


class PhaseTableTests(unittest.TestCase):

    def test_overlapping_intervals_of_one_name_pair_by_signpost_id(self):
        lines = [
            event('begin', 'pause', 1, 0), event('begin', 'pause', 2, 10),
            event('end', 'pause', 2, 40), event('end', 'pause', 1, 100),
        ]
        self.assertEqual(sorted(phases.durations(lines)['pause']), [30, 100])

    def test_an_interval_that_never_ended_and_foreign_lines_are_ignored(self):
        lines = [
            'Filtering the log data using "subsystem"', event('begin', 'tool', 1, 0, 'observe'),
            event('begin', 'tool', 2, 5, 'observe'), event('end', 'tool', 2, 25),
            json.dumps({'signpostType': 'end', 'signpostName': 'tool', 'signpostID': 1,
                        'machTimestamp': 99, 'subsystem': 'other'}),
        ]
        self.assertEqual(phases.durations(lines), {'tool:observe': [20]})

    def test_process_filter_and_tick_scale(self):
        lines = [
            event('begin', 'pause', 1, 0, path='/a/Mecum'), event('end', 'pause', 1, 10, path='/a/Mecum'),
            event('begin', 'pause', 1, 0, process=2, path='/a/Other'),
            event('end', 'pause', 1, 50, process=2, path='/a/Other'),
        ]
        self.assertEqual(phases.durations(lines, process='Other', tick_ms=0.5)['pause'], [25.0])

    def test_median_and_p95_of_the_table(self):
        found = {'pause': [float(value) for value in range(1, 21)], 'tool:act': [4.0, 8.0]}
        rows = phases.table(found).splitlines()
        self.assertTrue(rows[1].startswith('tool:act'))
        self.assertIn('6.0', rows[1])
        self.assertTrue(rows[2].startswith('pause'))
        self.assertEqual(phases.percentile(sorted(found['pause']), 0.95), 19.0)
        self.assertIn('10.5', rows[2])


if __name__ == '__main__':
    unittest.main()
