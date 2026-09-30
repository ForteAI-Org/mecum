//
//  DialogEndpointResolver.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 19/09/2026.
//

import ApplicationServices
import CoreGraphics
import Dispatch
import PrivateSymbols
import SeatCore
import WindowPlacement

/// Why a discovery produced no endpoint. Every case is a refusal with its
/// reason, and none of them is a licence to address the host instead: an
/// application that is modally blocked does not receive the events its own
/// dialog was meant to receive.
nonisolated public enum InputEndpointRefusal: Error, Sendable, Equatable {

    /// Accessibility answered no element at the point, twice.
    case noNodeAtPoint

    /// The point is outside the surface the seat is operating, so nothing here
    /// can attest a relation to it.
    case pointOutsideSurface

    /// Accessibility gave no node the discovery could stand on, or no node of
    /// the descent answered a Window ID: an incomplete subtree. It is not read
    /// as "this is the host's window", because a read that failed is not an
    /// answer.
    case subtreeUnreadable(surface: WindowIdentity)

    /// The Window ID the node named has no complete WindowServer identity.
    case identityUnattested(windowNumber: Int)

    /// The identity changed between the two readings that bracket the geometry:
    /// the window closed, its id was handed out again, or the helper that owned
    /// it was replaced.
    case identityChangedDuringDiscovery(windowNumber: Int)

    /// The window's geometry could not be read, from the public list or from
    /// the qualified reading for a window that list does not enumerate.
    case geometryUnavailable(windowNumber: Int)

    /// The window is real and attested and is not drawn inside the surface the
    /// seat is operating: another panel of the same service is the case that
    /// exists, and it is somebody else's.
    case notContainedInSurface(windowNumber: Int)

    /// The facts are complete and do not form one coherent recipient.
    case incoherentEndpoint(windowNumber: Int)
}

/// DialogEndpointResolver discovers which window the events of one Command have
/// to reach, starting from the assigned application and the modal relation the
/// seat already observed.
///
/// ## Why it exists
///
/// Measured on 26A428 against Slack's open panel: the sheet belonged to the
/// host application, and the panel's content was a separate window server
/// window owned by a different connection and a different process, absent from
/// the public window list. `AXUIElementGetPid` on the Cancel button kept
/// answering the host's PID; `_AXUIElementGetWindow` on that same element
/// answered the remote Window ID. Classifying the whole application as one
/// framework does not address that, and neither does the sheet: three clicks
/// worked only once the Window ID, the owner connection and the PID were all
/// three the content's.
///
/// ## What it reads, and what it never does
///
/// Every reading is observational. The hit test, the descent and the identity
/// chain observe geometry, relations and state; nothing here presses anything,
/// writes a focus or activates a process.
///
/// It is generic over the node type so the whole decision table can be proved
/// without a window on the screen. The shipping seat instantiates it over
/// `AXUIElement` with the kit's own readers; the Unit tier instantiates it over
/// a value it can make disagree with itself between two readings, which is the
/// only way to exercise a reused Window ID or a replaced helper.
nonisolated package struct DialogEndpointResolver<Node> {

    /// A children read distinguishes a leaf from an accessibility request that
    /// did not answer. Treating the latter as an empty array used to leave the
    /// proxy's Window ID selected when the concrete panel subtree was unreadable.
    package enum ChildReading {
        case children([Node])
        case leaf
        case unreadable
    }

    /// A missing focused control is a valid AX answer. A failed read is not.
    package enum FocusedControlReading {
        case node(Node)
        case absent
        case unreadable
    }

    /// One descendant's focused attribute. A missing or unsupported attribute
    /// simply does not nominate that node; a malformed read means the subtree
    /// cannot be completed and therefore refuses the keyboard route.
    package enum DescendantFocusReading {
        case focused
        case unfocused
        case notApplicable
        case unreadable
    }

    /// The complete, typed facts an AX leaf must establish before the ordinary
    /// keyboard route may treat its private Window ID as decoration rather than
    /// remote content. Every optional answer is required: an absent, failed, or
    /// unsupported attribute remains input-bearing and therefore refuses.
    package struct InertWindowlessLeafFacts: Equatable {
        package let role: String?
        package let axWindowWasNoValue: Bool
        package let focused: Bool?
        package let focusedIsSettable: Bool?
        package let actions: Set<String>?

        package init(
            role: String?,
            axWindowWasNoValue: Bool,
            focused: Bool?,
            focusedIsSettable: Bool?,
            actions: Set<String>?
        ) {
            self.role = role
            self.axWindowWasNoValue = axWindowWasNoValue
            self.focused = focused
            self.focusedIsSettable = focusedIsSettable
            self.actions = actions
        }
    }

    /// The pure policy behind the shipping AX adapter. It is deliberately
    /// narrow: the resolver separately proves a complete empty child list,
    /// non-root position and the assigned process before calling it.
    package static func inertWindowlessLeaf(_ facts: InertWindowlessLeafFacts) -> Bool {
        facts.role == kAXGroupRole as String
            && facts.axWindowWasNoValue
            && facts.focused == false
            && facts.focusedIsSettable == false
            && facts.actions?.isEmpty == true
    }

    /// The chain the seat has already attested: the host, the surface it is
    /// operating, and that surface's current window server rectangle. A
    /// discovery may only attest a relation to **this** surface; it never
    /// learns a parent from a helper's name, its parent process or a PID found
    /// somewhere else.
    nonisolated package struct SurfaceChain: Sendable, Equatable {

        package let host        : WindowIdentity
        package let surface     : WindowIdentity
        package let surfaceFrame: CGRect

        package init(host: WindowIdentity, surface: WindowIdentity, surfaceFrame: CGRect) {
            self.host         = host
            self.surface      = surface
            self.surfaceFrame = surfaceFrame
        }
    }

    /// How far the descent may go below the node the hit test answered. The
    /// hit test already returns the deepest element the application reports,
    /// and for a hosted panel that is the sheet, so what is left is the
    /// proxied subtree underneath it.
    package static var maximumDepth: Int { 12 }

    /// How long a resolved endpoint may be used before it has to be resolved
    /// again. It is short on purpose: the endpoint is resolved immediately
    /// before the Command is handed to the driver, and the driver re-reads
    /// identity and geometry again before its first post.
    package static var lifetimeNanoseconds: UInt64 { 500_000_000 }

    let nodeAtPoint : (CGPoint) -> Node?
    let focusedNode : () -> Node?
    let children    : (Node) -> ChildReading
    let nodeFrame   : (Node) -> CGRect?
    let nodeWindow  : (Node) -> Int?
    let nodeProcess : (Node) -> Int32?
    let identity    : (Int) -> WindowIdentity?
    let geometry    : (Int, CGRect) -> WindowGeometryObservation?
    let now         : () -> UInt64
    let focusedControl: () -> FocusedControlReading
    let focusedWindow: () -> Node?
    let windowNode   : (Int) -> Node?
    let inertWindowlessLeaf: (Node) -> Bool
    let descendantFocus: (Node) -> DescendantFocusReading

    package init(
        nodeAtPoint : @escaping (CGPoint) -> Node?,
        focusedNode : @escaping () -> Node?,
        children    : @escaping (Node) -> ChildReading,
        nodeFrame   : @escaping (Node) -> CGRect?,
        nodeWindow  : @escaping (Node) -> Int?,
        nodeProcess : @escaping (Node) -> Int32?,
        identity    : @escaping (Int) -> WindowIdentity?,
        geometry    : @escaping (Int, CGRect) -> WindowGeometryObservation?,
        now         : @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        focusedControl: (() -> FocusedControlReading)? = nil,
        focusedWindow: (() -> Node?)? = nil,
        windowNode   : @escaping (Int) -> Node? = { _ in nil },
        inertWindowlessLeaf: @escaping (Node) -> Bool = { _ in false },
        descendantFocus: @escaping (Node) -> DescendantFocusReading = { _ in .unreadable }
    ) {
        self.nodeAtPoint = nodeAtPoint
        self.focusedNode = focusedNode
        self.children    = children
        self.nodeFrame   = nodeFrame
        self.nodeWindow  = nodeWindow
        self.nodeProcess = nodeProcess
        self.identity    = identity
        self.geometry    = geometry
        self.now         = now
        self.focusedControl = focusedControl ?? {
            focusedNode().map(FocusedControlReading.node) ?? .unreadable
        }
        self.focusedWindow = focusedWindow ?? { nil }
        self.windowNode    = windowNode
        self.inertWindowlessLeaf = inertWindowlessLeaf
        self.descendantFocus = descendantFocus
    }

    /// Resolves window-level keys when AX explicitly reports no focused control.
    ///
    /// A complete input-bearing subtree containing only this window distinguishes
    /// an ordinary window from a standalone panel proxy. A foreign or unreadable
    /// descendant refuses, except for a complete, non-root AXGroup leaf that
    /// independently proves it is inert windowless decoration.
    package func ordinaryKeyboardContext(
        within chain: SurfaceChain,
        selectionGeneration: UInt64
    ) -> Result<ResolvedInputEndpoint, InputEndpointRefusal> {
        let refusal = InputEndpointRefusal.subtreeUnreadable(surface: chain.surface)
        let (deadline, overflow) = now().addingReportingOverflow(300_000_000)
        guard !overflow else { return .failure(refusal) }
        guard chain.host == chain.surface,
              case .absent = focusedControl(),
              let window = focusedWindow(),
              nodeWindow(window) == chain.surface.windowNumber,
              nodeProcess(window) == chain.surface.processID,
              identity(chain.surface.windowNumber) == chain.surface
        else { return .failure(refusal) }

        var pending: [(Node, Int)] = [(window, 0)]
        var visited = 0
        while let (node, depth) = pending.popLast() {
            guard now() < deadline, depth <= 64, visited < 1_024,
                  nodeProcess(node) == chain.surface.processID
            else { return .failure(refusal) }
            visited += 1
            switch children(node) {
            case .leaf:
                // `.leaf` is an AX no-value or unsupported children answer. It
                // remains a valid same-window leaf, but can never establish the
                // complete empty-child fact required to ignore a foreign ID.
                let windowNumber = nodeWindow(node)
                guard windowNumber == chain.surface.windowNumber else {
                    return .failure(refusal)
                }
            case .unreadable: return .failure(refusal)
            case .children(let values):
                let windowNumber = nodeWindow(node)
                if values.isEmpty,
                   depth > 0,
                   windowNumber != chain.surface.windowNumber,
                   inertWindowlessLeaf(node) {
                    continue
                }
                guard windowNumber == chain.surface.windowNumber else {
                    return .failure(refusal)
                }
                guard values.count <= 1_024 - visited - pending.count else {
                    return .failure(refusal)
                }
                pending.append(contentsOf: values.map { ($0, depth + 1) })
            }
        }
        guard now() < deadline,
              case .absent = focusedControl(),
              let finalWindow = focusedWindow(),
              nodeWindow(finalWindow) == chain.surface.windowNumber,
              nodeProcess(finalWindow) == chain.surface.processID
        else { return .failure(refusal) }

        let answer = endpoint(
            kind: .keyboardContext,
            windowNumber: chain.surface.windowNumber,
            accessibilityProcessID: chain.surface.processID,
            within: chain,
            selectionGeneration: selectionGeneration,
            focusedNodeWindowNumber: chain.surface.windowNumber,
            evidence: .focusedWindowWithoutFocusedControl
        )
        guard now() < deadline else { return .failure(refusal) }
        if case .success(let resolved) = answer, resolved.identity != chain.surface {
            return .failure(.identityChangedDuringDiscovery(windowNumber: chain.surface.windowNumber))
        }
        return answer
    }

    /// Resolves keys for an attested modal surface only when AX explicitly says
    /// there is no focused control, but a complete scan finds one recipient
    /// window among its focused descendants. The remote child of a sheet is not
    /// enough by itself: only positive `AXFocused` values can nominate its
    /// WindowServer recipient. Descendants may belong to the panel helper; each
    /// must merely name a live AX process, while `endpoint` attests ownership.
    package func focusedDescendantKeyboardContext(
        within chain: SurfaceChain,
        selectionGeneration: UInt64
    ) -> Result<ResolvedInputEndpoint, InputEndpointRefusal> {
        let refusal = InputEndpointRefusal.subtreeUnreadable(surface: chain.surface)
        let (deadline, overflow) = now().addingReportingOverflow(300_000_000)
        guard !overflow,
              case .absent = focusedControl(),
              let window = focusedWindow(),
              focusedWindow(window, matches: chain)
        else { return .failure(refusal) }

        let focusedCandidate = focusedDescendantWindow(under: window, includingRoot: true, before: deadline)

        guard now() < deadline,
              let focusedCandidate,
              case .absent = focusedControl(),
              let finalWindow = focusedWindow(),
              focusedWindow(finalWindow, matches: chain)
        else { return .failure(refusal) }

        let answer = endpoint(
            kind: .keyboardContext,
            windowNumber: focusedCandidate.windowNumber,
            accessibilityProcessID: focusedCandidate.accessibilityProcessID,
            within: chain,
            selectionGeneration: selectionGeneration,
            focusedNodeWindowNumber: focusedCandidate.windowNumber,
            evidence: .focusedSurfaceDescendant
        )
        guard now() < deadline else { return .failure(refusal) }
        return answer
    }

    /// The window one mouse gesture has to be posted to.
    ///
    /// The point is the one the Command carries in screen coordinates. It has
    /// to be inside the attested surface: a point outside it belongs to no
    /// relation this discovery may state, and is refused rather than answered
    /// with the window underneath.
    package func pointerEndpoint(
        at point           : CGPoint,
        within chain       : SurfaceChain,
        selectionGeneration: UInt64
    ) -> Result<ResolvedInputEndpoint, InputEndpointRefusal> {

        guard chain.surfaceFrame.contains(point) else { return .failure(.pointOutsideSurface) }

        // An ambiguous reading gets one more bounded read and then a reason.
        guard let seed = nodeAtPoint(point) ?? nodeAtPoint(point) else {
            return .failure(.noNodeAtPoint)
        }
        let descended: (node: Node, windowNumber: Int?)
        switch descend(from: seed, to: point) {
        case .success(let result): descended = result
        case .failure(.windowless(let accessibilityProcessID, let windowAbove)):
            // Only a node that sits straight on the surface: one below a remote
            // group that stopped answering is a recipient gone, not a sheet.
            guard windowAbove == chain.surface.windowNumber,
                  nodeWindow(seed) == chain.surface.windowNumber,
                  let remote = remoteContentWindow(of: seed, within: chain)
            else { return .failure(.subtreeUnreadable(surface: chain.surface)) }
            return endpoint(
                kind                   : .pointer,
                windowNumber           : remote,
                accessibilityProcessID : accessibilityProcessID,
                within                 : chain,
                selectionGeneration    : selectionGeneration,
                focusedNodeWindowNumber: nil,
                evidence               : .remoteContentOfSurface
            )
        case .failure: return .failure(.subtreeUnreadable(surface: chain.surface))
        }
        guard let windowNumber = descended.windowNumber,
              let accessibilityProcessID = nodeProcess(descended.node)
                  ?? nodeProcess(descended.node)
        else { return .failure(.subtreeUnreadable(surface: chain.surface)) }

        return endpoint(
            kind                   : .pointer,
            windowNumber           : windowNumber,
            accessibilityProcessID : accessibilityProcessID,
            within                 : chain,
            selectionGeneration    : selectionGeneration,
            focusedNodeWindowNumber: nil
        )
    }

    /// The surface itself, for a window accessibility shows as a single leaf.
    ///
    /// Measured on 30/09/2026 with Photoshop's New Document, a top-level modal
    /// that draws its whole interface in a view accessibility reads no child
    /// of: the hit test inside it answered a node of the Home window behind it,
    /// or nothing at all, and the application's focused control was absent or
    /// in that same window. Neither is a recipient inside the dialog, and the
    /// dialog is the only window its application lets act. Nothing inside a
    /// leaf can be a different recipient, so when the surface's own
    /// `AXWindows` entry has no children, the events go to the surface, for a
    /// gesture and for a key. A sheet or a hosted panel is never answered
    /// here: its host is another window.
    ///
    /// The entry is looked up by its Window ID and not taken from the
    /// application's focused window: the same run's first session read the
    /// focus, like the hit test, on the Home window behind the dialog.
    package func leafSurfaceEndpoint(
        kind               : InputEndpointKind,
        within chain       : SurfaceChain,
        selectionGeneration: UInt64
    ) -> Result<ResolvedInputEndpoint, InputEndpointRefusal> {

        let refusal = InputEndpointRefusal.subtreeUnreadable(surface: chain.surface)
        guard chain.host == chain.surface else { return .failure(refusal) }
        guard let window = windowNode(chain.surface.windowNumber),
              focusedWindow(window, matches: chain)
        else { return .failure(.identityUnattested(windowNumber: chain.surface.windowNumber)) }
        switch children(window) {
            case .leaf: break
            case .children(let values) where values.isEmpty: break
            case .children, .unreadable: return .failure(refusal)
        }
        return endpoint(
            kind                   : kind,
            windowNumber           : chain.surface.windowNumber,
            accessibilityProcessID : chain.surface.processID,
            within                 : chain,
            selectionGeneration    : selectionGeneration,
            focusedNodeWindowNumber: nil,
            evidence               : .leafSurface
        )
    }

    /// The one remote content window of a modal surface, for keys, when the
    /// application's focus cannot be read at all.
    ///
    /// An unreadable focus used to refuse the keys outright. On a panel an out
    /// of process service draws, the first responder may be the service's, and
    /// accessibility does not report it, as on DaVinci Resolve's panels. So when
    /// the surface's descendants name exactly one window of another process
    /// drawn over the whole surface, that window is the recipient, attested by
    /// `endpoint` like any other; see `foreignContentWindow`. The caller asks
    /// this only of an attested modal surface.
    ///
    /// A focus on the surface's own window node is not answered here, and keeps
    /// the surface as its recipient. Measured on 30/09/2026 with Photoshop's
    /// Save As panel opened in the background, focus on the panel's window
    /// node: `/` to the service's window did nothing, 2 of 2 through this route
    /// and 3 of 3 by hand with and without the host primed, since no control of
    /// the panel had the focus; Escape to the panel window itself closed it. A
    /// click on the name field focused it, and `/` then opened Go to Folder, 2
    /// of 2. An absent focus is not answered here either: that is
    /// `focusedDescendantKeyboardContext`, which asks for a positive focused
    /// fact.
    ///
    /// The surface's node is its `AXWindows` entry, looked up by Window ID as in
    /// `leafSurfaceEndpoint`: the application's focused window lags behind the
    /// panel in the same application.
    package func remoteContentKeyboardContext(
        within chain       : SurfaceChain,
        selectionGeneration: UInt64
    ) -> Result<ResolvedInputEndpoint, InputEndpointRefusal> {

        let refusal = InputEndpointRefusal.subtreeUnreadable(surface: chain.surface)
        guard case .unreadable = focusedControl() else { return .failure(refusal) }
        guard let window = windowNode(chain.surface.windowNumber),
              focusedWindow(window, matches: chain)
        else { return .failure(.identityUnattested(windowNumber: chain.surface.windowNumber)) }
        guard let remote = foreignContentWindow(of: window, within: chain) else {
            return .failure(refusal)
        }
        return endpoint(
            kind                   : .keyboardContext,
            windowNumber           : remote,
            accessibilityProcessID : chain.surface.processID,
            within                 : chain,
            selectionGeneration    : selectionGeneration,
            focusedNodeWindowNumber: remote,
            evidence               : .remoteContentOfSurface
        )
    }

    /// The one foreign content window of a modal surface, for keys, when the
    /// application's focus reads as the surface's own window node and a
    /// descendant in that content window is focused.
    ///
    /// Measured on 30/09/2026 with Photoshop's Save As panel: after a click on
    /// the name field, `AXFocused` was true on the field, which answers the
    /// panel service's window, and on the panel's window node, while the
    /// application's focused element stayed the window node. `/` sent to the
    /// service's window then opened Go to Folder, 2 of 2. On a fresh panel only
    /// the window node is focused, and the surface stays the recipient, where
    /// Escape closed the panel. So the window node is no candidate, the focused
    /// descendants have to name one window, and that window has to be the one
    /// `foreignContentWindow` answers; anything else keeps the surface.
    package func focusedContentKeyboardContext(
        within chain       : SurfaceChain,
        selectionGeneration: UInt64
    ) -> Result<ResolvedInputEndpoint, InputEndpointRefusal> where Node: Equatable {

        let refusal = InputEndpointRefusal.subtreeUnreadable(surface: chain.surface)
        let (deadline, overflow) = now().addingReportingOverflow(300_000_000)
        guard !overflow else { return .failure(refusal) }
        guard let window = windowNode(chain.surface.windowNumber),
              focusedWindow(window, matches: chain)
        else { return .failure(.identityUnattested(windowNumber: chain.surface.windowNumber)) }
        guard case .node(let focused) = focusedControl(), focused == window,
              let candidate = focusedDescendantWindow(under: window, includingRoot: false, before: deadline),
              let content = foreignContentWindow(of: window, within: chain),
              candidate.windowNumber == content
        else { return .failure(refusal) }
        return endpoint(
            kind                   : .keyboardContext,
            windowNumber           : content,
            accessibilityProcessID : candidate.accessibilityProcessID,
            within                 : chain,
            selectionGeneration    : selectionGeneration,
            focusedNodeWindowNumber: content,
            evidence               : .focusedSurfaceDescendant
        )
    }

    /// The window the keys of one Command have to be posted to.
    ///
    /// It is resolved from the focused node of the surface and from no mouse
    /// point at all: a key has no coordinate, and the last place the pointer
    /// went is not evidence about where the keys go. The focused node's own
    /// window is recorded on the endpoint, so a focus that moves to another
    /// window retires the context even while this window is alive.
    package func keyboardContext(
        within chain       : SurfaceChain,
        selectionGeneration: UInt64
    ) -> Result<ResolvedInputEndpoint, InputEndpointRefusal> {

        guard let focused = focusedNode() ?? focusedNode() else {
            return .failure(.subtreeUnreadable(surface: chain.surface))
        }
        guard let accessibilityProcessID = nodeProcess(focused) ?? nodeProcess(focused)
        else { return .failure(.subtreeUnreadable(surface: chain.surface)) }
        guard let windowNumber = nodeWindow(focused) ?? nodeWindow(focused) else {
            // A control of an out of process sheet answers no Window ID at all.
            // The surface it sits in may still name its remote content window.
            guard let frame = nodeFrame(focused), chain.surfaceFrame.contains(frame),
                  let surfaceNode = focusedWindow(), focusedWindow(surfaceNode, matches: chain),
                  let remote = remoteContentWindow(of: surfaceNode, within: chain)
            else { return .failure(.subtreeUnreadable(surface: chain.surface)) }
            return endpoint(
                kind                   : .keyboardContext,
                windowNumber           : remote,
                accessibilityProcessID : accessibilityProcessID,
                within                 : chain,
                selectionGeneration    : selectionGeneration,
                focusedNodeWindowNumber: remote,
                evidence               : .remoteContentOfSurface
            )
        }

        return endpoint(
            kind                   : .keyboardContext,
            windowNumber           : windowNumber,
            accessibilityProcessID : accessibilityProcessID,
            within                 : chain,
            selectionGeneration    : selectionGeneration,
            focusedNodeWindowNumber: windowNumber
        )
    }

    /// The window the internal focus is in right now, `nil` when nothing
    /// answers.
    ///
    /// It is the one reading a keyboard context is revalidated against before
    /// the Command is handed over: the endpoint's own window can be alive and
    /// unchanged while the focus has moved to another one, and keys sent then
    /// would arrive somewhere nobody looked. An unreadable focus is not the
    /// same answer as an unchanged one, which is why `nil` retires the context
    /// instead of leaving it standing.
    package func focusedNodeWindowNumber() -> Int? {
        guard let focused = focusedNode() ?? focusedNode() else { return nil }
        return nodeWindow(focused) ?? nodeWindow(focused)
    }

    /// The attestation both kinds share, from a Window ID a node named.
    ///
    /// The identity chain is read before the geometry and again after it, and
    /// the geometry has to carry the same identity: three readings that agree,
    /// so a Window ID reassigned between them refuses instead of being posted
    /// to. The containment is what ties the window to **this** surface, which
    /// is why a helper's name, its parent process and its PID are never asked.
    private func endpoint(
        kind                   : InputEndpointKind,
        windowNumber           : Int,
        accessibilityProcessID : Int32,
        within chain           : SurfaceChain,
        selectionGeneration    : UInt64,
        focusedNodeWindowNumber: Int?,
        evidence               : InputEndpointEvidence? = nil
    ) -> Result<ResolvedInputEndpoint, InputEndpointRefusal> {

        guard let first = identity(windowNumber) ?? identity(windowNumber),
              first.windowNumber == windowNumber
        else { return .failure(.identityUnattested(windowNumber: windowNumber)) }

        guard let observation = geometry(windowNumber, chain.surfaceFrame) else {
            return .failure(.geometryUnavailable(windowNumber: windowNumber))
        }
        guard observation.window.identity == first else {
            return .failure(.identityChangedDuringDiscovery(windowNumber: windowNumber))
        }
        // The leg that says the window belongs to this panel and not to
        // another one the same service is hosting.
        guard chain.surfaceFrame.contains(observation.window.frame) else {
            return .failure(.notContainedInSurface(windowNumber: windowNumber))
        }
        guard let second = identity(windowNumber), second == first else {
            return .failure(.identityChangedDuringDiscovery(windowNumber: windowNumber))
        }

        let resolvedAt = now()
        guard let endpoint = ResolvedInputEndpoint(
            kind                   : kind,
            geometry               : observation,
            evidence               : evidence ?? (first == chain.surface
                ? .attestedSurfaceItself
                : .accessibilityNodeIdentity),
            relation               : first == chain.surface ? .logicalSurface : .remoteContent,
            logicalSurface         : chain.surface,
            accessibilityProcessID : accessibilityProcessID,
            selectionGeneration    : selectionGeneration,
            resolvedAtNanoseconds  : resolvedAt,
            expiresAtNanoseconds   : resolvedAt &+ Self.lifetimeNanoseconds,
            focusedNodeWindowNumber: focusedNodeWindowNumber
        ) else {
            return .failure(.incoherentEndpoint(windowNumber: windowNumber))
        }
        return .success(endpoint)
    }

    /// The application-level focused window remains evidence only when it is
    /// the exact selected logical surface, with the frame that framed this
    /// command. A sheet that changed or a different focused window cannot lend
    /// its descendants to the current modal route.
    private func focusedWindow(_ node: Node, matches chain: SurfaceChain) -> Bool {
        guard nodeWindow(node) == chain.surface.windowNumber,
              nodeProcess(node) == chain.surface.processID,
              identity(chain.surface.windowNumber) == chain.surface,
              let observation = geometry(chain.surface.windowNumber, chain.surfaceFrame),
              observation.window.identity == chain.surface,
              observation.window.frame == chain.surfaceFrame
        else { return false }
        return true
    }

    /// The one window other than the surface that the surface's descendants
    /// name, nil when they name none, more than one, or cannot be read whole.
    ///
    /// Measured on 27 on DaVinci Resolve's Go to Folder sheet: the sheet
    /// answers the host's window, its text field and buttons answer no Window
    /// ID at all (`-25201`), and the list beside them answers the panel
    /// service's window, with the sheet's own frame. That sibling is the only
    /// accessibility evidence of where the field's events have to go.
    /// `endpoint` still attests that window's identity and its containment.
    private func remoteContentWindow(of surfaceNode: Node, within chain: SurfaceChain) -> Int? {
        namedWindows(under: surfaceNode, within: chain, atMost: 1)?.first
    }

    /// The one window of another process the surface's descendants name, when
    /// it is drawn over the whole surface: the keyboard route's recipient.
    ///
    /// Measured on 30/09/2026 with Photoshop's Save As panel: its subtree named
    /// the panel service's window, with the panel's exact frame, and also a
    /// window of Photoshop's own, an accessory view a third of its height. The
    /// second is the application's and is never the remote content, so only a
    /// window whose owner is another process counts, and it has to be one. A
    /// named window whose identity cannot be read refuses, since nothing then
    /// says whose it is.
    private func foreignContentWindow(of surfaceNode: Node, within chain: SurfaceChain) -> Int? {
        guard let named = namedWindows(under: surfaceNode, within: chain, atMost: .max) else { return nil }
        var foreign: [Int] = []
        for number in named.sorted() {
            guard let owner = identity(number) else { return nil }
            if owner.process != chain.surface.process { foreign.append(number) }
        }
        guard foreign.count == 1, let only = foreign.first,
              geometry(only, chain.surfaceFrame)?.window.frame == chain.surfaceFrame
        else { return nil }
        return only
    }

    /// The one window the focused nodes under `root` name, with the
    /// accessibility PID of the last of them, nil when none is focused, they
    /// name two windows, a focused node names none, or the subtree cannot be
    /// read whole before `deadline`. Every node must name a live process.
    private func focusedDescendantWindow(
        under root     : Node,
        includingRoot  : Bool,
        before deadline: UInt64
    ) -> (windowNumber: Int, accessibilityProcessID: Int32)? {

        var pending: [(Node, Int)] = [(root, 0)]
        var visited = 0
        var candidate: (windowNumber: Int, accessibilityProcessID: Int32)?

        while let (node, depth) = pending.popLast() {
            guard now() < deadline,
                  depth <= 64,
                  visited < 1_024,
                  let accessibilityProcessID = nodeProcess(node),
                  accessibilityProcessID > 0
            else { return nil }
            visited += 1

            switch includingRoot || depth > 0 ? descendantFocus(node) : .notApplicable {
            case .focused:
                guard let windowNumber = nodeWindow(node) else { return nil }
                if let candidate, candidate.windowNumber != windowNumber { return nil }
                candidate = (windowNumber, accessibilityProcessID)

            case .unfocused, .notApplicable:
                break

            case .unreadable:
                return nil
            }

            switch children(node) {
            case .leaf:
                break
            case .unreadable:
                return nil
            case .children(let values):
                guard values.count <= 1_024 - visited - pending.count else { return nil }
                pending.append(contentsOf: values.map { ($0, depth + 1) })
            }
        }
        return candidate
    }

    /// Every window other than the surface that the surface's descendants
    /// name, nil when they name more than `limit` or cannot be read whole.
    private func namedWindows(
        under surfaceNode: Node,
        within chain     : SurfaceChain,
        atMost limit     : Int
    ) -> Set<Int>? {
        let (deadline, overflow) = now().addingReportingOverflow(300_000_000)
        guard !overflow else { return nil }
        var pending: [(Node, Int)] = [(surfaceNode, 0)]
        var visited = 0
        var named: Set<Int> = []
        while let (node, depth) = pending.popLast() {
            guard now() < deadline, depth <= 64, visited < 1_024 else { return nil }
            visited += 1
            if let window = nodeWindow(node), window != chain.surface.windowNumber {
                named.insert(window)
                guard named.count <= limit else { return nil }
            }
            switch children(node) {
            case .leaf: break
            case .unreadable: return nil
            case .children(let values):
                guard values.count <= 1_024 - visited - pending.count else { return nil }
                pending.append(contentsOf: values.map { ($0, depth + 1) })
            }
        }
        guard now() < deadline else { return nil }
        return named
    }

    /// The bounded descent: from the node the hit test answered, into the
    /// smallest child that still contains the point, and so on.
    ///
    /// The deepest Window ID any visited node answered is the one that counts.
    /// In the measured case the hit test stops at the sheet, which answers the
    /// host's window, and the control below it answers the remote one: taking
    /// the deepest is what makes the difference visible instead of stopping at
    /// the proxy.
    ///
    /// The smallest containing child is the choice because accessibility
    /// children are not ordered by what is drawn on top, so their order cannot
    /// decide it.
    private enum ChildReadFailure: Error {
        case unreadable
        /// The innermost node under the point answered no Window ID; its
        /// accessibility PID and the last Window ID above it are kept.
        case windowless(accessibilityProcessID: Int32, windowAbove: Int?)
    }

    private func descend(
        from seed: Node,
        to point: CGPoint
    ) -> Result<(node: Node, windowNumber: Int?), ChildReadFailure> {

        var node         = seed
        var windowNumber = nodeWindow(seed)

        for _ in 0..<Self.maximumDepth {
            var innermost: Node?
            var innermostArea = CGFloat.infinity
            let childNodes: [Node]
            switch children(node) {
            case .children(let values): childNodes = values
            case .leaf: return .success((node, windowNumber))
            case .unreadable: return .failure(.unreadable)
            }
            for child in childNodes {
                guard let frame = nodeFrame(child), frame.contains(point) else { continue }
                let area = frame.width * frame.height
                guard area.isFinite, area < innermostArea else { continue }
                innermost     = child
                innermostArea = area
            }
            guard let innermost else { break }
            node = innermost
            guard let found = nodeWindow(innermost) else {
                guard let processID = nodeProcess(innermost) else { return .failure(.unreadable) }
                return .failure(.windowless(accessibilityProcessID: processID, windowAbove: windowNumber))
            }
            windowNumber = found
        }
        return .success((node, windowNumber))
    }
}

// MARK: - The shipping readers

extension DialogEndpointResolver where Node == AXUIElement {

    /// The discovery the seat runs, over one application's accessibility tree
    /// and the kit's own window server readings.
    ///
    /// Every accessibility call is bounded by a messaging timeout, so a process
    /// that stops answering refuses the Command instead of holding the seat.
    /// The geometry reader asks the public window list first and the qualified
    /// reading for an unlisted window second: absence from that list is what an
    /// out of process panel's content looks like, and it is never a reason to
    /// address a window whose rectangle nobody read.
    package static func accessibility(
        assignedProcessID    : Int32,
        allowUnvalidatedBuild: Bool = false,
        table                : SymbolTable = .shared
    ) -> DialogEndpointResolver<AXUIElement> {

        let application = AXUIElementCreateApplication(assignedProcessID)
        AXUIElementSetMessagingTimeout(application, BoundedAccessibilityRead.fastTimeout)

        return DialogEndpointResolver<AXUIElement>(
            nodeAtPoint: { point in
                var element: AXUIElement?
                let error = AXUIElementCopyElementAtPosition(
                    application,
                    Float(point.x),
                    Float(point.y),
                    &element
                )
                guard error == .success, let element else { return nil }
                AXUIElementSetMessagingTimeout(element, BoundedAccessibilityRead.fastTimeout)
                return element
            },
            focusedNode: {
                guard case .node(let focused) = Self.focusedControl(in: application) else { return nil }
                return focused
            },
            children: Self.children(of:),
            nodeFrame  : Self.frame(of:),
            nodeWindow : { WindowRelocator.windowNumber(of: $0, table: table) },
            nodeProcess: { node in
                var processID: pid_t = 0
                guard AXUIElementGetPid(node, &processID) == .success, processID > 0 else {
                    return nil
                }
                return processID
            },
            identity: {
                WindowServerProbe.identity(
                    of                   : $0,
                    allowUnvalidatedBuild: allowUnvalidatedBuild,
                    table                : table
                )
            },
            geometry: { windowNumber, container in
                if let listed = WindowServerProbe.geometry(
                    of                   : windowNumber,
                    allowUnvalidatedBuild: allowUnvalidatedBuild,
                    table                : table
                ), let scaleFactor = WindowGeometryProbe.scaleFactor(for: listed.frame) {
                    return WindowGeometryObservation(
                        window     : listed,
                        scaleFactor: scaleFactor,
                        version    : GeometryObservationVersion(
                            observerGeneration: 0,
                            sequence          : DispatchTime.now().uptimeNanoseconds
                        )
                    )
                }
                return RemoteWindowProbe.observation(
                    of                   : windowNumber,
                    containedIn          : container,
                    allowUnvalidatedBuild: allowUnvalidatedBuild,
                    table                : table
                )
            },
            focusedControl: {
                Self.focusedControl(in: application)
            },
            focusedWindow: {
                Self.elementAttribute(application, kAXFocusedWindowAttribute)
            },
            windowNode: { number in
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                    application, kAXWindowsAttribute as CFString, &value
                ) == .success, let windows = value as? [AXUIElement]
                else { return nil }
                let window = windows.first {
                    WindowRelocator.windowNumber(of: $0, table: table) == number
                }
                window.map { AXUIElementSetMessagingTimeout($0, BoundedAccessibilityRead.fastTimeout) }
                return window
            },
            inertWindowlessLeaf: Self.inertWindowlessLeaf,
            descendantFocus: Self.descendantFocus(of:)
        )
    }

    /// Reads the exact positive facts that distinguish Electron's transient
    /// title-bar group from input-bearing remote content. Any failed or absent
    /// value is a refusal, never a decorative default.
    private static func inertWindowlessLeaf(_ node: AXUIElement) -> Bool {
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &roleValue) == .success,
              let role = roleValue as? String,
              role == kAXGroupRole as String
        else { return false }

        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, kAXWindowAttribute as CFString, &windowValue) == .noValue
        else { return false }

        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, kAXFocusedAttribute as CFString, &focusedValue) == .success,
              let focused = focusedValue as? NSNumber
        else { return false }

        var focusedIsSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            node, kAXFocusedAttribute as CFString, &focusedIsSettable
        ) == .success else { return false }

        var rawActions: CFArray?
        guard AXUIElementCopyActionNames(node, &rawActions) == .success,
              let actions = rawActions as? [String]
        else { return false }

        return Self.inertWindowlessLeaf(.init(
            role: role,
            axWindowWasNoValue: true,
            focused: focused.boolValue,
            focusedIsSettable: focusedIsSettable.boolValue,
            actions: Set(actions)
        ))
    }

    private static func focusedControl(in application: AXUIElement) -> FocusedControlReading {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            application, kAXFocusedUIElementAttribute as CFString, &value
        )
        if error == .noValue { return .absent }
        guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return .unreadable
        }
        let element = unsafeDowncast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, BoundedAccessibilityRead.fastTimeout)
        return .node(element)
    }

    /// Reads a descendant's focus state without treating a missing attribute as
    /// a negative fact. AX sheets contain many elements for which AXFocused is
    /// unavailable; those are not candidates, while an unreadable response
    /// still makes the bounded proof incomplete.
    private static func descendantFocus(of node: AXUIElement) -> DescendantFocusReading {
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(node, kAXFocusedAttribute as CFString, &value) {
        case .success:
            guard let focused = value as? NSNumber else { return .unreadable }
            return focused.boolValue ? .focused : .unfocused
        case .noValue, .attributeUnsupported:
            return .notApplicable
        default:
            return .unreadable
        }
    }

    private static func elementAttribute(_ node: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        let element = unsafeDowncast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, BoundedAccessibilityRead.fastTimeout)
        return element
    }

    /// The element's screen rectangle from the two public attributes, which
    /// carry it as `AXValue`s rather than as numbers.
    private static func frame(of node: AXUIElement) -> CGRect? {
        guard let positionValue: AXValue = attribute(node, kAXPositionAttribute),
              let sizeValue: AXValue = attribute(node, kAXSizeAttribute)
        else { return nil }

        var origin = CGPoint.zero
        var size   = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue, .cgSize, &size)
        else { return nil }

        let frame = CGRect(origin: origin, size: size)
        return frame.hasFinitePositiveArea ? frame : nil
    }

    /// Reads one AXChildren attribute with one retry. A leaf is a valid answer;
    /// a timed-out, unsupported-value, or otherwise malformed read is not.
    private static func children(of node: AXUIElement) -> ChildReading {
        func read() -> ChildReading {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &value)
            switch error {
            case .success:
                guard let children = value as? [AXUIElement] else { return .unreadable }
                for child in children {
                    AXUIElementSetMessagingTimeout(child, BoundedAccessibilityRead.fastTimeout)
                }
                return .children(children)
            case .noValue, .attributeUnsupported:
                return .leaf
            default:
                return .unreadable
            }
        }

        switch read() {
        case .unreadable: return read()
        case let answer: return answer
        }
    }

    private static func attribute<Value>(_ node: AXUIElement, _ name: String) -> Value? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else {
            return nil
        }
        return value as? Value
    }
}
