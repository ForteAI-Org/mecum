#!/bin/bash
# The whole Mecum vs Cua Driver benchmark in one command; the logic is in bench.py.
exec python3 "$(dirname "$0")/bench.py" "$@"
