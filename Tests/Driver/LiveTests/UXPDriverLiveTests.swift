//
//  UXPDriverLiveTests.swift
//  AgentSeatKit
//

import AppKit
import CursorGuard
import Foundation
import PrivateSymbols
import SeatCapture
import SeatCore
import SeatInput
@testable import SeatSession
import Testing
import WindowPlacement

/// Runs Photoshop document, modal and editing flows through fresh capture,
/// directed input and exact native-model checks. It never accepts a delivery receipt as effect.
@Suite("Adobe UXP qualification", .serialized)
@MainActor
struct UXPDriverLiveTests {

    @Test(
        "Photoshop dialogs remain usable across repeated background cycles",
        .enabled(
            if: liveSkipReason(optIn: "AGENTSEAT_UXP_TESTS") == nil,
            Comment(rawValue: liveSkipReason(optIn: "AGENTSEAT_UXP_TESTS") ?? "")
        )
    )
    func dialogsInBackground() async throws {
        LivePump.prepare()
        try #require(Permissions.preflight(.accessibility), "The live runner lacks Accessibility permission")
        try requireIdlePhysicalInput()
        let probe = try PhotoshopProbe()
        let document = try await probe.preparedDocument()
        try #require(!probe.application.isActive, "Leave Photoshop in the background before the scoped run")
        let server = try #require(WindowServerProbe.geometry(of: document.number))
        let body = try #require(try WindowRelocator.frame(of: server))
        let reference = server.replacingFrame(body)
        let settle = ProcessInfo.processInfo.environment["AGENTSEAT_UXP_SETTLE_MS"].flatMap(Int.init) ?? 300
        let cycles = ProcessInfo.processInfo.environment["AGENTSEAT_UXP_CYCLES"].flatMap(Int.init) ?? 3
        try #require((0...1000).contains(settle) && (1...20).contains(cycles))
        let platform = UXPPlatform(keyPreparationSettle: .milliseconds(settle)).preparingLeftClicks.preparingDocumentShortcuts
        let defaultGate = FacilityGate.current(facility: .windowIdentity)
        try #require(defaultGate.mayAct, "Default WindowServer gate refused: \(defaultGate.readiness)")
        print("UXP_ENV build=\(BuildIdentity.current.osVersion) hardware=\(BuildIdentity.current.hardwareModel)"
            + " photoshop=\(Bundle(url: probe.application.bundleURL ?? URL(fileURLWithPath: "/"))?.infoDictionary?["CFBundleShortVersionString"] ?? "unknown")"
            + " unvalidated=\(defaultGate.unvalidatedBuild) settle-ms=\(settle) cycles=\(cycles)")

        var failure: (any Error)?
        try await LiveStage.run(
            needsFixture : false,
            needsChrome  : false,
            configuration: SeatHostConfiguration(followsNewWindows: true, restoresUserFocus: true)
        ) { stage in
            let person = UserSeatState.capture()
            let physicalBefore = stage.fence.snapshot().observedEventCount
            var adopted: AdoptedWindow?
            var openedDialogs = Set<Int>()
            do {
                adopted = try await stage.seat.adopt(reference, platform: platform, title: document.title)
                if let window = adopted, !stage.seat.isStaged(window) {
                    adopted = try await stage.seat.stage(window)
                }
                let seed = try #require(probe.documentName(document))
                let baseline = try await verifyDocumentCatalog([seed], active: seed, probe: probe, in: stage)
                let refreshProbe = ProcessInfo.processInfo.environment["AGENTSEAT_UXP_FOCUS_REFRESH_PROBE"] == "1"
                let forceRefresh = ProcessInfo.processInfo.environment["AGENTSEAT_UXP_FORCE_REFRESH"] == "1"
                let allKinds = ["displace", "map", "duplicate", "new-document"]
                let selected = ProcessInfo.processInfo.environment["AGENTSEAT_UXP_FLOWS"]?
                    .split(separator: ",").map(String.init)
                let kinds = selected ?? (refreshProbe ? ["new-document", "displace"] : allKinds)
                try #require(!kinds.isEmpty && kinds.allSatisfy(allKinds.contains))
                for cycle in 0..<cycles {
                    for kind in kinds {
                        let before = Set(try probe.windows().map(\.number))
                        let started = DispatchTime.now().uptimeNanoseconds
                        let menu = kind == "duplicate" ? ["Layer", "Duplicate Layer…"]
                            : kind == "new-document" ? ["File", "New…"] : ["Filter", "Distort", "Displace…"]
                        if forceRefresh || refreshProbe && kind == "displace" || probe.menuEnabledReading(menu) == false {
                            let refreshStarted = DispatchTime.now().uptimeNanoseconds
                            let refresh = await stage.seat.bringTargetBrieflyInFront(
                                until: { probe.menuIsEnabled(menu) }
                            )
                            print("UXP_MENU_REFRESH path=\(menu) outcome=\(refresh)"
                                + " elapsed-ms=\(Double(DispatchTime.now().uptimeNanoseconds - refreshStarted) / 1e6)")
                            guard case .ready = refresh else {
                                throw LiveFailure.unsupported("Photoshop menu refresh refused: \(refresh)")
                            }
                            try #require(!probe.application.isActive, "Menu refresh did not hand the foreground back")
                        }
                        try probe.pressMenu(menu)
                        let opened = LivePump.run(until: { probe.dialog(excluding: before) != nil }, timeout: 5)
                        try #require(opened, "The Photoshop \(kind) dialog never appeared")
                        var dialog = try #require(probe.dialog(excluding: before))
                        openedDialogs.insert(dialog.number)
                        try await qualify(dialog, in: stage, started: started, label: "\(kind)-\(cycle)")

                        if kind == "displace" {
                            try await editFilterControls(dialog, in: stage, probe: probe)
                        }

                        if kind == "map" {
                            try await send(.key(virtualKey: 36, text: "\r"), to: dialog, in: stage,
                                           effect: {
                                probe.dialog(excluding: before).map {
                                    $0.number != dialog.number && $0.title == "Choose a displacement map"
                                } == true
                            })
                            dialog = try #require(probe.dialog(excluding: before))
                            openedDialogs.insert(dialog.number)
                            try #require(dialog.title == "Choose a displacement map")
                            try await qualify(dialog, in: stage, started: started, label: "map-chooser-\(cycle)")
                        }

                        if cycle.isMultiple(of: 2) || kind == "new-document" {
                            try await send(.key(virtualKey: 53, text: ""), to: dialog, in: stage,
                                           effect: { !probe.contains(dialog.number) })
                        } else {
                            let current = try #require(try probe.windows().first { $0.number == dialog.number })
                            let button = try #require(probe.buttonFrame(in: current, named: "Cancel"))
                            let server = try #require(WindowServerProbe.geometry(of: dialog.number))
                            let geometry = try #require(WindowGeometryProbe.observation(of: server))
                            let location = try #require(InputLocation(
                                screenPoint: CGPoint(x: button.midX, y: button.midY), observedIn: geometry
                            ))
                            try await send(.click(location), to: dialog, in: stage,
                                           effect: { !probe.contains(dialog.number) })
                        }
                        _ = await stage.seat.concludeObservation()
                        let returnedAt = DispatchTime.now().uptimeNanoseconds
                        let next = try await observe(document.number, in: stage)
                        let returned = next.surface.windowNumber == document.number
                        #expect(next.surface.windowNumber == document.number)
                        #expect(!probe.application.isActive, "Photoshop remained foreground after directed input")
                        print("UXP_CYCLE kind=\(kind) cycle=\(cycle) returned=\(returned)"
                            + " handback-ms=\(Double(DispatchTime.now().uptimeNanoseconds - returnedAt) / 1e6)")
                    }
                }
                let seedAfter = try #require(probe.documentName(document))
                let restored = try await verifyDocumentCatalog([seedAfter], active: seedAfter, probe: probe, in: stage)
                try #require(restored.documents == baseline.documents && restored.activeID == baseline.activeID)
            } catch {
                failure = error
                let remaining = try? probe.windows()
                #expect(remaining != nil, "Cleanup could not read the Photoshop window inventory")
                for dialog in remaining ?? [] where openedDialogs.contains(dialog.number) {
                    probe.recordFocus(in: dialog)
                    do {
                        try await cancelForCleanup(dialog, in: stage, probe: probe)
                    } catch {
                        print("UXP_CLEANUP window=\(dialog.number) refused=\(error)")
                        #expect(Bool(false), "The test-owned Photoshop dialog could not be cancelled")
                    }
                }
            }
            let physical = stage.fence.snapshot().observedEventCount &- physicalBefore
            let after = UserSeatState.capture()
            #expect(after.frontmostProcessID == person.frontmostProcessID)
            try #require(physical == 0, "Physical input overlapped the run; isolation is inconclusive")
            #expect(after.cursor == person.cursor)
            print("UXP_ISOLATION physical-events=\(physical) foreground-preserved=\(after.frontmostProcessID == person.frontmostProcessID) cursor-preserved=\(after.cursor == person.cursor)")
            _ = await stage.seat.concludeObservation()
            for window in stage.seat.adoptedWindows.reversed() where window.id != document.number {
                _ = await stage.seat.release(window, .returnToUserSeat)
            }
            if let adopted {
                let result = await stage.seat.release(adopted, .returnToUserSeat)
                #expect(result == .returned)
                let home = try? WindowRelocator.frame(of: reference)
                #expect(home.map { rectanglesMatchLoosely($0, adopted.originalFrame) } == true)
            }
        }
        if let failure { throw failure }
    }

    @Test(
        "Return creates a document and document switching stays directed",
        .enabled(if: liveSkipReason(optIn: "AGENTSEAT_UXP_TESTS") == nil,
                 Comment(rawValue: liveSkipReason(optIn: "AGENTSEAT_UXP_TESTS") ?? ""))
    )
    func documentsInBackground() async throws {
        try await qualifyDocuments(drag: false)
    }

    @Test(
        "A document scrollbar drag produces an independently observed effect",
        .enabled(if: liveSkipReason(optIn: "AGENTSEAT_UXP_TESTS") == nil,
                 Comment(rawValue: liveSkipReason(optIn: "AGENTSEAT_UXP_TESTS") ?? ""))
    )
    func documentDragInBackground() async throws {
        try await qualifyDocuments(drag: true)
    }

    private enum EditingFlow: Equatable {
        case selection
        case pixels
        case layers
        case layerDialog
        case typedLayerDialog
    }

    @Test(
        "Owned Photoshop selection changes through directed shortcuts",
        .enabled(if: liveSkipReason(optIn: "AGENTSEAT_UXP_TESTS") == nil,
                 Comment(rawValue: liveSkipReason(optIn: "AGENTSEAT_UXP_TESTS") ?? ""))
    )
    func selectionInBackground() async throws {
        try await qualifyDocuments(drag: false, editing: .selection)
    }

    @Test(
        "Owned Photoshop pixels change and undo through directed shortcuts",
        .enabled(if: liveSkipReason(optIn: "AGENTSEAT_UXP_TESTS") == nil,
                 Comment(rawValue: liveSkipReason(optIn: "AGENTSEAT_UXP_TESTS") ?? ""))
    )
    func pixelEditingInBackground() async throws {
        try await qualifyDocuments(drag: false, editing: .pixels)
    }

    @Test(
        "Owned Photoshop layers support Unicode names, undo and redo",
        .enabled(if: liveSkipReason(optIn: "AGENTSEAT_UXP_TESTS") == nil,
                 Comment(rawValue: liveSkipReason(optIn: "AGENTSEAT_UXP_TESTS") ?? ""))
    )
    func layerEditingInBackground() async throws {
        try await qualifyDocuments(drag: false, editing: .layers)
    }

    @Test(
        "Owned New Layer dialog accepts a Unicode name and Return, then closes without saving",
        .enabled(if: liveSkipReason(optIn: "AGENTSEAT_UXP_TESTS") == nil,
                 Comment(rawValue: liveSkipReason(optIn: "AGENTSEAT_UXP_TESTS") ?? ""))
    )
    func newLayerDialogInBackground() async throws {
        try await qualifyDocuments(drag: false, editing: .layerDialog)
    }

    @Test(
        "Owned New Layer dialog accepts typed Unicode graphemes and Return",
        .enabled(if: liveSkipReason(optIn: "AGENTSEAT_UXP_TESTS") == nil,
                 Comment(rawValue: liveSkipReason(optIn: "AGENTSEAT_UXP_TESTS") ?? ""))
    )
    func newLayerTypedTextInBackground() async throws {
        try await qualifyDocuments(drag: false, editing: .typedLayerDialog)
    }

    /// A held physical modifier can contaminate input without any new HID event.
    /// Refuse it before adoption; the fixture never releases user-held keys.
    private func requireIdlePhysicalInput() throws {
        let relevant: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
        let hid = CGEventSource.flagsState(.hidSystemState).intersection(relevant)
        let session = CGEventSource.flagsState(.combinedSessionState).intersection(relevant)
        let buttonHeld = (0..<5).contains {
            CGEventSource.buttonState(.hidSystemState, button: CGMouseButton(rawValue: UInt32($0))!)
        }
        try #require(hid.isEmpty && session.isEmpty && !buttonHeld,
                     "A physical modifier or mouse button was already held; input isolation is inconclusive")
        print("UXP_PHYSICAL_PREFLIGHT modifiers-clear=true buttons-clear=true")
    }

    private func qualifyDocuments(drag: Bool, editing: EditingFlow? = nil) async throws {
        LivePump.prepare()
        try requireIdlePhysicalInput()
        let probe = try PhotoshopProbe()
        let document = try await probe.preparedDocument()
        try #require(!probe.application.isActive)
        let server = try #require(WindowServerProbe.geometry(of: document.number))
        let body = try #require(try WindowRelocator.frame(of: server))
        var failure: (any Error)?
        try await LiveStage.run(needsFixture: false, needsChrome: false,
            configuration: SeatHostConfiguration(followsNewWindows: true, restoresUserFocus: true)) { stage in
            let person = UserSeatState.capture()
            let physicalBefore = stage.fence.snapshot().observedEventCount
            var created: PhotoshopProbe.Window?
            var createdModel: PhotoshopDocumentCatalog.Document?
            var seedModel: PhotoshopDocumentCatalog.Document?
            var ownedModal: PhotoshopProbe.Window?
            do {
                var adopted = try await stage.seat.adopt(server.replacingFrame(body), platform: UXPPlatform().preparingLeftClicks.preparingDocumentShortcuts, title: document.title)
                if !stage.seat.isStaged(adopted) { adopted = try await stage.seat.stage(adopted) }
                let seed = try #require(probe.documentName(document))
                let baseline = try await probe.documentCatalog(in: stage.seat)
                let originalModel = try #require(baseline.documents.first)
                let seedPath = try #require(ProcessInfo.processInfo.environment["AGENTSEAT_UXP_DOCUMENT"])
                try #require(baseline.documents.count == 1 && baseline.activeID == originalModel.id
                             && originalModel.url == URL(fileURLWithPath: seedPath).standardizedFileURL)
                seedModel = originalModel
                let cycles = ProcessInfo.processInfo.environment["AGENTSEAT_UXP_CYCLES"].flatMap(Int.init) ?? 3
                try #require((1...20).contains(cycles))
                for cycle in 0..<cycles {
                    let menu = ["File", "New…"]
                    if probe.menuEnabledReading(menu) == false {
                        let refresh = await stage.seat.bringTargetBrieflyInFront(until: { probe.menuIsEnabled(menu) })
                        guard case .ready = refresh else { throw LiveFailure.unsupported("New Document menu refresh: \(refresh)") }
                    }
                    let before = Set(try probe.windows().map(\.number))
                    try probe.pressMenu(menu)
                    try #require(LivePump.run(until: { probe.dialog(excluding: before) != nil }, timeout: 5))
                    let modal = try #require(probe.dialog(excluding: before))
                    ownedModal = modal
                    let started = DispatchTime.now().uptimeNanoseconds
                    try await qualify(modal, in: stage, started: started, label: "new-document-return-\(cycle)")
                    try await send(.key(virtualKey: 36, text: "\r"), to: modal, in: stage, effect: {
                        !probe.contains(modal.number) && (try? probe.windows().contains {
                            $0.role == kAXWindowRole && $0.title.hasPrefix("Untitled-")
                        }) == true
                    })
                    ownedModal = nil
                    if let retired = stage.seat.adoptedWindows.first(where: { $0.id == modal.number }) {
                        _ = await stage.seat.release(retired, .leaveOnVirtualDisplay)
                    }
                    _ = try await observe(document.number, in: stage)
                    let newDocument = try #require(try probe.windows().first {
                        $0.role == kAXWindowRole && $0.title.hasPrefix("Untitled-")
                    })
                    created = newDocument
                    let catalog = try await probe.documentCatalog(in: stage.seat)
                    let model = try #require(catalog.createdDocument(since: baseline),
                                             "Return did not create exactly one active unsaved document")
                    createdModel = model
                    let name = model.name
                    try #require(probe.documentName(newDocument) == name && name != seed)
                    try #require(newDocument.number == document.number
                                 && (try probe.windowsExcludingInertProxies(for: newDocument)).count == 1,
                                 "This row qualifies two documents as tabs in one window")
                    try await qualify(newDocument, in: stage, started: started, label: "created-document-\(cycle)")
                    try await send(.key(virtualKey: 48, text: "\t", modifiers: .control), to: newDocument, in: stage, effect: {
                        probe.selectedDocument(named: seed, number: document.number) != nil
                    })
                    try await verifyDocumentCatalog([seed, name], active: seed, probe: probe, in: stage)
                    print("UXP_DOCUMENT_SWITCH direction=original effect=true")
                    try await waitForDocumentKeyboard(document.number, in: stage)
                    let original = try #require(probe.selectedDocument(named: seed, number: document.number))
                    try await send(.key(virtualKey: 48, text: "\t", modifiers: .control), to: original, in: stage, effect: {
                        probe.selectedDocument(named: name, number: document.number) != nil
                    })
                    try await verifyDocumentCatalog([seed, name], active: name, probe: probe, in: stage)
                    print("UXP_DOCUMENT_SWITCH direction=created effect=true")
                    try await waitForDocumentKeyboard(document.number, in: stage)
                    try await editAndMoveDocument(newDocument, in: stage, probe: probe, drag: drag, scroll: editing == nil)
                    try await qualify(newDocument, in: stage, started: started, label: "document-controls-\(cycle)")
                    if let editing {
                        try await editOwnedDocument(
                            newDocument,
                            model     : model,
                            preserving: originalModel,
                            in        : stage,
                            probe     : probe,
                            cycle     : cycle,
                            flow      : editing
                        )
                    }
                    try await closeCreatedDocument(newDocument, model: model, in: stage, probe: probe)
                    try await verifyDocumentCatalog([seed], active: seed, probe: probe, in: stage)
                    let restored = try await probe.documentCatalog(in: stage.seat)
                    try #require(restored.documents == baseline.documents && restored.activeID == baseline.activeID)
                    created = nil
                    createdModel = nil
                    try #require(try probe.document().number == document.number)
                }
            } catch {
                failure = error
                if let ownedModal, probe.contains(ownedModal.number) {
                    do { try await cancelForCleanup(ownedModal, in: stage, probe: probe) }
                    catch {
                        print("UXP_DOCUMENT_CLEANUP modal=\(ownedModal.number) refused=\(error)")
                        Issue.record("The test-owned modal could not be cancelled: \(error)")
                    }
                }
                if let createdModel, let seedModel {
                    do {
                        // Native fixture cleanup rechecks ownership independently
                        // from capture. A staging failure must not block it.
                        let catalog = try await probe.documentCatalog(in: stage.seat)
                        if catalog.documents.contains(createdModel), catalog.documents.contains(seedModel), catalog.documents.count == 2 {
                            let restored = try await probe.closeOwnedDocument(createdModel, preserving: seedModel, in: stage.seat)
                            try #require(restored.documents == [seedModel] && restored.activeID == seedModel.id)
                        } else {
                            try #require(catalog.documents == [seedModel] && catalog.activeID == seedModel.id)
                        }
                        print("UXP_DOCUMENT_CLEANUP model-restored=true")
                    } catch {
                        Issue.record("The test-owned document catalog was not restored: \(error)")
                    }
                } else if created != nil {
                    Issue.record("The created window has no complete document-model ownership proof")
                }
            }
            let physical = stage.fence.snapshot().observedEventCount &- physicalBefore
            let after = UserSeatState.capture()
            try #require(physical == 0, "Physical input overlapped the document row")
            #expect(after.frontmostProcessID == person.frontmostProcessID)
            #expect(after.cursor == person.cursor)
            print("UXP_DOCUMENT_ISOLATION physical-events=\(physical) foreground-preserved=\(after.frontmostProcessID == person.frontmostProcessID) cursor-preserved=\(after.cursor == person.cursor)")
            _ = await stage.seat.concludeObservation()
            for adopted in stage.seat.adoptedWindows.reversed() {
                _ = await stage.seat.release(adopted, .returnToUserSeat)
            }
        }
        if let failure { throw failure }
    }

    /// Edits both native filter fields without applying the filter to the PNG.
    private func editFilterControls(
        _ dialog: PhotoshopProbe.Window,
        in stage: LiveStage,
        probe: PhotoshopProbe
    ) async throws {
        let fields = try probe.controls(in: dialog, role: kAXTextFieldRole)
        try #require(fields.count == 2, "Displace must expose its two numeric scale fields")
        for (index, field) in fields.enumerated() {
            let frame = try #require(probe.frame(of: field))
            let point = try location(CGPoint(x: frame.midX, y: frame.midY), in: dialog)
            try await send(.click(point, count: 2), to: dialog, in: stage, effect: {
                probe.value(field, kAXFocusedAttribute, as: Bool.self) == true
            })
            let expected = index == 0 ? "17" : "23"
            let command: InputCommand = index == 0 ? .text(expected) : .insertText(expected)
            try await send(command, to: dialog, in: stage, effect: {
                probe.value(field, kAXValueAttribute, as: String.self) == expected
            })
            print("UXP_EDIT filter-field=\(index) value=\(expected) effect=true")
        }
    }

    /// Changes only the new blank document's view, using actual AX control
    /// frames and independent value changes for zoom, wheel and scrollbar drag.
    private func editAndMoveDocument(
        _ document: PhotoshopProbe.Window,
        in stage: LiveStage,
        probe: PhotoshopProbe,
        drag: Bool,
        scroll: Bool = true
    ) async throws {
        let name = try #require(probe.documentName(document))
        try #require(name.hasPrefix("Untitled-"))
        let current = try #require(probe.selectedDocument(named: name, number: document.number))
        try #require(probe.value(current.element, kAXDocumentAttribute, as: String.self) == nil)
        let fields = try probe.controls(in: document, role: kAXTextFieldRole)
        let zoom = try #require(fields.first {
            probe.value($0, kAXValueAttribute, as: String.self)?.hasSuffix("%") == true
                && probe.value($0, kAXEnabledAttribute, as: Bool.self) == true
        }, "The document zoom field must expose its percentage")
        let zoomFrame = try #require(probe.frame(of: zoom))
        try await send(.click(try location(CGPoint(x: zoomFrame.midX, y: zoomFrame.midY), in: document), count: 2),
                       to: document, in: stage, effect: {
            probe.value(zoom, kAXFocusedAttribute, as: Bool.self) == true
        })
        try await send(.insertText("100"), to: document, in: stage, effect: {
            probe.value(zoom, kAXValueAttribute, as: String.self)?.hasPrefix("100") == true
        })
        try await send(.key(virtualKey: 36, text: "\r"), to: document, in: stage, effect: {
            (try? probe.windows().contains { $0.number == document.number && $0.title.contains(" @ 100%") }) == true
        })
        print("UXP_EDIT zoom=100 effect=true")
        guard scroll else { return }
        func canvasBar() throws -> AXUIElement {
            let current = try #require(try probe.windows().first { $0.number == document.number })
            let bars = try probe.controls(in: current, role: kAXScrollBarRole)
                .filter { probe.frame(of: $0).map { $0.height > $0.width && $0.height > 100 } == true }
            return try #require(bars.max {
                (probe.frame(of: $0)?.height ?? 0) < (probe.frame(of: $1)?.height ?? 0)
            }, "The canvas must have a measured vertical scrollbar")
        }
        let bar = try canvasBar()
        let before = try #require(probe.value(bar, kAXValueAttribute, as: Double.self))
        let barFrame = try #require(probe.frame(of: bar))
        try await send(.scroll(try location(CGPoint(x: barFrame.midX, y: barFrame.midY), in: document), deltaY: -480),
                       to: document, in: stage, effect: {
            probe.value(bar, kAXValueAttribute, as: Double.self).map { abs($0 - before) > 0.001 } == true
        })
        print("UXP_SCROLL before=\(before) after=\(String(describing: probe.value(bar, kAXValueAttribute, as: Double.self))) effect=true")
        guard drag else { return }
        let freshBar = try canvasBar()
        let track = try #require(probe.frame(of: freshBar))
        let children = try #require(probe.value(freshBar, kAXChildrenAttribute, as: [AXUIElement].self))
        let knob = try #require(children.first {
            probe.value($0, kAXRoleAttribute, as: String.self) == kAXValueIndicatorRole
        })
        let handle = try #require(probe.frame(of: knob))
        let initial = try #require(probe.value(freshBar, kAXValueAttribute, as: Double.self))
        let start = CGPoint(x: handle.midX, y: handle.midY)
        let finish = CGPoint(x: track.midX, y: track.minY + handle.height / 2 + 4)
        try #require(track.contains(start) && track.contains(finish) && abs(finish.y - start.y) > 10)
        let travel = track.height - handle.height
        try #require(travel > 20)
        let expected = (finish.y - track.minY - handle.height / 2) / travel
        try #require((0...1).contains(expected) && abs(expected - initial) > 0.1)
        let server = try #require(WindowServerProbe.geometry(of: document.number))
        let geometry = try #require(WindowGeometryProbe.observation(of: server))
        let from = try #require(InputLocation(screenPoint: start, observedIn: geometry))
        let to = try #require(InputLocation(screenPoint: finish, observedIn: geometry))
        try await send(.drag(from: from, to: to), to: document, in: stage, effect: {
            (try? canvasBar()).flatMap { probe.value($0, kAXValueAttribute, as: Double.self) }.map {
                abs($0 - expected) <= 0.02 && abs($0 - initial) > 0.1
            } == true
        })
        print("UXP_DRAG before=\(initial) expected=\(expected) after=\(String(describing: probe.value(freshBar, kAXValueAttribute, as: Double.self))) effect=true")
    }

    private func location(_ point: CGPoint, in window: PhotoshopProbe.Window) throws -> InputLocation {
        let server = try #require(WindowServerProbe.geometry(of: window.number))
        let geometry = try #require(WindowGeometryProbe.observation(of: server))
        return try #require(InputLocation(screenPoint: point, observedIn: geometry))
    }

    /// Verifies editing with fresh native state, on the new unsaved document only.
    private func editOwnedDocument(
        _ document     : PhotoshopProbe.Window,
        model          : PhotoshopDocumentCatalog.Document,
        preserving seed: PhotoshopDocumentCatalog.Document,
        in stage       : LiveStage,
        probe          : PhotoshopProbe,
        cycle          : Int,
        flow           : EditingFlow
    ) async throws {
        let baseline = try await probe.editingSnapshot(of: model, preserving: seed, in: stage.seat)
        try #require(baseline.selection == nil && baseline.histogram.contains(where: { $0 > 0 }))
        print("UXP_EDITING_BASELINE id=\(baseline.documentID) layers=\(baseline.layerCount) canvas=\(baseline.canvas)"
            + " history=\(baseline.historyName) count=\(baseline.historyCount)")

        try await focusCanvas(in: document, named: model.name, stage: stage, probe: probe)
        switch flow {
            case .selection:
                try await sendEditingShortcut(.character("a", holding: .command), to: document,
                                             model: model, preserving: seed, in: stage, probe: probe,
                                             label: "select-all") { $0.selection == baseline.canvas }
                try await sendEditingShortcut(.character("d", holding: .command), to: document,
                                             model: model, preserving: seed, in: stage, probe: probe,
                                             label: "deselect") { $0.selection == nil }
                return
            case .pixels:
                try await sendEditingShortcut(.character("i", holding: .command), to: document,
                                             model: model, preserving: seed, in: stage, probe: probe,
                                             label: "invert-pixels") {
                    $0.histogram == Array(baseline.histogram.reversed()) && $0.histogram != baseline.histogram
                        && $0.layerCount == baseline.layerCount && $0.activeLayerName == baseline.activeLayerName
                }
                try await sendEditingShortcut(.character("z", holding: .command), to: document,
                                             model: model, preserving: seed, in: stage, probe: probe,
                                             label: "undo-pixels") { $0.histogram == baseline.histogram }
                return
            case .layers, .layerDialog, .typedLayerDialog:
                break
        }

        let before = Set(try probe.windows().map(\.number))
        var ownedModal: PhotoshopProbe.Window?
        let usesNativeDialog = flow == .layerDialog || flow == .typedLayerDialog
        let name = flow == .typedLayerDialog
            ? "Mecum typed è🧪 👩🏽‍💻 e\u{301} \(cycle)"
            : "Mecum layer è🧪 \(cycle)"
        let nameCommand: InputCommand = flow == .typedLayerDialog ? .text(name) : .insertText(name)
        do {
            func newLayerDialog() -> PhotoshopProbe.Window? {
                guard let candidates = try? probe.windows().filter({ window in
                    guard !before.contains(window.number), window.subrole == kAXDialogSubrole,
                          probe.value(window.element, kAXModalAttribute, as: Bool.self) == true
                    else { return false }
                    if window.title == "New Layer" { return true }
                    return window.title.isEmpty && window.role == "AXLayoutArea"
                        && probe.hasNoExposedChildren(in: window)
                }), candidates.count == 1 else { return nil }
                return candidates.first
            }
            if usesNativeDialog {
                let menu = ["Layer", "New", "Layer…"]
                if probe.menuEnabledReading(menu) == false {
                    let refresh = await stage.seat.bringTargetBrieflyInFront(until: { probe.menuIsEnabled(menu) })
                    guard case .ready = refresh else { throw LiveFailure.unsupported("New Layer menu refresh: \(refresh)") }
                }
                try probe.pressMenu(menu)
                try #require(LivePump.run(until: { newLayerDialog() != nil }, timeout: 5))
                print("UXP_NEW_LAYER_SETUP menu=true shortcut-qualified=false")
            } else {
                try await sendShortcut(.character("n", holding: [.command, .shift]), to: document,
                                       in: stage, effect: { newLayerDialog() != nil })
            }
            let modal = try #require(newLayerDialog())
            ownedModal = modal
            let modalLabel = flow == .typedLayerDialog ? "new-layer-typed-\(cycle)" : "new-layer-\(cycle)"
            try await qualify(modal, in: stage, started: DispatchTime.now().uptimeNanoseconds,
                              label: modalLabel)
            let fields = try probe.controls(in: modal, role: kAXTextFieldRole)
            if fields.isEmpty {
                try await enterOpaqueLayerName(
                    using: nameCommand,
                    into : modal,
                    in   : stage
                )
            } else {
                let names = fields.filter {
                    probe.value($0, kAXValueAttribute, as: String.self)?.hasPrefix("Layer ") == true
                        && probe.value($0, kAXEnabledAttribute, as: Bool.self) == true
                }
                let field = try #require(names.count == 1 ? names.first : nil)
                let frame = try #require(probe.frame(of: field))
                try await send(.click(try location(CGPoint(x: frame.midX, y: frame.midY), in: modal), count: 2),
                               to: modal, in: stage, effect: {
                    probe.value(field, kAXFocusedAttribute, as: Bool.self) == true
                })
                try await send(nameCommand, to: modal, in: stage, effect: {
                    probe.value(field, kAXValueAttribute, as: String.self) == name
                })
            }
            try await send(.key(virtualKey: 36, text: "\r"), to: modal, in: stage,
                           effect: { !probe.contains(modal.number) })
            ownedModal = nil
            if let retired = stage.seat.adoptedWindows.first(where: { $0.id == modal.number }) {
                _ = await stage.seat.release(retired, .leaveOnVirtualDisplay)
            }
        } catch {
            if let modal = ownedModal ?? probe.dialog(excluding: before), probe.contains(modal.number) {
                do { try await cancelForCleanup(modal, in: stage, probe: probe) }
                catch { Issue.record("The test-owned New Layer modal was not cancelled: \(error)") }
            }
            throw error
        }
        _ = try await observe(document.number, in: stage)
        try await waitForDocumentKeyboard(document.number, in: stage)
        let created = try await probe.editingSnapshot(of: model, preserving: seed, in: stage.seat)
        try #require(created.layerCount == baseline.layerCount + 1 && created.activeLayerName == name)
        print("UXP_EDITING_EFFECT label=create-layer cycle=\(cycle) effect=true layers=\(created.layerCount)")
        if usesNativeDialog { return }

        try await sendEditingShortcut(.character("z", holding: .command), to: document,
                                     model: model, preserving: seed, in: stage, probe: probe,
                                     label: "undo-layer") { $0.layerCount == baseline.layerCount }
        try await sendEditingShortcut(.character("z", holding: [.command, .shift]), to: document,
                                     model: model, preserving: seed, in: stage, probe: probe,
                                     label: "redo-layer") {
            $0.layerCount == baseline.layerCount + 1 && $0.activeLayerName == name
        }
        try await sendEditingShortcut(.character("z", holding: .command), to: document,
                                     model: model, preserving: seed, in: stage, probe: probe,
                                     label: "restore-layer") {
            $0.layerCount == baseline.layerCount && $0.histogram == baseline.histogram && $0.selection == nil
        }
    }

    /// enterOpaqueLayerName posts one text command to the positively owned modal leaf.
    /// Its receipt stays unknown; the exact created layer name is the effect oracle.
    private func enterOpaqueLayerName(
        using command: InputCommand,
        into modal   : PhotoshopProbe.Window,
        in stage     : LiveStage
    ) async throws {
        let turn = try await stage.seat.acquire()
        var pending: InputReceipt?
        do {
            let observation = try await liveObservation(stage.seat)
            try #require(observation.surface.windowNumber == modal.number)
            let person = UserSeatState.capture()
            let physical = stage.fence.snapshot().observedEventCount
            let receipt = try await stage.seat.send(command, observation: observation, turn: turn)
            pending = receipt
            LivePump.run(for: 0.1)
            try #require(UserSeatState.capture() == person && stage.fence.snapshot().observedEventCount == physical)
            try stage.seat.confirm(receipt, .unknown)
            pending = nil
            _ = await stage.seat.concludeObservation()
            try stage.seat.release(turn)
            print("UXP_LAYER_TEXT posted=true effect-awaits-model=true events=\(receipt.eventCount)")
        } catch {
            if let pending { try? stage.seat.confirm(pending, .unknown) }
            _ = await stage.seat.concludeObservation()
            try? stage.seat.release(turn)
            throw error
        }
    }

    /// focusCanvas restores the owned canvas after native model inspection.
    /// Photoshop can restore a text field when the fixture activates its app.
    private func focusCanvas(
        in document: PhotoshopProbe.Window,
        named name : String,
        stage      : LiveStage,
        probe      : PhotoshopProbe
    ) async throws {
        let tracks = try probe.controls(in: document, role: kAXScrollBarRole).compactMap { probe.frame(of: $0) }
        let vertical = try #require(tracks.filter { $0.height > $0.width && $0.height > 100 }
            .max { $0.height < $1.height })
        let horizontal = try #require(tracks.filter { $0.width > $0.height && $0.width > 100 }
            .max { $0.width < $1.width })
        try #require(abs(horizontal.maxX - vertical.maxX) < 20 && abs(horizontal.minY - vertical.maxY) < 20,
                     "The native scrollbar pair does not bound the same canvas")
        let canvasPoint = CGPoint(x: horizontal.midX, y: vertical.midY)
        try await send(.click(try location(canvasPoint, in: document)), to: document, in: stage, effect: {
            guard let focused = probe.value(probe.element, kAXFocusedUIElementAttribute, as: AXUIElement.self),
                  let role = probe.value(focused, kAXRoleAttribute, as: String.self)
            else { return false }
            return role == kAXWindowRole && WindowRelocator.windowNumber(of: focused) == document.number
                && probe.selectedDocument(named: name, number: document.number) != nil
        })
        print("UXP_CANVAS_FOCUS horizontal=\(horizontal) vertical=\(vertical) point=\(canvasPoint) effect=true")
    }

    /// Measures input isolation before the explicitly activated read-only model fixture.
    private func sendEditingShortcut(
        _ shortcut     : Shortcut,
        to document    : PhotoshopProbe.Window,
        model          : PhotoshopDocumentCatalog.Document,
        preserving seed: PhotoshopDocumentCatalog.Document,
        in stage       : LiveStage,
        probe          : PhotoshopProbe,
        label          : String,
        effect         : (PhotoshopEditingSnapshot) -> Bool
    ) async throws {
        try await waitForDocumentKeyboard(document.number, in: stage)
        let focused = try #require(probe.value(probe.element, kAXFocusedUIElementAttribute, as: AXUIElement.self))
        try #require(probe.value(focused, kAXRoleAttribute, as: String.self) == kAXWindowRole
                     && WindowRelocator.windowNumber(of: focused) == document.number,
                     "The model fixture changed canvas focus before the editing shortcut")
        let turn = try await stage.seat.acquire()
        var pending: InputReceipt?
        do {
            let observation = try await liveObservation(stage.seat)
            try #require(observation.surface.windowNumber == document.number)
            let person = UserSeatState.capture()
            let physical = stage.fence.snapshot().observedEventCount
            let receipt = try await stage.seat.send(shortcut, observation: observation, turn: turn)
            pending = receipt
            LivePump.run(for: 0.1)
            let after = UserSeatState.capture()
            try #require(after.frontmostProcessID == person.frontmostProcessID && after.cursor == person.cursor)
            try #require(stage.fence.snapshot().observedEventCount == physical)
            let snapshot = try await probe.editingSnapshot(of: model, preserving: seed, in: stage.seat)
            let landed = effect(snapshot)
            try stage.seat.confirm(receipt, landed ? .observed : .unknown)
            pending = nil
            #expect(receipt.route.windowNumber == document.number)
            #expect(receipt.layoutGeneration != nil)
            print("UXP_EDITING_EFFECT label=\(label) effect=\(landed) layers=\(snapshot.layerCount)"
                + " selection=\(String(describing: snapshot.selection)) history=\(snapshot.historyName)"
                + " history-count=\(snapshot.historyCount) preparation=\(receipt.preparation) input-isolation=true")
            _ = await stage.seat.concludeObservation()
            try stage.seat.release(turn)
            try #require(landed, "The editing shortcut had no independently observed model effect: \(label)")
        } catch {
            if let pending { try? stage.seat.confirm(pending, .unknown) }
            _ = await stage.seat.concludeObservation()
            try? stage.seat.release(turn)
            throw error
        }
    }

    /// Closes only the disposable document created by this row. The original
    /// URL and a different title cannot qualify a destructive cleanup key.
    private func closeCreatedDocument(
        _ document: PhotoshopProbe.Window,
        model     : PhotoshopDocumentCatalog.Document,
        in stage  : LiveStage,
        probe     : PhotoshopProbe
    ) async throws {
        let catalog = try await probe.documentCatalog(in: stage.seat)
        try #require(catalog.activeID == model.id && catalog.documents.contains(model) && model.url == nil)
        let name = model.name
        try #require(name.hasPrefix("Untitled-"))
        let current = try #require(probe.selectedDocument(named: name, number: document.number),
                                  "The selected document is not the exact test-owned document")
        try #require(probe.value(current.element, kAXDocumentAttribute, as: String.self) == nil)
        let seedPath = try #require(ProcessInfo.processInfo.environment["AGENTSEAT_UXP_DOCUMENT"])
        let seed = URL(fileURLWithPath: seedPath).lastPathComponent
        let before = Set(try probe.windows().map(\.number))
        func savePrompt() -> PhotoshopProbe.Window? {
            guard let candidates = try? probe.windows().filter({ window in
                guard !before.contains(window.number), window.subrole == kAXDialogSubrole,
                      probe.value(window.element, kAXModalAttribute, as: Bool.self) == true
                else { return false }
                if probe.buttonFrame(in: window, named: "Don't Save") != nil { return true }
                return window.title.isEmpty && window.role == "AXLayoutArea"
                    && probe.hasNoExposedChildren(in: window)
            }), candidates.count == 1 else { return nil }
            return candidates.first
        }
        try await sendShortcut(.character("w", holding: .command), to: current, in: stage, effect: {
            probe.selectedDocument(named: seed, number: document.number) != nil || savePrompt() != nil
        })
        if let prompt = savePrompt() {
            do {
                try await qualify(prompt, in: stage, started: DispatchTime.now().uptimeNanoseconds, label: "created-document-close")
                if let button = probe.buttonFrame(in: prompt, named: "Don't Save") {
                    let server = try #require(WindowServerProbe.geometry(of: prompt.number))
                    let geometry = try #require(WindowGeometryProbe.observation(of: server))
                    let location = try #require(InputLocation(screenPoint: CGPoint(x: button.midX, y: button.midY), observedIn: geometry))
                    try await send(.click(location), to: prompt, in: stage, effect: { !probe.contains(prompt.number) })
                } else {
                    try await sendShortcut(.character("d", holding: .command), to: prompt, in: stage,
                                           effect: { !probe.contains(prompt.number) })
                }
            } catch {
                if probe.contains(prompt.number) { try await cancelForCleanup(prompt, in: stage, probe: probe) }
                throw error
            }
        }
        _ = try await observe(document.number, in: stage)
        try await waitForDocumentKeyboard(document.number, in: stage)
        print("UXP_CREATED_DOCUMENT closed=true")
    }

    /// A fresh vendor-model snapshot checks all tabs independently from AX.
    /// No menu is opened and no fixture command qualifies directed input.
    @discardableResult
    private func verifyDocumentCatalog(
        _ names: [String],
        active: String,
        probe: PhotoshopProbe,
        in stage: LiveStage
    ) async throws -> PhotoshopDocumentCatalog {
        let catalog = try await probe.documentCatalog(in: stage.seat)
        let seedPath = try #require(ProcessInfo.processInfo.environment["AGENTSEAT_UXP_DOCUMENT"])
        let seedURL = URL(fileURLWithPath: seedPath).standardizedFileURL
        try #require(catalog.documents.filter { $0.url == seedURL }.count == 1,
                     "The model must contain the exact disposable seed URL")
        try #require(catalog.documents.map(\.name).sorted() == names.sorted(),
                     "Photoshop documents differ from the exact test-owned catalog")
        try #require(catalog.activeDocument?.name == active)
        print("UXP_DOCUMENT_CATALOG count=\(catalog.documents.count) active-id=\(String(describing: catalog.activeID)) model=true")
        return catalog
    }

    /// Waits for Photoshop's tab transition to finish before resolving a new
    /// command. Both ordinary focus and the qualified UXP proxy are valid;
    /// neither a receipt nor a transient title change establishes readiness.
    private func waitForDocumentKeyboard(_ number: Int, in stage: LiveStage) async throws {
        let deadline = Date().addingTimeInterval(5)
        var evidence: InputEndpointEvidence?
        var stableSince: Date?
        while Date() < deadline {
            let observation = try await liveObservation(stage.seat)
            if observation.surface.windowNumber == number,
               let resolution = try? stage.seat.inputEndpoint(
                   for: .key(virtualKey: 48, text: "\t", modifiers: .control), observation: observation
               ),
               resolution.endpoint.kind == .keyboardContext,
               resolution.endpoint.identity == observation.surface {
                let current = resolution.endpoint.evidence
                if current != evidence { evidence = current; stableSince = Date() }
                if let stableSince, Date().timeIntervalSince(stableSince) >= 0.3 {
                    print("UXP_DOCUMENT_READY evidence=\(current) stable=true")
                    return
                }
            } else { evidence = nil; stableSince = nil }
            LivePump.run(for: 0.025)
            await Task.yield()
        }
        throw LiveFailure.unsupported("Photoshop document keyboard context did not stabilize")
    }

    private func sendShortcut(
        _ shortcut: Shortcut,
        to document: PhotoshopProbe.Window,
        in stage: LiveStage,
        effect: () -> Bool
    ) async throws {
        let turn = try await stage.seat.acquire()
        do {
            let observation = try await liveObservation(stage.seat)
            try #require(observation.surface.windowNumber == document.number)
            let receipt = try await stage.seat.send(shortcut, observation: observation, turn: turn)
            let landed = LivePump.run(until: effect, timeout: 5)
            try stage.seat.confirm(receipt, landed ? .observed : .unknown)
            #expect(receipt.route.windowNumber == document.number)
            #expect(receipt.layoutGeneration != nil)
            print("UXP_SHORTCUT effect=\(landed) layout-generation=\(String(describing: receipt.layoutGeneration))")
            _ = await stage.seat.concludeObservation()
            try stage.seat.release(turn)
            try #require(landed, "The layout-resolved document shortcut had no observed effect")
        } catch {
            _ = await stage.seat.concludeObservation()
            try? stage.seat.release(turn)
            throw error
        }
    }

    /// Cancels only a dialog opened by this row, with fresh geometry and an
    /// independently observed closure. An AX press receipt is not cleanup proof.
    private func cancelForCleanup(
        _ dialog: PhotoshopProbe.Window,
        in stage: LiveStage,
        probe   : PhotoshopProbe
    ) async throws {
        guard let current = try probe.windows().first(where: { $0.number == dialog.number }) else {
            print("UXP_CLEANUP window=\(dialog.number) already-closed=true")
            return
        }
        try #require(current.subrole == kAXDialogSubrole)
        do {
            if probe.value(current.element, kAXModalAttribute, as: Bool.self) == false,
               let adopted = stage.seat.adoptedWindows.first(where: { $0.id == current.number }) {
                try await stage.seat.switchTarget(to: adopted)
            }
            if current.role == "AXLayoutArea", probe.buttonFrame(in: current, named: "Cancel") == nil {
                try await send(.key(virtualKey: 53, text: ""), to: current, in: stage,
                               effect: { !probe.contains(current.number) })
                print("UXP_CLEANUP window=\(current.number) closed=true")
                return
            }
            let button = try #require(probe.buttonFrame(in: current, named: "Cancel"))
            let server = try #require(WindowServerProbe.geometry(of: current.number))
            let geometry = try #require(WindowGeometryProbe.observation(of: server))
            let location = try #require(InputLocation(
                screenPoint: CGPoint(x: button.midX, y: button.midY), observedIn: geometry
            ))
            try await send(.click(location), to: current, in: stage,
                           effect: { !probe.contains(current.number) })
            print("UXP_CLEANUP window=\(current.number) closed=true")
        } catch {
            // A failed capture must not strand the owned save prompt. This
            // native fixture cleanup never qualifies directed input.
            try probe.cancelOwnedDialog(current)
            print("UXP_CLEANUP window=\(current.number) native-fixture=true cause=\(error)")
        }
    }

    private func qualify(
        _ dialog: PhotoshopProbe.Window,
        in stage: LiveStage,
        started : UInt64,
        label   : String
    ) async throws {
        let followed = await LivePump.settle(until: {
            stage.seat.adoptedWindows.contains { $0.id == dialog.number }
        }, timeout: 10)
        let adoptedAt = DispatchTime.now().uptimeNanoseconds
        print("UXP_FOLLOW label=\(label) dialog=\(dialog.number) title=\(dialog.title) role=\(dialog.role)"
            + " followed=\(followed) scans=\(stage.seat.windowFollowScanCount) state=\(stage.seat.state)"
            + " selection=\(String(describing: stage.seat.currentTarget?.id))"
            + " elapsed-ms=\(Double(adoptedAt - started) / 1e6)")
        if !followed {
            print("UXP_DIAGNOSTICS adopted=\(stage.seat.adoptedWindows.map(\.id)) events=\(stage.events.events)")
            let reading = CrossCheckedSurfaceReader.snapshot(
                ownedBy: [stage.seat.adoptedWindows.first?.reference.processID ?? 0], windowNumbers: AccessibilityWindowNumberCache()
            )
            print("UXP_DIAGNOSTICS inventory=\(reading)")
        }
        try #require(followed, "The seat did not automatically adopt the Photoshop dialog")
        let probe = try PhotoshopProbe()
        if probe.value(dialog.element, kAXModalAttribute, as: Bool.self) == false,
           let adopted = stage.seat.adoptedWindows.first(where: { $0.id == dialog.number }) {
            try await stage.seat.switchTarget(to: adopted)
            print("UXP_SELECTION window=\(dialog.number) ax-modal=false explicit=true")
        }
        let geometry = try #require(WindowServerProbe.geometry(of: dialog.number))
        #expect(stage.virtualBounds.contains(geometry.frame))
        let deadline = Date().addingTimeInterval(5)
        var lastFailure: ObservationUnavailable?
        while Date() < deadline {
            switch await stage.seat.observe() {
                case .failure(let reason): lastFailure = reason
                case .success(let delivery) where delivery.reference.surface.windowNumber == dialog.number:
                    #expect(delivery.reference.surface.processID == geometry.processID)
                    #expect(delivery.frame.pixelSize.width > 0 && delivery.frame.pixelSize.height > 0)
                    print("UXP_CAPTURE label=\(label) age=\(delivery.contentAge) pixels=\(delivery.frame.pixelSize)"
                        + " elapsed-ms=\(Double(DispatchTime.now().uptimeNanoseconds - adoptedAt) / 1e6)")
                    if let directory = ProcessInfo.processInfo.environment["AGENTSEAT_UXP_ARTIFACTS"],
                       let image = delivery.frame.makeCGImage(),
                       let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                        let destination = URL(fileURLWithPath: directory, isDirectory: true)
                        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                        try png.write(to: destination.appendingPathComponent("\(label).png"))
                    }
                    return
                case .success: break
            }
            LivePump.run(for: 0.02)
            await Task.yield()
        }
        throw LiveFailure.unsupported("The dialog observation did not stabilize for \(dialog.number): \(String(describing: lastFailure))")
    }

    /// Closing a proxy can precede WindowServer withdrawal. Observe through
    /// the production grace and require the selected document, without replay.
    private func observe(_ number: Int, in stage: LiveStage) async throws -> SeatObservationReference {
        let deadline = Date().addingTimeInterval(5)
        var lastFailure: ObservationUnavailable?
        while Date() < deadline {
            switch await stage.seat.observe() {
                case .success(let delivery) where delivery.reference.surface.windowNumber == number:
                    return delivery.reference
                case .success:
                    break
                case .failure(let reason):
                    lastFailure = reason
            }
            LivePump.run(for: 0.02)
            await Task.yield()
        }
        throw LiveFailure.unsupported("The selected window did not return to \(number): \(String(describing: lastFailure))")
    }

    private func send(
        _ command: InputCommand,
        to dialog: PhotoshopProbe.Window,
        in stage : LiveStage,
        platform : (any InputPlatform)? = nil,
        effect   : () -> Bool
    ) async throws {
        let turn = try await stage.seat.acquire()
        var phase = "observation"
        do {
            let observation = try await liveObservation(stage.seat)
            try #require(observation.surface.windowNumber == dialog.number)
            phase = "recipient-check"
            let endpoint = try stage.seat.inputEndpoint(for: command, observation: observation)?.endpoint
            let expectedWindow = endpoint?.identity.windowNumber ?? dialog.number
            let expectedOwner = endpoint?.identity.ownerConnectionID ?? observation.surface.ownerConnectionID
            if let endpoint {
                try #require(endpoint.logicalSurface.windowNumber == dialog.number)
            }
            print("UXP_RECIPIENT window=\(dialog.number) evidence=\(String(describing: endpoint?.evidence))")
            let started = DispatchTime.now().uptimeNanoseconds
            phase = "production-send"
            let receipt = try await stage.seat.send(
                command, observation: observation, turn: turn, platform: platform
            )
            let landed = LivePump.run(until: effect, timeout: 5)
            if !landed, let directory = ProcessInfo.processInfo.environment["AGENTSEAT_UXP_ARTIFACTS"],
               case .success(let delivery) = await stage.seat.observe(),
               delivery.reference.surface.windowNumber == dialog.number,
               let image = delivery.frame.makeCGImage(),
               let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("failed-input-\(dialog.number).png"))
            }
            try stage.seat.confirm(receipt, landed ? .observed : .unknown)
            print("UXP_INPUT window=\(dialog.number) command=\(command) effect=\(landed) route=\(receipt.route.windowNumber)"
                + " elapsed-ms=\(Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6)"
                + " preparation=\(receipt.preparation)"
                + " settle-ns=\(String(describing: receipt.trace?.settling.intentionalWaitNanoseconds))")
            #expect(receipt.route.windowNumber == expectedWindow)
            #expect(receipt.route.ownerConnectionID == expectedOwner)
            _ = await stage.seat.concludeObservation()
            try stage.seat.release(turn)
            try #require(landed, "The directed command did not produce the expected dialog effect")
        } catch {
            print("UXP_REFUSAL window=\(dialog.number) phase=\(phase) reason=\(error)")
            _ = await stage.seat.concludeObservation()
            try? stage.seat.release(turn)
            throw error
        }
    }
}
