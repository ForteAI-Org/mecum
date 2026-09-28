//
//  RowPreparation.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit
import ModelTransports
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
nonisolated enum RowPreparation {

    struct Result: Sendable {
        let rows    : [PreparedRow]
        let measured: [LayoutMeasurementCache.Key: CGSize]
    }

    @concurrent
    static func prepare(
        _ items       : [TranscriptItem],
        workerName    : String,
        workerProvider: ModelProvider? = nil,
        width         : CGFloat,
        style         : TranscriptStyle,
        cache         : LayoutMeasurementCache,
        pipeline      : any MessageContentPipeline
    ) async -> Result {
        var measured: [LayoutMeasurementCache.Key: CGSize] = [:]
        let rows = items.map { item in
            let text  = preparedText(
                for           : item,
                workerName    : workerName,
                workerProvider: workerProvider,
                pipeline      : pipeline
            )
            let sizes = text.blocks.map { block in
                let limit = RowGeometry.textWidthLimit(for: block.kind, in: item.kind, rowWidth: width, style: style)
                let key   = LayoutMeasurementCache.Key(content: block, width: limit, style: style)
                if let known = cache.size(for: key) ?? measured[key] { return known }
                let size = block.kind == .rule ? .zero : measure(block.attributed(style), width: CGFloat(key.width))
                measured[key] = size
                return size
            }
            let quote = item.quote.map { quote in
                quoteSize(
                    quote,
                    of        : item.kind,
                    workerName: workerName,
                    rowWidth  : width,
                    style     : style,
                    cache     : cache,
                    measured  : &measured
                )
            }
            return PreparedRow(
                item    : item,
                text    : text,
                geometry: RowGeometry(
                    item    : item,
                    rowWidth: width,
                    style   : style,
                    blocks  : text.blocks.map(\.kind),
                    sizes   : sizes,
                    quote   : quote
                )
            )
        }
        return Result(rows: rows, measured: measured)
    }

    // MARK: Quotes

    /// What a reply's quote measures: its excerpt in at most `RowGeometry.quoteLines`
    /// lines, and the worker's name above it when the quoted message is the
    /// worker's. Both go through the cache, keyed apart from blocks by their line cap.
    private static func quoteSize(
        _ quote   : MessageQuote,
        of kind   : TranscriptItem.Kind,
        workerName: String,
        rowWidth  : CGFloat,
        style     : TranscriptStyle,
        cache     : LayoutMeasurementCache,
        measured  : inout [LayoutMeasurementCache.Key: CGSize]
    ) -> RowGeometry.QuoteSize {
        let limit = RowGeometry.quoteWidthLimit(
            for     : kind,
            rowWidth: rowWidth,
            style   : style
        )
        func size(
            of text: NSAttributedString,
            lines  : Int
        ) -> CGSize {
            var content = PreparedBlock(kind: .quote)
            content.append(
                text.string,
                role: lines == 1 ? .captionStrong : .caption
            )
            let key = LayoutMeasurementCache.Key(
                content: content,
                width  : limit,
                style  : style,
                lines  : lines
            )
            if let known = cache.size(for: key) ?? measured[key] { return known }
            let size = measure(
                text,
                width       : limit,
                maximumLines: lines
            )
            measured[key] = size
            return size
        }
        let name = quote.isFromPerson ? nil : size(
            of   : quoteName(workerName, style: style),
            lines: 1
        ).width
        return RowGeometry.QuoteSize(
            text : size(
                of   : quoteExcerpt(quote, style: style),
                lines: RowGeometry.quoteLines
            ),
            width: limit,
            name : name
        )
    }

    /// A quote's excerpt as its bubble draws it, one step below the body, in `color`.
    static func quoteExcerpt(
        _ quote: MessageQuote,
        style  : TranscriptStyle,
        color  : NSColor = .secondaryLabelColor
    ) -> NSAttributedString {
        NSAttributedString(
            string    : quote.excerpt,
            attributes: [
                .font           : style.textFont(ofSize: style.quotePointSize),
                .foregroundColor: color,
            ]
        )
    }

    /// The name above a quote of the worker's message, in the caption's bold face, in `color`.
    static func quoteName(
        _ name: String,
        style : TranscriptStyle,
        color : NSColor = .labelColor
    ) -> NSAttributedString {
        NSAttributedString(
            string    : name,
            attributes: [
                .font           : style.textFont(
                    ofSize: style.captionPointSize,
                    weight: .bold
                ),
                .foregroundColor: color,
            ]
        )
    }

    /// The size `text` lays out at when no line may exceed `width`.
    ///
    /// One measurement at a time across every window: TextKit in many threads
    /// at once beside the main thread's drawing ended the test process a few
    /// tests later, where one thread beside it never did.
    /// `maximumLines` caps the lines laid out, the last cut with an ellipsis; zero is no cap.
    static func measure(
        _ text      : NSAttributedString,
        width       : CGFloat,
        maximumLines: Int = 0
    ) -> CGSize {
        measuring.withLock { _ in
            let (storage, manager, container) = textStack(
                text,
                width       : width,
                maximumLines: maximumLines
            )
            // The layout manager does not retain its storage, so the storage must outlive the layout.
            return withExtendedLifetime(storage) {
                manager.ensureLayout(for: container)
                let used = manager.usedRect(for: container)
                return CGSize(width: used.width.rounded(.up), height: used.height.rounded(.up))
            }
        }
    }

    private static let measuring = Mutex(())

    /// The TextKit 1 stack both measuring and drawing use. `maximumLines` caps
    /// the lines laid out and cuts the last with an ellipsis; zero is no cap.
    static func textStack(
        _ text      : NSAttributedString,
        width       : CGFloat,
        maximumLines: Int = 0
    ) -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
        let storage   = NSTextStorage(attributedString: text)
        let manager   = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        if maximumLines > 0 {
            container.maximumNumberOfLines = maximumLines
            container.lineBreakMode        = .byTruncatingTail
        }
        manager.usesFontLeading       = true
        // Background layout enrols the manager in AppKit's main-thread list of dirty managers,
        // and a stack released off the main thread then races it; both uses lay out on demand.
        manager.backgroundLayoutEnabled = false
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        return (storage, manager, container)
    }

    // MARK: Text per kind

    /// `workerProvider` is the worker's provider, which a failure card needs to say how to sign in
    /// again; nil when it has none.
    static func preparedText(
        for item      : TranscriptItem,
        workerName    : String,
        workerProvider: ModelProvider? = nil,
        pipeline      : any MessageContentPipeline
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

        case .contextSeparator(let change):
            return PreparedText(TranscriptWording.context(change, at: item.date), role: .caption)

        case .executionFailed(let reason):
            // A signed-out command line fails every turn the same way: the card says how to sign in,
            // where sending the message again would only fail again.
            if let workerProvider, SignInFailure.isSignedOut(reason),
               let signIn = TranscriptWording.signedOut(workerProvider, worker: workerName) {
                var result = PreparedText(signIn.headline, role: .alert)
                result.append("\n" + signIn.steps, role: .body)
                result.append("\n" + reason, role: .monospaced)
                return result
            }
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

    /// The tool line: its summary, one quiet line the chevron follows; opened, the steps on a card
    /// under it, one line each. Nothing on it is marked as a problem: a turn that failed has its own card.
    private static func toolLine(_ steps: [ToolStep], isExpanded: Bool, ending: TranscriptItem.TurnEnding?)
        -> PreparedText {
        var summary = PreparedBlock(kind: .toolSummary)
        summary.append(TranscriptWording.toolSummary(steps, ending: ending), role: .toolCaption)
        let lines = isExpanded ? TranscriptWording.toolSteps(steps, ending: ending) : []
        guard !lines.isEmpty else { return PreparedText(blocks: [summary]) }

        var card = PreparedBlock(kind: .toolSteps)
        card.append(lines.joined(separator: "\n"), role: .toolCaption)
        return PreparedText(blocks: [summary, card])
    }
}
