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
//                the verification rule, the act cycle, what it remembers, and
//                the roles an actuator and a store fill.
//   Integration/ where two layers meet: the Driver's seat filling the Engine's
//                roles, so the same engine drives a window in the background.
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
    _ dependencies: [String],
      resources   : [Resource]? = nil
) -> Target {

    .testTarget(
        name         : "\(name)Tests",
        dependencies : dependencies.map { .target(name: $0) },
        path         : "Tests/Perception/\(name)Tests",
        resources    : resources,
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

func integration(
    _ name        : String,
    _ dependencies: [String]       = [],
      settings    : [SwiftSetting] = facility
) -> Target {

    .target(
        name         : name,
        dependencies : dependencies.map { .target(name: $0) },
        path         : "Sources/Integration/\(name)",
        swiftSettings: settings
    )
}

func engineTests(
    _ name        : String,
    _ dependencies: [String],
      resources   : [Resource]? = nil
) -> Target {

    .testTarget(
        name         : "\(name)Tests",
        dependencies : dependencies.map { .target(name: $0) },
        path         : "Tests/Engine/\(name)Tests",
        resources    : resources,
        swiftSettings: suite
    )
}

let package = Package(
    name     : "Mecum",
    platforms: [deployment],
    products : [
        .library(name: "MecumChat",
                 targets: ["ChatCore", "CLIProviders", "FileConversations", "LocalMCP",
                           "AutomationRuntime", "AutomationMCP"]),
        .library(
            name: "MecumDriver",
            targets: ["SeatCore", "PrivateSymbols", "VirtualScreens", "WindowPlacement",
                      "SeatInput", "CursorGuard", "SeatCapture", "SeatSession", "TargetReader"]
        ),
        .library(
            name: "MecumPerception",
            targets: ["PerceptionCore", "VisionText", "PixelSections", "PixelRegions", "WindowServerListing", "Perception", "AccessibilityFacts",
                      "ScreenCapture"]
        ),
        .library(
            name: "MecumEngine",
            targets: ["EngineCore", "Engine", "HIDActuation", "AccessibilityActions", "WorkspaceActivation",
                      "Memory", "FileKnowledge", "LiveScenes"]
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
        perception("PixelSections", ["PerceptionCore"], settings: pure),
        perception("PixelRegions", ["PerceptionCore"], settings: pure),

        // The window server's window list behind `WindowListing`.
        perception("WindowServerListing", ["PerceptionCore"], settings: pure),

        // The live accessibility tree behind `SceneAugmenting`; reads hop to the main actor.
        perception("AccessibilityFacts", ["PerceptionCore"], settings: pure),

        // The pipeline: roles in, a scene out. Nonisolated on purpose: recognition must not block the UI.
        perception("Perception", ["PerceptionCore"], settings: pure),

        // One still of a window, or of a region with its pop-up, through ScreenCaptureKit: the foreground eye.
        perception("ScreenCapture", ["PerceptionCore"], settings: pure),

        // MARK: Engine
        // Outcomes, the verification rule, policies and the roles an actuator and a scene source fill. Pure.
        engine("EngineCore", ["PerceptionCore"], settings: pure),

        // The act and observe cycle over the roles: resolve, gesture, verify, outcome. Nonisolated on purpose.
        engine("Engine", ["EngineCore", "PerceptionCore"], settings: pure),

        // The foreground `Actuating`: synthetic events at the HID system tap.
        engine("HIDActuation", ["EngineCore"], settings: pure),

        // `ControlPressing` over the live accessibility tree; reads and presses hop to the main actor.
        engine("AccessibilityActions", ["EngineCore", "PerceptionCore", "AccessibilityFacts"], settings: pure),

        // `ApplicationActivating` over AppKit's workspace.
        engine("WorkspaceActivation", ["EngineCore"], settings: pure),

        // What the agent remembers: observed objects, the brain, routes, recall, and the storing role. Pure.
        engine("Memory", ["EngineCore", "PerceptionCore"], settings: pure),

        // `KnowledgeStoring` over one JSON file per application, with backups and write-behind.
        engine("FileKnowledge", ["Memory"], settings: pure),

        // `SceneProviding` for a window on the real screen: census, capture, pipeline.
        engine("LiveScenes", ["EngineCore", "PerceptionCore", "Perception", "ScreenCapture"], settings: pure),

        // MARK: Integration
        // Where two layers meet. SeatDriving fills the Engine's roles from the Driver's seat: stills of the
        // adopted window, routed commands inside a Turn, no activation.
        integration("SeatDriving", ["SeatCore", "SeatSession", "SeatCapture", "SeatInput", "WindowPlacement",
                                    "EngineCore", "PerceptionCore", "Perception", "AccessibilityActions"],
                    settings: pure),

        // MARK: Engine tools
        // Chat contracts exclude processes, persistence, MCP, AppKit and the Driver.
        .target(name: "ChatCore", path: "Sources/Chat/ChatCore", swiftSettings: pure),
        .target(name: "CLIProviders", dependencies: ["ChatCore"],
                path: "Sources/Chat/CLIProviders", swiftSettings: facility),
        .target(name: "FileConversations", dependencies: ["ChatCore"],
                path: "Sources/Chat/FileConversations", swiftSettings: pure),
        .target(name: "LocalMCP", path: "Sources/Chat/LocalMCP", swiftSettings: facility),
        integration("AutomationRuntime", ["Perception", "VisionText", "PixelSections", "PixelRegions", "WindowServerListing", "AccessibilityFacts",
                    "ScreenCapture", "Engine", "EngineCore", "HIDActuation", "AccessibilityActions",
                    "WorkspaceActivation", "Memory", "FileKnowledge", "LiveScenes", "PerceptionCore",
                    "SeatDriving", "SeatCore", "SeatSession", "PrivateSymbols"]),
        integration("AutomationMCP", ["AutomationRuntime", "LocalMCP", "EngineCore", "PerceptionCore",
                                     "PrivateSymbols", "SeatCore", "WindowServerListing"]),
        // The foreground command line: windows, scene, act, memory. What a model host does, by hand.
        .executableTarget(
            name: "mecum",
            dependencies: ["Perception", "PerceptionCore", "VisionText", "WindowServerListing", "AccessibilityFacts",
                           "ScreenCapture", "Engine", "EngineCore", "HIDActuation", "AccessibilityActions",
                           "WorkspaceActivation", "Memory", "FileKnowledge", "LiveScenes",
                           "SeatDriving", "SeatCore", "SeatSession", "PrivateSymbols", "AutomationRuntime",
                           "ChatCore", "CLIProviders", "FileConversations", "LocalMCP", "AutomationMCP"].map { .target(name: $0) },
            path: "Tools/Engine/mecum",
            swiftSettings: facility
        ),

        // MARK: Perception tests
        perceptionTests("PerceptionCore", ["PerceptionCore"]),
        perceptionTests("Perception", ["Perception", "PerceptionCore"]),
        perceptionTests("PixelSections", ["PixelSections", "PerceptionCore"]),
        perceptionTests("PixelRegions", ["PixelRegions", "PerceptionCore"]),

        // Boundary checks against a running application, gated by MECUM_LIVE_TESTS=1. Named apart from
        // the Driver Live tier on purpose: `make live-tests` filters on `LiveTests` and asserts a count.
        perceptionTests("PerceptionBoundary",
                        ["Perception", "PerceptionCore", "VisionText", "AccessibilityFacts", "WindowServerListing"],
                        resources: [.copy("Fixtures/NewPathsMono.png")]),

        // MARK: Engine tests
        .testTarget(name: "ChatTests", dependencies: ["ChatCore", "CLIProviders", "FileConversations", "LocalMCP",
                                                    "AutomationMCP", "AutomationRuntime", "EngineCore", "PerceptionCore"],
                    path: "Tests/Chat", swiftSettings: facility),
        .testTarget(
            name: "MecumCLITests",
            dependencies: ["mecum", "EngineCore", "PerceptionCore", "ChatCore", "AutomationRuntime", "Perception"],
            path: "Tests/Engine/MecumCLITests",
            swiftSettings: facility
        ),
        engineTests("EngineCore", ["EngineCore", "PerceptionCore"]),
        engineTests("Engine", ["Engine", "EngineCore", "PerceptionCore"]),
        engineTests("Memory", ["Memory", "EngineCore", "PerceptionCore"],
                    resources: [.copy("Fixtures/route-corpus.json"), .copy("Fixtures/misfire-corpus.json"),
                                .copy("Fixtures/misfire-corpus.md")]),
        engineTests("FileKnowledge", ["FileKnowledge", "Memory", "PerceptionCore"]),
    ]
)
