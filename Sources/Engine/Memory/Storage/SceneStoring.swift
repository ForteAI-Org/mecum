//
//  SceneStoring.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

/// SceneStoring persists structural scenes and the associations between samples and scenes. The
/// comparison itself is `SceneStructureMatcher`'s; a conformer runs it on the stored sample against
/// the stored scenes of the sample's application and writes the decision, all inside one
/// transaction, so evaluation and insertion are serialized with every other writer of the file.
/// A conformer never confirms from an incomplete sample, never offers the app scope as a candidate,
/// and never re-decides a sample it already decided: a second call answers the stored decision.
public protocol SceneStoring: Sendable {

    /// The structural scenes of an application, with their skeletons rebuilt from their elements.
    func scenes(of bundleID: String) async throws -> [SceneDefinition]

    /// Associates a stored sample with the scenes of its event's application, at this time.
    func associate(_ key: CaptureSampleKey, at nowMS: Int64) async throws -> SceneAssociationOutcome

    /// The associations stored for a sample, in scene order.
    func associations(of key: CaptureSampleKey) async throws -> [SceneAssociation]
}
