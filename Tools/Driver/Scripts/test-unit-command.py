"""Exercise the unit runner's dispatch, quoting and failure propagation with fake commands."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class UnitCommandTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mecum-unit-command-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.log = self.root / "calls.jsonl"
        self.bin_dir = self.root / "Products with spaces"
        self.swift = self.root / "fake swift"
        self.swift.write_text("""#!/usr/bin/env python3
import json, os, sys
with open(os.environ['MECUM_UNIT_COMMAND_LOG'], 'a') as log:
    log.write(json.dumps(['swift', *sys.argv[1:]]) + '\\n')
arguments = sys.argv[1:]
if arguments and arguments[0] == 'prefix': arguments = arguments[1:]
if arguments[0] == 'test': sys.exit(int(os.environ.get('MECUM_UNIT_SWIFT_STATUS', '0')))
if arguments == ['build', '--show-bin-path']:
    print(os.environ['MECUM_UNIT_BIN_DIR'])
else:
    sys.exit(90)
""")
        self.swift.chmod(0o700)
        native = self.root / ".build/native-driver-test-main"
        native.parent.mkdir()
        native.write_text("""#!/usr/bin/env python3
import json, os, sys
with open(os.environ['MECUM_UNIT_COMMAND_LOG'], 'a') as log:
    log.write(json.dumps(['native', *sys.argv[1:]]) + '\\n')
sys.exit(int(os.environ.get('MECUM_UNIT_NATIVE_STATUS', '0')))
""")
        native.chmod(0o700)
        self.script = Path(__file__).with_name("unit-test-command.sh").resolve()

    def run_command(self, *, swift_status=0, native_status=0, prefix=False):
        environment = dict(os.environ,
            MECUM_UNIT_COMMAND_LOG=str(self.log),
            MECUM_UNIT_BIN_DIR=str(self.bin_dir),
            MECUM_UNIT_SWIFT_STATUS=str(swift_status),
            MECUM_UNIT_NATIVE_STATUS=str(native_status),
        )
        arguments = ["bash", str(self.script), str(self.swift)]
        if prefix:
            arguments.append("prefix")
        result = subprocess.run(arguments, cwd=self.root, env=environment,
                                capture_output=True, text=True)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        return result, calls

    def test_dispatches_serialized_suites_and_preserves_spaces(self):
        result, calls = self.run_command()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [
            ["swift", "test", "--no-parallel", "--skip", "^SeatSessionTests[./]"],
            ["swift", "build", "--show-bin-path"],
            ["native", str(self.bin_dir / "SeatSessionTests.xctest/Contents/MacOS/SeatSessionTests"),
             "--no-parallel"],
        ])

    def test_swift_failure_stops_before_the_native_run(self):
        result, calls = self.run_command(swift_status=7)
        self.assertEqual(result.returncode, 7)
        self.assertEqual(len(calls), 1)

    def test_native_failure_is_not_masked(self):
        result, calls = self.run_command(native_status=23)
        self.assertEqual(result.returncode, 23)
        self.assertEqual(calls[-1][0], "native")

    def test_forwards_a_compound_swift_command_to_both_calls(self):
        result, calls = self.run_command(prefix=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[0][1:3], ["prefix", "test"])
        self.assertEqual(calls[1][1:], ["prefix", "build", "--show-bin-path"])


if __name__ == "__main__":
    unittest.main()
