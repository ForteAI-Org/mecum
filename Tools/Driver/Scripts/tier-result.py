#!/usr/bin/env python3
"""Validate a Swift Testing transcript without counting skipped tests as executed."""
import json
import pathlib
import re
import sys

SUMMARY = re.compile(r'^.*?Test run with (\d+) tests?\b.*?\b(passed|failed)\b', re.MULTILINE)
SKIPPED = re.compile(r'^[^\w\n]*Test (?!run with ).+ skipped(?:[.:].*)?$', re.MULTILINE)


def summarize(text, expected, runner_status):
    summaries = SUMMARY.findall(text)
    reported = sum(int(count) for count, _ in summaries)
    skip_details = SKIPPED.findall(text)
    skipped = len(skip_details)
    problems = []
    if runner_status:
        problems.append(f'the runner exited {runner_status}')
    if not summaries:
        problems.append('no summary line, so completion is unproven')
    if any(verdict == 'failed' for _, verdict in summaries):
        problems.append('the runner reported a failed test run')
    if expected != '-' and reported != int(expected):
        problems.append(f'{reported} tests reported, {expected} expected')
    if skipped > reported:
        problems.append('more skipped tests than reported tests')
    return dict(reported=reported, executed=max(0, reported - skipped), skipped=skipped,
                runs=len(summaries), status='failed' if problems else 'passed', problems=problems,
                skip_details=skip_details)


def main():
    label, expected, runner_status, path = sys.argv[1:]
    result = summarize(pathlib.Path(path).read_text(errors='replace'), expected, int(runner_status))
    print('TIER_RESULT ' + json.dumps(result, sort_keys=True))
    verdict = 'FAIL' if result['problems'] else 'OK  '
    print(f"{verdict} {label}: {result['executed']} executed, {result['skipped']} skipped, "
          f"{result['reported']} reported in {result['runs']} run(s), log at {path}")
    for problem in result['problems']:
        print(f'     {problem}')
    return 1 if result['problems'] else 0


if __name__ == '__main__':
    sys.exit(main())
