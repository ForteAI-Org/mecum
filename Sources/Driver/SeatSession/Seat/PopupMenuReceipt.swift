import CoreGraphics
import SeatCore

/// Evidence for a dropdown operation. Consumers must verify the selected value separately.
/// Native actions have no input receipts; mouse and keyboard commands retain their actual receipts.
public struct PopupMenuReceipt: Sendable {
    public let menu: ContextMenu
    public let selectionRequested: Bool
    public let closedBy: ContextMenuReceipt.Closure
    public let observation: SeatObservation?
    public let opening: InputReceipt?
    public let choosing: [InputReceipt]

    init(menu: ContextMenu, selectionRequested: Bool, closedBy: ContextMenuReceipt.Closure,
         observation: SeatObservation?, opening: InputReceipt? = nil, choosing: [InputReceipt] = []) {
        self.menu = menu
        self.selectionRequested = selectionRequested
        self.closedBy = closedBy
        self.observation = observation
        self.opening = opening
        self.choosing = choosing
    }
}

public enum PopupMenuFailure: Error { case ambiguousMenu }
