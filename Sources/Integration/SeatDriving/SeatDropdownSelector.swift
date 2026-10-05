import CoreGraphics
import AccessibilityActions
import EngineCore
import Foundation
import Perception
import PerceptionCore
import SeatCapture
import SeatCore
import SeatSession
import WindowPlacement

/// SelectionResult is what one dropdown selection answered and what the selector perceived on the
/// way: the window before the menu opened, the menu as it read it (nil when none was read) and the
/// window after it closed (nil when the selection ended before it was read). The perceptions are the
/// ones the verdict was made from, for the caller's record; the outcome's scene is the last of them.
public struct SelectionResult: Sendable {

    public let outcome: ActOutcome
    public let receipt: PopupMenuReceipt?
    public let before: PerceivedWindow?
    public let menu: PerceivedWindow?
    public let after: PerceivedWindow?
    /// What the selector knew when it decided, for a developer's diagnosis; never in the outcome.
    public let diagnosis: SelectionDiagnosis

    public init(
        outcome  : ActOutcome,
        receipt  : PopupMenuReceipt?,
        before   : PerceivedWindow? = nil,
        menu     : PerceivedWindow? = nil,
        after    : PerceivedWindow? = nil,
        diagnosis: SelectionDiagnosis = SelectionDiagnosis()
    ) {
        self.outcome   = outcome
        self.receipt   = receipt
        self.before    = before
        self.menu      = menu
        self.after     = after
        self.diagnosis = diagnosis
    }
}

/// SelectionMiss is why a selection ended without the menu being asked to select, told apart where
/// the selector's own branches tell them apart. The outcome's sentence ("no unique …") is unchanged and
/// still covers several of these; this is the typed reason beside it.
public enum SelectionMiss: Error, Sendable, Equatable {
    /// The dropdown the control names was not resolved before anything opened: `matches` elements of
    /// the window's scene carried the name, 0 for none and 2 or more for an ambiguous name.
    case controlNotResolved(matches: Int)
    /// The menu was read and the item resolved to `matches` of its elements, not exactly one.
    case itemNotResolved(matches: Int)
    /// The menu was read and the item resolved, and no arrow route was planned: why for the rows the
    /// application named (nil when no row reader was given) and for the rows cut out of the pixels.
    case routeNotPlanned(namedRows: PopupRowPick.Refusal?, paintedRows: PopupRowPick.Refusal)
    /// The menu operation ended without asking for the selection, and the selector never read a menu.
    case menuNotRead
    /// The menu was read and a choice made, and the menu operation still did not ask for the selection.
    case selectionNotRequested
}

/// SelectionDiagnosis is what a selection knew when it decided: how the opener was found and which
/// label it carried (the value the route counts from), which menu path ran, the menu's rows as the
/// application named them and as the pixels painted them, the route, and the miss. A field is nil when
/// that step did not run or was not read: nothing here is reconstructed afterwards.
public struct SelectionDiagnosis: Sendable, Equatable {

    /// Where the opener came from.
    public enum OpenerSource: String, Sendable, Equatable {
        /// The window's scene resolved the control.
        case scene
        /// The scene did not, and the control's accessibility frame scoped a second reading that did.
        case accessibilityFrame
    }

    /// Which menu operation ran.
    public enum MenuPath: String, Sendable, Equatable {
        /// The application's own pop-up menu, opened and chosen through accessibility.
        case nativeMenu
        /// A custom menu opened by a click and chosen with arrow keys and Return.
        case keyboardRoute
    }

    public var openerLabel: String?
    public var openerSource: OpenerSource?
    public var menuPath: MenuPath?
    /// The menu's elements as the selector read them, in order; nil when no menu was read.
    public var menuLabels: [String]?
    /// The rows the application named for itself; nil when no row reader was given.
    public var namedRows: [String]?
    /// The rows cut out of the menu's pixels, a row's labels together; nil when no route was counted.
    public var paintedRows: [[String]]?
    /// The route chosen, as `PopupRowPick.Plan.route` says it; nil when none was.
    public var route: String?
    public var miss: SelectionMiss?

    public init() {}
}

/// SeatDropdownSelector keeps observation, opening, selection and verification in one Seat Turn.
/// The Driver owns the temporary menu and its cleanup. Perception identifies a row only in a
/// capture of that menu's attested window, never in the parent application's accessibility tree.
@MainActor
public struct SeatDropdownSelector {

    private let target: SeatTarget
    private let pipeline: ScenePipeline
    private let popupRows: (any PopupRowReading)?

    /// Creates a selector. `popupRows` is optional and nil by default: with a reader the arrow-key
    /// route is counted over the rows the application named for itself, scrolled-out ones included,
    /// and without one it is counted over the rows the pixels cut out of the painted page, which is
    /// what this always did.
    public init(target: SeatTarget, pipeline: ScenePipeline, popupRows: (any PopupRowReading)? = nil) {
        self.target = target
        self.pipeline = pipeline
        self.popupRows = popupRows
    }

    /// Selects one item in a flat native dropdown. Success requires the requested value to be
    /// visible at the original control after the menu closes. Capture diagnostics are optional and
    /// remain local to the caller; no images enter the outcome's text scene.
    public func select(
        control: String,
        item: String,
        identity: ApplicationIdentity,
        permissions: ActionPermissions = ActionPermissions(),
        dryRun: Bool = false,
        onMenu: @escaping @MainActor @Sendable (ContextMenu) -> Void = { _ in },
        onCapture: @escaping @MainActor @Sendable (String, CGImage) throws -> Void = { _, _ in }
    ) async throws -> SelectionResult {
        let seat = try target.agentSeat()
        let window = try target.currentWindow()
        let turn = try await seat.acquire()
        do {
            let result = try await perform(
                control: control, item: item, identity: identity, permissions: permissions,
                dryRun: dryRun, seat: seat, window: window, turn: turn, onMenu: onMenu, onCapture: onCapture
            )
            try seat.release(turn)
            return result
        } catch {
            do { try seat.release(turn) }
            catch let cleanup { throw DropdownFailure.cleanup(primary: String(describing: error), cleanup: String(describing: cleanup)) }
            throw error
        }
    }

    private func perform(
        control: String,
        item: String,
        identity: ApplicationIdentity,
        permissions: ActionPermissions,
        dryRun: Bool,
        seat: AgentSeat,
        window: AdoptedWindow,
        turn: Turn,
        onMenu: @escaping @MainActor @Sendable (ContextMenu) -> Void,
        onCapture: @escaping @MainActor @Sendable (String, CGImage) throws -> Void
    ) async throws -> SelectionResult {
        let beforeDelivery = try await target.observe()
        let beforeStill = beforeDelivery.frame
        let before = try await perceive(
            beforeStill, identity: identity, title: window.title,
            stage: "before", onCapture: onCapture
        )
        var opener: SceneElement?
        var scopedBounds: NormalizedRect?
        let resolution = before.scene.resolve(target: control)
        if case .found(let element) = resolution {
            opener = element
        } else if case .none = resolution,
                  beforeStill.geometry.windowObservation != nil,
                  let frame = try? DropdownOpening.frame(control: control, window: window.title, processID: window.reference.processID),
                  before.frame.contains(frame),
                  let bounds = AccessibilityFrameTrust.normalized(frame, in: before.frame),
                  let scoped = try await controlScene(beforeStill, bounds: bounds, identity: identity, title: window.title),
                  case .found(let value) = scoped.resolve(target: control) {
            scopedBounds = bounds
            opener = SceneElement(id: value.id, kind: .control, label: value.label, bounds: bounds, role: "AXPopUpButton")
        }
        var diagnosis = SelectionDiagnosis()
        guard let opener else {
            let labels = before.scene.elements.map(\.label).joined(separator: ", ")
            if case .ambiguous(let count) = resolution {
                diagnosis.miss = .controlNotResolved(matches: count)
            } else {
                diagnosis.miss = .controlNotResolved(matches: 0)
            }
            return SelectionResult(
                outcome: ActOutcome(.honestMiss, "dropdown '\(control)' is missing or ambiguous. Read: \(labels)", scene: before.scene),
                receipt: nil, before: before, diagnosis: diagnosis
            )
        }
        diagnosis.openerLabel  = opener.label
        diagnosis.openerSource = scopedBounds == nil ? .scene : .accessibilityFrame
        if !permissions.allowsDestructive,
           ActionPolicy.isDestructive(label: opener.label) || ActionPolicy.isDestructive(label: item) {
            return SelectionResult(
                outcome: ActOutcome(.refused, "selection requires --allow-destructive", scene: before.scene),
                receipt: nil, before: before, diagnosis: diagnosis
            )
        }
        if dryRun {
            return SelectionResult(
                outcome: ActOutcome(.dryRun, "would open '\(opener.label)' and select '\(item)' in its own menu window", scene: before.scene),
                receipt: nil, before: before, diagnosis: diagnosis
            )
        }
        var menuScene: SceneSnapshot?
        var menuWindow: PerceivedWindow?
        // Written by the menu callbacks as they decide, read once the menu operation has answered.
        var miss: SelectionMiss?
        var namedRows: [String]?
        var paintedRows: [[String]]?
        var chosenRoute: String?
        @MainActor @Sendable func readItem(_ menu: ContextMenu, fromDisplay: Bool) async throws -> SceneElement? {
            onMenu(menu)
            guard let identityOfMenu = menu.window.identity else { throw SeatDrivingFailure.frameUnusable }
            let observed: PerceivedWindow
            if fromDisplay {
                // Some custom menu window filters return scaled parent pixels. Capture the actual
                // display composition and crop only the attested, still-unmoved menu rectangle.
                let still = try await target.displayStill()
                guard still.geometry.isValid, let pixels = still.makeCGImage(),
                      still.geometry.screenRect.contains(menu.frame),
                      let live = WindowServerProbe.geometry(of: menu.window.windowNumber),
                      live.hasSameIdentity(as: menu.window), live.frame == menu.frame else {
                    throw SeatDrivingFailure.frameUnusable
                }
                let display = still.geometry.screenRect
                let scale = still.geometry.scaleFactor
                let crop = CGRect(x: (menu.frame.minX - display.minX) * scale,
                                  y: (menu.frame.minY - display.minY) * scale,
                                  width: menu.frame.width * scale, height: menu.frame.height * scale).integral
                guard let image = pixels.cropping(to: crop) else { throw SeatDrivingFailure.frameUnusable }
                try onCapture("menu", image)
                let scene = try await pipeline.perceive(image, of: ScenePipeline.Window(
                    bundleID: identity.bundleID, appName: identity.name, title: "Dropdown", frame: menu.frame
                ))
                observed = PerceivedWindow(scene: scene, frame: menu.frame)
            } else {
                observed = try await perceive(
                    try await SeatCaptureStream.still(of: .attestedWindow(identityOfMenu), timeout: .seconds(3)),
                    identity: identity, title: "Dropdown", stage: "menu", onCapture: onCapture
                )
            }
            menuScene  = observed.scene
            menuWindow = observed
            guard observed.frame == menu.frame else { throw SeatDrivingFailure.frameUnusable }
            switch Self.menuItem(item, in: observed.scene) {
                case .success(let element): return element
                case .failure(let reason) : miss = reason; return nil
            }
        }
        let receipt: PopupMenuReceipt
        if try DropdownOpening.canShow(control: opener.label, window: window.title, processID: window.reference.processID) {
            diagnosis.menuPath = .nativeMenu
            receipt = try await seat.useNativePopupMenu(
                of: window, turn: turn,
                opening: {
                    try DropdownOpening.show(control: opener.label, window: window.title, processID: window.reference.processID)
                }
            ) { menu in
                guard try await readItem(menu, fromDisplay: false) != nil else { return false }
                try Task.checkCancellation()
                try DropdownOpening.select(item: item, in: menu.frame, processID: window.reference.processID)
                return true
            }
        } else {
            // The observation's own geometry, which is what the seat converts a coordinate
            // through: the opener is clicked under the picture it was read in.
            guard let location = InputLocation(screenPoint: before.globalPoint(of: opener),
                                               observedIn: beforeDelivery.geometry) else {
                throw SeatDrivingFailure.frameUnusable
            }
            diagnosis.menuPath = .keyboardRoute
            receipt = try await seat.useDropdownMenu(
                openedAt: location, of: window, turn: turn, keyInterval: ActionTiming.standard.popupArrow
            ) { [rowReader = popupRows] menu in
                guard let element = try await readItem(menu, fromDisplay: true), let scene = menuScene else { return nil }
                // The rows the application named for itself, when a reader is there to ask: they
                // include what the page does not paint, so the distance between two items is the
                // real one. Pixel rows, and no wrap through a page, otherwise.
                let named = await rowReader?.popupRows(
                    ofProcess : window.reference.processID,
                    popupFrame: menu.frame
                ) ?? []
                let painted = PopupRowPick.rows(in: scene, windowFrame: menu.frame, popupFrame: menu.frame)
                if rowReader != nil { namedRows = named.map(\.title) }
                paintedRows = painted.map { $0.map(\.label) }
                let plan: PopupRowPick.Plan
                switch Self.route(named: rowReader == nil ? nil : named, painted: painted,
                                  currentValue: opener.label, target: element) {
                    case .success(let chosen): plan = chosen
                    case .failure(let reason): miss = reason; return nil
                }
                chosenRoute = plan.route
                let arrow = plan.delta > 0 ? Key.downArrow : Key.upArrow
                return Array(repeating: arrow, count: abs(plan.delta)) + [Key.return]
            }
        }
        let afterStill = try await target.windowStill()
        let after = try await perceive(
            afterStill, identity: identity, title: window.title,
            stage: "after", onCapture: onCapture
        )
        diagnosis.menuLabels  = menuScene?.elements.map(\.label)
        diagnosis.namedRows   = namedRows
        diagnosis.paintedRows = paintedRows
        diagnosis.route       = chosenRoute
        guard receipt.selectionRequested else {
            let labels = menuScene?.elements.map(\.label).joined(separator: ", ") ?? "unreadable"
            diagnosis.miss = miss ?? (menuScene == nil ? .menuNotRead : .selectionNotRequested)
            return SelectionResult(
                outcome: ActOutcome(.honestMiss, "no unique '\(item)' in the dropdown; menu closed. Items: \(labels)", scene: after.scene),
                receipt: receipt, before: before, menu: menuWindow, after: after, diagnosis: diagnosis
            )
        }
        let verified: Bool
        if let scopedBounds {
            let scoped = try await controlScene(afterStill, bounds: scopedBounds, identity: identity, title: window.title)
            if let scoped, case .found(let value) = scoped.resolve(target: item) {
                verified = LabelText.normalize(value.label) == LabelText.normalize(item)
                    && after.frame.size == before.frame.size
            } else { verified = false }
        } else {
            verified = after.scene.elements.contains { element in
                let original = opener.bounds.cgRect
                let current = element.bounds.cgRect
                let overlap = original.intersection(current)
                return LabelText.normalize(element.label) == LabelText.normalize(item)
                    && !overlap.isNull && overlap.width > 0
                    && overlap.height > min(original.height, current.height) * 0.5
            }
        }
        let message = verified
            ? "selected '\(item)' in menu window #\(receipt.menu.window.windowNumber); the dropdown now reads '\(item)'"
            : "requested '\(item)' in menu window #\(receipt.menu.window.windowNumber), but the dropdown value was not verified"
        return SelectionResult(
            outcome: ActOutcome(verified ? .foundActed : .actedUnverified, message, scene: after.scene),
            receipt: receipt, before: before, menu: menuWindow, after: after, diagnosis: diagnosis
        )
    }

    /// The menu element `item` names, or why there is not exactly one: the scene's own resolution.
    static func menuItem(_ item: String, in scene: SceneSnapshot) -> Result<SceneElement, SelectionMiss> {
        switch scene.resolve(target: item) {
            case .found(let element)  : .success(element)
            case .ambiguous(let count): .failure(.itemNotResolved(matches: count))
            case .none                : .failure(.itemNotResolved(matches: 0))
        }
    }

    /// The arrow route from the control's current value to `target`: over the rows the application named
    /// when there is a plan there (`named` is nil when no row reader was given, which counts as no rows),
    /// else over the painted rows without wrapping, as always; otherwise why neither has one.
    static func route(named: [PopupRow]?, painted: [[SceneElement]], currentValue: String,
                      target: SceneElement) -> Result<PopupRowPick.Plan, SelectionMiss> {
        let fromNames  = PopupRowPick.planning(rows: named ?? [], currentValue: currentValue, target: target.label)
        let fromPixels = PopupRowPick.planning(rows: painted, currentValue: currentValue, target: target, wraps: false)
        switch (fromNames, fromPixels) {
            case (.success(let plan), _): return .success(plan)
            case (_, .success(let plan)): return .success(plan)
            case (.failure(let names), .failure(let pixels)):
                return .failure(.routeNotPlanned(namedRows: named == nil ? nil : names, paintedRows: pixels))
        }
    }

    private func controlScene(
        _ still: SeatFrame, bounds: NormalizedRect, identity: ApplicationIdentity, title: String
    ) async throws -> SceneSnapshot? {
        guard still.geometry.windowObservation != nil, let image = still.makeCGImage() else { return nil }
        // Map the window region into the delivered surface, including ScreenCaptureKit padding.
        let content = still.geometry.contentRectInSurface
        let scale = still.geometry.scaleFactor
        let pixels = bounds.pixelBox(in: CGSize(width: content.width * scale, height: content.height * scale))
            .offsetBy(dx: content.minX * scale, dy: content.minY * scale)
        let imageBounds = NormalizedRect(
            x: pixels.minX / CGFloat(image.width), y: pixels.minY / CGFloat(image.height),
            width: pixels.width / CGFloat(image.width), height: pixels.height / CGFloat(image.height)
        )
        return try await pipeline.perceive(
            image, inside: imageBounds, of: ScenePipeline.Window(bundleID: identity.bundleID, appName: identity.name, title: title)
        )
    }

    private func perceive(
        _ still: SeatFrame,
        identity: ApplicationIdentity,
        title: String,
        stage: String,
        onCapture: (String, CGImage) throws -> Void
    ) async throws -> PerceivedWindow {
        guard still.geometry.isValid, let image = still.makeCGImage() else { throw SeatDrivingFailure.frameUnusable }
        try onCapture(stage, image)
        let frame = still.geometry.screenRect
        let scene = try await pipeline.perceive(image, of: ScenePipeline.Window(
            bundleID: identity.bundleID, appName: identity.name, title: title
        ))
        return PerceivedWindow(scene: scene, frame: frame)
    }
}

/// DropdownFailure preserves both the primary operation error and a failed Turn release.
public enum DropdownFailure: Error {
    case cleanup(primary: String, cleanup: String)
}
