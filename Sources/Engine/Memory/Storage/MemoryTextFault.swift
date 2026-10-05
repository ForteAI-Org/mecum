//
//  MemoryTextFault.swift
//  Mecum
//
//  Created by Tommaso Mazzarini on 30/09/2026.
//

/// MemoryTextFault locates a stored text that is not valid UTF-8: which column of the row, how
/// many bytes it holds and where the first invalid sequence starts. It carries none of the bytes:
/// a caller that needs them reads the column as a blob. A `STRICT` table checks a value's storage
/// class, not its encoding, so a text column can hold such bytes; the store refuses to decode
/// them by replacement, since a replaced character would read as content.
public struct MemoryTextFault: Sendable, Equatable {

    public let column           : Int
    public let byteCount        : Int
    public let invalidByteOffset: Int

    public init(column: Int, byteCount: Int, invalidByteOffset: Int) {
        self.column            = column
        self.byteCount         = byteCount
        self.invalidByteOffset = invalidByteOffset
    }
}
