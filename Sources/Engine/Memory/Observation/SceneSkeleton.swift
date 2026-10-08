//
//  SceneSkeleton.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 01/10/2026.
//

import EngineCore
import PerceptionCore

/// SceneSkeleton is the structure of one capture or one stored scene as structure-v3 reads it: the
/// surface, the set of roles at every structural path, the set of stable captions at every path,
/// and the set of collections. Everything else is excluded on purpose: the window's and the
/// dialog's title (a hint, never identity: a dialog titled after a file is not one scene per file),
/// control states and values, static text, images, pixel elements, counts, and everything inside a
/// collection below the collection itself (rows repeat content, not structure).
///
/// A caption is a label whose origin is a title or a description, on a role that carries one; a
/// value is content. Even a caption does not prove stability ("Reply to Alice" is a title), which
/// is why the matcher treats differing captions as uncertainty, never as proof of a different
/// scene.
public struct SceneSkeleton: Sendable, Equatable, Hashable {

    /// Caption is one stable label on one role, normalized the way labels are compared.
    public struct Caption: Sendable, Equatable, Hashable {

        public let role: String
        public let label: String

        public init(role: String, label: String) {
            self.role  = role
            self.label = LabelText.normalize(label)
        }
    }

    /// Roles that never count as structure: rows and cells repeat, static text and images are
    /// content, unknown is unknown.
    public static let excludedRoles: Set<String> = ["AXRow", "AXCell", "AXStaticText", "AXImage", "AXUnknown"]

    /// Roles whose title or description is a caption.
    public static let captionRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXTab", "AXDisclosureTriangle", "AXSlider", "AXLink",
    ]

    /// Origins a caption may come from.
    public static let captionOrigins: Set<LabelOrigin> = [.title, .description]

    public var surface: CaptureSurface
    public var rolesByPath: [String: Set<String>]
    public var captionsByPath: [String: Set<Caption>]
    public var collections: Set<String>

    public init(
        surface       : CaptureSurface,
        rolesByPath   : [String: Set<String>],
        captionsByPath: [String: Set<Caption>],
        collections   : Set<String>
    ) {
        self.surface        = surface
        self.rolesByPath    = rolesByPath
        self.captionsByPath = captionsByPath
        self.collections    = collections
    }

    /// The skeleton of a sample's elements on a surface.
    public init(surface: CaptureSurface, elements: [CaptureElement]) {
        var roles: [String: Set<String>] = [:]
        var captions: [String: Set<Caption>] = [:]
        var collections: Set<String> = []
        for element in elements {
            if element.isUnderCollection {
                collections.insert(element.containerPath)
                continue
            }
            guard !Self.excludedRoles.contains(element.role) else { continue }
            roles[element.containerPath, default: []].insert(element.role)
            if Self.captionRoles.contains(element.role),
               let origin = element.labelOrigin, Self.captionOrigins.contains(origin) {
                captions[element.containerPath, default: []].insert(Caption(role: element.role, label: element.label))
            }
        }
        self.init(surface: surface, rolesByPath: roles, captionsByPath: captions, collections: collections)
    }

    /// The skeleton of a sample.
    public init(sample: CaptureSample) {
        self.init(surface: sample.surface, elements: sample.elements)
    }

    /// The structural paths with at least one role.
    public var paths: Set<String> { Set(rolesByPath.keys) }

    /// Every role of the skeleton, whatever its path.
    public var roles: Set<String> { rolesByPath.values.reduce(into: []) { $0.formUnion($1) } }

    /// Every caption of the skeleton, whatever its path.
    public var captions: Set<Caption> { captionsByPath.values.reduce(into: []) { $0.formUnion($1) } }

    /// A skeleton with no role is empty: no scene is created from it.
    public var isEmpty: Bool { rolesByPath.isEmpty }

    /// The canonical rendering of the skeleton: surface, then every path with its sorted roles and
    /// captions, then the sorted collections. Equal skeletons render alike.
    public var canonical: String {
        var lines = ["surface=\(surface.rawValue)"]
        for path in paths.sorted() {
            let roles = rolesByPath[path, default: []].sorted().joined(separator: ",")
            let captions = captionsByPath[path, default: []]
                .map { "\($0.role):\($0.label)" }.sorted().joined(separator: ",")
            lines.append("path=\(path)\u{1F}roles=\(roles)\u{1F}captions=\(captions)")
        }
        lines.append("collections=\(collections.sorted().joined(separator: "\u{1F}"))")
        return lines.joined(separator: "\n")
    }

    /// A deterministic digest of the canonical rendering: a search hint for candidate scenes,
    /// never a unique key and never an identity.
    public var structuralKey: String { StructuralDigest.fnv1a(canonical) }
}
