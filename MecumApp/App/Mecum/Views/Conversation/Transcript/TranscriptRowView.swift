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

    /// A press, then either a drag that selects text from where it began, or
    /// a click that selects the bubble. A click never starts a text selection.
    enum PointerPhase {
        case press
        case dragStart
        case drag
        case click(count: Int, modifiers: NSEvent.ModifierFlags)
    }

    /// Called with a press, drag or click on the row's bubble and its window location.
    var onPointer: ((PointerPhase, NSPoint) -> Void)?

    /// Called when the row's own action runs: a tool run expands or folds.
    var onActivate: (() -> Void)?

    /// Called when a click or VoiceOver runs one of the row's actions.
    var onAction: ((RowAction) -> Void)?

    /// Asked for the row's context menu on a right or Control click, with the
    /// block and the row offset of the character under the pointer, if any.
    var onMenu: ((_ block: Int?, _ offset: Int?) -> NSMenu?)?

    var isFocusedRow = false { didSet { needsDisplay = true } }

    /// Whether a focused row draws its outline: the keyboard's focus is outlined, a click's is not.
    var showsFocusRing = false { didSet { if showsFocusRing != oldValue { needsDisplay = true } } }

    private var isOutlined: Bool { isFocusedRow && showsFocusRing }

    /// True when the whole message is selected as a bubble: drawn lighter, and spoken as selected.
    var isBubbleSelected = false {
        didSet {
            guard isBubbleSelected != oldValue else { return }
            setAccessibilitySelected(isBubbleSelected)
            needsDisplay = true
        }
    }

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

    /// Each finished code block's copy icon, by block, which turns into a check once its code is copied.
    private var copyIcons  : [Int: NSImageView] = [:]
    private var copiedReset: Task<Void, Never>?

    /// A tool line's disclosure chevron, which turns to point down while the line is open.
    private var chevron    : NSImageView?

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
        let previousRow = self.row?.item.id == row.item.id ? self.row : nil
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
        showCopyIcons(row, keepsCopied: previous != nil)
        showChevron(row, wasExpanded: Self.isExpanded(previousRow))
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

    /// Whether `row` is an open tool line, or nil when it is no tool line at all.
    private static func isExpanded(_ row: PreparedRow?) -> Bool? {
        guard case .toolRun(_, let isExpanded, _)? = row?.item.kind else { return nil }
        return isExpanded
    }

    /// The chevron over a tool line's disclosure slot. The same line opening or
    /// closing turns it with a short rotation; Reduce Motion turns it at once.
    private func showChevron(_ row: PreparedRow, wasExpanded: Bool?) {
        guard let isExpanded = Self.isExpanded(row), let frame = disclosureSlot(in: row) else {
            chevron?.isHidden = true
            return
        }
        let icon = chevron ?? makeChevron()
        chevron = icon
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: style.captionPointSize * 0.8,
                                                               weight: .semibold)
        icon.isHidden = false
        // A rotated view's frame is its bounding box, so it is placed upright and turned after.
        icon.frameCenterRotation = 0
        icon.frame = frame
        // Flipped, a positive rotation turns clockwise: the chevron that pointed right points down.
        let angle: CGFloat = isExpanded ? 90 : 0
        guard let wasExpanded, wasExpanded != isExpanded, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            icon.frameCenterRotation = angle
            return
        }
        icon.frameCenterRotation = wasExpanded ? 90 : 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            icon.animator().frameCenterRotation = angle
        }
    }

    private func makeChevron() -> NSImageView {
        let icon = NSImageView()
        icon.image            = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling     = .scaleProportionallyDown
        icon.wantsLayer       = true
        // The row's expanded state speaks for it, and its press goes to the row.
        icon.setAccessibilityElement(false)
        addSubview(icon)
        return icon
    }

    /// A square on the tool line's disclosure slot, the last character of its first line.
    private func disclosureSlot(in row: PreparedRow) -> CGRect? {
        guard let (storage, manager, container) = stacks.first ?? nil, let origin = row.geometry.blockTexts.first?.origin
        else { return nil }
        let text = storage.string as NSString
        let end  = text.range(of: "\n").location == NSNotFound ? text.length : text.range(of: "\n").location
        guard end > 0 else { return nil }
        let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: end - 1, length: 1),
                                        actualCharacterRange: nil)
        let glyph = manager.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y)
        let side  = (style.captionPointSize * 0.9).rounded()
        // Turned down it is wider than the slot's glyph, so it sits a little right of the glyph's centre.
        return CGRect(x: glyph.midX - side / 2 + 2, y: glyph.midY - side / 2, width: side, height: side).integral
    }

    /// The copy icons of the row's finished code blocks. Another row starts
    /// them as copy icons; the same row growing keeps a check still showing.
    private func showCopyIcons(_ row: PreparedRow, keepsCopied: Bool) {
        if !keepsCopied { copiedReset?.cancel() }
        let blocks = Set(row.text.blocks.indices.filter {
            row.text.blocks[$0].isCompleteCode && row.geometry.blocks.indices.contains($0)
        })
        for (index, icon) in copyIcons where !blocks.contains(index) {
            icon.removeFromSuperview()
            copyIcons[index] = nil
        }
        for index in blocks {
            let icon = copyIcons[index] ?? makeCopyIcon()
            copyIcons[index] = icon
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: style.captionPointSize, weight: .medium)
            if !keepsCopied { icon.image = Self.copySymbol(copied: false) }
        }
        placeCopyIcons()
    }

    private func makeCopyIcon() -> NSImageView {
        let icon = NSImageView()
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling     = .scaleProportionallyDown
        // The row's Copy action speaks for it, and its press goes to the row.
        icon.setAccessibilityElement(false)
        addSubview(icon)
        return icon
    }

    private func placeCopyIcons() {
        guard let row else { return }
        for (index, icon) in copyIcons where row.geometry.blocks.indices.contains(index) {
            icon.frame = RowGeometry.copyControl(in: row.geometry.blocks[index], style: style)
                .offsetBy(dx: drift(of: row), dy: 0)
        }
    }

    /// Turns the block's copy icon into a check, then back, with the system's symbol replace animation.
    func showCopied(block: Int) {
        guard let icon = copyIcons[block] else { return }
        // Off and up swaps the symbols in place; the default replace slides them down.
        icon.setSymbolImage(Self.copySymbol(copied: true), contentTransition: .replace.offUp)
        copiedReset?.cancel()
        copiedReset = Task { [weak icon] in
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            icon?.setSymbolImage(Self.copySymbol(copied: false), contentTransition: .replace.offUp)
        }
    }

    private static func copySymbol(copied: Bool) -> NSImage {
        let name = copied ? "checkmark" : "doc.on.doc"
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
    }

    /// How far a row's parts move from where they were placed: a live resize
    /// widens the row before its parts are placed again off the main thread,
    /// so the person's bubble, anchored to the right edge, follows the edge,
    /// and a divider, centred, follows the centre on a whole point.
    private func drift(of row: PreparedRow) -> CGFloat {
        let widened = bounds.width - row.geometry.rowWidth
        switch row.item.kind {
        case .personMessage:                   return widened
        case .daySeparator, .activityNotShown: return (widened / 2).rounded()
        default:                               return 0
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize.width != frame.width
        super.setFrameSize(newSize)
        guard changed else { return }
        placeCopyIcons()
        needsDisplay = true
    }

    /// The copy icons and the chevron take no press of their own; the row decides what a press on them does.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit is NSImageView ? self : hit
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

        // ponytail: only drawing follows the drift; a press during it hits where the parts were placed.
        let drift = drift(of: row)
        if drift != 0 { NSGraphicsContext.current?.cgContext.translateBy(x: drift, y: 0) }
        drawSurface(row, geometry: geometry, isPerson: isPerson)
        if let avatar, let frame = geometry.avatar { avatar.draw(in: frame) }
        if let header = geometry.header { drawName(row, in: header) }
        if let footer = geometry.footer { drawTime(row, in: footer, isPerson: isPerson) }
        for index in row.text.blocks.indices
        where geometry.blocks.indices.contains(index) && geometry.blocks[index].offsetBy(dx: drift, dy: 0).intersects(dirtyRect) {
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
            let fill = isPerson ? TranscriptColors.personBubble : TranscriptColors.neutralSurface
            bubbleFill(fill, isPerson: isPerson).setFill()
            path.fill()
            if isOutlined, !isBubbleSelected { strokeFocus(path) }

        case .card:
            let path = NSBezierPath(roundedRect: surface, xRadius: 8, yRadius: 8)
            NSGraphicsContext.saveGraphicsState()
            if case .toolRun = row.item.kind {
                // An opened tool line lifts off the background as a card, so its steps read apart from the replies.
                let shadow = NSShadow()
                shadow.shadowColor      = .black.withAlphaComponent(0.14)
                shadow.shadowBlurRadius = 3
                shadow.shadowOffset     = NSSize(width: 0, height: -1)
                shadow.set()
            }
            TranscriptColors.cardSurface.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            if case .executionFailed = row.item.kind {
                NSColor.systemRed.withAlphaComponent(0.6).setStroke()
            } else {
                NSColor.separatorColor.setStroke()
            }
            path.lineWidth = 1
            path.stroke()
            if isOutlined { strokeFocus(path) }

        case .line, .divider:
            // A quiet caption with no surface of its own; focus still outlines it.
            let frame = geometry.text.insetBy(dx: -6, dy: -2)
            if case .daySeparator = row.item.kind { drawRules(beside: geometry.text, drift: drift(of: row)) }
            if isOutlined { strokeFocus(NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4)) }
        }
    }

    /// A day's label between two hairlines that run out to the gutters. They reach the edges of
    /// the row as it is now, so a live resize stretches them at once; the context is moved by
    /// `drift` already, which they undo at their outer ends.
    private func drawRules(
        beside label: CGRect,
        drift       : CGFloat
    ) {
        let gap   = CGFloat(12)
        let hair  = 1 / (window?.backingScaleFactor ?? 2)
        let y     = label.midY.rounded()
        let start = RowGeometry.gutter - drift
        let end   = bounds.width - RowGeometry.gutter - drift
        NSColor.separatorColor.setFill()
        NSRect(x: start, y: y, width: max(0, label.minX - gap - start), height: hair).fill()
        NSRect(x: label.maxX + gap, y: y, width: max(0, end - label.maxX - gap), height: hair).fill()
    }

    /// A selected bubble is its own fill made lighter, with no border: toward
    /// white on the accent, a step up on the neutral surface in either theme.
    private func bubbleFill(_ fill: NSColor, isPerson: Bool) -> NSColor {
        guard isBubbleSelected else { return fill }
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return fill.blended(withFraction: isPerson ? 0.28 : isDark ? 0.14 : 0.6, of: .white) ?? fill
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

    /// The icon is a subview; the keyboard's focus on it is outlined here.
    private func drawCopyControl(in block: CGRect, isFocused: Bool) {
        guard isFocused else { return }
        let frame = RowGeometry.copyControl(in: block, style: style)
        strokeFocus(NSBezierPath(roundedRect: frame.insetBy(dx: -3, dy: -1), xRadius: 4, yRadius: 4))
    }

    private func drawName(_ row: PreparedRow, in frame: CGRect) {
        guard let name = TranscriptWording.header(for: row.item, workerName: workerName).name else { return }
        NSAttributedString(
            string    : name,
            attributes: [.font: style.textFont(ofSize: style.captionPointSize, weight: .bold),
                         .foregroundColor: NSColor.labelColor]
        ).draw(at: frame.origin)
    }

    /// The time sits at the bubble's inner corner, in from its edge, past the
    /// badge when there is one: bottom left under the person's, bottom right under the worker's.
    private func drawTime(_ row: PreparedRow, in frame: CGRect, isPerson: Bool) {
        guard row.item.endsGroup, style.showsTimes else { return }
        let time = NSAttributedString(
            string    : TranscriptWording.header(for: row.item, workerName: workerName).time,
            attributes: [.font: style.textFont(ofSize: style.captionPointSize - 1),
                         .foregroundColor: NSColor.tertiaryLabelColor]
        )
        let size  = time.size()
        let badge = row.geometry.badge.map { $0.width + 4 } ?? 0
        let x     = isPerson ? frame.minX + RowGeometry.footerInset + badge
                             : frame.maxX - RowGeometry.footerInset - badge - size.width
        time.draw(at: CGPoint(x: x, y: frame.midY - size.height / 2))
    }

    /// The badge's symbol: its shape carries the meaning, and a stopped or
    /// failed turn's is also a red disc so it is seen; the unsent clock stays quiet.
    private func draw(_ badge: DeliveryBadge, in frame: CGRect) {
        let colors: [NSColor] = badge == .interrupted ? [.white, .systemRed] : [.secondaryLabelColor]
        let configuration = NSImage.SymbolConfiguration(pointSize: frame.height, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: colors))
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
        guard let row, blockCharacter(at: point, boundary: true) != nil || row.geometry.surface.contains(point)
        else {
            super.mouseDown(with: event)
            return
        }
        if Self.isToolRun(row), event.clickCount == 1 {
            // A press first, as on any row, so the keyboard comes here and no outline is drawn.
            onPointer?(.press, event.locationInWindow)
            onActivate?()
            return
        }
        pressLocation = event.locationInWindow
        didDrag       = false
        onPointer?(.press, event.locationInWindow)
    }

    /// Past the viewport's edge the drag scrolls it; the controller keeps the
    /// selection's far end on whichever row is then under the pointer.
    override func mouseDragged(with event: NSEvent) {
        guard let press = pressLocation else { return }
        if !didDrag, hypot(event.locationInWindow.x - press.x, event.locationInWindow.y - press.y) > 2 {
            didDrag = true
            onPointer?(.dragStart, press)
        }
        guard didDrag else { return }
        autoscroll(with: event)
        onPointer?(.drag, event.locationInWindow)
    }

    /// A click that did not drag opens the link under it, as its explicit
    /// action, or else selects the bubble.
    override func mouseUp(with event: NSEvent) {
        defer { pressLocation = nil }
        guard !didDrag, pressLocation != nil, let row else { return }
        if let (block, offset) = blockCharacter(at: convert(event.locationInWindow, from: nil)),
           let action = RowAction.actions(in: row.text).first(where: {
               if case .openLink(_, block, let range) = $0 { NSLocationInRange(offset, range) } else { false }
           }) {
            onAction?(action)
            return
        }
        onPointer?(.click(count: event.clickCount, modifiers: event.modifierFlags), event.locationInWindow)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let hit = blockCharacter(at: convert(event.locationInWindow, from: nil))
        return onMenu?(hit?.block, hit.map { ranges[$0.block].location + $0.offset })
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
                // macOS 15 has no heading role; the heading is read as text there.
                if #available(macOS 26, *) {
                    element.setAccessibilityRole(.headingRole)
                } else {
                    element.setAccessibilityRole(.staticText)
                }
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
