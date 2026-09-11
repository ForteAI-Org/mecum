//
//  CancellationSafePause.swift
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

import Foundation

/// pauseIgnoringCancellation waits without throwing on cancellation, unlike
/// `Task.sleep`. Teardown and recovery need it: a window that was moved has to
/// be moved back even when the task carrying the work was cancelled, and a
/// pause that throws there would leave the person's window on a display that is
/// about to disappear.
public func pauseIgnoringCancellation(nanoseconds: UInt64) async {
    await withCheckedContinuation { continuation in
        
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Double(nanoseconds) / 1_000_000_000
            
        ) { continuation.resume() }
    }
}
