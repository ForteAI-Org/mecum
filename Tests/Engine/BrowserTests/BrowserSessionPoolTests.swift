import BrowserCore
import Testing

struct BrowserSessionPoolTests {
    @Test func chatsCannotShareOneProfileUntilTheOwnerDisconnects() async throws {
        let pool = BrowserSessionPool { SyntheticBrowser() }
        let first = pool.client(), second = pool.client()
        _ = try await first.connect(profile: .current)
        await #expect(throws: BrowserFailure.self) { _ = try await second.connect(profile: .current) }
        await #expect(throws: BrowserFailure.self) { _ = try await second.tabs() }
        _ = try await first.connect(profile: .current)
        try await first.disconnect()
        _ = try await second.connect(profile: .current)
        try await second.disconnect()
    }

    @Test func separateProfilesCanBeUsedIndependently() async throws {
        let pool = BrowserSessionPool { SyntheticBrowser() }
        let first = pool.client(), second = pool.client()
        _ = try await first.connect(profile: .current)
        _ = try await second.connect(profile: .automation)
        await #expect(throws: BrowserFailure.self) { _ = try await first.connect(profile: .automation) }
        try await first.disconnect()
        try await second.disconnect()
    }

    @Test func failedConnectReleasesTheLeaseAndFailedCleanupKeepsIt() async throws {
        let backend = SyntheticBrowser()
        let pool = BrowserSessionPool { backend }
        let first = pool.client(), second = pool.client()
        await backend.failConnection(true)
        await #expect(throws: BrowserFailure.self) { _ = try await first.connect(profile: .current) }
        await backend.failConnection(false)
        _ = try await second.connect(profile: .current)
        await backend.failDisconnect(true)
        await #expect(throws: BrowserFailure.self) { try await second.disconnect() }
        await #expect(throws: BrowserFailure.self) { _ = try await first.connect(profile: .current) }
        await backend.failDisconnect(false)
        try await second.disconnect()
        _ = try await first.connect(profile: .current)
        try await first.disconnect()
    }
}
