// swift-tools-version: 6.4
//
// Mecum: an agent environment for the Mac. The repository is the library, and
// the folders under Sources/ are its layers. Each layer is a set of targets,
// so the compiler enforces the boundaries between them.
//
//   Driver/   how the agent touches the Mac: background display, window
//             placement, input, cursor fence, capture, read-only reader.
//
//   Perception/  how the agent SEES a window: the text scene a language model
//                reads instead of pixels, the pure algorithms that build it, the
//                roles a platform fills and the thin adapters that fill them.
//
//   Engine/      how the agent ACTS on what it sees: the outcome vocabulary,
//                the verification rule, and the roles an actuator fills.
//
// The Driver targets come from AgentSeatKit and keep its per-target settings:
// pure types are nonisolated by default, facilities are main actor by default.
import PackageDescription

let deployment: SupportedPlatform = .macOS(.v26)

// Pure types and role protocols: nonisolated by default.
let pure: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(nil),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
]

// Facilities and orchestration: main actor by default, `actor` and
// `nonisolated` written where the work leaves the main thread.
let facility: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ExistentialAny"),
]

let suite: [SwiftSetting] = pure
func driver(
    _ name        : String,
    _ dependencies: [String]       = [],
      settings    : [SwiftSetting] = facility,
      resources   : [Resource]?    = nil
) -> Target {
    
    .target(
        name         : name,
        dependencies : dependencies.map { .target(name: $0) },
        path         : "Sources/Driver/\(name)",
        resources    : resources,
        swiftSettings: settings
    )
}

func driverTests(
    _ name        : String,
    _ dependencies: [String],
      resources   : [Resource]? = nil
) -> Target {
    
    .testTarget(
        name         : "\(name)Tests",
        dependencies : dependencies.map { .target(name: $0) },
        path         : "Tests/Driver/\(name)Tests",
        resources    : resources,
        swiftSettings: suite
    )
}

func perception(
    _ name        : String,
    _ dependencies: [String]       = [],
      settings    : [SwiftSetting] = facility
) -> Target {

    .target(
        name         : name,
        dependencies : dependencies.map { .target(name: $0) },
        path         : "Sources/Perception/\(name)",
        swiftSettings: settings
    )
}

func perceptionTests(
    _ name        : String,
    _ dependencies: [String]
) -> Target {

    .testTarget(
        name         : "\(name)Tests",
        dependencies : dependencies.map { .target(name: $0) },
        path         : "Tests/Perception/\(name)Tests",
        swiftSettings: suite
    )
}

func engine(
    _ name        : String,
    _ dependencies: [String]       = [],
      settings    : [SwiftSetting] = facility
) -> Target {

    .target(
        name         : name,
        dependencies : dependencies.map { .target(name: $0) },
        path         : "Sources/Engine/\(name)",
        swiftSettings: settings
    )
}

func engineTests(
    _ name        : String,
    _ dependencies: [String]
) -> Target {

    .testTarget(
        name         : "\(name)Tests",
        dependencies : dependencies.map { .target(name: $0) },
        path         : "Tests/Engine/\(name)Tests",
        swiftSettings: suite
    )
}

let package = Package(
    name     : "Mecum",
    platforms: [deployment],
    products : [
        .library(
            name: "MecumDriver",
            targets: ["SeatCore", "PrivateSymbols", "VirtualScreens", "WindowPlacement",
                      "SeatInput", "CursorGuard", "SeatCapture", "SeatSession", "TargetReader"]
        ),
        .library(
            name: "MecumPerception",
            targets: ["PerceptionCore", "VisionText", "WindowServerListing", "Perception", "AccessibilityFacts"]
        ),
        .library(
            name: "MecumEngine",
            targets: ["EngineCore"]
        ),
    ],
    targets: [
        
        // MARK: Driver
        // Pure types and role protocols. No OS call, no facility import.
        driver("SeatCore", settings: pure),
        
        // Build identity, private symbol table, record layouts, ledger, TCC preflight.
        driver(
            "PrivateSymbols",
            ["SeatCore"],
            resources: [.copy("Ledger/validated-builds.json")]
        ),
        
        // The virtual display: create it, attach it to the topology, put the topology back.
        driver("VirtualScreens", ["SeatCore", "PrivateSymbols"]),
        
        // Where a window is, its front to back order, and how it is moved.
        driver("WindowPlacement", ["SeatCore", "PrivateSymbols", "VirtualScreens"]),
        
        // Input posting, preparation and platform policies.
        driver("SeatInput", ["SeatCore", "PrivateSymbols", "WindowPlacement"]),
        
        // The HID cursor fence.
        driver("CursorGuard", ["SeatCore", "PrivateSymbols"]),
        
        // Window and display capture, frames and the monitor layer.
        driver("SeatCapture", ["SeatCore", "WindowPlacement"]),
        
        // The host and the seat: turns, adoption, recovery, watchdog.
        driver("SeatSession", ["SeatCore", "PrivateSymbols", "VirtualScreens", "WindowPlacement", "SeatInput", "CursorGuard", "SeatCapture"]),
        
        // Read-only reader of another application's window.
        driver("TargetReader", ["SeatCore", "WindowPlacement"]),

        // MARK: Driver tools
        // The `malloc_logger` counter every allocation budget is measured with.
        // A C target: the hook runs inside the allocator, so its body must not allocate.
        .target(name: "AllocationCounter", path: "Tools/Driver/AllocationCounter"),
        
        // The measurement driver behind `make bench`.
        .executableTarget(
            name: "SeatBench",
            dependencies: ["SeatCore", "PrivateSymbols", "VirtualScreens", "WindowPlacement", "SeatInput", "CursorGuard", "SeatCapture", "SeatSession", "AllocationCounter"].map { .target(name: $0) },
            path: "Tools/Driver/SeatBench",
            swiftSettings: facility
        ),

        // MARK: Driver tests
        driverTests("SeatCore", ["SeatCore"]),
        driverTests("PrivateSymbols", ["PrivateSymbols", "SeatCore"]),
        driverTests("VirtualScreens", ["VirtualScreens", "PrivateSymbols"]),
        driverTests("WindowPlacement", ["WindowPlacement", "VirtualScreens", "PrivateSymbols", "SeatCore"]),
        driverTests("SeatInput", ["SeatInput", "SeatCore", "PrivateSymbols"]),
        driverTests("CursorGuard", ["CursorGuard", "SeatCore"]),
        driverTests("SeatCapture", ["SeatCapture", "SeatCore"]),
        driverTests("SeatSession", ["SeatSession", "SeatCore", "CursorGuard", "SeatInput"]),
        driverTests("TargetReader", ["TargetReader"]),

        // Host (TCC, real display) and Live (fixture and reader) tiers, gated by
        // AGENTSEAT_HOST_TESTS=1 and AGENTSEAT_LIVE_TESTS=1 and run serialized.
        driverTests("Host", ["SeatCore", "PrivateSymbols", "VirtualScreens", "WindowPlacement", "SeatInput", "CursorGuard", "SeatCapture", "SeatSession"]),
        driverTests("Live", ["SeatCore", "PrivateSymbols", "VirtualScreens", "WindowPlacement",
                             "SeatInput", "CursorGuard", "SeatSession", "TargetReader"],
                    resources: [.copy("Fixtures/probe-page.html")]),

        // MARK: Perception
        // The scene vocabulary, the pure algorithms that build and compare scenes, the accessibility
        // harvest and the roles the pipeline consumes. Foundation and CoreGraphics only: no OS call.
        perception("PerceptionCore", settings: pure),

        // Vision text recognition behind `TextRecognizing`. Runs where it is called; no main actor.
        perception("VisionText", ["PerceptionCore"], settings: pure),

        // The window server's window list behind `WindowListing`.
        perception("WindowServerListing", ["PerceptionCore"], settings: pure),

        // The live accessibility tree behind `SceneAugmenting`; reads hop to the main actor.
        perception("AccessibilityFacts", ["PerceptionCore"], settings: pure),

        // The pipeline: roles in, a scene out. Nonisolated on purpose: recognition must not block the UI.
        perception("Perception", ["PerceptionCore"], settings: pure),

        // MARK: Engine
        // Outcomes, the verification rule and the actuator roles. Pure.
        engine("EngineCore", ["PerceptionCore"], settings: pure),

        // MARK: Perception tests
        perceptionTests("PerceptionCore", ["PerceptionCore"]),
        perceptionTests("Perception", ["Perception", "PerceptionCore"]),

        // Boundary checks against a running application, gated by MECUM_LIVE_TESTS=1. Named apart from
        // the Driver Live tier on purpose: `make live-tests` filters on `LiveTests` and asserts a count.
        perceptionTests("PerceptionBoundary",
                        ["Perception", "PerceptionCore", "VisionText", "AccessibilityFacts", "WindowServerListing"]),

        // MARK: Engine tests
        engineTests("EngineCore", ["EngineCore", "PerceptionCore"]),
    ]
)
