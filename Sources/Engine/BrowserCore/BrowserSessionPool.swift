import Foundation

/// BrowserSessionPool grants one chat exclusive engine access to each profile until it disconnects.
/// The application owns the pool. It never locks out a human or an unrelated debugging client.
public actor BrowserSessionPool {
    private let makeBrowser: @Sendable () -> any BrowserControlling
    private var owners: [BrowserProfile: UUID] = [:]

    public init(makeBrowser: @escaping @Sendable () -> any BrowserControlling) {
        self.makeBrowser = makeBrowser
    }

    /// Makes a disconnected client. Its host must disconnect it after draining calls, including on failure.
    public nonisolated func client() -> any BrowserControlling {
        Client(pool: self, browser: makeBrowser())
    }

    private func acquire(_ profile: BrowserProfile, owner: UUID) throws {
        guard owners[profile] == nil || owners[profile] == owner else {
            throw BrowserFailure(.busy, "Another Mecum chat owns this Chrome profile. Disconnect the browser in that chat before using it here.")
        }
        owners[profile] = owner
    }

    private func release(_ profile: BrowserProfile, owner: UUID) {
        if owners[profile] == owner { owners[profile] = nil }
    }

    private actor Client: BrowserControlling {
        let pool: BrowserSessionPool
        let browser: any BrowserControlling
        let owner = UUID()
        var profile: BrowserProfile?
        var isConnecting = false

        init(pool: BrowserSessionPool, browser: any BrowserControlling) {
            self.pool = pool
            self.browser = browser
        }

        func connect(profile requested: BrowserProfile) async throws -> BrowserConnection {
            guard !isConnecting else { throw BrowserFailure(.busy, "Browser connection is already in progress.") }
            guard profile == nil || profile == requested else {
                throw BrowserFailure(.invalidArgument, "Disconnect before changing browser profile.")
            }
            isConnecting = true
            defer { isConnecting = false }
            let alreadyOwned = profile != nil
            try await pool.acquire(requested, owner: owner)
            do {
                let result = try await browser.connect(profile: requested)
                profile = requested
                return result
            } catch {
                if !alreadyOwned { await pool.release(requested, owner: owner) }
                throw error
            }
        }

        func disconnect() async throws {
            guard !isConnecting else { throw BrowserFailure(.busy, "Wait for the connection attempt to finish before disconnecting.") }
            isConnecting = true
            defer { isConnecting = false }
            try await browser.disconnect()
            if let held = profile {
                profile = nil
                await pool.release(held, owner: owner)
            }
        }

        private func requireLease() throws {
            guard !isConnecting else { throw BrowserFailure(.busy, "The browser connection is changing.") }
            guard profile != nil else { throw BrowserFailure(.notConnected, "Connect this chat to Chrome first.") }
        }

        func tabs() async throws -> [BrowserTab] { try requireLease(); return try await browser.tabs() }
        func open(url: String) async throws -> BrowserTab { try requireLease(); return try await browser.open(url: url) }
        func close(tab: String) async throws { try requireLease(); try await browser.close(tab: tab) }
        func snapshot(tab: String, options: BrowserObservationOptions) async throws -> BrowserSnapshot {
            try requireLease()
            return try await browser.snapshot(tab: tab, options: options)
        }
        func readContent(tab: String) async throws -> BrowserContentPage {
            try requireLease()
            return try await browser.readContent(tab: tab)
        }
        func advanceContent(tab: String, by pixels: Double) async throws -> BrowserReceipt {
            try requireLease()
            return try await browser.advanceContent(tab: tab, by: pixels)
        }
        func perform(_ action: BrowserAction, tab: String, snapshot: String?) async throws -> BrowserReceipt {
            try requireLease()
            return try await browser.perform(action, tab: tab, snapshot: snapshot)
        }
        func screenshot(tab: String) async throws -> Data { try requireLease(); return try await browser.screenshot(tab: tab) }
        func dialog(tab: String) async throws -> BrowserDialog? { try requireLease(); return try await browser.dialog(tab: tab) }
        func handleDialog(tab: String, accept: Bool, text: String?) async throws -> BrowserReceipt {
            try requireLease()
            return try await browser.handleDialog(tab: tab, accept: accept, text: text)
        }
    }
}
