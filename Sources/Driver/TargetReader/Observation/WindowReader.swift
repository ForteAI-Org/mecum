//
//  WindowReader.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 09/09/2026.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import SeatCore
import WindowPlacement

/// What a reading of another application's window can get wrong.
nonisolated public enum WindowReaderError: LocalizedError {

    case accessibilityPermissionMissing
    case webAccessibilityNotReady(windowNumber: Int?)
    case processMissing
    case windowMissing
    case windowNumberMissing
    case valueMissing(String)

    public var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing:
            "Accessibility is not granted, so no window can be read from outside."
        case .webAccessibilityNotReady(let windowNumber):
            "Chrome did not publish web accessibility for window \(windowNumber.map(String.init) ?? "unknown") within 4 seconds."
        case .processMissing:
            "The observed process is no longer running."
        case .windowMissing:
            "No window of the observed process can be resolved from outside."
        case .windowNumberMissing:
            "The accessibility window cannot be tied to a Window ID. No window was guessed."
        case .valueMissing(let name):
            "The state \(name) cannot be read from outside."
        }
    }
}

/// WindowReader reads another application's window from outside, through
/// accessibility, and answers with an `ObservedWindow`.
///
/// It reads and returns. It takes no action on the target, it is not a Facility
/// and it is not a fallback for one: nothing in `VirtualScreens`,
/// `WindowPlacement`, `SeatInput`, `CursorGuard`, `SeatCapture` or
/// `SeatSession` imports this module, and the caller decides what the reading
/// means. The
/// kit's own use of accessibility stays `AXPosition`, `AXRaise` and
/// `_AXUIElementGetWindow` (ADR 0004).
///
/// AXManualAccessibility is the deliberate bootstrap write for Electron
/// (ADR 0009). Chrome and Chromium browsers instead need individual AXRole
/// reads, starting with the application, followed by bounded web-tree polling.
/// Neither path invokes a control, activates an app or posts input.
///
/// The type holds no mutable state, so it is safe from any thread and there is
/// nothing here to race on.
nonisolated public enum WindowReader {

    /// The reader only observes: asking for the grant is the kit's job
    /// (`Permissions.request(.accessibility)`), and this module depends on
    /// `WindowPlacement` and nothing else.
    public static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Reads one window of `processID`, the front one unless a Window ID is
    /// named, and answers with its identity, its geometry and its whole
    /// accessibility hierarchy as value types.
    public static func windowSnapshot(
        processID             : Int32,
        windowNumber          : Int? = nil,
        allowUnvalidatedBuild : Bool = false
    ) throws -> ObservedWindow {

        let resolved = try resolveWindow(
            processID            : processID,
            requestedWindowNumber: windowNumber
        )
        guard let server = WindowServerProbe.geometry(
            of                   : resolved.windowNumber,
            allowUnvalidatedBuild: allowUnvalidatedBuild
        ),
              server.processID == processID,
              let windowIdentity = server.identity
        else { throw WindowReaderError.windowMissing }

        let geometryObservation = server.frame == resolved.windowFrame
            ? WindowGeometryProbe.scaleFactor(for: server.frame).flatMap { scale in
                WindowGeometryObservation(
                    window     : server,
                    scaleFactor: scale,
                    version    : GeometryObservationVersion(
                        observerGeneration: 0,
                        sequence          : mach_absolute_time()
                    )
                )
            }
            : nil

        return ObservedWindow(
            processID          : processID,
            applicationName    : resolved.applicationName,
            windowTitle        : stringAttribute(resolved.window, kAXTitleAttribute as CFString) ?? "untitled",
            windowNumber       : resolved.windowNumber,
            windowFrame        : resolved.windowFrame,
            windowOrder        : WindowServerProbe.orderIndex(of: resolved.windowNumber),
            applicationIsActive: resolved.applicationIsActive,
            windowIsFocused    : boolAttribute(resolved.window, kAXFocusedAttribute as CFString) ?? false,
            axTree             : resolved.axTree,
            axTreeWasTruncated : resolved.axTreeWasTruncated,
            signature          : resolved.signature,
            axTreeLimitReason  : resolved.limitReason,
            windowIdentity     : windowIdentity,
            geometryObservation: geometryObservation
        )
    }

    /// Reads the contextual menu a target has open right now, if it exposes
    /// one, and says which of the three situations it is in.
    ///
    /// Read it **while the menu is up**: a contextual menu exists only for the
    /// duration of its tracking loop, so this is a call to make from inside
    /// whatever holds the menu open, and it answers `notOpen` a moment later.
    ///
    /// ## Where the menu is, and where it is not
    ///
    /// An AppKit contextual menu appears in the tree as an `AXMenu` child of the
    /// **window** element. It is not under the application element, which is
    /// where the menu bar and its menus live, and looking there is how this
    /// package once concluded that a background application opens no menu at
    /// all. So the search is the named window's children, or every window's
    /// when no Window ID is given, and the menu bar's own subtree is never
    /// walked.
    ///
    /// ## A Chromium menu cannot be read, and this says so
    ///
    /// A Chromium, Electron or CEF contextual menu is absent from the
    /// accessibility tree for the whole time its window is on the screen, with
    /// `AXManualAccessibility` written and with the browser's own tree
    /// otherwise readable. There is no attribute to ask and no wait that helps.
    /// So on that family the answer is `drawnOutsideTheAccessibilityTree` with
    /// the window server's rectangle, which is the truth, rather than an empty
    /// list, which would read as "the menu has no items".
    ///
    /// The window server is what separates that case from `notOpen`: it is the
    /// only witness that a menu exists at all.
    public static func contextMenu(
        processID   : Int32,
        windowNumber: Int? = nil
    ) throws -> ObservedContextMenu {

        guard isTrusted() else { throw WindowReaderError.accessibilityPermissionMissing }
        guard let runningApplication = NSRunningApplication(processIdentifier: processID),
              !runningApplication.isTerminated
        else { throw WindowReaderError.processMissing }

        guard let menuWindow = WindowServerProbe.menuWindows(ownedBy: processID).first else {
            return .notOpen
        }

        let applicationElement = AXUIElementCreateApplication(processID)
        let windows            = windowList(of: applicationElement)
        let searched           = windowNumber.map { requested in
            windows.filter { self.windowNumber(for: $0) == requested }
        } ?? windows

        for window in searched {
            for child in children(of: window)
            where stringAttribute(child, kAXRoleAttribute as CFString) == kAXMenuRole {
                return .items(items(of: child))
            }
        }
        return .drawnOutsideTheAccessibilityTree(frame: menuWindow.frame)
    }

    /// One `AXMenu`'s rows, read one element at a time.
    ///
    /// A separator answers no title and no position, and it is kept rather than
    /// filtered: an index into this list is an index into what the target
    /// draws, and dropping rows would shift every one after them.
    private static func items(of menu: AXUIElement) -> [ObservedMenuItem] {
        children(of: menu).map { item in
            ObservedMenuItem(
                title     : stringAttribute(item, kAXTitleAttribute as CFString) ?? "",
                isEnabled : boolAttribute(item, kAXEnabledAttribute as CFString) ?? false,
                isSelected: boolAttribute(item, kAXSelectedAttribute as CFString) ?? false,
                hasSubmenu: !children(of: item).isEmpty,
                frame     : frame(of: item)
            )
        }
    }

    private struct ResolvedWindow {
        let applicationName    : String
        let applicationIsActive: Bool
        let window             : AXUIElement
        let windowFrame        : CGRect
        let windowNumber       : Int
        let axTree             : [AXElementNode]
        let axTreeWasTruncated : Bool
        let signature          : Int
        let limitReason        : String?
    }

    private struct ElementIdentity: Hashable {
        let element: AXUIElement
        static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }

    private static let nodeAttributeNames = [
        kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
        kAXPositionAttribute, kAXSizeAttribute, kAXIdentifierAttribute, kAXEnabledAttribute,
        kAXSelectedAttribute, kAXExpandedAttribute, kAXFocusedAttribute, kAXChildrenAttribute,
        kAXSelectedTextAttribute, kAXSelectedTextRangeAttribute, kAXHelpAttribute,
        kAXPlaceholderValueAttribute,
    ]

    /// One aggregated read per node instead of a round trip per attribute. The
    /// per attribute errors stay distinguishable from the values a provider
    /// simply does not expose.
    private static func nodeAttributes(_ element: AXUIElement) -> AXNodeAttributeReader.Result {
        var rawValues: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            element,
            nodeAttributeNames as CFArray,
            [],
            &rawValues
        )
        return AXNodeAttributeReader.read(
            names     : nodeAttributeNames,
            bulkError : error,
            bulkValues: rawValues as? [AnyObject]
        ) { name in
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return (error, value)
        }
    }

    private static func resolveWindow(
        processID            : Int32,
        requestedWindowNumber: Int? = nil
    ) throws -> ResolvedWindow {

        guard isTrusted() else {
            throw WindowReaderError.accessibilityPermissionMissing
        }
        guard let runningApplication = NSRunningApplication(processIdentifier: processID),
              !runningApplication.isTerminated
        else {
            throw WindowReaderError.processMissing
        }
        let applicationName    = runningApplication.localizedName ?? "PID \(processID)"
        let applicationElement = AXUIElementCreateApplication(processID)
        guard let window = try window(
            of                   : applicationElement,
            requestedWindowNumber: requestedWindowNumber,
            isChromiumBrowser    : ChromiumAXTreeReadiness.supports(
                bundleIdentifier: runningApplication.bundleIdentifier
            )
        ) else {
            throw WindowReaderError.windowMissing
        }
        guard let windowFrame = frame(of: window) else {
            throw WindowReaderError.windowMissing
        }
        guard let windowNumber = windowNumber(for: window) else {
            throw WindowReaderError.windowNumberMissing
        }

        var axTree: [AXElementNode] = []
        var signatureHasher         = Hasher()
        var pending: [(element: AXUIElement, parentNodeID: Int?, depth: Int)] = [
            (window, nil, 0)
        ]
        var pendingIndex = 0
        var scheduled: Set<ElementIdentity> = [ElementIdentity(element: window)]
        var limitReason: String?
        var textBytes = 0
        let deadline = Date(timeIntervalSinceNow: 8)
        // Acquisition limits, not a relevance filter. A truncated snapshot is
        // reported and must not feed a plan.
        let maximumTreeNodes = 20_000
        while pendingIndex < pending.count {
            guard axTree.count < maximumTreeNodes, Date() < deadline, textBytes <= 16_000_000 else {
                limitReason = "accessibility acquisition limit: 20000 nodes, 8 seconds or 16 MB of text"
                break
            }
            let entry = pending[pendingIndex]
            pendingIndex += 1
            let element = entry.element
            let nodeID  = axTree.count
            let attributes = nodeAttributes(element)
            if let failure = attributes.failure { limitReason = failure }
            let values          = attributes.values
            let role            = values[kAXRoleAttribute] as? String ?? "AXUnknown"
            let title           = values[kAXTitleAttribute] as? String ?? ""
            let nodeDescription = values[kAXDescriptionAttribute] as? String ?? ""
            let value           = values[kAXValueAttribute] as? String
                ?? (values[kAXValueAttribute] as? NSNumber)?.stringValue ?? ""
            let elementFrame = frame(
                positionValue: values[kAXPositionAttribute],
                sizeValue    : values[kAXSizeAttribute]
            )
            let identifier    = values[kAXIdentifierAttribute] as? String ?? ""
            let help          = values[kAXHelpAttribute] as? String ?? ""
            let placeholder   = values[kAXPlaceholderValueAttribute] as? String ?? ""
            let enabled       = (values[kAXEnabledAttribute] as? NSNumber)?.boolValue
            let selected      = (values[kAXSelectedAttribute] as? NSNumber)?.boolValue
            let expanded      = (values[kAXExpandedAttribute] as? NSNumber)?.boolValue
            let focused       = (values[kAXFocusedAttribute] as? NSNumber)?.boolValue
            let selectedText  = values[kAXSelectedTextAttribute] as? String ?? ""
            let selectedRange = rangeValue(values[kAXSelectedTextRangeAttribute])
            textBytes += title.utf8.count + nodeDescription.utf8.count + value.utf8.count
                + identifier.utf8.count + help.utf8.count + placeholder.utf8.count
                + selectedText.utf8.count
            signatureHasher.combine(role)
            signatureHasher.combine(title)
            signatureHasher.combine(nodeDescription)
            signatureHasher.combine(entry.parentNodeID)
            signatureHasher.combine(identifier)
            signatureHasher.combine(help)
            signatureHasher.combine(placeholder)
            signatureHasher.combine(enabled)
            signatureHasher.combine(selected)
            signatureHasher.combine(expanded)
            signatureHasher.combine(focused)
            signatureHasher.combine(value)
            signatureHasher.combine(elementFrame.map { Int($0.origin.x) })
            signatureHasher.combine(elementFrame.map { Int($0.origin.y) })

            // Character geometry is asked of the nodes that answered with a
            // selected range, which is the provider's own way of saying it
            // tracks text. Asking every node would be a round trip per node for
            // an answer only text can give.
            let textPoints = selectedRange == nil
                ? (start: CGPoint?.none, end: CGPoint?.none)
                : textEndpoints(of: element, text: value)

            axTree.append(AXElementNode(
                nodeID           : nodeID,
                parentNodeID     : entry.parentNodeID,
                depth            : entry.depth,
                role             : role,
                title            : title,
                description      : nodeDescription,
                value            : value,
                help             : help,
                placeholder      : placeholder,
                identifier       : identifier,
                frame            : elementFrame,
                isEnabled        : enabled,
                isSelected       : selected,
                isExpanded       : expanded,
                isFocused        : focused,
                selectedText     : selectedText,
                selectedRange    : selectedRange,
                textStartPoint   : textPoints.start,
                textEndPoint     : textPoints.end,
                attributeWarnings: attributes.warnings
            ))
            for child in elements(values[kAXChildrenAttribute]) ?? [] {
                let identity = ElementIdentity(element: child)
                guard !scheduled.contains(identity) else {
                    limitReason = "accessibility hierarchy with cyclic or shared references"
                    continue
                }
                guard pending.count < maximumTreeNodes else {
                    limitReason = "accessibility acquisition limit: over 20000 nodes"
                    break
                }
                scheduled.insert(identity)
                pending.append((child, nodeID, entry.depth + 1))
            }
        }
        if textBytes > 16_000_000 {
            limitReason = "accessibility acquisition limit: over 16 MB of text"
        }

        return ResolvedWindow(
            applicationName    : applicationName,
            applicationIsActive: runningApplication.isActive,
            window             : window,
            windowFrame        : windowFrame,
            windowNumber       : windowNumber,
            axTree             : axTree,
            axTreeWasTruncated : limitReason != nil || pendingIndex < pending.count,
            signature          : signatureHasher.finalize(),
            limitReason        : limitReason
        )
    }

    // MARK: Finding the window, and the one write that makes it readable

    /// How long a target is given to build its tree after the switch below is
    /// written, in seconds. Measured on 26A5425a: a cold Electron target still
    /// answered with fifteen nodes at one second and with 1673 at two, so the
    /// ceiling is that measurement plus half again. The blind
    /// 400 ms sleep this replaces was below the real latency of a cold target.
    static let manualAccessibilityCeilingSeconds = 3.0

    private static let manualAccessibilityPollInterval: UInt32 = 20_000

    /// What separates a built tree from one that has not arrived yet, and the
    /// cap that stops the counting walk early.
    ///
    /// It is a plain node count and not a depth limited one, because a depth
    /// limited count cannot answer the question at all: measured on this build,
    /// an Electron window reports seven descendants down to depth three whether
    /// its tree holds 1452 nodes or fifteen. Its content sits at depth seven and
    /// deeper, so a shallow count stabilises inside sixty milliseconds in both
    /// cases and reads the thin tree every time.
    private static let builtTreeNodeCap = 64

    /// Picks the window to read, after making the target readable.
    ///
    /// The switch below is written first and its answer is the whole test: it is
    /// a Chromium family attribute, so an application that accepts it is one
    /// that builds its tree on demand, and one that refuses it needs nothing
    /// and waits for nothing. Asking the window "do you have children" instead
    /// would not work: an unmanaged Chrome window already answers with a
    /// handful of them, which is exactly the thin tree the switch exists to
    /// replace.
    private static func window(
        of applicationElement: AXUIElement,
        requestedWindowNumber: Int?,
        isChromiumBrowser    : Bool
    ) throws -> AXUIElement? {

        if isChromiumBrowser {
            return try chromiumWindow(of: applicationElement, requestedWindowNumber: requestedWindowNumber)
        }
        guard enableManualAccessibility(applicationElement) else {
            return pickWindow(of: applicationElement, requestedWindowNumber: requestedWindowNumber)
        }
        // The target builds the tree asynchronously, so the wait is on the
        // condition and not on the clock, and it ends on whichever of three
        // answers arrives first: the tree is already built (it passes the cap),
        // it grew and then stopped growing, or the ceiling expires.
        //
        // Stability alone is not enough, which is the trap this loop was written
        // into once already: an unbuilt tree is perfectly stable, so a rule that
        // returns on "the count stopped changing" returns the thin tree inside
        // sixty milliseconds and calls the switch useless. Growth has to be seen
        // before stability means anything.
        var window          = pickWindow(of: applicationElement, requestedWindowNumber: requestedWindowNumber)
        // A named window the application does not list is **absent**, not late,
        // and waiting the ceiling out for it would slow a caller's recovery
        // loop down by 400 ms an attempt. The tree is what arrives late here,
        // never the window list.
        if window == nil, !windowList(of: applicationElement).isEmpty { return nil }

        // A target whose tree is already built answers here, before the first
        // sleep, and pays the walk to the cap and nothing else.
        var previousCount    = window.map { cappedDescendantCount(of: $0) } ?? 0
        if previousCount >= builtTreeNodeCap { return window }

        var hasGrown         = false
        var agreementCount   = 0
        let deadline         = Date(timeIntervalSinceNow: manualAccessibilityCeilingSeconds)
        repeat {
            usleep(manualAccessibilityPollInterval)
            window = pickWindow(
                of                   : applicationElement,
                requestedWindowNumber: requestedWindowNumber
            ) ?? window
            let count = window.map { cappedDescendantCount(of: $0) } ?? 0
            if count >= builtTreeNodeCap { return window }
            if count > previousCount {
                hasGrown       = true
                agreementCount = 0
            } else if hasGrown, count == previousCount {
                agreementCount += 1
                if agreementCount >= 2 { return window }
            }
            previousCount = count
        } while Date() < deadline
        return window
    }

    /// Chrome does not implement Electron's manual switch. Reading the app
    /// role requests native accessibility; individual roles in the content
    /// hierarchy then request web accessibility. No additional AX write is used.
    private static func chromiumWindow(
        of applicationElement: AXUIElement,
        requestedWindowNumber: Int?
    ) throws -> AXUIElement? {
        _ = stringAttribute(applicationElement, kAXRoleAttribute as CFString)
        guard var selected = pickWindow(
            of: applicationElement,
            requestedWindowNumber: requestedWindowNumber
        ) else { return nil }
        let initial = chromiumContent(of: selected)
        if initial.hasWebArea || (!initial.hasTabs && !initial.wasTruncated) { return selected }
        let deadline = Date(timeIntervalSinceNow: 4)
        repeat {
            usleep(manualAccessibilityPollInterval)
            guard let current = pickWindow(
                of: applicationElement,
                requestedWindowNumber: requestedWindowNumber
            ) else { return nil }
            selected = current
            if chromiumContent(of: selected).hasWebArea { return selected }
        } while Date() < deadline
        throw WindowReaderError.webAccessibilityNotReady(windowNumber: requestedWindowNumber)
    }

    /// Read roles before children: querying a web container can itself ask
    /// Chromium to publish renderer accessibility. Native Chrome dialogs have
    /// no tab group, so they remain readable without demanding a web subtree.
    private static func chromiumContent(of window: AXUIElement) -> ChromiumAXTreeReadiness.Reading {
        ChromiumAXTreeReadiness.read(
            root: ElementIdentity(element: window),
            role: { stringAttribute($0.element, kAXRoleAttribute as CFString) },
            children: { children(of: $0.element).map { ElementIdentity(element: $0) } }
        )
    }

    /// How many descendants the window has, stopping at `cap`.
    ///
    /// No depth limit: the cap is what makes this cheap, and a depth limit is
    /// what made the previous version blind. A built tree reaches the cap in its
    /// first walk; an unbuilt one is a handful of nodes, so the walk is short in
    /// the case that has to be detected too.
    private static func cappedDescendantCount(
        of element: AXUIElement,
        cap       : Int = builtTreeNodeCap
    ) -> Int {
        var count   = 0
        var pending = [element]
        while let node = pending.popLast() {
            let offspring = children(of: node)
            count += offspring.count
            if count >= cap { return cap }
            pending += offspring
        }
        return count
    }

    private static func pickWindow(
        of applicationElement: AXUIElement,
        requestedWindowNumber: Int?
    ) -> AXUIElement? {

        let windows = windowList(of: applicationElement)
        guard !windows.isEmpty else { return nil }
        guard let requestedWindowNumber else { return windows[0] }
        return windows.first { windowNumber(for: $0) == requestedWindowNumber }
    }

    private static func windowList(of applicationElement: AXUIElement) -> [AXUIElement] {
        elements(attribute(applicationElement, kAXWindowsAttribute as CFString)) ?? []
    }

    /// **The single write this package makes to a target through
    /// accessibility**, and the reason it is allowed (ADR 0009, user's decision
    /// of 09/09/2026).
    ///
    /// Chromium based applications, Electron and CEF included, build their
    /// accessibility tree only when a client asks for it explicitly: without
    /// this switch they expose a handful of elements and no text at all, so it
    /// is the precondition of reading the tree, not an action on the target. It
    /// changes no state the person can see, presses nothing and moves nothing.
    /// Every other write, including `AXSize`, stays outside the kit.
    ///
    /// The switch is idempotent and it is not remembered: a cache keyed on a pid
    /// goes stale the moment the system recycles that pid, and one accessibility
    /// write costs less than remembering the answer wrongly. True means the
    /// target accepted it, which is also how a target that needs it is told from
    /// one that does not.
    @discardableResult
    private static func enableManualAccessibility(_ applicationElement: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(
            applicationElement,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        ) == .success
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        elements(attribute(element, kAXChildrenAttribute as CFString)) ?? []
    }

    // MARK: Reading one value

    /// Where the node's text begins and ends, when the node can say where its
    /// own characters are. Both are `nil` when it cannot: the frame's edges are
    /// a guess, and a guess is the caller's business, not the reader's.
    private static func textEndpoints(
        of element: AXUIElement,
        text      : String
    ) -> (start: CGPoint?, end: CGPoint?) {

        let length = text.utf16.count
        guard length > 0,
              let first = bounds(for: NSRange(location: 0, length: 1), in: element),
              let last  = bounds(for: NSRange(location: length - 1, length: 1), in: element),
              first.width > 0, last.width > 0
        else {
            return (nil, nil)
        }
        return (
            CGPoint(x: first.minX + first.width * 0.5, y: first.midY),
            CGPoint(x: last.maxX - last.width * 0.2,   y: last.midY)
        )
    }

    private static func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else {
            return nil
        }
        return value
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: CFString) -> String? {
        attribute(element, name) as? String
    }

    private static func boolAttribute(_ element: AXUIElement, _ name: CFString) -> Bool? {
        (attribute(element, name) as? NSNumber)?.boolValue
    }

    private static func elements(_ value: CFTypeRef?) -> [AXUIElement]? {
        value as? [AXUIElement]
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        frame(
            positionValue: attribute(element, kAXPositionAttribute as CFString),
            sizeValue    : attribute(element, kAXSizeAttribute as CFString)
        )
    }

    private static func frame(positionValue: CFTypeRef?, sizeValue: CFTypeRef?) -> CGRect? {
        guard
            let positionValue,
            let sizeValue,
            CFGetTypeID(positionValue) == AXValueGetTypeID(),
            CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else {
            return nil
        }
        var position = CGPoint.zero
        var size     = CGSize.zero
        let positionAXValue = unsafeDowncast(positionValue, to: AXValue.self)
        let sizeAXValue     = unsafeDowncast(sizeValue, to: AXValue.self)
        guard
            AXValueGetValue(positionAXValue, .cgPoint, &position),
            AXValueGetValue(sizeAXValue, .cgSize, &size)
        else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func rangeValue(_ value: CFTypeRef?) -> NSRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private static func bounds(for range: NSRange, in element: AXUIElement) -> CGRect? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var rawBounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &rawBounds
        ) == .success,
        let rawBounds,
        CFGetTypeID(rawBounds) == AXValueGetTypeID()
        else {
            return nil
        }
        var bounds = CGRect.zero
        let boundsValue = unsafeDowncast(rawBounds, to: AXValue.self)
        guard AXValueGetValue(boundsValue, .cgRect, &bounds) else { return nil }
        return bounds
    }

    /// `_AXUIElementGetWindow` lives in `WindowPlacement`, gated per build: the
    /// probe does not resolve the private symbol on its own.
    private static func windowNumber(for window: AXUIElement) -> Int? {
        WindowRelocator.windowNumber(of: window)
    }
}
