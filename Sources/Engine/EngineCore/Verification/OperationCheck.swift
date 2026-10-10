//
//  OperationCheck.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 09/10/2026.
//

import PerceptionCore

/// OperationCheck is what one operation's oracle actually controlled, in the terms the oracle used:
/// the condition it judged, the method and its version, the verdict, the expected and observed
/// values when the method compares any, the limits of that evidence, the gesture that really went
/// out and the target it went to. It travels with the operation's `ActOutcome`, so the living
/// memory records the judgement the engine made instead of reinterpreting the outcome's sentence.
///
/// The verdict is about the condition only. `passed` on `structuralEffect` says a change was
/// attributed to the gesture, not that the user's goal was reached; `unknown` stays unknown
/// whatever the outcome's kind says. A path with no oracle reports the condition `none` and an
/// `unknown` verdict, never a pass.
public struct OperationCheck: Sendable, Equatable {

    /// Condition is the fact an oracle judged.
    public enum Condition: String, Sendable, Equatable, Hashable, CaseIterable {

        /// The requested state was already present before any gesture (`set_toggle` already on).
        case requestedStateAlreadyPresent = "requested_state_already_present"

        /// The control's state read after the gesture against the requested one.
        case stateAfterGesture = "state_after_gesture"

        /// A value read back after the gesture against the expected one: a field's text, a
        /// dropdown's value, a pop-up's current item.
        case valueReadBack = "value_read_back"

        /// A structural change of the window attributed to the gesture by the scene difference.
        case structuralEffect = "structural_effect"

        /// A pop-up menu the choice was made in closed afterwards.
        case menuClosedAfterChoice = "menu_closed_after_choice"

        /// A submenu opened after a choice in a pop-up.
        case submenuOpened = "submenu_opened"

        /// The application's set of windows changed after a menu command or a dialog button.
        case windowSetChanged = "window_set_changed"

        /// Another gesture than the requested one ran to recover the window (a pop-up dismissed),
        /// and its own effect is what was judged. The requested operation was not performed.
        case recoveryInsteadOfRequest = "recovery_instead_of_request"

        /// A contextual menu's item was requested from the menu the Driver opened and the menu was
        /// withdrawn; the command's own effect in the application is a separate, unchecked fact.
        case menuItemChosen = "menu_item_chosen"

        /// The path has no oracle for the operation: nothing was compared.
        case none
    }

    /// Method is how the condition was judged.
    public enum Method: String, Sendable, Equatable, Hashable, CaseIterable {

        /// The difference between the scene before and the scene after, with the pop-up census.
        case sceneDifference = "scene_difference"

        /// A control's state read back through accessibility, or from the scene's element.
        case controlState = "control_state"

        /// A control's or a field's value read back through accessibility or from the scene.
        case controlValue = "control_value"

        /// Text recognized in a region of the window.
        case sceneText = "scene_text"

        /// The window server's census of pop-up and menu windows.
        case windowCensus = "window_census"

        /// The application's accessibility windows, by role, subrole and title.
        case windowSignature = "window_signature"

        /// The Driver's own receipt of a menu it opened, chose in and withdrew.
        case driverReceipt = "driver_receipt"

        /// Nothing was read.
        case none
    }

    /// Verdict is the closed result of the check.
    public enum Verdict: String, Sendable, Equatable, Hashable, CaseIterable {
        case passed, failed, unknown
    }

    /// Limit names what the evidence cannot say, so a reader does not take more from the verdict
    /// than the method gives.
    public enum Limit: String, Sendable, Equatable, Hashable, CaseIterable {

        /// The gesture's delivery failed or its result is not known: it may or may not have landed.
        case deliveryUncertain = "delivery_uncertain"

        /// No scene could be read after the gesture.
        case noAfterScene = "no_after_scene"

        /// The value or state could not be read back.
        case readbackUnavailable = "readback_unavailable"

        /// What the field held before could not be read, so the resulting value cannot be predicted.
        case previousValueUnknown = "previous_value_unknown"

        /// The Brain had no expectation for this element and verb: any structural change passes.
        case noExpectation = "no_expectation"

        /// The change was found anywhere in the window, not on the target itself.
        case windowWide = "window_wide"

        /// Only the menu or the window closed; the command's own effect was not checked.
        case commandEffectUnchecked = "command_effect_unchecked"

        /// The control was pressed through accessibility by its label, not at the resolved element.
        case labelMatchOnly = "label_match_only"

        /// The request gave no expected value to compare with.
        case noExpectedValue = "no_expected_value"

        /// No element was resolved for the operation.
        case targetNotResolved = "target_not_resolved"

        /// The change was found but could not be attributed to a structural effect.
        case unattributed = "unattributed"

        /// The value compared is withheld from the record (a secret): the verdict stands, the texts
        /// are not kept.
        case valueWithheld = "value_withheld"
    }

    /// Performed is the gesture that really went out, apart from the one requested.
    public enum Performed: String, Sendable, Equatable, Hashable, CaseIterable {

        /// The requested gesture went out.
        case requested

        /// Another gesture went out instead of the requested one (`substitute` names it).
        case substitute

        /// No gesture went out: a no-op, a refusal, a miss, a listing.
        case none

        /// A gesture was sent and its delivery failed or is unknown.
        case uncertain
    }

    /// Target is the element the operation resolved and acted on, as the scene named it then.
    public struct Target: Sendable, Equatable {
        public let elementID: String
        public let role: String?
        public let label: String
        public let section: String?

        public init(elementID: String, role: String?, label: String, section: String?) {
            self.elementID = elementID
            self.role      = role
            self.label     = label
            self.section   = section
        }

        public init(_ element: SceneElement) {
            self.init(elementID: element.id, role: element.role, label: element.label, section: element.section)
        }
    }

    public let condition: Condition
    public let method: Method
    public let methodVersion: String
    public let verdict: Verdict
    public let expected: String?
    public let observed: String?
    public let limits: [Limit]
    public let performed: Performed
    public let substitute: String?
    public let target: Target?

    public init(
        condition    : Condition,
        method       : Method,
        methodVersion: String = OperationCheck.engineVersion,
        verdict      : Verdict,
        expected     : String? = nil,
        observed     : String? = nil,
        limits       : [Limit] = [],
        performed    : Performed,
        substitute   : String? = nil,
        target       : Target? = nil
    ) {
        self.condition     = condition
        self.method        = method
        self.methodVersion = methodVersion
        self.verdict       = verdict
        self.expected      = expected
        self.observed      = observed
        self.limits        = Self.ordered(limits)
        self.performed     = performed
        self.substitute    = substitute
        self.target        = target
    }

    /// The version of the engine's oracles this build reports: bump it when a method's rule changes,
    /// so verdicts of two rules are never read as one.
    public static let engineVersion = "engine-oracle-1"

    /// The check of a path with no oracle: nothing compared, the verdict unknown.
    public static func unchecked(performed: Performed, limits: [Limit] = [], target: Target? = nil) -> OperationCheck {
        OperationCheck(condition: .none, method: .none, verdict: .unknown, limits: limits, performed: performed,
                       target: target)
    }

    /// The same check with other limits added, kept in their declared order and once each.
    public func adding(_ more: [Limit]) -> OperationCheck {
        OperationCheck(condition: condition, method: method, methodVersion: methodVersion, verdict: verdict,
                       expected: expected, observed: observed, limits: limits + more, performed: performed,
                       substitute: substitute, target: target)
    }

    /// The check of a scene difference's verdict on a gesture that went out: a structural effect
    /// that matches the expectation passes, one of another family fails, an identical scene fails,
    /// and a change with no attributable effect is unknown.
    public static func sceneDifference(
        _ verdict: ActVerification.Verdict,
        expected : SceneEffect?,
        target   : Target?,
        limits   : [Limit] = []
    ) -> OperationCheck {
        var more = limits
        if expected == nil { more.append(.noExpectation) }
        switch verdict {
            case .landed(let effect, let matches):
                return OperationCheck(condition: .structuralEffect, method: .sceneDifference,
                                      verdict: matches ? .passed : .failed, expected: expected?.family,
                                      observed: effect.family, limits: more, performed: .requested, target: target)
            case .ghost:
                return OperationCheck(condition: .structuralEffect, method: .sceneDifference, verdict: .failed,
                                      expected: expected?.family, observed: "unchanged", limits: more,
                                      performed: .requested, target: target)
            case .unattributable:
                return OperationCheck(condition: .structuralEffect, method: .sceneDifference, verdict: .unknown,
                                      expected: expected?.family, limits: more + [.unattributed],
                                      performed: .requested, target: target)
        }
    }

    private static func ordered(_ limits: [Limit]) -> [Limit] {
        var seen: Set<Limit> = []
        return limits.filter { seen.insert($0).inserted }
    }
}
