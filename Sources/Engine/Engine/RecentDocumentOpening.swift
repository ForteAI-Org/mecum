import EngineCore
import Foundation
import PerceptionCore

/// RecentDocumentOpening delivers once, waits for an exact document witness, then adopts its window.
/// A timeout or failure after delivery stays unverified; it never retries or confirms another dialog.
@MainActor
public struct RecentDocumentOpening {
    private let menus: any ApplicationMenuOperating
    private let windows: any WindowListing
    private let wait: @MainActor () async throws -> Void
    private let attempts: Int

    public init(menus: any ApplicationMenuOperating, windows: any WindowListing,
                attempts: Int = 80,
                wait: @escaping @MainActor () async throws -> Void = {
                    try await Task.sleep(for: .milliseconds(250))
                }) {
        self.menus = menus
        self.windows = windows
        self.attempts = max(1, attempts)
        self.wait = wait
    }

    public func perform(path: [String], processID: pid_t, bundleID: String,
                        adopt: @MainActor (String) async throws -> SceneSnapshot) async -> ActOutcome {
        var delivered = false
        do {
            let document = try RecentDocument(path: path)
            try Task.checkCancellation()
            let catalog = try menus.catalog(processID: processID)
            let matches = catalog.matching(path: path)
            guard catalog.isComplete, matches.count == 1, let item = matches.first,
                  item.path == path, item.isEnabled == true, !item.hasSubmenu else {
                throw MenuFailure("The recent document is missing, ambiguous, disabled or incompletely read.")
            }
            let before = try inventory(processID)
            guard !before.contains(where: { document.matches(windowTitle: $0.title) }) else {
                throw MenuFailure("That document is already open. Use open_session and observe it; no menu was pressed.")
            }
            let delivery = try await menus.invoke(path: path, processID: processID)
            delivered = true
            if case .uncertain(let reason) = delivery {
                return ActOutcome(.actedUnverified, reason + " Read windows before continuing. Do not replay open_recent.")
            }
            var previous: WindowRow?
            for _ in 0..<attempts {
                try await wait()
                try Task.checkCancellation()
                let visible = try inventory(processID).filter {
                    WindowSurfaceClassifier.isWindowLayer($0.layer)
                        && WindowSurfaceClassifier.isSubstantialWindow($0.frame)
                }
                let documents = visible.filter { document.matches(windowTitle: $0.title) }
                let intermediates = visible.filter { row in
                    guard let title = row.title, !title.isEmpty else { return false }
                    return !before.contains { $0.number == row.number && $0.title == title }
                }
                let candidates = documents.isEmpty ? intermediates : documents
                guard candidates.count == 1, let candidate = candidates.first else {
                    previous = nil
                    continue
                }
                if previous?.number == candidate.number, previous?.title == candidate.title,
                   let title = candidate.title {
                    let scene = try await adopt(title)
                    let readback = try inventory(processID).filter { $0.title == title }
                    guard scene.bundleID == bundleID, scene.coverage == .window,
                          scene.windowTitle == title,
                          scene.viewportPixelSize.width >= 120, scene.viewportPixelSize.height >= 120,
                          readback.count == 1, readback.first?.number == candidate.number else {
                        throw MenuFailure("The adopted scene does not attest the window that appeared.")
                    }
                    guard document.matches(windowTitle: title) else {
                        return ActOutcome(.actedUnverified, "The command opened '\(title)', which is now on the Seat. "
                            + "The requested document is not verified. Inspect this window before continuing; "
                            + "do not replay open_recent or automatically confirm a dialog.", scene: scene)
                    }
                    return ActOutcome(.foundActed, "Opened the recent document and verified its full path in "
                                      + "two inventories and the adopted scene.", scene: scene)
                }
                previous = candidate
            }
            throw MenuFailure("The requested document was not verified within the opening allowance.")
        } catch {
            return ActOutcome(delivered ? .actedUnverified : .refused,
                              "\(error)" + (delivered
                                ? " The command may have happened. Read windows and adopt the result; do not replay open_recent."
                                : " No recent-document command was delivered."))
        }
    }

    private func inventory(_ pid: pid_t) throws -> [WindowRow] {
        guard let rows = try windows.allWindows(ownedBy: pid),
              Set(rows.map(\.number)).count == rows.count else {
            throw MenuFailure("A complete, unambiguous window inventory is unavailable.")
        }
        return rows
    }
}
