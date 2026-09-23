//
//  TranscriptRowView.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit

/// TranscriptRowView draws one prepared row, block by block, and lets its
/// text be selected.
///
/// A recycled view: `configure` replaces everything it shows, including the
/// selection, which the controller owns in logical terms (`TranscriptSelection`)
/// so a view that scrolls away and comes back as another row keeps nothing of
/// the old one. A press or drag on text is handed to the controller with its
/// window location: the view that took the press may be showing another row
/// before the drag ends, so it keeps no selection state of its own. Main actor only.
///
/// Nothing here runs on its own: a link opens and a code block is copied only
/// on a click or on the controller's keyboard action, and nothing is fetched.
@MainActor
final class TranscriptRowView: NSView {

    typealias TextStack = (NSTextStorage, NSLayoutManager, NSTextContainer)

    enum PointerPhase {
        case down(clickCount: Int)
        case drag
    }

    /// Called with a press or drag on the row's text and its window location.
    var onPointer: ((PointerPhase, NSPoint) -> Void)?

    /// Called when the row's own action runs: a tool run expands or folds.
    var onActivate: (() -> Void)?

    /// Called when a click or VoiceOver runs one of the row's actions.
    var onAction: ((RowAction) -> Void)?

    var isFocusedRow = false { didSet { needsDisplay = true } }

    /// The action the keyboard has reached inside the focused row, outlined.
    var focusedAction: RowAction? { didSet { needsDisplay = true } }

    private var row        : PreparedRow?
    private var style      = TranscriptStyle()
    private var workerName = ""
    private var avatar     : NSImage?
    private(set) var selection: NSRange?
    private var pressLocation : NSPoint?
    private var didDrag       = false
    private(set) var stacks: [TextStack?] = []
    private var ranges     : [NSRange] = []
    private var thinkingDots: ThinkingDotsView?

    override var isFlipped: Bool { true }

    func configure(
        _ row     : PreparedRow,
        style     : TranscriptStyle,
        workerName: String,
        avatar    : NSImage?,
        selection : NSRange?
    ) {
        // The same row again, as a streamed reply grows, keeps the laid out stacks of its unchanged blocks.
        let previous    = self.row?.item.id == row.item.id && self.style == style ? self.row : nil
        let oldStacks   = stacks
        self.row        = row
        self.style      = style
        self.workerName = workerName
        self.avatar     = avatar
        self.selection  = selection
        ranges          = row.text.blockRanges
        stacks          = zip(row.text.blocks, row.geometry.blockTexts).enumerated().map { index, pair in
            let (block, frame) = pair
            if let previous, oldStacks.indices.contains(index), previous.text.blocks.indices.contains(index),
               previous.text.blocks[index] == block, previous.geometry.blockTexts[index].width == frame.width {
                return oldStacks[index]
            }
            return block.kind == .rule ? nil : RowPreparation.textStack(block.attributed(style), width: frame.width)
        }
        showThinking(row)
        configureAccessibility(row)
        needsDisplay = true
    }

    /// The dots of a thinking row, in its text's place; hidden for any other row.
    private func showThinking(_ row: PreparedRow) {
        guard row.item.kind == .thinking else {
            thinkingDots?.stop()
            thinkingDots?.isHidden = true
            return
        }
        let dots = thinkingDots ?? ThinkingDotsView()
        if thinkingDots == nil {
            thinkingDots = dots
            addSubview(dots)
        }
        dots.frame    = row.geometry.text
        dots.isHidden = false
        dots.start(reducesMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// Replaces the drawn selection and nothing else.
    func show(selection range: NSRange?) {
        guard range != selection else { return }
        selection    = range
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
        for index in row.text.blocks.indices
        where geometry.blocks.indices.contains(index) && geometry.blocks[index].intersects(dirtyRect) {
            drawBlock(at: index, of: row, isOnAccent: isPerson)
        }
        if let frame = geometry.badge, let badge = DeliveryBadge(row.item.kind) { draw(badge, in: frame) }
    }

    private func drawBlock(at index: Int, of row: PreparedRow, isOnAccent: Bool) {
        let block = row.text.blocks[index]
        let frame = row.geometry.blocks[index]
        let text  = row.geometry.blockTexts[index]

        switch block.kind {
        case .code(_, true):
            TranscriptColors.codeSurface.setFill()
            NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).fill()
            drawCopyControl(in: frame, isFocused: focusedAction == .copyBlock(index: index))
        case .quote:
            NSColor.tertiaryLabelColor.setFill()
            NSRect(x: frame.minX, y: frame.minY, width: 3, height: frame.height).fill()
        case .rule:
            NSColor.separatorColor.setFill()
            NSRect(x: frame.minX, y: frame.midY.rounded(), width: frame.width, height: 1).fill()
        default:
            break
        }
        guard let (_, manager, container) = stacks[index] else { return }
        // A code block in the person's bubble has its own light surface, so it selects as any text does.
        drawSelection(in: text, block: index, clip: frame, isOnAccent: isOnAccent && !block.isCompleteCode)
        let glyphs = manager.glyphRange(for: container)
        manager.drawBackground(forGlyphRange: glyphs, at: text.origin)
        manager.drawGlyphs(forGlyphRange: glyphs, at: text.origin)
        if case .openLink(_, index, let range)? = focusedAction {
            strokeFocus(around: range, in: index, origin: text.origin)
        }
    }

    private func drawSurface(_ row: PreparedRow, geometry: RowGeometry, isPerson: Bool) {
        let surface = geometry.surface
        switch RowGeometry.shape(of: row.item.kind) {
        case .bubble:
            let path = BubblePath.path(surface: surface, tail: geometry.tail)
            (isPerson ? TranscriptColors.personBubble : TranscriptColors.neutralSurface).setFill()
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

        case .line, .divider:
            // A quiet caption with no surface of its own; focus still outlines it.
            let frame = geometry.text.insetBy(dx: -6, dy: -2)
            if isFocusedRow { strokeFocus(NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4)) }
        }
    }

    /// Focus is an outline, so it reads without colour (§3.3).
    private func strokeFocus(_ path: NSBezierPath) {
        NSColor.keyboardFocusIndicatorColor.setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    private func strokeFocus(around range: NSRange, in block: Int, origin: CGPoint) {
        guard let (_, manager, container) = stacks[block] else { return }
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        manager.enumerateEnclosingRects(
            forGlyphRange           : glyphs,
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
            in                      : container
        ) { rect, _ in
            let frame = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -2, dy: -1)
            self.strokeFocus(NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3))
        }
    }

    private func drawCopyControl(in block: CGRect, isFocused: Bool) {
        let frame = RowGeometry.copyControl(in: block, style: style)
        let label = NSAttributedString(
            string    : TranscriptWording.copyBlock,
            attributes: [.font: NSFont.systemFont(ofSize: style.captionPointSize),
                         .foregroundColor: NSColor.secondaryLabelColor]
        )
        label.draw(at: CGPoint(x: frame.maxX - label.size().width, y: frame.minY))
        if isFocused { strokeFocus(NSBezierPath(roundedRect: frame.insetBy(dx: -3, dy: -1), xRadius: 4, yRadius: 4)) }
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

    /// The part of the row's selection inside `block`, kept within its frame.
    ///
    /// On the accent bubble the selection is a near opaque white with the
    /// selected glyphs in the accent, as Messages draws it: white text on a
    /// lighter tint of the accent would not read. Elsewhere it is the system's.
    private func drawSelection(in frame: CGRect, block: Int, clip: CGRect, isOnAccent: Bool) {
        guard let (storage, manager, container) = stacks[block] else { return }
        // The stack outlives a selection change when its block is unchanged, so an old inversion is cleared first.
        manager.removeTemporaryAttribute(.foregroundColor,
                                         forCharacterRange: NSRange(location: 0, length: storage.length))
        guard let selection, selection.length > 0 else { return }
        let local = NSIntersectionRange(selection, ranges[block])
        guard local.length > 0 else { return }
        let characters = NSRange(location: local.location - ranges[block].location, length: local.length)
        let glyphs     = manager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        if isOnAccent {
            manager.addTemporaryAttribute(.foregroundColor, value: TranscriptColors.personBubble,
                                          forCharacterRange: characters)
        }
        (isOnAccent ? NSColor.white.withAlphaComponent(0.9) : NSColor.selectedTextBackgroundColor).setFill()
        manager.enumerateEnclosingRects(
            forGlyphRange             : glyphs,
            withinSelectedGlyphRange  : NSRange(location: NSNotFound, length: 0),
            in                        : container
        ) { rect, _ in
            rect.offsetBy(dx: frame.minX, dy: frame.minY).intersection(clip).fill()
        }
    }

    // MARK: Selection and action

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let row, let block = copyControl(at: point, in: row) {
            onAction?(.copyBlock(index: block))
            return
        }
        guard let row, blockCharacter(at: point, boundary: true) != nil else {
            super.mouseDown(with: event)
            return
        }
        if Self.isToolRun(row), event.clickCount == 1 {
            onActivate?()
            return
        }
        pressLocation = event.locationInWindow
        didDrag       = false
        onPointer?(.down(clickCount: event.clickCount), event.locationInWindow)
    }

    /// Past the viewport's edge the drag scrolls it; the controller keeps the
    /// selection's far end on whichever row is then under the pointer.
    override func mouseDragged(with event: NSEvent) {
        guard let press = pressLocation else { return }
        didDrag = didDrag || hypot(event.locationInWindow.x - press.x, event.locationInWindow.y - press.y) > 2
        autoscroll(with: event)
        onPointer?(.drag, event.locationInWindow)
    }

    /// A click that did not drag, on a link, is the explicit action that opens it.
    override func mouseUp(with event: NSEvent) {
        defer { pressLocation = nil }
        guard !didDrag, pressLocation != nil, let row,
              let (block, offset) = blockCharacter(at: convert(event.locationInWindow, from: nil)),
              let action = RowAction.actions(in: row.text).first(where: {
                  if case .openLink(_, block, let range) = $0 { NSLocationInRange(offset, range) } else { false }
              })
        else { return }
        onAction?(action)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let row, Self.isToolRun(row) else { return false }
        onActivate?()
        return true
    }

    private func copyControl(at point: CGPoint, in row: PreparedRow) -> Int? {
        row.text.blocks.indices.first { index in
            row.text.blocks[index].isCompleteCode && row.geometry.blocks.indices.contains(index)
                && RowGeometry.copyControl(in: row.geometry.blocks[index], style: style)
                    .insetBy(dx: -4, dy: -4).contains(point)
        }
    }

    /// The character boundary in the row's text nearest `point`, anywhere in
    /// the row: above its text is the start, below it the end, and between
    /// two blocks the start of the lower one.
    func nearestCharacter(to point: CGPoint) -> Int {
        guard let row else { return 0 }
        let texts = row.geometry.blocks.indices.filter { stacks.indices.contains($0) && stacks[$0] != nil }
        guard let block = texts.first(where: { point.y < row.geometry.blocks[$0].maxY }) else {
            return row.length
        }
        guard point.y >= row.geometry.blocks[block].minY, let (storage, manager, container) = stacks[block] else {
            return ranges[block].location
        }
        let frame = row.geometry.blockTexts[block]
        var fraction: CGFloat = 0
        let index = manager.characterIndex(
            for                                : CGPoint(x: point.x - frame.minX, y: point.y - frame.minY),
            in                                 : container,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )
        return ranges[block].location + min(storage.length, index + (fraction > 0.5 ? 1 : 0))
    }

    /// The block under `point` and the character in it: the character hit,
    /// or with `boundary` the nearest insertion point.
    private func blockCharacter(at point: CGPoint, boundary: Bool = false) -> (block: Int, offset: Int)? {
        guard let row else { return nil }
        let frames = row.geometry.blocks
        guard let block = frames.indices.first(where: {
            stacks.indices.contains($0) && stacks[$0] != nil && frames[$0].insetBy(dx: -4, dy: -4).contains(point)
        }), let (storage, manager, container) = stacks[block] else { return nil }
        let frame = row.geometry.blockTexts[block]
        var fraction: CGFloat = 0
        let index = manager.characterIndex(
            for                                : CGPoint(x: point.x - frame.minX, y: point.y - frame.minY),
            in                                 : container,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )
        return (block, min(storage.length, index + (boundary && fraction > 0.5 ? 1 : 0)))
    }

    private static func isToolRun(_ row: PreparedRow) -> Bool {
        if case .toolRun = row.item.kind { true } else { false }
    }

    // MARK: Accessibility

    /// The row reads as a whole; a reply with structure also lists its blocks,
    /// so headings are headings and code is named as code (§3.3). The row's
    /// actions are VoiceOver actions. Nothing is announced when a row changes.
    private func configureAccessibility(_ row: PreparedRow) {
        let isMessage = row.item.messageID != nil
        setAccessibilityElement(true)
        setAccessibilityRole(Self.isToolRun(row) ? .button : .staticText)
        setAccessibilityLabel(TranscriptWording.accessibilityLabel(
            for: row.item, workerName: workerName, content: isMessage ? row.text.string : nil
        ))

        let isStructured = isMessage && row.text.blocks.contains { $0.kind != .text }
        setAccessibilityChildren(isStructured ? blockElements(row) : nil)

        let text = row.text
        setAccessibilityCustomActions(RowAction.actions(in: text).map { action in
            NSAccessibilityCustomAction(name: TranscriptWording.action(action, in: text)) { [weak self] in
                self?.onAction?(action)
                return true
            }
        })
    }

    private func blockElements(_ row: PreparedRow) -> [NSAccessibilityElement] {
        zip(row.text.blocks, row.geometry.blocks).compactMap { block, frame -> NSAccessibilityElement? in
            let element = NSAccessibilityElement()
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(frame)
            switch block.kind {
            case .rule:
                return nil
            case .heading:
                element.setAccessibilityRole(.headingRole)
                element.setAccessibilityLabel(block.string)
            case .code(let language, _):
                element.setAccessibilityRole(.staticText)
                element.setAccessibilityLabel(TranscriptWording.codeBlock(language: language))
                element.setAccessibilityValue(block.string)
            case .table:
                element.setAccessibilityRole(.staticText)
                element.setAccessibilityRoleDescription("table")
                element.setAccessibilityValue(block.string.replacingOccurrences(of: "\n", with: ", "))
            case .text, .quote:
                element.setAccessibilityRole(.staticText)
                element.setAccessibilityValue(block.string)
            }
            return element
        }
    }
}
