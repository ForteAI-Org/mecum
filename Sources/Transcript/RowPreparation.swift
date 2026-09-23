//
//  RowPreparation.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit

/// RowPreparation builds each row's text and measures it, off the main thread.
///
/// Text is measured with a TextKit stack made for the call and dropped at its
/// end, never attached to a view, which is the use AppKit allows off the main
/// thread. `TranscriptRowView` lays out with the same configuration, so the
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
            let text = preparedText(for: item, workerName: workerName, pipeline: pipeline)
            let limit = RowGeometry.textWidthLimit(for: item.kind, rowWidth: width, style: style)
            let key   = LayoutMeasurementCache.Key(content: text, width: limit, style: style)
            let size: CGSize
            if let known = cache.size(for: key) ?? measured[key] {
                size = known
            } else {
                size = measure(text.attributed(style), width: CGFloat(key.width))
                measured[key] = size
            }
            return PreparedRow(
                item    : item,
                text    : text,
                geometry: RowGeometry(item: item, rowWidth: width, style: style, textSize: size)
            )
        }
        return Result(rows: rows, measured: measured)
    }

    /// The size `text` lays out at when no line may exceed `width`.
    static func measure(_ text: NSAttributedString, width: CGFloat) -> CGSize {
        let (storage, manager, container) = textStack(text, width: width)
        // The layout manager does not retain its storage, so the storage must outlive the layout.
        return withExtendedLifetime(storage) {
            manager.ensureLayout(for: container)
            let used = manager.usedRect(for: container)
            return CGSize(width: used.width.rounded(.up), height: used.height.rounded(.up))
        }
    }

    /// The TextKit 1 stack both measuring and drawing use.
    static func textStack(_ text: NSAttributedString, width: CGFloat)
        -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
        let storage   = NSTextStorage(attributedString: text)
        let manager   = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.usesFontLeading       = true
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
            var result = PreparedText((isExpanded ? "▾ " : "▸ ") + TranscriptWording.toolSummary(lines, ending: ending),
                                      role: .caption)
            if isExpanded { result.append("\n" + lines.joined(separator: "\n"), role: .monospaced) }
            return result

        case .executionStarted:
            return PreparedText("\(TranscriptWording.started(by: workerName)) · \(when)", role: .caption)

        case .executionCompleted:
            return PreparedText("\(TranscriptWording.completed) · \(when)", role: .caption)

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
}
