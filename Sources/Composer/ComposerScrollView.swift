//
//  ComposerScrollView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit

/// ComposerScrollView holds the composer's text view and is as tall as its
/// text, from one line up to `maximumLines`; past that the text scrolls inside
/// and the conversation above keeps its room (§13.1).
///
/// The height is its intrinsic content size, which SwiftUI reads for the
/// hosted view, so it is invalidated whenever the text or the width changes
/// the number of lines. It uses TextKit 1, whose used rect is the measurement.
final class ComposerScrollView: NSScrollView {

    static let maximumLines = 6

    /// The conversation body's size, and the spec's floor (§3.3).
    static let pointSize: CGFloat = 14

    let textView = ComposerTextView(usingTextLayoutManager: false)

    private var measuredHeight: CGFloat = 0

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        drawsBackground       = false
        borderType            = .noBorder
        hasVerticalScroller   = true
        hasHorizontalScroller = false
        autohidesScrollers    = true

        let font = NSFont.systemFont(ofSize: Self.pointSize)
        textView.font                    = font
        textView.textColor               = .labelColor
        textView.typingAttributes        = [.font: font, .foregroundColor: NSColor.labelColor]
        textView.isRichText              = false
        textView.importsGraphics         = false
        textView.allowsUndo              = true
        textView.drawsBackground         = false
        textView.textContainerInset      = NSSize(width: 0, height: 4)
        textView.minSize                 = .zero
        textView.maxSize                 = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable   = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask        = [.width]
        textView.textContainer?.widthTracksTextView = true
        // The text starts where the notice above it does.
        textView.textContainer?.lineFragmentPadding = 0
        textView.frame = NSRect(origin: .zero, size: contentSize)
        documentView = textView

        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: fittingHeight)
    }

    /// The height the text asks for, clamped to one line and `maximumLines`.
    var fittingHeight: CGFloat {
        let line  = lineHeight
        let inset = textView.textContainerInset.height * 2
        return (min(max(textHeight, line), line * CGFloat(Self.maximumLines)) + inset).rounded(.up)
    }

    /// Asks SwiftUI for a new height when the text now needs one.
    func updateHeight() {
        let height = fittingHeight
        guard height != measuredHeight else { return }
        measuredHeight = height
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()
        // A new width can rewrap the text into more or fewer lines.
        updateHeight()
    }

    private var lineHeight: CGFloat {
        guard let layoutManager = textView.layoutManager, let font = textView.font else { return Self.pointSize }
        return layoutManager.defaultLineHeight(for: font)
    }

    private var textHeight: CGFloat {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return 0 }
        layoutManager.ensureLayout(for: container)
        return layoutManager.usedRect(for: container).height
    }
}
