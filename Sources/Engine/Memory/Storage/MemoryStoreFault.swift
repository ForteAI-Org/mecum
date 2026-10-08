//
//  MemoryStoreFault.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 30/09/2026.
//

/// MemoryStoreFault is one answer of the storage library: its primary and extended result codes,
/// the phase it was met in, the library's own message, which names a constraint, a table or a
/// file and never a value the agent typed or read, and what became of the transaction it
/// interrupted.
public struct MemoryStoreFault: Sendable, Equatable {

    /// Code is the library's primary result code with its extended refinement, kept as integers
    /// so the pure module never imports the library. A primary of 0 with a message is a refusal
    /// the library did not report as an error, such as a journal mode it silently kept.
    public struct Code: Sendable, Equatable, Hashable {

        public let primary : Int32
        public let extended: Int32

        public init(primary: Int32, extended: Int32) {
            self.primary  = primary
            self.extended = extended
        }
    }

    /// Cleanup is what the store found and did about the transaction after the failure. A library
    /// error inside a transaction may or may not have rolled it back on its own, so the store
    /// looks, ends what is still open, and reports which it was: the primary failure stays the
    /// one answered, and a cleanup that failed is diagnostic beside it.
    public enum Cleanup: Sendable, Equatable {

        /// No transaction was open when the failure was met.
        case notNeeded

        /// The library had already rolled the transaction back when the store looked.
        case alreadyRolledBack

        /// The transaction was still open; the store's own rollback ended it.
        case rolledBack

        /// The store could not end the transaction: its rollback answered this code and message,
        /// or answered OK while the connection stayed inside a transaction (code 0). The
        /// connection is not trusted after this.
        case failed(Code, String)
    }

    public let code   : Code
    public let phase  : MemoryStoreError.Phase
    public let message: String
    public let cleanup: Cleanup

    public init(code: Code, phase: MemoryStoreError.Phase, message: String, cleanup: Cleanup = .notNeeded) {
        self.code    = code
        self.phase   = phase
        self.message = message
        self.cleanup = cleanup
    }
}
