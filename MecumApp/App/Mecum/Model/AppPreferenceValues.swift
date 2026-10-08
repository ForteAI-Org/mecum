//
//  AppPreferenceValues.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/10/2026.
//

import Foundation
import Observation

/// AppPreferenceValues holds the preferences the team window reads, kept in
/// step with the defaults.
///
/// A view that reads a preference through `@AppStorage` is updated on every
/// write to the defaults, whatever its key, and the split view writes its
/// column widths there on each step of a drag, so the sidebar, each of its
/// rows, the composer and the transcript were all updated every frame. Here a
/// write that leaves a value as it was changes nothing, and a view updates only
/// when what it reads does. Settings still edits them through `@AppStorage`.
@MainActor
@Observable
final class AppPreferenceValues {

    /// The person's defaults, or in a snapshot run the suite the snapshots draw with.
    static let shared = AppPreferenceValues(
        defaults: WindowSnapshots.isRequested ? WindowSnapshots.appStorage ?? .standard : .standard
    )

    private(set) var sidebarShowsSearch         = AppPreferences.sidebarShowsSearchDefault
    private(set) var sidebarShowsModel          = AppPreferences.sidebarShowsModelDefault
    private(set) var sidebarShowsUnreadCount    = AppPreferences.sidebarShowsUnreadCountDefault
    private(set) var chatShowsTimes             = AppPreferences.chatShowsTimesDefault
    private(set) var chatOpensToolSteps         = AppPreferences.chatOpensToolStepsDefault
    private(set) var chatSendsWithCommandReturn = AppPreferences.chatSendsWithCommandReturnDefault
    private(set) var chatFontFamily             = AppPreferences.chatFontFamilyDefault
    private(set) var bodyPointSize              = Double(TranscriptStyle.actualSize.bodyPointSize)

    @ObservationIgnored private let defaults: UserDefaults

    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        read()
        // At once for a write on the main thread, so what draws next reads it; later for one from elsewhere.
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object : defaults,
            queue  : nil
        ) { [weak self] _ in
            guard Thread.isMainThread else {
                Task { @MainActor in self?.read() }
                return
            }
            MainActor.assumeIsolated { self?.read() }
        }
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Reads every value again, and sets only those that changed.
    private func read() {
        set(
            \.sidebarShowsSearch,
            to: bool(AppPreferences.sidebarShowsSearch, AppPreferences.sidebarShowsSearchDefault)
        )
        set(
            \.sidebarShowsModel,
            to: bool(AppPreferences.sidebarShowsModel, AppPreferences.sidebarShowsModelDefault)
        )
        set(
            \.sidebarShowsUnreadCount,
            to: bool(AppPreferences.sidebarShowsUnreadCount, AppPreferences.sidebarShowsUnreadCountDefault)
        )
        set(
            \.chatShowsTimes,
            to: bool(AppPreferences.chatShowsTimes, AppPreferences.chatShowsTimesDefault)
        )
        set(
            \.chatOpensToolSteps,
            to: bool(AppPreferences.chatOpensToolSteps, AppPreferences.chatOpensToolStepsDefault)
        )
        set(
            \.chatSendsWithCommandReturn,
            to: bool(AppPreferences.chatSendsWithCommandReturn, AppPreferences.chatSendsWithCommandReturnDefault)
        )
        set(
            \.chatFontFamily,
            to: defaults.string(forKey: AppPreferences.chatFontFamily) ?? AppPreferences.chatFontFamilyDefault
        )
        set(
            \.bodyPointSize,
            to: defaults.object(forKey: TextSizeCommands.storageKey) as? Double
                ?? Double(TranscriptStyle.actualSize.bodyPointSize)
        )
    }

    private func bool(
        _ key     : String,
        _ fallback: Bool
    ) -> Bool {
        AppPreferences.bool(
            key,
            default: fallback,
            in     : defaults
        )
    }

    private func set<Value: Equatable>(
        _ property: ReferenceWritableKeyPath<AppPreferenceValues, Value>,
        to value  : Value
    ) {
        if self[keyPath: property] != value { self[keyPath: property] = value }
    }
}
