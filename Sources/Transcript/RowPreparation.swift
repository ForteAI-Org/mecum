//
//  RowPreparation.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import Synchronization

/// RowPreparation builds each row's text and measures it block by block, off
/// the main thread.
///
/// Text is measured with a TextKit stack made for the call and dropped at its
/// end, never attached to a view and with background layout off, which is the
/// use AppKit allows off the main thread. `TranscriptRowView` lays out with the same configuration, so the
/// measured size is the drawn size.
///
/// The cache arrives as a copy; what this pass measured comes back beside the
/// rows, for the owner to merge on the main actor.
enum RowPreparation {

    struct Result: Sendable {
        let rows    : [PreparedRow]
        let measured: [LayoutMeasurementCache.Key: CGSize]
    }

    @concurrent
    static func prepare(
        _ items   : [TranscriptItem],
        workerName: String,
        width     : CGFloat,
        style     : TranscriptStyle,
        cache     : LayoutMeasurementCache,
        pipeline  : any MessageContentPipeline
    ) async -> Result {
        var measured: [LayoutMeasurementCache.Key: CGSize] = [:]
        let rows = items.map { item in
            let text  = preparedText(for: item, workerName: workerName, pipeline: pipeline)
            let sizes = text.blocks.map { block in
                let limit = RowGeometry.textWidthLimit(for: block.kind, in: item.kind, rowWidth: width, style: style)
                let key   = LayoutMeasurementCache.Key(content: block, width: limit, style: style)
                if let known = cache.size(for: key) ?? measured[key] { return known }
                let size = block.kind == .rule ? .zero : measure(block.attributed(style), width: CGFloat(key.width))
                measured[key] = size
                return size
            }
            return PreparedRow(
                item    : item,
                text    : text,
                geometry: RowGeometry(item: item, rowWidth: width, style: style, blocks: text.blocks.map(\.kind),
                                      sizes: sizes)
            )
        }
        return Result(rows: rows, measured: measured)
    }

    /// The size `text` lays out at when no line may exceed `width`.
    ///
    /// One measurement at a time across every window: TextKit in many threads
    /// at once beside the main thread's drawing ended the test process a few
    /// tests later, where one thread beside it never did.
    static func measure(_ text: NSAttributedString, width: CGFloat) -> CGSize {
        measuring.withLock { _ in
            let (storage, manager, container) = textStack(text, width: width)
            // The layout manager does not retain its storage, so the storage must outlive the layout.
            return withExtendedLifetime(storage) {
                manager.ensureLayout(for: container)
                let used = manager.usedRect(for: container)
                return CGSize(width: used.width.rounded(.up), height: used.height.rounded(.up))
            }
        }
    }

    private static let measuring = Mutex(())

    /// The TextKit 1 stack both measuring and drawing use.
    static func textStack(_ text: NSAttributedString, width: CGFloat)
        -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
        let storage   = NSTextStorage(attributedString: text)
        let manager   = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.usesFontLeading       = true
        // Background layout enrols the manager in AppKit's main-thread list of dirty managers,
        // and a stack released off the main thread then races it; both uses lay out on demand.
        manager.backgroundLayoutEnabled = false
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        return (storage, manager, container)
    }

    // MARK: Text per kind

    static func preparedText(
        for item  : TranscriptItem,
        workerName: String,
        pipeline  : any MessageContentPipeline
    ) -> PreparedText {
        let when = TranscriptWording.time(item.date)

        switch item.kind {
        case .personMessage(let text, _, _):
            return pipeline.prepare(text, isOnAccent: true)

        case .workerReply(let text, _):
            return pipeline.prepare(text, isOnAccent: false)

        case .toolRun(let lines, let isExpanded, let ending):
            return toolLine(ToolStep.steps(from: lines), isExpanded: isExpanded, ending: ending)

        case .thinking:
            return PreparedText()

        case .daySeparator(let label):
            return PreparedText(label, role: .caption)

        case .executionFailed(let reason):
            var result = PreparedText(TranscriptWording.failed(by: workerName), role: .alert)
            result.append("\n" + reason, role: .monospaced)
            return result

        case .executionInterrupted(let note):
            var result = PreparedText("\(TranscriptWording.stopped) · \(when)", role: .captionStrong)
            result.append("\n" + note, role: .caption)
            return result

        case .activityNotShown:
            return PreparedText(TranscriptWording.activityNotShown, role: .caption)
        }
    }

    /// The tool line: a gear, or the error mark when a step failed, the
    /// summary and a disclosure; expanded, one indented line per step.
    private static func toolLine(_ steps: [ToolStep], isExpanded: Bool, ending: TranscriptItem.TurnEnding?)
        -> PreparedText {
        let hasFailure = steps.contains { if case .failed = $0.state { true } else { false } }
        var block = PreparedBlock(kind: .text)
        block.append(hasFailure ? errorMark : "⚙\u{FE0E} ", role: hasFailure ? .captionAlert : .caption)
        block.append(TranscriptWording.toolSummary(steps, ending: ending) + " ", role: .caption)
        block.append(disclosureSlot, role: .disclosureSlot)
        guard isExpanded else { return PreparedText(blocks: [block]) }
        for line in TranscriptWording.toolSteps(steps, ending: ending) {
            block.append("\n", role: .caption, indent: 1)
            if line.isFailed { block.append(errorMark, role: .captionAlert, indent: 1) }
            block.append(line.text, role: .caption, indent: 1)
        }
        return PreparedText(blocks: [block])
    }

    /// The character a tool line's summary ends with, where its chevron is drawn.
    static let disclosureSlot = "›"

    /// The mark a tool line or step carries when something failed.
    private static let errorMark = "⚠\u{FE0E} "
}
