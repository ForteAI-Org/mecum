//
//  AppWindowWatch.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 15/09/2026.
//

import ApplicationServices
import CoreFoundation
import Foundation

/// AppWindowWatch is the wake-up: it tells the seat that one of the processes
/// it is driving has just created a window. It reads nothing, decides nothing
/// and moves nothing.
///
/// ## Why accessibility is the wake-up and not the evidence
///
/// `kAXWindowCreatedNotification` arrives on the run loop, so between two
/// windows this process sleeps: there is no tight poll and no timer of its own.
/// Measured on this build with Accessibility granted, over eight openings on
/// three application families, the notification arrived 79 to 249 ms **before**
/// the window server published the window, and never after it. That lead is why
/// the notification cannot be the evidence: at the moment it fires there is
/// usually nothing on screen to read yet, and the geometry that follows has not
/// settled. It is a reason to look, and the window server is what is looked at.
///
/// Correctness therefore never depends on it. An Electron application was
/// measured offering no menu item that creates a native window at all, so the
/// family is undeclared rather than negative, and the periodic net behind this
/// is what covers a family whose notification never comes.
///
/// ## Why there is no destroyed notification here
///
/// `AXUIElementDestroyedNotification` does arrive, and the element it carries
/// is already invalid: `_AXUIElementGetWindow` answers -25201 and even `AXRole`
/// fails, so the notification cannot say **which** window died. A watch that
/// subscribed to it would learn only that something happened, which is what the
/// periodic pass already establishes with the Window ID attached.
///
/// ## Ownership and lifetime
///
/// One observer per process, created on the process's own accessibility
/// application element and added to the main run loop. `follow` reconciles the
/// set: processes that left lose their observer immediately. `stop` removes
/// every run loop source and drops the closure, so a notification already on
/// its way in finds nothing to call and does nothing.
final class AppWindowWatch {

    private struct Subscription {
        let observer   : AXObserver
        let application: AXUIElement
    }

    private var subscriptions: [Int32: Subscription] = [:]

    /// Dropped by `stop`, which is what makes a late callback inert rather than
    /// a call into a seat that has given the person their windows back.
    private var created: (() -> Void)?

    init(created: @escaping () -> Void) {
        self.created = created
    }

    /// Subscribes to the processes in the set and unsubscribes from every other
    /// one. Idempotent: a process already followed keeps the observer it has,
    /// so a seat that adopts a second window of the same application does not
    /// churn the run loop source.
    func follow(_ processIDs: Set<Int32>) {

        guard created != nil else { return }

        for processID in subscriptions.keys where !processIDs.contains(processID) {
            remove(processID)
        }
        for processID in processIDs where subscriptions[processID] == nil {
            add(processID)
        }
    }

    func stop() {
        created = nil
        for processID in subscriptions.keys { remove(processID) }
    }

    /// The processes this watch currently has an observer on, for a test that
    /// needs to see a subscription go away rather than infer it.
    var followedProcessIDs: Set<Int32> { Set(subscriptions.keys) }

    private func add(_ processID: Int32) {

        var observer: AXObserver?
        guard AXObserverCreate(processID, { _, _, _, context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<AppWindowWatch>.fromOpaque(context).takeUnretainedValue().windowCreated()
            }
        }, &observer) == .success, let observer else { return }

        let application = AXUIElementCreateApplication(processID)
        // The focus watch's timeout: blocking the main actor on a busy
        // target is worse than no subscription, the periodic pass covers it.
        AXUIElementSetMessagingTimeout(application, 0.05)

        guard AXObserverAddNotification(
            observer,
            application,
            kAXWindowCreatedNotification as CFString,
            Unmanaged.passUnretained(self).toOpaque()
        ) == .success else { return }

        subscriptions[processID] = Subscription(observer: observer, application: application)
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
    }

    private func remove(_ processID: Int32) {

        guard let subscription = subscriptions.removeValue(forKey: processID) else { return }

        AXObserverRemoveNotification(
            subscription.observer,
            subscription.application,
            kAXWindowCreatedNotification as CFString
        )
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(subscription.observer),
            .commonModes
        )
    }

    private func windowCreated() { created?() }

    isolated deinit { stop() }
}
