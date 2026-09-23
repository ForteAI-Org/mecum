//
//  MarkdownContent.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import Foundation
import Synchronization

/// MarkdownContent renders a worker's reply as Markdown blocks, reusing every
/// block whose source did not change (§12.2, §12.3).
///
/// The source is split into chunks (`MarkdownSourceChunks`), and each chunk
/// is prepared once and remembered by its text: a message that grows parses
/// only its tail. A fence still open at the end is not parsed at all. Its
/// lines show provisionally as monospaced text, in groups of
/// `provisionalLines`, so an update prepares the last group and not the
/// thousands of lines above it. When the fence closes, its chunk is parsed
/// once as a code block.
///
/// The person's own message is shown exactly as typed: Markdown is how a
/// model formats, and reading the person's `*` or `_` as emphasis would hide
/// characters they wrote.
///
/// One instance serves every row of a controller. `prepare` runs off the main
/// thread, possibly from more than one task; the memory of prepared chunks is
/// guarded by a mutex and parsing happens outside it. Entries beyond
/// `capacity` empty it, and the next pass prepares what it shows again.
public final class MarkdownContent: MessageContentPipeline {

    /// Lines of an open fence per provisional block.
    public static let provisionalLines = 40

    public static let capacity = 2048

    private enum Source: Hashable {
        case markdown(String)
        case provisionalCode(String, language: String?)
    }

    private struct Memory {
        var blocks  : [Source: [PreparedBlock]] = [:]
        var prepared = 0
    }

    private let memory = Mutex(Memory())

    public init() {}

    /// Chunks and provisional groups prepared so far, reused ones excluded.
    /// Evidence for tests: what an update cost, counted rather than timed.
    public var preparedBlockCount: Int {
        memory.withLock { $0.prepared }
    }

    public func prepare(_ text: String, isOnAccent: Bool) -> PreparedText {
        guard !isOnAccent else { return PreparedText(text, role: .bodyOnAccent) }
        var blocks: [PreparedBlock] = []
        for chunk in MarkdownSourceChunks.split(text) {
            switch chunk.kind {
            case .markdown:
                let made = remembered(.markdown(chunk.text)) { MarkdownRendering.blocks(chunk.text) }
                blocks += stamped(made, offset: chunk.offset, firstPart: 0)
            case .openFence(let language):
                let lines = chunk.text.split(separator: "\n", omittingEmptySubsequences: false)
                for (group, start) in stride(from: 0, to: lines.count, by: Self.provisionalLines).enumerated() {
                    let slice = lines[start..<min(lines.count, start + Self.provisionalLines)].joined(separator: "\n")
                    let made = remembered(.provisionalCode(slice, language: language)) {
                        var block = PreparedBlock(kind: .code(language: language, isComplete: false))
                        block.append(slice, role: .code)
                        return [block]
                    }
                    blocks += stamped(made, offset: chunk.offset, firstPart: group)
                }
            }
        }
        return PreparedText(blocks: blocks)
    }

    /// The blocks remembered for `source`, or `make`'s, remembered.
    private func remembered(_ source: Source, make: () -> [PreparedBlock]) -> [PreparedBlock] {
        if let known = memory.withLock({ $0.blocks[source] }) { return known }
        let made = make()
        memory.withLock { memory in
            if memory.blocks.count >= Self.capacity { memory.blocks.removeAll(keepingCapacity: true) }
            memory.blocks[source] = made
            memory.prepared += 1
        }
        return made
    }

    /// The blocks with their identity in this message: where their chunk starts.
    private func stamped(_ blocks: [PreparedBlock], offset: Int, firstPart: Int) -> [PreparedBlock] {
        blocks.enumerated().map { index, block in
            var block = block
            block.id = PreparedBlock.ID(offset: offset, part: firstPart + index)
            return block
        }
    }
}
