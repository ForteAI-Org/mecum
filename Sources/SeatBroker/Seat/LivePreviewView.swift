import AppKit
import SeatCapture

/// An AppKit view whose backing layer receives the capture stream's frames.
/// Frames go IOSurface to layer, no CGImage in between.
@MainActor
public final class LivePreviewView: NSView {
    private let monitorLayer: MonitorLayer
    private weak var driver: SeatDriver?

    init(driver: SeatDriver, contentsScale: CGFloat) {
        self.driver = driver
        self.monitorLayer = MonitorLayer(contentsScale: contentsScale)
        super.init(frame: .zero)
        wantsLayer = true
        driver.attach(monitorLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("LivePreviewView is code-only") }

    public override func makeBackingLayer() -> CALayer { monitorLayer }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        monitorLayer.contentsScale = window?.backingScaleFactor ?? monitorLayer.contentsScale
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { driver?.detach(monitorLayer) } else { driver?.attach(monitorLayer) }
    }
}
