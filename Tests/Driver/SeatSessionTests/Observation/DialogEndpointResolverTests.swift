//
//  DialogEndpointResolverTests.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 19/09/2026.
//

import CoreGraphics
import SeatCore
@testable import SeatSession
import Testing

/// The discovery of the window a dialog's events actually have to reach.
///
/// Every row is driven with a fake world: an accessibility tree that answers
/// frames, Window IDs and PIDs, and a window server that answers identities in
/// order so a row can make two readings disagree. The oracle is that world and
/// not the implementation: the test states which window really owns what, and
/// then asks what the discovery concluded.
///
/// The identifiers are this fixture's own. No Window ID, PID or connection from
/// any live measurement appears here, because the shipping code must never
/// recognise a number and a test that pinned one would invite it to.
@Suite("The dialog endpoint discovery")
struct DialogEndpointResolverTests {

    // MARK: The world

    private struct Node: Hashable {
        let id: Int
    }

    /// One accessibility subtree. A node missing from `windows` or `processes`
    /// is a node whose read failed, which is the incomplete subtree.
    private struct Tree {
        var hit      : Int?
        var focused  : Int?
        var frames   : [Int: CGRect] = [:]
        var children : [Int: [Int]]  = [:]
        var windows  : [Int: Int]    = [:]
        var processes: [Int: Int32]  = [:]
        var parents  : [Int: Int]    = [:]
        var unreadableWindows : Set<Int> = []
        var unreadableChildren: Set<Int> = []
    }

    private final class Answers {
        var identityCalls = 0
    }

    private static let hostWindow    = 900
    private static let sheetWindow   = 901
    private static let remoteWindow  = 902
    private static let hostProcessID : Int32 = 100
    private static let remoteProcess : Int32 = 200

    private static let surfaceFrame = CGRect(x: 400, y: 300, width: 600, height: 400)
    private static let contentFrame = CGRect(x: 400, y: 340, width: 600, height: 360)
    private static let buttonFrame  = CGRect(x: 440, y: 650, width: 100, height: 30)
    private static let pointOnCancel = CGPoint(x: 490, y: 665)

    private func identity(
        window    : Int,
        processID : Int32,
        connection: Int32,
        serial    : UInt32 = 1
    ) -> WindowIdentity {

        WindowIdentity(
            process: ProcessIdentity(
                processID       : processID,
                serialNumberHigh: 0,
                serialNumberLow : serial
            ),
            windowNumber     : window,
            ownerConnectionID: connection
        )
    }

    private var host: WindowIdentity {
        identity(window: Self.hostWindow, processID: Self.hostProcessID, connection: 7000)
    }

    private var sheet: WindowIdentity {
        identity(window: Self.sheetWindow, processID: Self.hostProcessID, connection: 7000)
    }

    private var remote: WindowIdentity {
        identity(window: Self.remoteWindow, processID: Self.remoteProcess, connection: 8000)
    }

    private var chain: DialogEndpointResolver<Node>.SurfaceChain {
        .init(host: host, surface: sheet, surfaceFrame: Self.surfaceFrame)
    }

    private func observation(
        _ identity: WindowIdentity,
        _ frame   : CGRect
    ) -> WindowGeometryObservation {

        WindowGeometryObservation(
            window     : WindowReference(identity: identity, frame: frame),
            scaleFactor: 2,
            version    : GeometryObservationVersion(observerGeneration: 0, sequence: 1)
        )!
    }

    /// The measured shape: the hit test stops at the sheet, which answers the
    /// host's Window ID, and the panel's own control below it answers the
    /// remote one while accessibility keeps reporting the host's PID.
    private var hostedPanelTree: Tree {
        Tree(
            hit      : 1,
            focused  : 3,
            frames   : [1: Self.surfaceFrame, 2: Self.contentFrame, 3: Self.buttonFrame],
            children : [1: [2], 2: [3]],
            windows  : [1: Self.sheetWindow, 2: Self.remoteWindow, 3: Self.remoteWindow],
            processes: [1: Self.hostProcessID, 2: Self.hostProcessID, 3: Self.hostProcessID]
        )
    }

    private func makeResolver(
        tree      : Tree,
        identities: [Int: [WindowIdentity?]],
        geometries: [Int: WindowGeometryObservation],
        now       : UInt64 = 1_000_000
    ) -> DialogEndpointResolver<Node> {

        let answers = Answers()
        return DialogEndpointResolver<Node>(
            nodeAtPoint: { _ in tree.hit.map(Node.init) },
            focusedNode: { tree.focused.map(Node.init) },
            children   : {
                tree.unreadableChildren.contains($0.id)
                    ? .unreadable
                    : .children((tree.children[$0.id] ?? []).map(Node.init))
            },
            nodeFrame  : { tree.frames[$0.id] },
            nodeWindow : { tree.windows[$0.id] },
            nodeProcess: { tree.processes[$0.id] },
            identity   : { window in
                let sequence = identities[window] ?? []
                defer { answers.identityCalls += 1 }
                guard answers.identityCalls < sequence.count else { return sequence.last ?? nil }
                return sequence[answers.identityCalls]
            },
            geometry   : { window, _ in geometries[window] },
            now        : { now },
            parent     : { tree.parents[$0.id].map(Node.init) },
            windowReading: { node in
                if tree.unreadableWindows.contains(node.id) { return .unreadable }
                return tree.windows[node.id].map { .window($0) } ?? .windowless
            }
        )
    }

    /// The resolver of the measured case, with every reading agreeing.
    private func coherentResolver(tree: Tree? = nil) -> DialogEndpointResolver<Node> {
        makeResolver(
            tree      : tree ?? hostedPanelTree,
            identities: [Self.remoteWindow: [remote, remote], Self.sheetWindow: [sheet, sheet]],
            geometries: [
                Self.remoteWindow: observation(remote, Self.contentFrame),
                Self.sheetWindow : observation(sheet, Self.surfaceFrame)
            ]
        )
    }

    // MARK: The measured case

    @Test("the accessibility PID stays the host's while the owner is the remote service")
    func remoteOwnerBehindAHostAccessibilityIdentifier() throws {
        let endpoint = try coherentResolver()
            .pointerEndpoint(
                at                 : Self.pointOnCancel,
                within             : chain,
                selectionGeneration: 12
            )
            .get()

        // The oracle: the world says window 902 is owned by connection 8000 of
        // process 200, and says every accessibility node reports process 100.
        #expect(endpoint.identity == remote)
        #expect(endpoint.identity.processID == Self.remoteProcess)
        #expect(endpoint.accessibilityProcessID == Self.hostProcessID)
        #expect(endpoint.accessibilityProcessID != endpoint.identity.processID)
        #expect(endpoint.relation == .remoteContent)
        #expect(endpoint.evidence == .accessibilityNodeIdentity)
        #expect(endpoint.logicalSurface == sheet)
        #expect(endpoint.kind == .pointer)
        #expect(endpoint.selectionGeneration == 12)
        #expect(endpoint.geometry.window.frame == Self.contentFrame)
    }

    @Test("the descent goes past the proxy the hit test stops at")
    func descentPassesTheProxy() throws {
        // The node the hit test answers names the sheet, so a discovery that
        // stopped there would address the proxy.
        let tree = hostedPanelTree
        #expect(tree.windows[tree.hit!] == Self.sheetWindow)

        let endpoint = try coherentResolver()
            .pointerEndpoint(at: Self.pointOnCancel, within: chain, selectionGeneration: 1)
            .get()
        #expect(endpoint.identity.windowNumber == Self.remoteWindow)
    }

    @Test("a surface whose own control answers it stays the recipient")
    func ordinarySheetIsNotRedirected() throws {
        var tree = hostedPanelTree
        tree.windows = [1: Self.sheetWindow, 2: Self.sheetWindow, 3: Self.sheetWindow]

        let endpoint = try coherentResolver(tree: tree)
            .pointerEndpoint(at: Self.pointOnCancel, within: chain, selectionGeneration: 1)
            .get()

        #expect(endpoint.identity == sheet)
        #expect(endpoint.relation == .logicalSurface)
        #expect(endpoint.evidence == .attestedSurfaceItself)
    }

    // MARK: What it refuses

    private func refusal(
        tree      : Tree? = nil,
        identities: [Int: [WindowIdentity?]]? = nil,
        geometries: [Int: WindowGeometryObservation]? = nil,
        at point  : CGPoint = DialogEndpointResolverTests.pointOnCancel
    ) -> InputEndpointRefusal? {

        let resolver = makeResolver(
            tree      : tree ?? hostedPanelTree,
            identities: identities ?? [
                Self.remoteWindow: [remote, remote],
                Self.sheetWindow : [sheet, sheet]
            ],
            geometries: geometries ?? [
                Self.remoteWindow: observation(remote, Self.contentFrame),
                Self.sheetWindow : observation(sheet, Self.surfaceFrame)
            ]
        )
        guard case .failure(let refusal) = resolver.pointerEndpoint(
            at                 : point,
            within             : chain,
            selectionGeneration: 1
        ) else { return nil }
        return refusal
    }

    @Test("a window absent from every geometry reading is refused, never assumed")
    func missingGeometryIsRefused() {
        #expect(
            refusal(geometries: [Self.sheetWindow: observation(sheet, Self.surfaceFrame)])
                == .geometryUnavailable(windowNumber: Self.remoteWindow)
        )
    }

    @Test("a reused Window ID is refused")
    func reusedIdentifierIsRefused() {
        let reused = identity(
            window    : Self.remoteWindow,
            processID : Self.remoteProcess,
            connection: 8000,
            serial    : 2
        )
        #expect(reused.windowNumber == remote.windowNumber)
        #expect(reused != remote)

        #expect(
            refusal(identities: [Self.remoteWindow: [remote, reused]])
                == .identityChangedDuringDiscovery(windowNumber: Self.remoteWindow)
        )
    }

    @Test("a helper replaced under the panel is refused")
    func replacedHelperIsRefused() {
        let successor = identity(window: Self.remoteWindow, processID: 314, connection: 8100)

        // Replaced before the geometry: the reading carries the new owner.
        #expect(
            refusal(
                identities: [Self.remoteWindow: [remote, remote]],
                geometries: [Self.remoteWindow: observation(successor, Self.contentFrame)]
            ) == .identityChangedDuringDiscovery(windowNumber: Self.remoteWindow)
        )
        // Replaced after it: the second chain reading disagrees.
        #expect(
            refusal(identities: [Self.remoteWindow: [remote, successor]])
                == .identityChangedDuringDiscovery(windowNumber: Self.remoteWindow)
        )
    }

    @Test("a second panel of the same service is not this panel")
    func anotherPanelOfTheSameServiceIsRefused() {
        // Same process and same owner connection, drawn somewhere else: the
        // service hosts both, and only one of them is inside this surface.
        let elsewhere = CGRect(x: 1400, y: 340, width: 600, height: 360)
        #expect(!Self.surfaceFrame.contains(elsewhere))

        #expect(
            refusal(geometries: [Self.remoteWindow: observation(remote, elsewhere)])
                == .notContainedInSurface(windowNumber: Self.remoteWindow)
        )
    }

    @Test("an incomplete accessibility subtree refuses instead of naming the host")
    func incompleteSubtreeIsRefused() {
        var unreadableWindows = hostedPanelTree
        unreadableWindows.windows = [:]
        #expect(refusal(tree: unreadableWindows) == .subtreeUnreadable(surface: sheet))

        var unreadableProcess = hostedPanelTree
        unreadableProcess.processes = [:]
        #expect(refusal(tree: unreadableProcess) == .subtreeUnreadable(surface: sheet))

        var noHit = hostedPanelTree
        noHit.hit = nil
        #expect(refusal(tree: noHit) == .noNodeAtPoint)
    }

    @Test("a concrete descendant without a Window ID refuses instead of retaining its proxy")
    func concreteDescendantWithoutWindowIsUnreadable() {
        // The control contains the target point, so retaining the group above
        // would address a proxy after the concrete recipient stopped answering.
        var tree = hostedPanelTree
        tree.windows[3] = nil
        #expect(refusal(tree: tree) == .subtreeUnreadable(surface: sheet))
    }

    @Test("an unreadable children read refuses instead of selecting the proxy")
    func unreadableChildrenRefuse() {
        let resolver = DialogEndpointResolver<Node>(
            nodeAtPoint: { _ in Node(id: 1) },
            focusedNode: { nil },
            children: { node in node.id == 1 ? .unreadable : .leaf },
            nodeFrame: { hostedPanelTree.frames[$0.id] },
            nodeWindow: { hostedPanelTree.windows[$0.id] },
            nodeProcess: { hostedPanelTree.processes[$0.id] },
            identity: { _ in remote },
            geometry: { _, _ in observation(remote, Self.contentFrame) },
            now: { 1 }
        )
        guard case .failure(let refusal) = resolver.pointerEndpoint(
            at: Self.pointOnCancel, within: chain, selectionGeneration: 1
        ) else {
            Issue.record("unreadable children must refuse")
            return
        }
        #expect(refusal == .subtreeUnreadable(surface: sheet))
    }

    @Test("a window the chain cannot attest is refused")
    func unattestedWindowIsRefused() {
        #expect(
            refusal(identities: [Self.remoteWindow: [nil]])
                == .identityUnattested(windowNumber: Self.remoteWindow)
        )
    }

    @Test("a point outside the attested surface names no relation")
    func pointOutsideTheSurfaceIsRefused() {
        let outside = CGPoint(x: 100, y: 100)
        #expect(!Self.surfaceFrame.contains(outside))
        #expect(refusal(at: outside) == .pointOutsideSurface)
    }

    @Test("no incoherent window, connection and process combination becomes a recipient")
    func incoherentCombinationsNeverResolve() {
        // The geometry names another window than the one the node reported.
        let otherWindow = identity(window: 903, processID: Self.remoteProcess, connection: 8000)
        #expect(
            refusal(geometries: [Self.remoteWindow: observation(otherWindow, Self.contentFrame)])
                == .identityChangedDuringDiscovery(windowNumber: Self.remoteWindow)
        )
        // The chain names another owner connection than the geometry carries.
        let otherConnection = identity(
            window    : Self.remoteWindow,
            processID : Self.remoteProcess,
            connection: 9999
        )
        #expect(
            refusal(identities: [Self.remoteWindow: [otherConnection, otherConnection]])
                == .identityChangedDuringDiscovery(windowNumber: Self.remoteWindow)
        )
        // The chain answers an identity of a different window entirely.
        #expect(
            refusal(identities: [Self.remoteWindow: [otherWindow, otherWindow]])
                == .identityUnattested(windowNumber: Self.remoteWindow)
        )
    }

    // MARK: The keyboard context

    @Test("the keyboard context comes from the focused node, not from a point")
    func keyboardContextIsResolvedFromFocus() throws {
        let endpoint = try coherentResolver()
            .keyboardContext(within: chain, selectionGeneration: 4)
            .get()

        #expect(endpoint.kind == .keyboardContext)
        #expect(endpoint.identity == remote)
        #expect(endpoint.focusedNodeWindowNumber == Self.remoteWindow)
    }

    @Test("a surface with no readable focused node refuses")
    func keyboardContextWithoutFocusRefuses() {
        var tree = hostedPanelTree
        tree.focused = nil
        let outcome = coherentResolver(tree: tree)
            .keyboardContext(within: chain, selectionGeneration: 1)

        guard case .failure(let refusal) = outcome else {
            Issue.record("a missing focused node must refuse")
            return
        }
        #expect(refusal == .subtreeUnreadable(surface: sheet))
    }

    /// The reading the boundary revalidates a keyboard context against. An
    /// unreadable focus answers nil, which retires the context rather than
    /// leaving it standing on a window nobody is typing into.
    @Test("the focused node's window is read on its own, and answers nil when nothing does")
    func focusedNodeWindowIsReadableOnItsOwn() {
        #expect(coherentResolver().focusedNodeWindowNumber() == Self.remoteWindow)

        var tree = hostedPanelTree
        tree.focused = nil
        #expect(coherentResolver(tree: tree).focusedNodeWindowNumber() == nil)
    }

    // MARK: The windowless content of an ordinary window

    private var ordinaryChain: DialogEndpointResolver<Node>.SurfaceChain {
        .init(host: host, surface: host, surfaceFrame: Self.surfaceFrame)
    }

    /// The shape of a web page: the window names itself, while the web area
    /// and every node under it name no window, all with the application's PID.
    /// The hit test answers the link, whose text is the innermost node.
    private var webPageTree: Tree {
        Tree(
            hit      : 3,
            focused  : 4,
            frames   : [
                1: Self.surfaceFrame,
                2: Self.contentFrame,
                3: Self.buttonFrame,
                4: Self.buttonFrame.insetBy(dx: 10, dy: 5),
                5: CGRect(x: 400, y: 300, width: 600, height: 40)
            ],
            children : [1: [5, 2], 2: [3], 3: [4]],
            windows  : [1: Self.hostWindow, 5: Self.hostWindow],
            processes: [1: Self.hostProcessID, 2: Self.hostProcessID, 3: Self.hostProcessID,
                        4: Self.hostProcessID, 5: Self.hostProcessID],
            parents  : [2: 1, 3: 2, 4: 3, 5: 1]
        )
    }

    private func pageResolver(_ tree: Tree) -> DialogEndpointResolver<Node> {
        makeResolver(
            tree      : tree,
            identities: [Self.hostWindow: [host, host]],
            geometries: [Self.hostWindow: observation(host, Self.surfaceFrame)]
        )
    }

    private func windowless(
        _ tree : Tree,
        pointer: Bool,
        within chain: DialogEndpointResolver<Node>.SurfaceChain? = nil
    ) -> Result<ResolvedInputEndpoint, InputEndpointRefusal> {
        pageResolver(tree).windowlessContentEndpoint(
            at                 : pointer ? Self.pointOnCancel : nil,
            within             : chain ?? ordinaryChain,
            selectionGeneration: 6
        )
    }

    @Test("a web page's node under the point, or its focused control, is the window's own content",
          arguments: [true, false])
    func windowlessContentIsTheSurfaces(pointer: Bool) throws {
        // The discovery refuses this tree, which is the refusal the route answers.
        let resolver = pageResolver(webPageTree)
        let refused = pointer
            ? resolver.pointerEndpoint(at: Self.pointOnCancel, within: ordinaryChain, selectionGeneration: 6)
            : resolver.keyboardContext(within: ordinaryChain, selectionGeneration: 6)
        #expect(refused == .failure(.subtreeUnreadable(surface: host)))

        let endpoint = try windowless(webPageTree, pointer: pointer).get()
        #expect(endpoint.identity == host)
        #expect(endpoint.logicalSurface == host)
        #expect(endpoint.relation == .logicalSurface)
        #expect(endpoint.evidence == .windowlessContentOfSurface)
        #expect(endpoint.kind == (pointer ? .pointer : .keyboardContext))
        #expect(endpoint.focusedNodeWindowNumber == (pointer ? nil : Self.hostWindow))
        #expect(endpoint.selectionGeneration == 6)
    }

    @Test("a node on the path that names another window refuses", arguments: [true, false])
    func windowlessContentRefusesAForeignWindow(pointer: Bool) {
        let refusal = Result<ResolvedInputEndpoint, InputEndpointRefusal>
            .failure(.subtreeUnreadable(surface: host))
        // Above the start, and at the innermost node: the focused control for keys.
        for node in [2, 4] {
            var tree = webPageTree
            tree.windows[node] = Self.remoteWindow
            #expect(windowless(tree, pointer: pointer) == refusal)
        }
        // The nearest node naming a window is another window of the same process.
        var nested = webPageTree
        nested.windows[2] = Self.sheetWindow
        #expect(windowless(nested, pointer: pointer) == refusal)
    }

    @Test("a node on the path of another process refuses", arguments: [true, false])
    func windowlessContentRefusesAnotherProcess(pointer: Bool) {
        for node in [2, 4] {
            var tree = webPageTree
            tree.processes[node] = Self.remoteProcess
            #expect(windowless(tree, pointer: pointer) == .failure(.subtreeUnreadable(surface: host)))
        }
    }

    @Test("a read on the path that failed refuses", arguments: [true, false])
    func windowlessContentRefusesAnUnreadableRead(pointer: Bool) {
        let refusal = Result<ResolvedInputEndpoint, InputEndpointRefusal>
            .failure(.subtreeUnreadable(surface: host))

        var window = webPageTree
        window.unreadableWindows = [2]
        #expect(windowless(window, pointer: pointer) == refusal)

        var parent = webPageTree
        parent.parents[2] = nil
        #expect(windowless(parent, pointer: pointer) == refusal)

        var focus = webPageTree
        focus.focused = nil
        var children = webPageTree
        children.unreadableChildren = [3]
        #expect(windowless(pointer ? children : focus, pointer: pointer) == refusal)
    }

    @Test("a hosted surface, or a path past its budget, refuses", arguments: [true, false])
    func windowlessContentRefusesAHostedSurfaceAndALongPath(pointer: Bool) throws {
        #expect(windowless(webPageTree, pointer: pointer, within: chain)
            == .failure(.subtreeUnreadable(surface: sheet)))

        // A start node with `length` windowless ancestors before the window.
        func path(_ length: Int) -> Tree {
            var tree = webPageTree
            tree.hit     = 100
            tree.focused = 100
            for node in 100..<(100 + length) {
                tree.processes[node] = Self.hostProcessID
                tree.parents[node]   = node + 1
            }
            tree.parents[100 + length - 1] = 1
            return tree
        }
        _ = try windowless(path(60), pointer: pointer).get()
        #expect(windowless(path(70), pointer: pointer) == .failure(.subtreeUnreadable(surface: host)))
    }

    // MARK: Retiring an endpoint

    @Test("every retirement is named, and a current endpoint is not retired")
    func invalidationTable() throws {
        let endpoint = try coherentResolver()
            .pointerEndpoint(at: Self.pointOnCancel, within: chain, selectionGeneration: 12)
            .get()

        func invalidation(
            at now             : UInt64 = 1_000_000,
            generation         : UInt64 = 12,
            surface            : WindowIdentity? = nil,
            current            : WindowIdentity?? = nil,
            focusedNodeWindow  : Int? = nil
        ) -> InputEndpointInvalidation? {

            endpoint.invalidation(
                at                     : now,
                selectionGeneration    : generation,
                logicalSurface         : surface ?? sheet,
                currentIdentity        : current ?? remote,
                focusedNodeWindowNumber: focusedNodeWindow
            )
        }

        #expect(invalidation() == nil)
        #expect(invalidation(at: endpoint.expiresAtNanoseconds) == .expired)
        #expect(invalidation(generation: 13) == .selectionSuperseded)
        #expect(invalidation(surface: host) == .relationNoLongerValid)
        #expect(invalidation(current: .some(nil)) == .identityChanged)
        #expect(
            invalidation(
                current: identity(
                    window    : Self.remoteWindow,
                    processID : Self.remoteProcess,
                    connection: 8000,
                    serial    : 9
                )
            ) == .identityChanged
        )
        // A pointer endpoint knows nothing about where the focus is.
        #expect(invalidation(focusedNodeWindow: 12_345) == nil)
    }

    @Test("a keyboard context is retired when the focus moves to another window")
    func keyboardContextFollowsTheFocusedNode() throws {
        let endpoint = try coherentResolver()
            .keyboardContext(within: chain, selectionGeneration: 4)
            .get()

        #expect(
            endpoint.invalidation(
                at                     : 1_000_000,
                selectionGeneration    : 4,
                logicalSurface         : sheet,
                currentIdentity        : remote,
                focusedNodeWindowNumber: Self.remoteWindow
            ) == nil
        )
        #expect(
            endpoint.invalidation(
                at                     : 1_000_000,
                selectionGeneration    : 4,
                logicalSurface         : sheet,
                currentIdentity        : remote,
                focusedNodeWindowNumber: Self.sheetWindow
            ) == .focusedNodeChanged
        )
    }

    @Test("an endpoint cannot be assembled from facts that contradict each other")
    func endpointInitializerRefusesContradictions() {
        let geometry = observation(remote, Self.contentFrame)

        // Remote content that is the surface itself is not a relation.
        #expect(
            ResolvedInputEndpoint(
                kind                  : .pointer,
                geometry              : geometry,
                evidence              : .accessibilityNodeIdentity,
                relation              : .remoteContent,
                logicalSurface        : remote,
                accessibilityProcessID: Self.hostProcessID,
                selectionGeneration   : 1,
                resolvedAtNanoseconds : 10,
                expiresAtNanoseconds  : 20
            ) == nil
        )
        // A deadline that has already passed at the moment of the resolution.
        #expect(
            ResolvedInputEndpoint(
                kind                  : .pointer,
                geometry              : geometry,
                evidence              : .accessibilityNodeIdentity,
                relation              : .remoteContent,
                logicalSurface        : sheet,
                accessibilityProcessID: Self.hostProcessID,
                selectionGeneration   : 1,
                resolvedAtNanoseconds : 20,
                expiresAtNanoseconds  : 20
            ) == nil
        )
        // A geometry with no attested identity cannot exist in the first place.
        #expect(
            WindowGeometryObservation(
                window     : WindowReference(
                    processID   : Self.remoteProcess,
                    windowNumber: Self.remoteWindow,
                    frame       : Self.contentFrame
                ),
                scaleFactor: 2,
                version    : GeometryObservationVersion(observerGeneration: 0, sequence: 1)
            ) == nil
        )
    }
}
