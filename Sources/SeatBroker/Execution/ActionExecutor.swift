import CoreGraphics
import SeatCore

/// One complete Mecum Command. A semantic action can expand into a succession,
/// but every member is sent against its own observation.
enum ActionInput: Sendable, Equatable {
    case command(InputCommand)
    case shortcut(Shortcut)
}

/// Converts an observed action into Mecum's public input vocabulary. The frame
/// that produced the observation remains the authority for click coordinates.
enum ActionExecutor {
    /// Every action whose whole effect is a succession of Commands, and no
    /// other: the menu action's seam is above this function, not inside it.
    ///
    /// A contextual menu is one scoped interaction rather than a list of
    /// inputs. It owns its own opening, its own recipient surface, its own
    /// closing guarantee and its own budget, and it spends the parent
    /// observation on the way in. An `ActionInput` case for it would put all of
    /// that behind `driver.send`, which answers one Receipt per input against
    /// one reference and has nowhere to put a body that runs between the two.
    /// So `AgentSession.execute` routes a menu action before it reaches here,
    /// and arriving here at all is a routing mistake rather than an action.
    static func inputs(for action: SemanticAction, in observation: SceneObservation,
                       frame: FrameGeometryObservation) throws -> [ActionInput] {
        if case .key(let key, let modifiers) = action {
            if modifiers.isEmpty, key == .slash || key == .tilde {
                return [.command(.text(key.rawValue))]
            }
            return [.shortcut(try shortcut(key, modifiers))]
        }
        let location = try location(ofElement: action.element ?? 0, in: observation, frame: frame)
        switch action {
        case .click(_, let count):
            return [.command(.click(location, count: count))]
        case .type(_, let text):
            return [.command(.click(location)), .command(.insertText(text))]
        case .scroll(_, let deltaY):
            return [.command(.scroll(location, deltaY: deltaY))]
        case .key(let key, let modifiers):
            return [.shortcut(try shortcut(key, modifiers))]
        case .menu:
            throw SeatBrokerError.capabilityMissing(
                "a contextual menu action decomposes into no plain inputs; it is routed by execute")
        }
    }

    /// Where an element's centre is, under the geometry its own observation was
    /// taken with. It is the one aiming rule in the kit, and a menu action uses
    /// it too: the right click that opens a contextual menu lands on the same
    /// point an ordinary click on that element would.
    static func location(ofElement index: Int, in observation: SceneObservation,
                         frame: FrameGeometryObservation) throws -> InputLocation {
        guard let element = observation.elements.first(where: { $0.index == index }) else {
            throw SeatBrokerError.elementOutOfRange(index: index, count: observation.elements.count)
        }
        let pixel = element.center(in: observation.pixelSize)
        guard let location = InputLocation(pixelPoint: pixel, observedIn: frame), location.isFinite else {
            throw SeatBrokerError.frameUnavailable
        }
        return location
    }

    private static func shortcut(_ key: KeyName, _ modifiers: KeyModifiers) throws -> Shortcut {
        var held: Modifiers = []
        if modifiers.contains(.command) { held.insert(.command) }
        if modifiers.contains(.shift) { held.insert(.shift) }
        if modifiers.contains(.option) { held.insert(.option) }
        if modifiers.contains(.control) { held.insert(.control) }

        if let name = physicalName(key) {
            guard let physical = KeyNames.key(named: name) else {
                throw SeatBrokerError.capabilityMissing("Mecum physical key \(name)")
            }
            return .physical(physical, holding: held)
        }
        guard key.rawValue.count == 1, let character = key.rawValue.first else {
            throw SeatBrokerError.capabilityMissing("Mecum shortcut for \(key.rawValue)")
        }
        return .character(character, holding: held)
    }

    /// Planner control names are translated to Mecum's physical-key names.
    /// Virtual key codes and character layouts belong to Mecum alone.
    private static func physicalName(_ key: KeyName) -> String? {
        switch key {
        case .return: "Enter"
        case .escape: "Escape"
        case .tab: "Tab"
        case .space: "Space"
        case .delete: "Backspace"
        case .up: "ArrowUp"
        case .down: "ArrowDown"
        case .left: "ArrowLeft"
        case .right: "ArrowRight"
        default: nil
        }
    }
}
