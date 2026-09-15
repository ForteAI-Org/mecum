// swift-tools-version: 6.4
//
// Mecum: an agent environment for the Mac. The repository is the library, and
// the folders under Sources/ are its layers. Each layer is a set of targets,
// so the compiler enforces the boundaries between them.
//
//   Driver/   how the agent touches the Mac: background display, window
//             placement, input, cursor fence, capture, read-only reader.
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

// Test targets stay nonisolated by default so synchronous tests run in parallel.
let suite: [SwiftSetting] = pure

func driver(_ name: String, _ dependencies: [String] = [], settings: [SwiftSetting] = facility,
            resources: [Resource]? = nil) -> Target {
    .target(name: name, dependencies: dependencies.map { .target(name: $0) },
            path: "Sources/Driver/\(name)", resources: resources, swiftSettings: settings)
}

func driverTests(_ name: String, _ dependencies: [String], resources: [Resource]? = nil) -> Target {
    .testTarget(name: "\(name)Tests", dependencies: dependencies.map { .target(name: $0) },
                path: "Tests/Driver/\(name)Tests", resources: resources, swiftSettings: suite)
}

let package = Package(
    name: "Mecum",
    platforms: [deployment],
    products: [],
    targets: [
        // MARK: Driver
        // Pure types and role protocols. No OS call, no facility import.
        driver("SeatCore", settings: pure),
        // Build identity, private symbol table, record layouts, ledger, TCC preflight.
        driver("PrivateSymbols", ["SeatCore"], resources: [.copy("Ledger/validated-builds.json")]),
        // The virtual display: create it, attach it to the topology, put the topology back.
        driver("VirtualScreens", ["SeatCore", "PrivateSymbols"]),
        // Where a window is, its front to back order, and how it is moved.
        driver("WindowPlacement", ["SeatCore", "PrivateSymbols", "VirtualScreens"]),
        // Input posting, preparation and platform policies.
        driver("SeatInput", ["SeatCore", "PrivateSymbols", "WindowPlacement"]),

        // MARK: Driver tests
        driverTests("SeatCore", ["SeatCore"]),
        driverTests("PrivateSymbols", ["PrivateSymbols", "SeatCore"]),
        driverTests("VirtualScreens", ["VirtualScreens", "PrivateSymbols"]),
        driverTests("WindowPlacement", ["WindowPlacement", "VirtualScreens", "PrivateSymbols", "SeatCore"]),
        driverTests("SeatInput", ["SeatInput", "SeatCore", "PrivateSymbols"]),
    ]
)
