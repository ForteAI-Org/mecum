import Foundation
import CoreGraphics

/// The redundant, persisted descriptor of a single picked UI element.
///
/// A descriptor is captured once (AX path + visual crops + text + geometry) and later used to
/// relocate the element via a confidence cascade. Every field is a value type over `Sendable`
/// members, so the whole graph is trivially `Sendable` and `Codable`.
public struct Descriptor: Codable, Equatable, Sendable {
    /// On-disk schema version, independent of `version`. Bumped only when the descriptor *shape*
    /// changes (migration), not on self-heal. Defaults to ``currentSchemaVersion`` for old files.
    public var schemaVersion: Int
    public var id: UUID
    /// Self-heal revision — bumped whenever a lower relocation stage re-saves crop/geometry.
    public var version: Int
    public var created: Date
    public var lastVerified: Date
    public var app: AppContext
    public var ax: AXDescriptor
    public var visual: VisualDescriptor
    public var text: TextDescriptor
    public var geometry: GeometryDescriptor
    /// App-specific stable keys, e.g. `["track_name": "Vox Lead", "element_kind": "solo_button"]`.
    /// For Pro Tools, `track_name` is the single most stable key (survives reorder/scroll/resize).
    public var appSpecific: [String: String]
    public var thresholds: Thresholds
    /// Actuation intent for a stateful control (toggle/checkbox/radio) — its kind + desired end-state, so
    /// replay sets it idempotently instead of blindly re-clicking. nil for plain-click elements / legacy.
    public var control: ControlIntent?

    public static let currentSchemaVersion = 1

    public init(
        schemaVersion: Int = Descriptor.currentSchemaVersion,
        id: UUID,
        version: Int,
        created: Date,
        lastVerified: Date,
        app: AppContext,
        ax: AXDescriptor,
        visual: VisualDescriptor,
        text: TextDescriptor,
        geometry: GeometryDescriptor,
        appSpecific: [String: String] = [:],
        thresholds: Thresholds = .defaults,
        control: ControlIntent? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.version = version
        self.created = created
        self.lastVerified = lastVerified
        self.app = app
        self.ax = ax
        self.visual = visual
        self.text = text
        self.geometry = geometry
        self.appSpecific = appSpecific
        self.thresholds = thresholds
        self.control = control
    }

    // Forward-compatible decode: tolerate descriptors written before `schemaVersion`/`thresholds`
    // existed (or with a partial thresholds object — see Thresholds.init(from:)).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Descriptor.currentSchemaVersion
        // Tolerate OLDER files (missing key → current). Refuse NEWER files whose shape this build
        // can't be trusted to interpret, rather than silently misreading them as current.
        guard schemaVersion <= Descriptor.currentSchemaVersion else {
            throw StoreError.unsupportedSchemaVersion(found: schemaVersion, supported: Descriptor.currentSchemaVersion)
        }
        self.id = try c.decode(UUID.self, forKey: .id)
        self.version = try c.decode(Int.self, forKey: .version)
        self.created = try c.decode(Date.self, forKey: .created)
        self.lastVerified = try c.decode(Date.self, forKey: .lastVerified)
        self.app = try c.decode(AppContext.self, forKey: .app)
        self.ax = try c.decode(AXDescriptor.self, forKey: .ax)
        self.visual = try c.decode(VisualDescriptor.self, forKey: .visual)
        self.text = try c.decode(TextDescriptor.self, forKey: .text)
        self.geometry = try c.decode(GeometryDescriptor.self, forKey: .geometry)
        self.appSpecific = try c.decodeIfPresent([String: String].self, forKey: .appSpecific) ?? [:]
        self.thresholds = try c.decodeIfPresent(Thresholds.self, forKey: .thresholds) ?? .defaults
        self.control = try c.decodeIfPresent(ControlIntent.self, forKey: .control)
    }
}

/// The application + window context at capture time. Used to scope and scale relocation.
public struct AppContext: Codable, Equatable, Sendable {
    public var bundleID: String
    /// Regex *source* (kept as a String so it stays `Codable`/`Sendable`); compiled lazily at match time.
    public var windowTitlePattern: String
    public var windowSizeAtCapture: CGSize
    /// 2.0 on Retina; multiplies points → pixels.
    public var backingScale: CGFloat

    public init(bundleID: String, windowTitlePattern: String, windowSizeAtCapture: CGSize, backingScale: CGFloat) {
        self.bundleID = bundleID
        self.windowTitlePattern = windowTitlePattern
        self.windowSizeAtCapture = windowSizeAtCapture
        self.backingScale = backingScale
    }
}
