import ApplicationServices
import Testing
@testable import AccessibilityActions

@MainActor
@Suite("Native dropdown opening action")
struct DropdownOpeningTests {

    @Test("the primary dropdown action wins over its contextual menu action", arguments: [false, true])
    func primaryAction(reverse: Bool) {
        let actions = reverse ? [kAXShowMenuAction, kAXPressAction] : [kAXPressAction, kAXShowMenuAction]
        #expect(DropdownOpening.openingAction(in: actions) == kAXPressAction)
    }

    @Test("a dropdown exposing only its primary action can open")
    func primaryOnly() {
        #expect(DropdownOpening.openingAction(in: [kAXPressAction]) == kAXPressAction)
    }

    @Test("Show Menu remains available when it is the dropdown's only opening action")
    func showMenuOnly() {
        #expect(DropdownOpening.openingAction(in: [kAXShowMenuAction]) == kAXShowMenuAction)
        #expect(DropdownOpening.openingAction(in: []) == nil)
        #expect(DropdownOpening.openingAction(in: [kAXCancelAction]) == nil)
    }
}
