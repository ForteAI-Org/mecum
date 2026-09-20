import AppKit

/// OverlayPanel cannot become key or main, so showing it never takes keyboard focus.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
