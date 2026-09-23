//
//  TranscriptRowView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit

/// TranscriptRowView draws one prepared row and lets its text be selected.
///
/// A recycled view: `configure` replaces everything it shows, including the
/// selection, which the controller owns in logical terms (row id and character
/// range) so a view that scrolls away and comes back as another row keeps
/// nothing of the old one. Main actor only.
@MainActor
final class TranscriptRowView: NSView {

    /// Called with the selected character range, or nil when it is cleared.
    var onSelectText: ((NSRange?) -> Void)?

    /// Called when the row's own action runs: a tool run expands or folds.
    var onActivate: (() -> Void)?

    var isFocusedRow = false { didSet { needsDisplay = true } }

    private var row        : PreparedRow?
    private var style      = TranscriptStyle()
    private var workerName = ""
    private var avatar     : NSImage?
    private var selection  : NSRange?
    private var dragStart  : Int?
    private var textStack  : (NSTextStorage, NSLayoutManager, NSTextContainer)?

    override var isFlipped: Bool { true }

    func configure(
        _ row     : PreparedRow,
        style     : TranscriptStyle,
        workerName: String,
        avatar    : NSImage?,
        selection : NSRange?
    ) {
        self.row        = row
        self.style      = style
        self.workerName = workerName
        self.avatar     = avatar
        self.selection  = selection
        textStack       = RowPreparation.textStack(row.text.attributed(style), width: row.geometry.text.width)
        setAccessibilityElement(true)
        setAccessibilityRole(Self.isToolRun(row) ? .button : .staticText)
        setAccessibilityLabel(TranscriptWording.accessibilityLabel(for: row.item, workerName: workerName))
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        let geometry = row.geometry
        let isPerson: Bool
        if case .personMessage = row.item.kind { isPerson = true } else { isPerson = false }

        drawSurface(row, geometry: geometry, isPerson: isPerson)
        if let avatar, let frame = geometry.avatar { avatar.draw(in: frame) }
        if let header = geometry.header { drawHeader(row, in: header, isPerson: isPerson) }
        drawSelection(in: geometry.text, isOnAccent: isPerson)
        if let (_, manager, container) = textStack {
            manager.drawGlyphs(forGlyphRange: manager.glyphRange(for: container), at: geometry.text.origin)
        }
        if let frame = geometry.badge, let badge = DeliveryBadge(row.item.kind) { draw(badge, in: frame) }
    }

    private func drawSurface(_ row: PreparedRow, geometry: RowGeometry, isPerson: Bool) {
        let surface = geometry.surface
        switch RowGeometry.shape(of: row.item.kind) {
        case .bubble:
            let path = NSBezierPath(roundedRect: surface, xRadius: 14, yRadius: 14)
            (isPerson ? NSColor.controlAccentColor : TranscriptColors.neutralSurface).setFill()
            path.fill()
            if isFocusedRow { strokeFocus(path) }

        case .card:
            let path = NSBezierPath(roundedRect: surface, xRadius: 8, yRadius: 8)
            TranscriptColors.cardSurface.setFill()
            path.fill()
            if case .executionFailed = row.item.kind {
                NSColor.systemRed.withAlphaComponent(0.6).setStroke()
            } else {
                NSColor.separatorColor.setStroke()
            }
            path.lineWidth = 1
            path.stroke()
            if isFocusedRow { strokeFocus(path) }

        case .divider:
            // Two hairlines beside the centred caption.
            NSColor.separatorColor.setFill()
            let y = geometry.text.midY.rounded()
            NSRect(x: surface.minX, y: y, width: max(0, geometry.text.minX - 8 - surface.minX), height: 1).fill()
            NSRect(x: geometry.text.maxX + 8, y: y, width: max(0, surface.maxX - geometry.text.maxX - 8),
                   height: 1).fill()
            if isFocusedRow { strokeFocus(NSBezierPath(roundedRect: surface, xRadius: 4, yRadius: 4)) }
        }
    }

    /// Focus is an outline, so it reads without colour (§3.3).
    private func strokeFocus(_ path: NSBezierPath) {
        NSColor.keyboardFocusIndicatorColor.setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    private func drawHeader(_ row: PreparedRow, in frame: CGRect, isPerson: Bool) {
        let size   = style.captionPointSize
        let parts  = TranscriptWording.header(for: row.item, workerName: workerName)
        let header = NSMutableAttributedString()
        if let name = parts.name {
            header.append(NSAttributedString(
                string    : name + "  ",
                attributes: [.font: NSFont.boldSystemFont(ofSize: size), .foregroundColor: NSColor.labelColor]
            ))
        }
        header.append(NSAttributedString(
            string    : parts.time,
            attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.secondaryLabelColor]
        ))
        let width = header.size().width
        header.draw(at: CGPoint(x: isPerson ? frame.maxX - width : frame.minX, y: frame.minY))
    }

    /// The badge's symbol, in the secondary label colour: its shape carries the meaning.
    private func draw(_ badge: DeliveryBadge, in frame: CGRect) {
        let configuration = NSImage.SymbolConfiguration(pointSize: frame.height, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor]))
        guard let symbol = NSImage(systemSymbolName: badge.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return }
        symbol.draw(in: frame)
    }

    private func drawSelection(in frame: CGRect, isOnAccent: Bool) {
        guard let selection, selection.length > 0, let (_, manager, container) = textStack else { return }
        let glyphs = manager.glyphRange(forCharacterRange: selection, actualCharacterRange: nil)
        (isOnAccent ? NSColor.white.withAlphaComponent(0.35) : NSColor.selectedTextBackgroundColor).setFill()
        manager.enumerateEnclosingRects(
            forGlyphRange             : glyphs,
            withinSelectedGlyphRange  : NSRange(location: NSNotFound, length: 0),
            in                        : container
        ) { rect, _ in
            rect.offsetBy(dx: frame.minX, dy: frame.minY).fill()
        }
    }

    // MARK: Selection and action

    override func mouseDown(with event: NSEvent) {
        guard let row, let index = characterIndex(at: convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event)
            return
        }
        if Self.isToolRun(row), event.clickCount == 1 {
            onActivate?()
            return
        }
        if event.clickCount == 2 {
            select(NSRange(location: 0, length: (row.text.string as NSString).length))
            return
        }
        dragStart = index
        select(nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let index = characterIndex(at: convert(event.locationInWindow, from: nil))
        else { return }
        select(NSRange(location: min(start, index), length: abs(index - start)))
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
    }

    override func accessibilityPerformPress() -> Bool {
        guard let row, Self.isToolRun(row) else { return false }
        onActivate?()
        return true
    }

    private func select(_ range: NSRange?) {
        selection = range
        needsDisplay = true
        onSelectText?(range)
    }

    /// The character boundary nearest `point`, or nil outside the text.
    private func characterIndex(at point: CGPoint) -> Int? {
        guard let row, let (storage, manager, container) = textStack else { return nil }
        let frame = row.geometry.text
        guard frame.insetBy(dx: -4, dy: -4).contains(point) else { return nil }
        var fraction: CGFloat = 0
        let index = manager.characterIndex(
            for                                : CGPoint(x: point.x - frame.minX, y: point.y - frame.minY),
            in                                 : container,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )
        return min(storage.length, index + (fraction > 0.5 ? 1 : 0))
    }

    private static func isToolRun(_ row: PreparedRow) -> Bool {
        if case .toolRun = row.item.kind { true } else { false }
    }
}
