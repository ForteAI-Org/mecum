#
#  Makefile
#  Mecum, Driver layer
#
#  Created by Eliomar Alejandro Rodriguez Ferrer on 09/09/2026.
#
# The three test tiers, the benchmarks, the compatibility report and the one
# thing that writes the ledger. Nothing here is clever: what it encodes is the
# two facts about this package that a plain `swift test` gets wrong.
#
# 1. The Host tier runs as **two commands**, the seat cycle apart from
#    everything else. A live HID fence held across repeated virtual display
#    creation ends the process, and in one command the run stops partway with a
#    green exit status and no summary at all (Documentation/Driver/SpiLedger.md).
# 2. Every tier **asserts how many tests it reported**, because of the same
#    defect: exit status 0 is not evidence that a run finished.
# 3. The unit tier runs **serialized**. Every suite in it is `@MainActor`, and a
#    wait inside an adoption turns the event loop synchronously (ADR 0008),
#    which holds the main queue for its whole slice and not just the main actor.
#    Run in parallel, the seat's own recovery loop gets one 250 ms lap in sixty
#    seconds and its rows fail on a starved actor instead of on a budget.
#    Parallelism buys nothing here to pay for that: the main actor is the whole
#    bottleneck, so the tier measures 107 s serialized against 108 s parallel,
#    and the ten bundles other than SeatSession are 1.5 s of it together.
#
# Counts change when tests are added, on purpose: a number here that nobody
# updates is a number that stopped meaning anything.

SWIFT  := xcrun swift
PYTHON := python3
TIER   := bash Tools/Driver/Scripts/run-tier.sh

BASELINES := Tests/Driver/Benchmarks/Baselines
BENCH_OUT := .build/bench
REPORTS   := Documentation/Driver/compatibility

# The unit tier runs unfiltered, so every test target in Package.swift reports
# one summary line, the Driver's, the Engine's and the app libraries' alike: 32
# on 2026-09-23 (`swift package describe --type json`, type "test"), the last
# being TranscriptBenchmarks, whose rows skip unless MECUM_BENCH=1.
# This is the bundle count, not a test count, because test counts move with every
# ticket (987 to 1018 in one day) and a number nobody updates stops meaning
# anything, while a new test target is rare and worth failing over.
UNIT_BUNDLES := 32

# The seat cycle, alone in its own process.
HOST_CYCLE_TESTS := 1

# Everything else in the Host tier: the display suites, capture, the fence, the
# permissions preflight and the version gate.
HOST_REST_TESTS := 29

# The Live tier: the probe page title contract, the input matrix with its six Commands on both families, the
# target's layout, the two probe rows, the contextual menu on both families,
# the multi window row with its two controlled windows, the two window watch
# rows, the two fullscreen transfer rows, the typing cost sweep and the two text
# delivery measurements. The last three are reported and skipped unless
# AGENTSEAT_TYPING_SWEEP=1 or AGENTSEAT_TEXT_DELIVERY=1 asks for them, the
# third-party window watch row unless AGENTSEAT_FOLLOW_APP names a running
# application, and the fullscreen rows unless AGENTSEAT_FULLSCREEN_PROBE=1 does:
# they take a window in and out of fullscreen, which is the person's screen.
# Verified by `xcrun swift test list | rg LiveTests` on 2026-09-21. This is an
# assertion over the reported Live bundle, including intentionally skipped rows.
LIVE_TESTS := 82

# The measurements `make bench` gates on. Narrow it for a quick pass, for
# example `make bench BENCH="fence-callback send-click"`; `seat-idle` alone
# takes five minutes, which is the window its median and p95 are written over.
# `focus-refresh` reports and gates nothing yet, and it needs an ordinary
# application frontmost with a window on a physical display to be its
# destination: without one the refresh it measures returns at its first guard,
# so the row fails rather than report a zero.
BENCH ?= fence-callback fence-clamp input-trace-overhead send-click display-lifecycle \
         monitor-60 monitor-120 stage seat-idle window-watch focus-refresh recovery

.PHONY: all test host-tests live-tests bench compat-report promote-build clean help

all: test

help:
	@echo 'make test           unit tier: pure, serialized, no permission needed'
	@echo 'make host-tests     host tier: TCC and a real display, two commands, counts asserted'
	@echo 'make live-tests     live tier: real windows and a real browser'
	@echo 'make bench          the measurements of spec section 8, each one a gate'
	@echo 'make compat-report  runs the tiers and writes Documentation/Driver/compatibility/Build<build>.{md,json}'
	@echo 'make promote-build BUILD=26A5425a   copies that draft into the ledger'
	@echo
	@echo 'AGENTSEAT_FIXTURE_APP must point at the consumer'"'"'s instrumented binary for'
	@echo 'live-tests, for `bench stage` and for compat-report. The kit ships no application.'
	@echo
	@echo 'host-tests, live-tests and bench need a display that is AWAKE: the active'
	@echo 'display list is empty on a sleeping Mac, so a virtual display has no physical'
	@echo 'topology to attach to and the seat cycle fails with .noPhysicalDisplays.'
	@echo 'live-tests also needs the person not to be driving the machine: their own'
	@echo 'app switches are indistinguishable from an anomaly and the row reads INCO.'

# MARK: The tiers

# `--no-parallel` is load bearing, and it is fact 3 of the header: a pumping
# wait holds the main queue, so concurrent suites starve the recovery loops.
test:
	@$(PYTHON) Tools/Driver/Scripts/test-run-tier.py
	@$(PYTHON) Tools/Driver/Scripts/test-focus-latency.py
	@$(PYTHON) Tools/Driver/Scripts/test-compat-report.py
	@bash Tools/Driver/Scripts/test-seatbench-contract.sh
	@TIER_BUNDLES=$(UNIT_BUNDLES) $(TIER) unit - $(SWIFT) test --no-parallel

# Two commands, and the split is not a style choice: see the header.
host-tests:
	@AGENTSEAT_HOST_TESTS=1 $(TIER) host-seat-cycle $(HOST_CYCLE_TESTS) \
	    $(SWIFT) test --filter theSeatCycle
	@AGENTSEAT_HOST_TESTS=1 $(TIER) host-display-suites $(HOST_REST_TESTS) \
	    $(SWIFT) test --filter HostTests --skip theSeatCycle

# `--no-parallel` is load bearing: both Live suites drive the same browser and
# the process admits one virtual display at a time, so run in parallel one suite
# quits the window the other adopted. Measured: `.processUnavailable` on the
# browser's pid, and the reader's own row disturbed by the matrix's target
# coming up. Serialized, the matrix passes eight rows out of eight.
live-tests: require-fixture
	@AGENTSEAT_LIVE_TESTS=1 AGENTSEAT_FIXTURE_APP="$(AGENTSEAT_FIXTURE_APP)" \
	    $(TIER) live $(LIVE_TESTS) $(SWIFT) test --filter LiveTests --no-parallel

# MARK: The measurements

bench:
	@mkdir -p $(BENCH_OUT)
	@$(SWIFT) build -c release --product SeatBench
	@failed=""; \
	for name in $(BENCH); do \
	    printf '\n== bench %s\n' "$$name"; \
	    if [ "$$name" = "stage" ] && [ -z "$(AGENTSEAT_FIXTURE_APP)" ]; then \
	        echo "SKIP stage: AGENTSEAT_FIXTURE_APP is not set, and the stash needs a second process"; \
	        continue; \
	    fi; \
	    AGENTSEAT_BENCH_TESTS=1 AGENTSEAT_FIXTURE_APP="$(AGENTSEAT_FIXTURE_APP)" \
	        $(SWIFT) run -c release SeatBench "$$name" "" \
	        $(BENCH_OUT)/$$name.json $(BASELINES) || failed="$$failed $$name"; \
	done; \
	if [ -n "$$failed" ]; then echo "FAIL bench:$$failed"; exit 1; fi; \
	echo "OK   bench: $(BENCH)"

# Focus is measured independently from WindowServer; physical input invalidates
# the run. A successful functional test does not imply the 8 ms budget passed.
.PHONY: focus-latency
FOCUS_RUNS ?= 5
FOCUS_OUTPUT ?= /tmp/agentseat-focus-latency.json
focus-latency:
	@$(PYTHON) Tools/Driver/Scripts/measure-focus-latency.py --runs $(FOCUS_RUNS) --budget-ms 8 --output $(FOCUS_OUTPUT)

# MARK: The build gate

# The report is assembled from the tiers this target has just run, so the order
# is the dependency order and this is deliberately not parallel safe.
compat-report: require-fixture test host-tests live-tests bench
	@$(PYTHON) Tools/Driver/Scripts/compat-report.py --bench $(BENCH_OUT) --out $(REPORTS)

# The only thing in this repository that writes the ledger, and it takes a
# build on the command line because it is a decision and not a step.
promote-build:
	@test -n "$(BUILD)" || { echo 'usage: make promote-build BUILD=26A5425a'; exit 2; }
	@$(PYTHON) Tools/Driver/Scripts/promote-build.py $(BUILD)

# MARK: Helpers

require-fixture:
	@test -n "$(AGENTSEAT_FIXTURE_APP)" || { \
	    echo 'AGENTSEAT_FIXTURE_APP is not set. The kit ships no application: point it at'; \
	    echo 'the consumer'"'"'s instrumented binary, which must come up as the cooperative'; \
	    echo 'target when launched with `--session <token>` and publish its report at'; \
	    echo '/tmp/agentseat-fixture-$(shell id -u)-<token>.json.'; \
	    exit 2; }

clean:
	@rm -rf .build/bench
	@$(SWIFT) package clean
