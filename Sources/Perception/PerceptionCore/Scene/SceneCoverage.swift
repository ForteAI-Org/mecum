//
//  SceneCoverage.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 24/09/2026.
//

/// SceneCoverage is which surfaces a scene's pixels came from, as the provider that captured them
/// knows it. A consumer that attributes elements to a window, such as the living memory's
/// sightings, trusts only `.window`: a scene that also holds pop-up rows under the parent's title
/// cannot say which rows belong to the window.
///
/// It is provenance of one capture, not scene content: it is not encoded with the scene, so a scene
/// read back from JSON is `.unattributed`, the value that claims nothing.
public enum SceneCoverage: String, Sendable, Equatable, Hashable {

    /// The provider did not say. The default for every scene.
    case unattributed

    /// The pixels are the captured window alone.
    case window

    /// The pixels are the union of the window and its open pop-ups, under the window's title.
    case windowAndPopups
}
