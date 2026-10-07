//
//  FrameSample.swift
//  Mecum
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 07/10/2026.
//

#if MECUM_PHASES

/// FrameSample is what one ScreenCaptureKit callback carried, as plain values, so the module that
/// counts frames needs no capture framework.
///
/// `status` is the raw `SCFrameStatus` of the attachment (0 complete, 1 idle, 2 blank, 3 suspended,
/// 4 started, 5 stopped), nil when the sample has no status. `contentHash` is filled only when
/// `FrameProbe.hashesFrames` is set, since reading the pixels is not free.
public struct FrameSample: Sendable {
    public var status: Int?
    public var hasAttachment  = false
    public var hasDisplayTime = false
    public var hasScreenRect  = false
    public var hasContentRect = false
    public var hasScaleFactor = false
    public var hasContentScale = false
    public var dirtyRectCount = 0
    public var contentHash: UInt64?

    public init() {}
}
#endif
