//
//  LiveSceneFailure.swift
//  Mecum
//
//  Created by Ronaldo Zefi on 18/09/2026.
//

/// LiveSceneFailure names why no scene could be perceived for a process.
public enum LiveSceneFailure: Error, Equatable {

    /// The process owns no window worth driving: nothing on screen, or only slivers and palettes.
    case noInteractionWindow(processID: Int32, rows: Int)
    /// The process is not a running application the identity closure knows.
    case unknownApplication(processID: Int32)
}
