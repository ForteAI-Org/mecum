import AutomationRuntime
import InteractionListener
import InteractionObservation

/// WatcherSession owns one passive run. stop joins native teardown; run joins perception cleanup.
/// No action engine, provider, workspace store or learned-action memory participates.
@MainActor
protocol WatcherSession: AnyObject {
    func run(
        report: @escaping @MainActor (InteractionReport) -> Void,
        status: @escaping @MainActor (InteractionObserverStatus) -> Void
    ) async throws
    func stop() async
}

/// NativeWatcherSession composes the same production observer as the CLI inside Mecum's process.
@MainActor
final class NativeWatcherSession: WatcherSession {
    private let listener: PassiveInteractionListener
    private let observer: InteractionObserver

    init(application: WatcherApplication?) throws {
        listener = try PassiveInteractionListener(eventBufferLimit: 256)
        observer = InteractionObserver(
            reader: InteractionSceneReader(pipeline: ProductionPerception.pipeline()),
            processID: application?.processID
        )
    }

    func run(
        report: @escaping @MainActor (InteractionReport) -> Void,
        status: @escaping @MainActor (InteractionObserverStatus) -> Void
    ) async throws {
        do {
            try await observer.run(listener: listener, report: report, diagnostic: { _ in }, status: status)
        } catch {
            await listener.stop()
            throw error
        }
        await listener.stop()
    }

    func stop() async { await listener.stop() }
}
