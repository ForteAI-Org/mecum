import CoreGraphics

/// TextRecognitionScope identifies the captured surface whose OCR an adapter may retain.
/// Changes to owner, window, title or capture geometry require a full read. It carries no AX state.
public struct TextRecognitionScope: Sendable, Equatable {
    public let application: String
    public let processID: Int32?
    public let windowNumber: Int?
    public let title: String
    public let frame: CGRect?

    public init(application: String, processID: Int32?, windowNumber: Int?, title: String, frame: CGRect?) {
        self.application = application
        self.processID = processID
        self.windowNumber = windowNumber
        self.title = title
        self.frame = frame
    }
}
