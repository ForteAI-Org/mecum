#!/usr/bin/env python3
"""Turns the signposts of a MECUM_PHASES build into a table of milliseconds per phase.

    phase-table.py record [--process NAME] [OUT.ndjson]   stream signposts until Ctrl-C, then print
    phase-table.py table  FILE.ndjson [--process NAME]    print the table of a recorded stream

`record` runs `/usr/bin/log stream --signpost --style ndjson` for the subsystem
`dev.forte.Mecum.phases`. It needs no sudo; it only has to be running while the measured build
works. An interval that began and never ended (its operation threw) is ignored. Durations come
from the Mach timestamps of the begin and end events, so they are not rounded by the log's clock.
"""
import argparse
import ctypes
import json
import signal
import subprocess
import sys
from collections import defaultdict

SUBSYSTEM = 'dev.forte.Mecum.phases'

# The order the table prints in. A name not listed follows, alphabetically.
ORDER = [
    'tool', 'perception',
    'capture.windowStill', 'target.observe', 'target.verify', 'seat.observe',
    'seat.preCapture', 'seat.foldReading', 'seat.captureLoop', 'seat.captureSource',
    'capture.oneShotStill', 'capture.streamStill', 'capture.stream.size', 'capture.stream.start',
    'capture.stream.firstFrame', 'capture.stream.stop', 'seat.stillCurrent',
    'capture.displayStill', 'capture.makeCGImage',
    'pipeline', 'pipeline.ocr', 'pipeline.segments', 'pipeline.ax', 'pipeline.compose',
    'pipeline.axWait', 'pipeline.merge', 'pipeline.controlState',
    'delivery.prepare', 'delivery', 'delivery.confirm', 'pause',
    'render.scene', 'render.result',
]


def milliseconds_per_tick():
    """Mach ticks to milliseconds on this machine."""
    class Timebase(ctypes.Structure):
        _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]
    base = Timebase()
    ctypes.CDLL('/usr/lib/libSystem.B.dylib').mach_timebase_info(ctypes.byref(base))
    return base.numer / base.denom / 1e6


def durations(lines, process=None, tick_ms=1.0):
    """Pairs begin and end events: {phase: [milliseconds]}. A phase with a detail is `name:detail`."""
    open_intervals = {}
    found = defaultdict(list)
    for line in lines:
        line = line.strip()
        if not line.startswith('{'):
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        kind = event.get('signpostType')
        if kind not in ('begin', 'end') or event.get('subsystem') != SUBSYSTEM:
            continue
        if process and not event.get('processImagePath', '').endswith('/' + process):
            continue
        key = (event.get('processID'), event.get('signpostID'), event.get('signpostName'))
        if kind == 'begin':
            open_intervals[key] = (event['machTimestamp'], event.get('eventMessage', ''))
        elif key in open_intervals:
            started, detail = open_intervals.pop(key)
            name = key[2] + (':' + detail if detail else '')
            found[name].append((event['machTimestamp'] - started) * tick_ms)
    return found


def percentile(sorted_values, fraction):
    """Nearest rank."""
    rank = max(1, -(-len(sorted_values) * fraction // 1))
    return sorted_values[int(min(rank, len(sorted_values))) - 1]


def table(found):
    def position(name):
        base = name.split(':')[0]
        return (ORDER.index(base) if base in ORDER else len(ORDER), name)

    rows = ['%-28s %6s %10s %10s %10s' % ('phase', 'n', 'median ms', 'p95 ms', 'max ms')]
    for name in sorted(found, key=position):
        values = sorted(found[name])
        median = values[len(values) // 2] if len(values) % 2 else (values[len(values) // 2 - 1] + values[len(values) // 2]) / 2
        rows.append('%-28s %6d %10.1f %10.1f %10.1f' % (
            name, len(values), median, percentile(values, 0.95), values[-1]))
    return '\n'.join(rows)


def record(out_path, process):
    out = open(out_path, 'w') if out_path else None
    stream = subprocess.Popen(
        ['/usr/bin/log', 'stream', '--signpost', '--style', 'ndjson',
         '--predicate', f'subsystem == "{SUBSYSTEM}"'],
        stdout=subprocess.PIPE, text=True)
    lines = []
    # Only this process stops the stream it started, on Ctrl-C.
    signal.signal(signal.SIGINT, lambda *_: stream.terminate())
    print('Recording signposts, Ctrl-C when the run is done.', file=sys.stderr)
    for line in stream.stdout:
        lines.append(line)
        if out:
            out.write(line)
    stream.wait()
    if out:
        out.close()
    print(table(durations(lines, process, milliseconds_per_tick())))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    recording = commands.add_parser('record')
    recording.add_argument('out', nargs='?')
    recording.add_argument('--process')
    reading = commands.add_parser('table')
    reading.add_argument('file')
    reading.add_argument('--process')
    arguments = parser.parse_args()
    if arguments.command == 'record':
        record(arguments.out, arguments.process)
    else:
        with open(arguments.file) as lines:
            print(table(durations(lines, arguments.process, milliseconds_per_tick())))


if __name__ == '__main__':
    main()
