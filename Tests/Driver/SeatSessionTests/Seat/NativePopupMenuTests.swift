import CoreGraphics
import SeatCore
import SeatInput
@testable import SeatSession
import Testing

@MainActor
@Suite("Native dropdown lifecycle")
struct NativePopupMenuTests {
    private func ready() async throws -> (AgentSeat, AdoptedWindow, Turn, FakeSensing, FakeSender) {
        let sensing = FakeSensing()
        let sender = FakeSender()
        sender.onCyclePreparation = { sensing.menus = [] }
        let seat = makeSeat(sensing: sensing, sender: sender)
        let window = try await seat.adopt(FakeGeometry.userSeatWindow, platform: AppKitPlatform())
        return (seat, window, try await seat.acquire(), sensing, sender)
    }

    @Test("native selection observes the menu window and does not fabricate mouse events")
    func selects() async throws {
        let (seat, window, turn, sensing, sender) = try await ready()
        let receipt = try await seat.useNativePopupMenu(of: window, turn: turn, opening: {
            sensing.menus = [FakeGeometry.menuWindow]
        }) { menu in
            await Task.yield()
            #expect(menu.window.windowNumber == FakeGeometry.menuWindowNumber)
            sensing.menus = []
            return true
        }
        #expect(receipt.selectionRequested)
        #expect(receipt.closedBy == .chosenItem)
        #expect(sender.sent.isEmpty)
        #expect(sender.preparationCycles.isEmpty)
        #expect(seat.state == .ready)
        try seat.release(turn)
    }

    @Test("missing items close the menu without selecting anything")
    func missingItem() async throws {
        let (seat, window, turn, sensing, sender) = try await ready()
        let receipt = try await seat.useNativePopupMenu(of: window, turn: turn, opening: {
            sensing.menus = [FakeGeometry.menuWindow]
        }) { _ in false }
        #expect(!receipt.selectionRequested)
        #expect(receipt.closedBy == .preparationCycle)
        #expect(sensing.menus.isEmpty)
        #expect(sender.sent.isEmpty)
        try seat.release(turn)
    }

    @Test("reader cancellation still dismisses the menu and releases the action state")
    func readerCancelled() async throws {
        let (seat, window, turn, sensing, sender) = try await ready()
        await #expect(throws: CancellationError.self) {
            try await seat.useNativePopupMenu(of: window, turn: turn, opening: {
                sensing.menus = [FakeGeometry.menuWindow]
            }) { _ in throw CancellationError() }
        }
        #expect(sensing.menus.isEmpty)
        #expect(sender.sent.isEmpty)
        #expect(seat.state == .ready)
        try seat.release(turn)
    }

    @Test("an opening error after delivery does not leave a menu behind")
    func openingFailedAfterDelivery() async throws {
        let (seat, window, turn, sensing, _) = try await ready()
        await #expect(throws: CancellationError.self) {
            try await seat.useNativePopupMenu(of: window, turn: turn, opening: {
                sensing.menus = [FakeGeometry.menuWindow]
                throw CancellationError()
            }) { _ in Issue.record("must not select after an opening failure"); return true }
        }
        #expect(sensing.menus.isEmpty)
        try seat.release(turn)
    }

    @Test("an existing menu is preserved and the opener is never invoked")
    func alreadyOpen() async throws {
        let (seat, window, turn, sensing, sender) = try await ready()
        sensing.menus = [FakeGeometry.menuWindow]
        await #expect(throws: SessionFailure.contextMenuAlreadyOpen(processID: FakeGeometry.targetPID)) {
            try await seat.useNativePopupMenu(of: window, turn: turn, opening: {
                Issue.record("must not open on top of an existing menu")
            }) { _ in true }
        }
        #expect(sensing.menus.count == 1)
        #expect(sender.preparationCycles.isEmpty)
        try seat.release(turn)
    }

    @Test("two candidate menu windows refuse selection and are cleaned up")
    func ambiguousMenu() async throws {
        let (seat, window, turn, sensing, _) = try await ready()
        await #expect(throws: PopupMenuFailure.ambiguousMenu) {
            try await seat.useNativePopupMenu(of: window, turn: turn, opening: {
                sensing.menus = [FakeGeometry.menuWindow, FakeGeometry.menuWindow]
            }) { _ in Issue.record("must not guess the menu window"); return true }
        }
        #expect(sensing.menus.isEmpty)
        try seat.release(turn)
    }

    @Test("opening timeout performs cleanup without replaying the native request")
    func neverOpened() async throws {
        let (seat, window, turn, _, sender) = try await ready()
        var openings = 0
        await #expect(throws: SessionFailure.contextMenuNeverOpened(windowNumber: FakeGeometry.windowNumber, within: .milliseconds(30))) {
            try await seat.useNativePopupMenu(of: window, turn: turn, within: .milliseconds(30), opening: {
                openings += 1
            }) { _ in Issue.record("must not select without a menu"); return true }
        }
        #expect(openings == 1)
        #expect(sender.preparationCycles == [FakeGeometry.windowNumber])
        try seat.release(turn)
    }

    @Test("a menu that cannot close fails the Seat")
    func cannotClose() async throws {
        let (seat, window, turn, sensing, sender) = try await ready()
        sender.onCyclePreparation = nil
        await #expect(throws: SessionFailure.contextMenuNotClosed(menuWindowNumber: FakeGeometry.menuWindowNumber, processID: FakeGeometry.targetPID)) {
            try await seat.useNativePopupMenu(of: window, turn: turn, opening: {
                sensing.menus = [FakeGeometry.menuWindow]
            }) { _ in false }
        }
        #expect(seat.state == .failed)
    }

    @Test("a visual dropdown opens once and sends the measured keys while its menu exists")
    func routedDropdown() async throws {
        let (seat, window, turn, sensing, sender) = try await ready()
        sender.onSend = { command in
            if case .click = command { sensing.menus = [FakeGeometry.menuWindow] }
            if case .key(36, _, _, _, _) = command { sensing.menus = [] }
        }
        let receipt = try await seat.useDropdownMenu(
            openedAt: ContextMenuTests.openAt, of: window, turn: turn, keyInterval: .zero
        ) { menu in
            await Task.yield()
            #expect(menu.window.windowNumber == FakeGeometry.menuWindowNumber)
            return [126, 36]
        }
        #expect(sender.sent.count == 3)
        #expect(sender.sent.first?.command == .click(ContextMenuTests.openAt, button: .left))
        #expect(receipt.opening?.route.windowNumber == window.id)
        #expect(receipt.choosing.count == 2)
        #expect(sender.sent[1].command == .key(virtualKey: 126, text: ""))
        #expect(sender.sent[2].command == .key(virtualKey: 36, text: ""))
        #expect(receipt.closedBy == .chosenItem)
        #expect(receipt.selectionRequested)
        try seat.release(turn)
    }

    @Test("a visual menu with no matching item closes without posting a choice")
    func routedMissingItem() async throws {
        let (seat, window, turn, sensing, sender) = try await ready()
        sender.onSend = { _ in sensing.menus = [FakeGeometry.menuWindow] }
        let receipt = try await seat.useDropdownMenu(
            openedAt: ContextMenuTests.openAt, of: window, turn: turn, keyInterval: .zero
        ) { _ in nil }
        #expect(sender.sent.count == 1)
        #expect(receipt.choosing.isEmpty)
        #expect(!receipt.selectionRequested)
        #expect(receipt.closedBy == .preparationCycle)
        #expect(sensing.menus.isEmpty)
        try seat.release(turn)
    }

    @Test("a visual reader error cleans up and never replays the opener")
    func routedReaderFailure() async throws {
        let (seat, window, turn, sensing, sender) = try await ready()
        sender.onSend = { _ in sensing.menus = [FakeGeometry.menuWindow] }
        await #expect(throws: CancellationError.self) {
            try await seat.useDropdownMenu(
                openedAt: ContextMenuTests.openAt, of: window, turn: turn, keyInterval: .zero
            ) { _ in
                throw CancellationError()
            }
        }
        #expect(sender.sent.count == 1)
        #expect(sensing.menus.isEmpty)
        try seat.release(turn)
    }

    @Test("a menu that disappears between keys prevents Return from reaching the parent")
    func routedMenuDisappears() async throws {
        let (seat, window, turn, sensing, sender) = try await ready()
        sender.onSend = { command in
            if case .click = command { sensing.menus = [FakeGeometry.menuWindow] }
            if case .key = command { sensing.menus = [] }
        }
        await #expect(throws: (any Error).self) {
            try await seat.useDropdownMenu(
                openedAt: ContextMenuTests.openAt, of: window, turn: turn, keyInterval: .zero
            ) { _ in [126, 36] }
        }
        #expect(sender.sent.count == 2)
        #expect(sensing.menus.isEmpty)
        try seat.release(turn)
    }
}
