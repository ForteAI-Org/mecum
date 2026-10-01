import BrowserCore
import Foundation

extension ChromeBrowser {
    struct NodeReference: Sendable {
        let backendID: Double
        let frame: String
        let role: String
        let name: String
    }

    struct Observation: Sendable {
        let id: String
        let document: CDPValue
        let references: [String: NodeReference]
    }

    public func snapshot(tab: String, options: BrowserObservationOptions) async throws -> BrowserSnapshot {
        try begin()
        defer { busy = false }
        observations.removeValue(forKey: tab)
        let session = try await attach(tab)
        if await connection?.currentDialog(sessionID: session) != nil {
            throw BrowserFailure(.unavailable, "A JavaScript dialog blocks this page. Use browser_dialog and browser_handle_dialog.")
        }
        _ = try await command("Runtime.releaseObjectGroup", ["objectGroup": .string("mecum-browser")], session: session)
        let page = try await target(tab)
        let before = try await document(session)
        var references: [String: NodeReference] = [:]
        var nodes: [BrowserNode] = []
        var frameRows: [(String, [CDPValue])] = []
        var limitations: [String] = []
        let frames = Self.frames(before)
        guard !frames.isEmpty else { throw malformed("Page.getFrameTree") }
        for frame in frames {
            guard let frameID = frame["id"].string else { continue }
            let result: CDPValue
            do {
                result = try await command("Accessibility.getFullAXTree", ["frameId": .string(frameID)], session: session)
            } catch let failure as BrowserFailure where failure.code == .protocolError {
                limitations.append("Frame \(frameID) could not be read: \(failure.message). Out-of-process frames may require a separate adapter.")
                continue
            }
            guard let rows = result["nodes"].array else { throw malformed("Accessibility.getFullAXTree") }
            frameRows.append((frameID, rows))
        }
        let tree = AXSnapshotSelection(frames: frameRows)
        let selection = try tree.select(options)
        limitations += selection.limitations
        let refs = Dictionary(uniqueKeysWithValues: selection.entries.enumerated().map { ($0.element.key, "e\($0.offset + 1)") })
        for entry in selection.entries {
            guard let backendID = entry.row["backendDOMNodeId"].number, let ref = refs[entry.key] else { continue }
            var states: [String: String] = [:]
            for property in entry.row["properties"].array ?? [] {
                if let key = property["name"].string,
                   ["disabled", "checked", "selected", "expanded", "focused", "required", "readonly", "multiselectable"].contains(key),
                   let value = property["value"]["value"].scalar { states[key] = value }
            }
            // Editable values stay private; fill verifies internally without echoing secrets.
            let value = ["textbox", "searchbox", "combobox"].contains(entry.role) ? nil : entry.row["value"]["value"].scalar
            let parent = tree.ancestry(of: entry.key).compactMap { refs[$0] }.first
            nodes.append(BrowserNode(ref: ref, frame: entry.frame, role: entry.role, name: String(entry.name.prefix(512)),
                value: value.map { String($0.prefix(512)) }, states: states, parent: parent))
            references[ref] = NodeReference(backendID: backendID, frame: entry.frame, role: entry.role, name: entry.name)
        }
        guard try await document(session) == before else {
            throw BrowserFailure(.staleReference, "The page navigated during observation. Observe again.")
        }
        let id = UUID().uuidString
        observations[tab] = Observation(id: id, document: before, references: references)
        return BrowserSnapshot(id: id, tab: page, nodes: nodes, limitations: limitations, scope: selection.scope)
    }

    static let actionableRoles: Set<String> = ["button", "link", "textbox", "searchbox", "combobox", "checkbox",
        "radio", "switch", "slider", "spinbutton", "tab", "menuitem", "option", "listbox"]

    func document(_ session: String) async throws -> CDPValue {
        let result = try await command("Page.getFrameTree", session: session)
        guard result["frameTree"].object != nil else { throw malformed("Page.getFrameTree") }
        return Self.documentIdentity(result["frameTree"])
    }

    static func documentIdentity(_ tree: CDPValue) -> CDPValue {
        let frame = tree["frame"]
        return .object(["frame": .object(["id": frame["id"], "loaderId": frame["loaderId"], "url": frame["url"]]),
            "childFrames": .array((tree["childFrames"].array ?? []).map(documentIdentity))])
    }

    static func frames(_ tree: CDPValue) -> [CDPValue] {
        [tree["frame"]] + (tree["childFrames"].array ?? []).flatMap(frames)
    }

    func resolve(_ ref: String, tab: String, snapshot: String?, session: String) async throws -> (String, NodeReference) {
        guard let observation = observations[tab], observation.id == snapshot,
              let reference = observation.references[ref] else {
            throw BrowserFailure(.staleReference, "Use a reference and snapshot ID from the latest browser_snapshot for this tab.")
        }
        guard try await document(session) == observation.document else {
            observations.removeValue(forKey: tab)
            throw BrowserFailure(.staleReference, "The document or frame changed. Observe again before acting.")
        }
        let tree = try await command("Accessibility.getPartialAXTree", ["backendNodeId": .number(reference.backendID),
            "fetchRelatives": .bool(false)], session: session)
        guard let node = tree["nodes"].array?.first(where: { $0["backendDOMNodeId"].number == reference.backendID }),
              node["ignored"].bool != true, node["role"]["value"].string == reference.role,
              (node["name"]["value"].string ?? "") == reference.name,
              !(node["properties"].array ?? []).contains(where: { $0["name"].string == "disabled" && $0["value"]["value"].bool == true }) else {
            throw BrowserFailure(.staleReference, "The element disappeared, changed meaning or became disabled. Observe again.")
        }
        let result = try await command("DOM.resolveNode", ["backendNodeId": .number(reference.backendID), "objectGroup": .string("mecum-browser")], session: session)
        guard let object = result["object"]["objectId"].string else { throw malformed("DOM.resolveNode") }
        return (object, reference)
    }

    func onNode(_ object: String, function: String, arguments: [CDPValue] = [], session: String) async throws -> CDPValue {
        let result = try await command("Runtime.callFunctionOn", ["objectId": .string(object),
            "functionDeclaration": .string(function), "arguments": .array(arguments.map { .object(["value": $0]) }),
            "returnByValue": .bool(true), "awaitPromise": .bool(false)], session: session)
        if result["exceptionDetails"] != .null { throw BrowserFailure(.unavailable, "The page rejected the DOM operation.") }
        return result["result"]["value"]
    }

    public func screenshot(tab: String) async throws -> Data {
        try begin()
        defer { busy = false }
        let session = try await attach(tab)
        let result = try await command("Page.captureScreenshot", ["format": .string("png"),
            "captureBeyondViewport": .bool(false)], session: session)
        guard let encoded = result["data"].string, let data = Data(base64Encoded: encoded) else {
            throw malformed("Page.captureScreenshot")
        }
        return data
    }

    public func dialog(tab: String) async throws -> BrowserDialog? {
        try begin()
        defer { busy = false }
        let session = try await attach(tab)
        return await connection?.currentDialog(sessionID: session)
    }

    public func handleDialog(tab: String, accept: Bool, text: String?) async throws -> BrowserReceipt {
        try begin()
        defer { busy = false }
        let session = try await attach(tab)
        guard await connection?.currentDialog(sessionID: session) != nil else {
            throw BrowserFailure(.unavailable, "No JavaScript dialog has been observed on this attached tab.")
        }
        var params: [String: CDPValue] = ["accept": .bool(accept)]
        if let text { params["promptText"] = .string(text) }
        observations.removeValue(forKey: tab)
        _ = try await command("Page.handleJavaScriptDialog", params, session: session)
        return BrowserReceipt(.delivered, "Dialog response sent once. Observe the resulting page.")
    }
}
