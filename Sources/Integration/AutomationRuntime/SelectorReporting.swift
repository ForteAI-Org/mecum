//
//  SelectorReporting.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 09/10/2026.
//

import EngineCore
import Foundation
import SeatDriving

/// SelectorReporting hands what a Seat selector perceived around a choice to the recorder of the call
/// that asked it, so a selection and a contextual menu keep their samples and target like any input.
public enum SelectorReporting {

    /// The selector's report, to `recorder` when the call has one; nothing otherwise.
    @MainActor
    public static func reporting(
        to recorder: CallRecorder?,
        bundleID   : String?
    ) -> @MainActor (SelectorPerception) async -> Void {
        { perception in
            guard let recorder, let bundleID else { return }
            await recorder.record(before: perception.before, menu: perception.menu, after: perception.after,
                                  bundleID: bundleID, target: perception.target)
        }
    }
}
