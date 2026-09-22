//
//  TurnAssembler.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 22/09/2026.
//

import Foundation

/// Assembles one provider's event stream: bytes in, text deltas out, and the
/// provider's own terminal event before the turn may be called complete.
///
/// The network path and the tests drive the same `accept`: a chunk may end
/// anywhere, including inside a UTF-8 sequence or halfway through an event, so
/// nothing is decoded before the newline that completes its line.
struct TurnAssembler: Sendable {

    /// One payload in, the text it carries out. It also fills the running
    /// account: the token counts and the provider's own end of turn.
    typealias PayloadDecoding = @Sendable (Data, inout TurnProgress) throws -> String?

    private var reader: EventStreamReader
    private let decode: PayloadDecoding
    private(set) var progress = TurnProgress()
    private(set) var deltaCount = 0

    init(format: EventStreamReader.Format, decode: @escaping PayloadDecoding) {
        self.reader = EventStreamReader(format: format)
        self.decode = decode
    }

    /// The text this byte completed, if it completed any.
    mutating func accept(_ byte: UInt8) throws -> String? {
        guard let payload = reader.accept(byte) else { return nil }
        guard let text = try decode(payload, &progress), !text.isEmpty else { return nil }
        deltaCount += 1
        return text
    }

    /// The texts this chunk completed, in the order the provider sent them.
    mutating func accept(_ chunk: Data) throws -> [String] {
        try chunk.compactMap { try accept($0) }
    }

    /// The terminal element, or the refusal owed when the provider never
    /// declared the turn finished.
    func completion(wallClock: Duration) throws -> TurnEvent {
        guard progress.isFinished else { throw ModelTransportError.streamEndedEarly(deltas: deltaCount) }
        return .completed(progress.usage(wallClock: wallClock))
    }
}

/// Splits a byte stream into the JSON payloads its events carry: the `data:`
/// line of a server-sent event, or a whole line of newline-delimited JSON.
/// Bytes are held until the newline that ends their line, which is what makes
/// a split inside a multi-byte character harmless: nothing is ever decoded as
/// text before it is whole.
struct EventStreamReader: Sendable {

    enum Format: Sendable {
        /// `event:` and `data:` lines separated by blank lines. One `data:`
        /// line per event: no provider here splits a payload over several.
        case serverSentEvents
        /// One JSON object per line.
        case newlineDelimitedJSON
    }

    private static let dataPrefix = Array("data:".utf8)

    private let format: Format
    private var line: [UInt8] = []

    init(format: Format) {
        self.format = format
    }

    /// The payload this byte completed, if the line it ended carried one.
    mutating func accept(_ byte: UInt8) -> Data? {
        guard byte == 0x0A else {
            line.append(byte)
            return nil
        }
        defer { line.removeAll(keepingCapacity: true) }
        var bytes = line[...]
        if bytes.last == 0x0D { bytes = bytes.dropLast() }
        switch format {
        case .serverSentEvents:
            guard bytes.starts(with: Self.dataPrefix) else { return nil }
            var payload = bytes.dropFirst(Self.dataPrefix.count)
            if payload.first == 0x20 { payload = payload.dropFirst() }
            return payload.isEmpty ? nil : Data(payload)
        case .newlineDelimitedJSON:
            return bytes.isEmpty ? nil : Data(bytes)
        }
    }
}
