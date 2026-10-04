//
//  PhotoshopProbe.swift
//  AgentSeatKit
//

import AppKit
import ApplicationServices
import Foundation
import SeatCore
import SeatInput
import SeatSession
import Testing
import WindowPlacement

/// PhotoshopProbe scopes the optional UXP run to the disposable probe.
/// A scoped document-model fixture also checks tabs sharing one AX window.
/// AX menu presses are setup triggers, never evidence of directed input.
@MainActor
struct PhotoshopProbe {

    struct Window {
        let element: AXUIElement
        let number : Int
        let title  : String
        let role   : String
        let subrole: String
    }

    private enum DocumentFixtureFailure: Error {
        case activationNotReady
    }

    let application: NSRunningApplication
    let element    : AXUIElement

    init() throws {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.loginwindow" else {
            throw LiveFailure.unsupported("Unlock the approved desktop before Adobe UXP live tests")
        }
        application = try #require(NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.adobe.Photoshop"
        ).first, "Photoshop must already be running with only the disposable probe document")
        element = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.1)
    }

    func value<Value>(
        _ node        : AXUIElement,
        _ attribute   : String,
        as            : Value.Type,
        retryOnTimeout: Bool = true
    ) -> Value? {
        var value: CFTypeRef?
        var status = AXUIElementCopyAttributeValue(node, attribute as CFString, &value)
        if status == .cannotComplete, retryOnTimeout {
            AXUIElementSetMessagingTimeout(node, 0.5)
            status = AXUIElementCopyAttributeValue(node, attribute as CFString, &value)
            AXUIElementSetMessagingTimeout(node, 0.1)
        }
        if status != .success, attribute == kAXWindowsAttribute {
            print("UXP_AX windows-error=\(status.rawValue) trusted=\(AXIsProcessTrusted())")
        }
        guard status == .success else { return nil }
        return value as? Value
    }

    func windows() throws -> [Window] {
        guard let nodes = value(element, kAXWindowsAttribute, as: [AXUIElement].self) else {
            throw LiveFailure.unsupported("The Photoshop AX window inventory is unreadable")
        }
        return try nodes.map { node in
            let reading = WindowRelocator.windowNumberReading(of: node)
            guard case .number(let number) = reading, number > 0 else {
                let detail: String
                if case .readFailed(let status) = reading {
                    detail = "AX error \(status.rawValue)"
                } else {
                    detail = String(describing: reading)
                }
                throw LiveFailure.unsupported("A Photoshop AX window has no readable Window ID: \(detail)")
            }
            return Window(
                element: node,
                number : number,
                title  : value(node, kAXTitleAttribute, as: String.self) ?? "",
                role   : value(node, kAXRoleAttribute, as: String.self) ?? "",
                subrole: value(node, kAXSubroleAttribute, as: String.self) ?? ""
            )
        }
    }

    func document() throws -> Window {
        let document = try seedWindow()
        let windows = try windowsExcludingInertProxies(for: document)
        try #require(windows.count == 1 && windows.first?.number == document.number,
                     "The scoped test requires one document window and no other input-bearing surface")
        return document
    }

    /// preparedDocument refreshes only typed absence of AXMainWindow on the
    /// sole exact PNG fixture. Native cancellation can leave all focus attributes
    /// absent; input qualification still starts after verified foreground handback.
    func preparedDocument() async throws -> Window {
        var main: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXMainWindowAttribute as CFString, &main)
        guard status == .noValue else { return try document() }
        let seed = try seedWindow()
        let inventory = try windows()
        try #require(inventory.count == 1 && inventory[0].number == seed.number
                     && seed.role == kAXWindowRole && seed.subrole == kAXStandardWindowSubrole
                     && value(seed.element, kAXModalAttribute, as: Bool.self) == false,
                     "Native fixture refresh requires the sole exact nonmodal PNG window")
        for attribute in [kAXFocusedWindowAttribute, kAXFocusedUIElementAttribute] {
            var focus: CFTypeRef?
            try #require(AXUIElementCopyAttributeValue(element, attribute as CFString, &focus) == .noValue,
                         "Only complete typed absence permits native fixture context refresh")
        }
        let target = try #require(WindowServerProbe.geometry(of: seed.number))
        try #require(target.identity?.processID == application.processIdentifier)
        let refreshed = try await activateNativeFixture(target, usesKeyRecords: true, until: {
            guard let main = value(element, kAXMainWindowAttribute, as: AXUIElement.self,
                                   retryOnTimeout: false),
                  WindowRelocator.windowNumber(of: main) == seed.number,
                  let current = WindowServerProbe.geometry(of: seed.number),
                  current.hasSameIdentity(as: target),
                  (try? seedWindow().number) == seed.number else { return false }
            return true
        })
        try #require(refreshed, "The sole PNG fixture did not establish its native main window")
        print("UXP_NATIVE_PREFLIGHT context-refreshed=true foreground-and-cursor-restored=true")
        return try document()
    }

    private func seedWindow() throws -> Window {
        let path = try #require(ProcessInfo.processInfo.environment["AGENTSEAT_UXP_DOCUMENT"],
                                "AGENTSEAT_UXP_DOCUMENT must name the disposable open PNG")
        let expected = URL(fileURLWithPath: path).standardizedFileURL
        let inventory = try windows()
        let document = try #require(inventory.first { window in
            let raw = value(window.element, kAXDocumentAttribute, as: String.self)
                ?? value(window.element, kAXURLAttribute, as: URL.self)?.absoluteString
            return raw.flatMap(URL.init(string:))?.standardizedFileURL == expected
        })
        let raw = value(document.element, kAXDocumentAttribute, as: String.self)
            ?? value(document.element, kAXURLAttribute, as: URL.self)?.absoluteString
        let actual = raw.flatMap(URL.init(string:))?.standardizedFileURL
        try #require(actual == expected, "The selected Photoshop document must be \(expected.path); AXDocument=\(raw ?? "unreadable")")
        return document
    }

    /// Excludes only a complete empty same-process focus proxy beside the main window.
    /// A modal, unreadable child list or unmatched process identity remains in scope.
    func windowsExcludingInertProxies(for main: Window) throws -> [Window] {
        guard let node = value(element, kAXMainWindowAttribute, as: AXUIElement.self),
              WindowRelocator.windowNumber(of: node) == main.number,
              let mainIdentity = WindowServerProbe.geometry(of: main.number)?.identity
        else { throw LiveFailure.unsupported("The Photoshop main window is not independently identified") }
        return try windows().filter { window in
            guard window.number != main.number, window.role == "AXLayoutArea", window.subrole == "AXUnknown",
                  value(window.element, kAXModalAttribute, as: Bool.self) == false,
                  value(window.element, kAXChildrenAttribute, as: [AXUIElement].self)?.isEmpty == true,
                  WindowServerProbe.geometry(of: window.number)?.identity?.process == mainIdentity.process
            else { return true }
            return false
        }
    }

    /// hasNoExposedChildren distinguishes a terminal modal leaf from a failed read.
    /// An opaque UXP dialog can explicitly return unsupported or no-value children.
    func hasNoExposedChildren(in window: Window) -> Bool {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(window.element, kAXChildrenAttribute as CFString, &raw)
        switch status {
            case .success:
                return (raw as? [AXUIElement])?.isEmpty == true
            case .noValue, .attributeUnsupported:
                return true
            default:
                return false
        }
    }

    func documentName(_ window: Window) -> String? {
        guard let suffix = window.title.range(of: " @ ", options: .backwards) else { return nil }
        return String(window.title[..<suffix.lowerBound])
    }

    func selectedDocument(named name: String, number: Int) -> Window? {
        try? windows().first { $0.number == number && documentName($0) == name }
    }

    /// A read-only JSX fixture queries Photoshop's document model. Opening a
    /// native menu can leave AppKit in tracking; neither its cached items nor
    /// the AX window count attest all tabs. LaunchServices needs no Apple Events
    /// automation grant. Photoshop can activate itself while opening the script,
    /// so the Seat bounds the activation and verifies its handback.
    func documentCatalog(in seat: AgentSeat) async throws -> PhotoshopDocumentCatalog {
        do {
            return try await runDocumentFixture(action: "", in: seat)
        } catch DocumentFixtureFailure.activationNotReady {
            // UXP cancellation can ignore the first script open. Retry only the
            // read with a new nonce after handback; no input is ever replayed.
            print("UXP_MODEL_FIXTURE retry-read-only=true")
            return try await runDocumentFixture(action: "", in: seat)
        }
    }

    /// Cleanup is a guarded fixture operation, never input qualification. The
    /// script rechecks both IDs and the seed URL before closing the owned copy.
    func closeOwnedDocument(
        _ owned: PhotoshopDocumentCatalog.Document,
        preserving seed: PhotoshopDocumentCatalog.Document,
        in seat: AgentSeat
    ) async throws -> PhotoshopDocumentCatalog {
        let action = try ownedDocumentGuard(owned, preserving: seed) + "\nowned.close(SaveOptions.DONOTSAVECHANGES);"
        return try await runDocumentFixture(action: action, in: seat)
    }

    /// Reads selection, layers and pixels only from the exact active unsaved copy.
    /// The model query never applies an editing command or changes selection.
    func editingSnapshot(
        of owned       : PhotoshopDocumentCatalog.Document,
        preserving seed: PhotoshopDocumentCatalog.Document,
        in seat        : AgentSeat
    ) async throws -> PhotoshopEditingSnapshot {
        let guardSource = try ownedDocumentGuard(owned, preserving: seed)
        let query = """
            \(guardSource)
            if (app.activeDocument.id !== owned.id) { throw new Error('active document changed'); }
            if (owned.mode !== DocumentMode.RGB) { throw new Error('editing row requires RGB'); }
            var selection = 'none';
            try {
                var bounds = owned.selection.bounds;
                selection = [bounds[0].as('px'), bounds[1].as('px'), bounds[2].as('px'), bounds[3].as('px')].join(',');
            } catch (_) {}
            file.writeln([
                'MECUM_EDITING', token, owned.id, owned.layers.length,
                owned.width.as('px'), owned.height.as('px'), encodeURIComponent(owned.activeLayer.name),
                selection, owned.histogram.join(','), owned.historyStates.length, encodeURIComponent(owned.activeHistoryState.name)
            ].join('\\t'));
            """
        for attempt in 0..<2 {
            let token = UUID().uuidString
            do {
                let snapshot = try await runModelFixture(action: "", query: query, token: token, in: seat)
                return try PhotoshopEditingSnapshot(parsing: snapshot, token: token, documentID: owned.id)
            } catch DocumentFixtureFailure.activationNotReady where attempt == 0 {
                print("UXP_EDITING_FIXTURE retry-read-only=true")
            }
        }
        throw DocumentFixtureFailure.activationNotReady
    }

    private func ownedDocumentGuard(
        _ owned        : PhotoshopDocumentCatalog.Document,
        preserving seed: PhotoshopDocumentCatalog.Document
    ) throws -> String {
        guard owned.id != seed.id, owned.url == nil, let path = seed.nativePath else {
            throw LiveFailure.unsupported("Document fixture ownership is incomplete")
        }
        return """
            if (app.documents.length !== 2) { throw new Error('fixture count changed'); }
            var owned = null, seed = null;
            for (var i = 0; i < app.documents.length; i++) {
                if (app.documents[i].id === \(owned.id)) { owned = app.documents[i]; }
                if (app.documents[i].id === \(seed.id)) { seed = app.documents[i]; }
            }
            if (!owned || !seed || owned.name !== \(try javascriptString(owned.name)) || seed.name !== \(try javascriptString(seed.name))) { throw new Error('cleanup identity changed'); }
            if (seed.fullName.fsName !== new File(\(try javascriptString(path))).fsName) { throw new Error('seed URL changed'); }
            var ownedPath = null;
            try { ownedPath = owned.fullName.fsName; } catch (_) {}
            if (ownedPath) { throw new Error('owned document acquired a path'); }
            """
    }

    private func javascriptString(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw LiveFailure.unsupported("The fixture string is not UTF-8")
        }
        return string.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    private func runDocumentFixture(action: String, in seat: AgentSeat) async throws -> PhotoshopDocumentCatalog {
        let token = UUID().uuidString
        let query = """
            var count = app.documents.length;
            if (count > 2) { throw new Error('fixture scope exceeded'); }
            file.writeln('MECUM_DOCUMENTS\\t' + token + '\\t' + (count ? app.activeDocument.id : 'none') + '\\t' + count);
            for (var i = 0; i < count; i++) {
                var doc = app.documents[i], path = '';
                try { path = doc.fullName.fsName; } catch (_) {}
                file.writeln(doc.id + '\\t' + encodeURIComponent(doc.name) + '\\t' + encodeURIComponent(path));
            }
            """
        let snapshot = try await runModelFixture(action: action, query: query, token: token,
                                                 in: seat, allowsFailedSeatFixture: true)
        return try PhotoshopDocumentCatalog(parsing: snapshot, token: token)
    }

    /// runModelFixture launches one nonce-bound native operation after verified activation.
    /// Only a refusal before any request can wait for user-window evidence. A created
    /// launch is never retried, including when the operation performs owned cleanup.
    private func runModelFixture(
        action : String,
        query  : String,
        token  : String,
        in seat: AgentSeat,
        allowsFailedSeatFixture: Bool = false
    ) async throws -> String {
        guard !application.isTerminated, let applicationURL = application.bundleURL else {
            throw LiveFailure.unsupported("The Photoshop fixture host is unavailable")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mecum-photoshop-documents-\(token)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let script = directory.appendingPathComponent("document-fixture.jsx")
        let output = directory.appendingPathComponent("snapshot.tsv")
        var completed = false
        defer {
            // Retain queued requests on timeout to prevent a later missing-source alert.
            if completed { try? FileManager.default.removeItem(at: directory) }
        }
        let source = """
            (function () {
                var token = \(try javascriptString(token));
                var file = new File(\(try javascriptString(output.path)));
                file.encoding = 'UTF-8'; file.lineFeed = 'Unix';
                if (!file.open('w')) { throw new Error('fixture output unavailable'); }
                try {
                    \(action)
                    \(query)
                } catch (error) {
                    file.writeln('MECUM_ERROR\\t' + \(try javascriptString(token)) + '\\t' + encodeURIComponent(error.message));
                }
                file.writeln('MECUM_DONE\\t' + \(try javascriptString(token)));
                file.close();
            })();
            """
        try source.write(to: script, atomically: true, encoding: .utf8)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.promptsUserIfNeeded = false
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var launch: Task<NSRunningApplication, any Error>?
        var snapshot: String?
        let readFixture: @MainActor () -> Bool = {
            if launch == nil {
                launch = Task { @MainActor in
                    try await NSWorkspace.shared.open(
                        [script],
                        withApplicationAt: applicationURL,
                        configuration    : configuration
                    )
                }
            }
            if let value = try? String(contentsOf: output, encoding: .utf8),
               value.hasSuffix("MECUM_DONE\t\(token)\n") {
                snapshot = value
                return true
            }
            return false
        }
        let fixtureReady: Bool
        if seat.state == .failed, allowsFailedSeatFixture {
            // A failed Seat cannot authorize input or restore focus. This is
            // fixture setup/cleanup with its own identity-bound handback.
            fixtureReady = try await activateNativeFixture(nativeDocumentFixtureTarget(), until: readFixture)
            print("UXP_MODEL_FIXTURE independent-native=true ready=\(fixtureReady) foreground-restored=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)")
        } else {
            let clock = ContinuousClock()
            let admissionDeadline = clock.now.advanced(by: .milliseconds(500))
            var admissionChecks = 1
            var outcome = await seat.bringTargetBrieflyInFront(until: readFixture)
            // noUserWindow refuses before requesting activation or invoking readFixture.
            // A bounded admission wait never repeats a launch, mutation or input command.
            while case .refused(.noUserWindow) = outcome,
                  launch == nil, snapshot == nil, !application.isTerminated,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,
                  clock.now < admissionDeadline {
                try await Task.sleep(for: .milliseconds(20))
                admissionChecks += 1
                outcome = await seat.bringTargetBrieflyInFront(until: readFixture)
            }
            print("UXP_MODEL_FIXTURE activation=\(outcome) foreground-restored=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground) admission-checks=\(admissionChecks)")
            switch outcome {
                case .ready: fixtureReady = true
                case .notReady: fixtureReady = false
                default:
                    throw LiveFailure.unsupported("The Photoshop document fixture activation did not complete: \(outcome)")
            }
        }
        let host = try await launch?.value
        if let host {
            print("UXP_MODEL_LAUNCH pid=\(host.processIdentifier) requested=\(application.processIdentifier)")
            guard host.processIdentifier == application.processIdentifier else {
                throw LiveFailure.unsupported("The document fixture reached a different Photoshop process")
            }
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground else {
            throw LiveFailure.unsupported("The document fixture did not restore its foreground")
        }
        guard fixtureReady else { throw DocumentFixtureFailure.activationNotReady }
        guard let snapshot, host != nil else {
            throw LiveFailure.unsupported("The Photoshop document fixture has no complete output")
        }
        if snapshot.hasPrefix("MECUM_ERROR\t") {
            let detail = snapshot.split(separator: "\n").first?.split(separator: "\t").last
                .flatMap { String($0).removingPercentEncoding } ?? "unreadable refusal"
            throw LiveFailure.unsupported("The scoped Photoshop document fixture refused: \(detail)")
        }
        completed = true
        return snapshot
    }

    /// activateNativeFixture is test-owned native setup, never a Driver route.
    /// Callers attest the sole PNG or the exact main window after modal withdrawal.
    /// Each request binds both process lifetimes, waits at most two seconds for
    /// its condition and verifies handback for 250 ms, including a refused request.
    /// No keyboard or pointer command is posted. The absent-main preflight
    /// explicitly requests the destination-bound native make-key pair.
    private func activateNativeFixture(
        _ target: WindowReference,
        usesKeyRecords: Bool = false,
        until ready: @MainActor () -> Bool
    ) async throws -> Bool {
        let person = UserSeatState.capture()
        let user = try #require(NSRunningApplication(processIdentifier: person.frontmostProcessID))
        try #require(user.processIdentifier != application.processIdentifier && !user.isTerminated)
        let userElement = AXUIElementCreateApplication(user.processIdentifier)
        AXUIElementSetMessagingTimeout(userElement, 0.1)
        var userWindow: WindowReference?
        let admitted = await LivePump.settle(until: {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == user.processIdentifier,
                  !user.isTerminated,
                  let focused = value(userElement, kAXFocusedWindowAttribute, as: AXUIElement.self,
                                      retryOnTimeout: false),
                  let number = WindowRelocator.windowNumber(of: focused),
                  let reference = WindowServerProbe.geometry(of: number),
                  reference.identity?.processID == user.processIdentifier,
                  let rows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]],
                  rows.contains(where: {
                      ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == number
                          && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == user.processIdentifier
                  }) else { return false }
            userWindow = reference
            return true
        }, timeout: 0.5)
        let destination = try #require(admitted ? userWindow : nil,
                                      "The native fixture has no attested foreground destination")
        try #require(target.identity?.processID == application.processIdentifier)
        let restorer = try UserFocusRestorer(allowUnvalidatedBuild: true, usesKeyRecords: usesKeyRecords)
        try restorer.prepare(target, targets: [target, destination])
        try #require(restorer.isFrontmost(processID: user.processIdentifier)
                     && UserSeatState.capture() == person && !application.isTerminated)
        let clock = ContinuousClock()
        let started = clock.now
        var requestFailure: (any Error)?
        var result = false
        do {
            let code = try restorer.restore(target)
            guard code == 0 else {
                throw LiveFailure.unsupported("The native fixture front request was refused: \(code)")
            }
            let elapsed = started.duration(to: clock.now).components
            let remaining = max(0, 2 - Double(elapsed.seconds) - Double(elapsed.attoseconds) / 1e18)
            result = await LivePump.settle(until: {
                guard !application.isTerminated,
                      restorer.isFrontmost(processID: application.processIdentifier),
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier
                else { return false }
                return ready()
            }, timeout: remaining)
        } catch { requestFailure = error }
        // Even a refused front request may have changed the foreground. Retain
        // the prepared PSNs and reattest only our original destination.
        if restorer.isFrontmost(processID: application.processIdentifier) {
            let renewed = try #require(WindowServerProbe.geometry(of: destination.windowNumber))
            try #require(renewed.hasSameIdentity(as: destination) && !user.isTerminated)
            try restorer.renewDestination(renewed)
            let code = try restorer.restore(renewed)
            try #require(code == 0, "The native fixture handback request was refused")
        }
        let returned = await LivePump.settle(until: {
            restorer.isFrontmost(processID: user.processIdentifier)
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == user.processIdentifier
        }, timeout: 0.25)
        try #require(returned && UserSeatState.capture() == person,
                     "The independent native fixture did not restore foreground and cursor")
        if let requestFailure { throw requestFailure }
        return result
    }

    /// Requires positive MainWindow identity and no remaining input-bearing modal.
    private func nativeDocumentFixtureTarget() throws -> WindowReference {
        let mainElement = try #require(value(element, kAXMainWindowAttribute, as: AXUIElement.self))
        let mainNumber = try #require(WindowRelocator.windowNumber(of: mainElement))
        let main = try #require(try windows().first { $0.number == mainNumber })
        let inventory = try windowsExcludingInertProxies(for: main)
        try #require(inventory.count == 1 && inventory[0].number == mainNumber
                     && main.role == kAXWindowRole && main.subrole != kAXDialogSubrole,
                     "Owned modal withdrawal must precede native document cleanup")
        let target = try #require(WindowServerProbe.geometry(of: mainNumber))
        try #require(target.identity?.processID == application.processIdentifier)
        return target
    }

    func dialog(excluding numbers: Set<Int>) -> Window? {
        try? windows().first { !numbers.contains($0.number) && $0.subrole == kAXDialogSubrole }
    }

    func contains(_ number: Int) -> Bool {
        (try? windows().contains { $0.number == number }) ?? true
    }

    /// Reads presentation independently from AX's retained UXP window objects.
    func presentedReading(_ window: Window) -> Bool? {
        guard let entries = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]],
              entries.contains(where: {
                  ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == application.processIdentifier
              })
        else { return nil }
        guard let entry = entries.first(where: {
            ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == window.number
                && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == application.processIdentifier
        }) else { return false }
        if let visible = (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue {
            return visible
        }
        guard let onScreen = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        return onScreen.contains(where: {
            ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == window.number
                && ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == application.processIdentifier
        })
    }

    /// Records only roles, Window IDs and focus facts after a refused command.
    /// No control value or document content is included in this diagnostic.
    func recordFocus(in window: Window) {
        print("UXP_MODAL_STATE window=\(window.number) on-screen=\(String(describing: presentedReading(window))) modal=\(String(describing: value(window.element, kAXModalAttribute, as: Bool.self)))")
        func describe(_ node: AXUIElement) -> String {
            let role = value(node, kAXRoleAttribute, as: String.self, retryOnTimeout: false) ?? "unreadable"
            let focus = value(node, kAXFocusedAttribute, as: Bool.self, retryOnTimeout: false)
            return "role=\(role) window=\(WindowRelocator.windowNumberReading(of: node)) focused=\(String(describing: focus))"
        }
        for attribute in [kAXFocusedWindowAttribute, kAXFocusedUIElementAttribute] {
            if let node = value(element, attribute, as: AXUIElement.self, retryOnTimeout: false) {
                print("UXP_FOCUS attribute=\(attribute) \(describe(node))")
            } else {
                print("UXP_FOCUS attribute=\(attribute) unreadable-or-absent")
            }
        }
        let deadline = Date().addingTimeInterval(1)
        var pending = [(window.element, 0)]
        var visited = 0
        while let (node, depth) = pending.popLast(), visited < 256, Date() < deadline {
            visited += 1
            print("UXP_FOCUS modal=\(window.number) depth=\(depth) \(describe(node))")
            if depth < 12 {
                let children = value(node, kAXChildrenAttribute, as: [AXUIElement].self, retryOnTimeout: false) ?? []
                pending.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        print("UXP_FOCUS modal=\(window.number) visited=\(visited) pending=\(pending.count)")
    }

    /// An unreadable menu is not ready. Each AX read uses the fast timeout so
    /// a loading UXP menu cannot stretch the brief-activation polling bound.
    func menuIsEnabled(_ path: [String]) -> Bool {
        menuEnabledReading(path) == true
    }

    /// Nil is unreadable; only a positively disabled item permits UXP refresh.
    func menuEnabledReading(_ path: [String]) -> Bool? {
        guard let node = try? menuItem(path) else { return nil }
        return value(node, kAXEnabledAttribute, as: Bool.self, retryOnTimeout: false)
    }

    /// Waits for a complete enabled reading after menu refresh. Only reads are
    /// retried; a failed or uncertain AX press is never replayed.
    func pressMenu(_ path: [String]) throws {
        var ready: AXUIElement?
        let readable = LivePump.run(until: {
            guard let node = try? menuItem(path),
                  value(node, kAXEnabledAttribute, as: Bool.self, retryOnTimeout: false) == true
            else { return false }
            ready = node
            return true
        }, timeout: 2)
        guard readable, let node = ready else {
            throw LiveFailure.unsupported("Photoshop menu did not become readable and enabled: \(path)")
        }
        try #require(AXUIElementPerformAction(node, kAXPressAction as CFString) == .success)
    }

    private func menuItem(_ path: [String]) throws -> AXUIElement {
        guard var node = value(element, kAXMenuBarAttribute, as: AXUIElement.self, retryOnTimeout: false)
        else { throw LiveFailure.unsupported("The Photoshop menu bar is unreadable") }
        for title in path {
            var children = value(node, kAXChildrenAttribute, as: [AXUIElement].self, retryOnTimeout: false) ?? []
            if children.count == 1, let menu = children.first,
               value(menu, kAXRoleAttribute, as: String.self, retryOnTimeout: false) == kAXMenuRole {
                children = value(menu, kAXChildrenAttribute, as: [AXUIElement].self, retryOnTimeout: false) ?? []
            }
            guard let item = children.first(where: {
                let actual = value($0, kAXTitleAttribute, as: String.self, retryOnTimeout: false) ?? ""
                return actual.replacingOccurrences(of: "...", with: "…")
                    == title.replacingOccurrences(of: "...", with: "…")
            }) else { throw LiveFailure.unsupported("Photoshop menu path is missing: \(path)") }
            node = item
        }
        return node
    }

    /// Returns measured controls from a bounded, complete AX reading. These
    /// frames select input points; they never substitute for an effect oracle.
    func controls(in window: Window, role: String) throws -> [AXUIElement] {
        var pending = [window.element]
        var controls: [AXUIElement] = []
        var visited = 0
        let deadline = Date().addingTimeInterval(2)
        while let node = pending.popLast() {
            guard visited < 1_024, Date() < deadline else {
                throw LiveFailure.unsupported("Photoshop controls exceeded the reading bound")
            }
            visited += 1
            guard let actualRole = value(node, kAXRoleAttribute, as: String.self) else {
                throw LiveFailure.unsupported("A Photoshop control role is unreadable")
            }
            if actualRole == role { controls.append(node) }
            var raw: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &raw)
            if status == .noValue || status == .attributeUnsupported { continue }
            guard status == .success, let children = raw as? [AXUIElement] else {
                throw LiveFailure.unsupported("Photoshop children are unreadable: \(status)")
            }
            pending.append(contentsOf: children)
        }
        return controls
    }

    func frame(of node: AXUIElement) -> CGRect? {
        guard let position = geometryValue(node, attribute: kAXPositionAttribute, type: .cgPoint),
              let size = geometryValue(node, attribute: kAXSizeAttribute, type: .cgSize) else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point),
              AXValueGetValue(size, .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite,
              dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    func buttonFrame(in window: Window, named name: String) -> CGRect? {
        guard let buttons = try? controls(in: window, role: kAXButtonRole),
              let button = buttons.first(where: {
                  let label = value($0, kAXTitleAttribute, as: String.self)
                    ?? value($0, kAXDescriptionAttribute, as: String.self)
                return label?.replacingOccurrences(of: "’", with: "'") == name
              }) else { return nil }
        return frame(of: button)
    }

    /// Cancels only a positively identified row-owned dialog after directed
    /// cleanup fails. Native AX cleanup is never input qualification evidence.
    func cancelOwnedDialog(_ dialog: Window) throws {
        guard !application.isTerminated else {
            throw LiveFailure.unsupported("The Photoshop cleanup host terminated")
        }
        guard let current = try windows().first(where: { $0.number == dialog.number }) else { return }
        try #require(current.subrole == kAXDialogSubrole && CFEqual(current.element, dialog.element))
        try #require(WindowServerProbe.geometry(of: current.number)?.processID == application.processIdentifier)
        let buttons = try controls(in: current, role: kAXButtonRole).filter {
            let label = value($0, kAXTitleAttribute, as: String.self)
                ?? value($0, kAXDescriptionAttribute, as: String.self)
            return label == "Cancel" && value($0, kAXEnabledAttribute, as: Bool.self) == true
        }
        try #require(buttons.count == 1, "Native cleanup requires one exact enabled Cancel button")
        try #require(AXUIElementPerformAction(buttons[0], kAXPressAction as CFString) == .success)
        try #require(LivePump.run(until: {
            !contains(current.number) && presentedReading(current) == false
        }, timeout: 5), "The owned dialog did not independently withdraw after native cleanup")
    }

    /// Checks the CF type before extracting AX geometry; a conditional Swift
    /// cast alone does not validate an AXValue received as CFTypeRef.
    private func geometryValue(
        _ node   : AXUIElement,
        attribute: String,
        type     : AXValueType
    ) -> AXValue? {
        guard let raw = value(node, attribute, as: CFTypeRef.self),
              CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }
        let value = unsafeDowncast(raw, to: AXValue.self)
        return AXValueGetType(value) == type ? value : nil
    }

}
