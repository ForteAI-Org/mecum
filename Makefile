#
#  Makefile
#  Mecum, Driver layer
#
#  Created by Eliomar Alejandro Rodriguez Ferrer on 09/09/2026.
#
# The three test tiers, the benchmarks, the compatibility report and the one
# thing that writes the ledger. Nothing here is clever: what it encodes is the
# three facts about this package that a plain `swift test` gets wrong.
#
# 1. Both Host processes use a synchronous native entry point. Swift async main
#    could exit during native capture before either process reported completion.
#    Adobe UXP rows use the same runner, each in its own process.
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

# SwiftPM filters out SeatSession and reports 25 Swift Testing summaries.
# Filtering also omits the empty Swift Testing companions of the two XCTest-only
# targets; their XCTest tests still run. SeatSession's 674 tests run separately
# through the synchronous native entry point, for 26 required summaries:
# AppKit RunLoop pumping can also end this otherwise pure bundle before its
# async main reports completion.
# The app's own tests remain in MecumTests. This is a run count, not a test count.
UNIT_BUNDLES := 26

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
# Includes the eight opt-in Adobe UXP rows. This assertion counts the reported
# Live bundle, including intentionally skipped rows.
LIVE_TESTS := 124
UXP_LIVE_ROWS := dialogsInBackground documentsInBackground selectionInBackground pixelEditingInBackground layerEditingInBackground newLayerDialogInBackground newLayerTypedTextInBackground documentDragInBackground
QT_LIVE_ROWS := discoverDaVinci adoptAndReturnDaVinci observeDaVinci \
                clickDaVinciSearch openAndCancelDaVinciProjectDialog insertTextIntoDaVinciSearch \
                openDaVinciSearchContextMenu
QT_EDITOR_ROWS := switchEditorPages cancelImportMedia
QT_FIXTURE_ROWS := widgetCommands contextMenu dropdownMenu nativePopupMenu modalChild switchTargets widgetFileDialog nativeFileDialog quickCommands nativeDrag
QT_PYTHON ?= $(shell command -v python3)

# The measurements `make bench` gates on. Narrow it for a quick pass, for
# example `make bench BENCH="fence-callback send-click"`; `seat-idle` alone
# takes five minutes, which is the window its median and p95 are written over.
# `focus-refresh` reports and gates nothing yet, and it needs an ordinary
# application frontmost with a window on a physical display to be its
# destination: without one the refresh it measures returns at its first guard,
# so the row fails rather than report a zero.
BENCH ?= fence-callback fence-clamp input-trace-overhead send-click display-lifecycle \
         monitor-60 monitor-120 stage seat-idle window-watch focus-refresh recovery

.PHONY: all test native-test-runner host-tests live-tests uxp-live-tests qt-live-tests qt-editor-live-tests qt-fixture-live-tests qt-ime-live-tests qt-panel-birth-live-tests qt-geometry-live-tests chromium-live-tests bench compat-report promote-build clean help

all: test

help:
	@echo 'make test           unit tier: pure, serialized, no permission needed'
	@echo 'make host-tests     host tier: TCC and a real display, two commands, counts asserted'
	@echo 'make live-tests     live tier: real windows and a real browser'
	@echo 'make uxp-live-tests UXP tier: Photoshop with only the named disposable PNG'
	@echo 'make qt-live-tests  Qt tier: open DaVinci Project Manager, one process per row'
	@echo 'make qt-editor-live-tests  Qt editor tier: open the disposable New Project 1 project'
	@echo 'make qt-fixture-live-tests QT_PYTHON=<PySide6 Python>  Qt 6 controlled fixture tier'
	@echo 'make qt-ime-live-tests QT_PYTHON=<PySide6 Python>  Qt native composition and cleanup'
	@echo 'make qt-panel-birth-live-tests QT_PYTHON=<PySide6 Python>  Strict native panel visibility'
	@echo 'make qt-geometry-live-tests QT_PYTHON=<PySide6 Python>  Qt settled return geometry with Stage Manager'
	@echo 'make chromium-live-tests  Owned Chrome matrix, two windows, native picker, composition and Print'
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
test: native-test-runner
	@$(PYTHON) Tools/Driver/Scripts/test-run-tier.py
	@$(PYTHON) Tools/Driver/Scripts/test-unit-command.py
	@$(PYTHON) Tools/Driver/Scripts/test-focus-latency.py
	@$(PYTHON) Tools/Driver/Scripts/test-compat-report.py
	@bash Tools/Driver/Scripts/test-seatbench-contract.sh
	@TIER_BUNDLES=$(UNIT_BUNDLES) $(TIER) unit - bash Tools/Driver/Scripts/unit-test-command.sh $(SWIFT)

# The synchronous entry point survives native RunLoop returns during capture.
# It loads the same built Swift Testing bundle; each tier still checks its count.
native-test-runner:
	@$(SWIFT) build --build-tests
	@$(SWIFT)c -parse-as-library \
	    -F "$$(xcrun --sdk macosx --show-sdk-platform-path)/Developer/Library/Frameworks" \
	    -Xlinker -rpath \
	    -Xlinker "$$(xcrun --sdk macosx --show-sdk-platform-path)/Developer/Library/Frameworks" \
	    -Xlinker -rpath \
	    -Xlinker "$$(xcrun --sdk macosx --show-sdk-platform-path)/Developer/usr/lib" \
	    Tools/Driver/Scripts/NativeTestMain.swift -o .build/native-driver-test-main

host-tests: native-test-runner
	@AGENTSEAT_HOST_TESTS=1 $(TIER) host-seat-cycle $(HOST_CYCLE_TESTS) \
	    .build/native-driver-test-main \
	    "$$($(SWIFT) build --show-bin-path)/HostTests.xctest/Contents/MacOS/HostTests" \
	    --filter theSeatCycle --no-parallel
	@AGENTSEAT_HOST_TESTS=1 $(TIER) host-display-suites $(HOST_REST_TESTS) \
	    .build/native-driver-test-main \
	    "$$($(SWIFT) build --show-bin-path)/HostTests.xctest/Contents/MacOS/HostTests" \
	    --skip theSeatCycle --no-parallel

# `--no-parallel` is load bearing: both Live suites drive the same browser and
# the process admits one virtual display at a time, so run in parallel one suite
# quits the window the other adopted. Measured: `.processUnavailable` on the
# browser's pid, and the reader's own row disturbed by the matrix's target
# coming up. Serialized, the matrix passes eight rows out of eight.
live-tests: require-fixture
	@AGENTSEAT_LIVE_TESTS=1 AGENTSEAT_QT_TESTS=0 AGENTSEAT_QT_PYTHON= \
	    AGENTSEAT_QT_FIXTURE_PID= AGENTSEAT_QT_FIXTURE_STATE= \
	    AGENTSEAT_FIXTURE_APP="$(AGENTSEAT_FIXTURE_APP)" \
	    $(TIER) live $(LIVE_TESTS) $(SWIFT) test --filter LiveTests --no-parallel

# Photoshop must be open with only the disposable document named by the caller.
# Each row owns its repeated cycles in one Host lifecycle. The native entry
# point and count gate refuse a run without a completion summary.
uxp-live-tests: native-test-runner
	@status=0; for row in $(UXP_LIVE_ROWS); do \
	    AGENTSEAT_LIVE_TESTS=1 AGENTSEAT_UXP_TESTS=1 \
	        $(TIER) "adobe-uxp-$$row" 1 .build/native-driver-test-main \
	        "$$($(SWIFT) build --show-bin-path)/LiveTests.xctest/Contents/MacOS/LiveTests" \
	        --filter "UXPDriverLiveTests.$$row" --no-parallel \
	        || status=1; \
	done; exit $$status

# Repeated virtual display creation can terminate one test process with a
# successful exit status but no summary. Each Qt row therefore gets its own
# process and the same count check as the other tiers. This target does not
# need the consumer fixture or a browser; DaVinci must already be open.
qt-live-tests:
	@for row in $(QT_LIVE_ROWS); do \
	    AGENTSEAT_LIVE_TESTS=1 AGENTSEAT_QT_TESTS=1 \
	        $(TIER) "qt-$$row" 1 $(SWIFT) test --filter "QtDriverLiveTests.$$row" --no-parallel \
	        || exit $$?; \
	done

# The user's disposable recent project is already open. The rows return to Cut
# and cancel Import Media, without changing clips or saving the project.
qt-editor-live-tests:
	@for row in $(QT_EDITOR_ROWS); do \
	    AGENTSEAT_LIVE_TESTS=1 AGENTSEAT_QT_EDITOR_TESTS=1 \
	        $(TIER) "qt-editor-$$row" 1 $(SWIFT) test --filter "QtEditorLiveTests.$$row" --no-parallel \
	        || exit $$?; \
	done

# The stricter initial-visibility check remains red on the measured host.
qt-panel-birth-live-tests:
	@AGENTSEAT_LIVE_TESTS=1 AGENTSEAT_QT_PANEL_BIRTH_TESTS=1 AGENTSEAT_QT_PYTHON="$(QT_PYTHON)" \
	    $(TIER) qt-panel-birth 1 $(SWIFT) test --filter QtFixtureLiveTests.nativeFileDialog --no-parallel

# Native preedit/commit, deadline and cancellation have independent oracles.
qt-ime-live-tests:
	@AGENTSEAT_LIVE_TESTS=1 AGENTSEAT_QT_IME_TESTS=1 AGENTSEAT_QT_PYTHON="$(QT_PYTHON)" \
	    $(TIER) qt-ime 3 $(SWIFT) test --filter QtFixtureLiveTests.inputMethod --no-parallel

# Discovery deliberately precedes display creation. The owned window starts
# partly outside the physical display and may settle before adoption.
QT_INITIAL_POSITION ?= 1082,776
qt-geometry-live-tests:
	@AGENTSEAT_LIVE_TESTS=1 AGENTSEAT_QT_INITIAL_POSITION="$(QT_INITIAL_POSITION)" AGENTSEAT_QT_PYTHON="$(QT_PYTHON)" \
	    $(TIER) qt-geometry 1 $(SWIFT) test --filter QtFixtureLiveTests.widgetCommands --no-parallel

# An owned Qt 6 widget target is launched and stopped inside each row. Its
# Python interpreter must contain PySide6-Essentials; no fixture remains after
# the tier, and DaVinci is not touched.
qt-fixture-live-tests:
	@$(QT_PYTHON) -c 'import PySide6.QtWidgets' || { \
	    echo 'QT_PYTHON must point to a Python with PySide6-Essentials installed'; exit 1; \
	}
	@for row in $(QT_FIXTURE_ROWS); do \
	    AGENTSEAT_LIVE_TESTS=1 AGENTSEAT_QT_PYTHON="$(QT_PYTHON)" \
	        $(TIER) "qt6-$$row" 1 $(SWIFT) test --filter "QtFixtureLiveTests.$$row" --no-parallel \
	        || exit $$?; \
	done

# Every row owns a disposable browser profile and closes it before the next row.
chromium-live-tests:
	@for row in InputMatrixLiveTests.chromiumInputMatrix KeyIsolationLiveTests.heldModifiersDoNotCrossTargetChanges ChromiumFixtureLiveTests.nativeFileDialog ChromiumNativeTextInputLiveTests.nativeComposition ChromiumNativeTextInputLiveTests.nativeDeadline ChromiumNativeTextInputLiveTests.nativeCancellation ContextMenuLiveTests.chromiumContextMenus UserFocusRecoveryLiveTests.printRestoresUserFocus; do \
	    AGENTSEAT_LIVE_TESTS=1 AGENTSEAT_CHROMIUM_TESTS=1 $(TIER) "chromium-$$row" 1 $(SWIFT) test --filter "$$row" --no-parallel \
	        || exit $$?; \
	done

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
