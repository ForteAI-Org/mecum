//
//  PreparedText.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 23/09/2026.
//

import AppKit

/// PreparedText is a row's text after the content pipeline: its blocks, each
/// with its characters and the role of each run, with no font or colour
/// object in it.
///
/// A value rather than an attributed string because it crosses from the
/// preparation pass to the main actor, and `NSFont` is not `Sendable`. Turning
/// a block into an attributed string only applies attributes, so the parsing
/// it came from happens once, off the main thread.
///
/// The row's text as one string is its blocks joined by a newline. A
/// selection is a range in that string, so it names a message and the blocks
/// inside it without holding any view.
nonisolated struct PreparedText: Sendable, Hashable {

    /// What a run of characters is, which decides its font and colour.
    enum Role: Sendable, Hashable {
        case body
        case bodyOnAccent
        case caption
        case captionStrong
        case monospaced
        case alert

        /// A Markdown heading, level 1 to 6.
        case heading(level: Int)

        /// Code, inline or in a block, in the monospaced face and the body's colour.
        case code

        /// Inline code in the person's bubble, in the monospaced face on the accent.
        case codeOnAccent

        /// A token of a code block, in the monospaced face and its token's colour.
        case syntax(CodeToken.Kind)

        /// A tool line's summary and steps: a step below the caption, in the secondary colour.
        case toolCaption

        /// A link's own text. A model wrote it, so it looks like any link and
        /// never like a source that was consulted (§11.2).
        case link

        /// Where a link or an image points, shown beside it so it is never hidden.
        case destination
    }

    /// Inline emphasis, which changes the face and not the role.
    struct Traits: OptionSet, Sendable, Hashable {
        let rawValue: Int
        init(rawValue: Int) { self.rawValue = rawValue }

        static let bold          = Traits(rawValue: 1 << 0)
        static let italic        = Traits(rawValue: 1 << 1)
        static let strikethrough = Traits(rawValue: 1 << 2)
    }

    struct Run: Sendable, Hashable {
        let range : NSRange
        let role  : Role
        var traits: Traits = []

        /// What an explicit click on the run opens, for a link or an image reference.
        var link  : String?

        /// List nesting, in steps of `TranscriptStyle.indentStep`.
        var indent: Int = 0

        /// The run's paragraph starts with a list marker that hangs into the indent.
        var hangs : Bool = false
    }

    private(set) var blocks: [PreparedBlock] = []

    init() {}

    init(_ string: String, role: Role) {
        append(string, role: role)
    }

    init(blocks: [PreparedBlock]) {
        self.blocks = blocks
    }

    /// Adds `string` as one run of `role` to the last block, which is a text
    /// block made for it when there is none.
    mutating func append(_ string: String, role: Role) {
        if blocks.isEmpty { blocks.append(PreparedBlock(kind: .text)) }
        blocks[blocks.count - 1].append(string, role: role)
    }

    /// The whole row's text: the blocks joined by a newline.
    var string: String {
        blocks.map(\.string).joined(separator: "\n")
    }

    /// Where each block sits in `string`, in UTF-16 units.
    var blockRanges: [NSRange] {
        var location = 0
        return blocks.map { block in
            let length = (block.string as NSString).length
            defer { location += length + 1 }
            return NSRange(location: location, length: length)
        }
    }

    /// The attributes of `run` at `style`. Safe on any thread: it creates its
    /// fonts and colours and shares none.
    static func attributes(_ run: Run, _ style: TranscriptStyle) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any]
        switch run.role {
        case .body:
            attributes = [.font: style.textFont(ofSize: style.bodyPointSize), .foregroundColor: NSColor.labelColor]
        case .bodyOnAccent:
            attributes = [.font: style.textFont(ofSize: style.bodyPointSize), .foregroundColor: NSColor.white]
        case .caption:
            attributes = [.font: style.textFont(ofSize: style.captionPointSize),
                          .foregroundColor: NSColor.secondaryLabelColor]
        case .captionStrong:
            attributes = [.font: style.textFont(ofSize: style.captionPointSize, weight: .bold),
                          .foregroundColor: NSColor.secondaryLabelColor]
        case .monospaced:
            attributes = [.font: NSFont.monospacedSystemFont(ofSize: style.monospacedPointSize, weight: .regular),
                          .foregroundColor: NSColor.secondaryLabelColor]
        case .alert:
            attributes = [.font: style.textFont(ofSize: style.bodyPointSize), .foregroundColor: NSColor.systemRed]
        case .heading(let level):
            attributes = [.font: style.textFont(ofSize: style.headingPointSize(level: level), weight: .semibold),
                          .foregroundColor: NSColor.labelColor]
        case .code:
            attributes = [.font: NSFont.monospacedSystemFont(ofSize: style.codePointSize, weight: .regular),
                          .foregroundColor: NSColor.labelColor]
        case .codeOnAccent:
            attributes = [.font: NSFont.monospacedSystemFont(ofSize: style.codePointSize, weight: .regular),
                          .foregroundColor: NSColor.white]
        case .syntax(let kind):
            attributes = [.font: NSFont.monospacedSystemFont(ofSize: style.codePointSize, weight: .regular),
                          .foregroundColor: TranscriptColors.syntax(kind)]
        case .toolCaption:
            attributes = [.font: style.textFont(ofSize: style.toolPointSize),
                          .foregroundColor: NSColor.secondaryLabelColor]
        case .link:
            attributes = [.font: style.textFont(ofSize: style.bodyPointSize), .foregroundColor: NSColor.linkColor,
                          .underlineStyle: NSUnderlineStyle.single.rawValue]
        case .destination:
            attributes = [.font: style.textFont(ofSize: style.bodyPointSize),
                          .foregroundColor: NSColor.secondaryLabelColor]
        }
        if !run.traits.isEmpty, let font = attributes[.font] as? NSFont {
            attributes[.font] = Self.font(font, with: run.traits)
            if run.traits.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
        }
        if run.indent > 0 {
            let step  = style.indentStep
            let depth = CGFloat(run.indent)
            let paragraph = NSMutableParagraphStyle()
            paragraph.headIndent          = depth * step
            paragraph.firstLineHeadIndent = run.hangs ? (depth - 1) * step : depth * step
            paragraph.tabStops            = [NSTextTab(textAlignment: .left, location: depth * step)]
            paragraph.paragraphSpacing    = 2
            attributes[.paragraphStyle]   = paragraph
        }
        return attributes
    }

    /// `font` with bold or italic, through its descriptor, which is safe off
    /// the main thread. A face without the trait keeps the plain one.
    private static func font(_ font: NSFont, with traits: Traits) -> NSFont {
        var symbolic = font.fontDescriptor.symbolicTraits
        if traits.contains(.bold)   { symbolic.insert(.bold) }
        if traits.contains(.italic) { symbolic.insert(.italic) }
        return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(symbolic), size: font.pointSize) ?? font
    }
}
