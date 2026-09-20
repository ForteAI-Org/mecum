import Accelerate
import CoreGraphics

/// ImageOps normalizes captured pixels and applies Locator's grayscale edge kernels locally.
enum ImageOps {
    /// Renders into owned sRGB premultiplied RGBA8 bytes, returning nil if allocation geometry or
    /// CoreGraphics context creation is rejected. Rows preserve the input image's pixel orientation.
    static func renderRGBA(
        _ image: CGImage,
        width: Int,
        height: Int,
        highQuality: Bool = false
    ) -> [UInt8]? {
        guard width > 0, height > 0 else { return nil }
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !pixelOverflow, !byteOverflow,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var rgba = [UInt8](repeating: 0, count: byteCount)
        let rendered = rgba.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            if highQuality { context.interpolationQuality = .high }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered ? rgba : nil
    }

    /// Converts normalized RGB to luminance using separately rounded multiplies and additions.
    static func grayscale(_ image: CGImage) -> GrayImage? {
        let width = image.width
        let height = image.height
        guard let rgba = renderRGBA(image, width: width, height: height) else { return nil }
        let count = width * height
        let length = vDSP_Length(count)
        var pixels = [Float](repeating: 0, count: count)
        var temporary = pixels
        let converted = rgba.withUnsafeBufferPointer { source in
            guard let start = source.baseAddress else { return false }
            var coefficient: Float = 0.299
            vDSP_vfltu8(start, 4, &pixels, 1, length)
            vDSP_vsmul(pixels, 1, &coefficient, &pixels, 1, length)
            coefficient = 0.587
            vDSP_vfltu8(start + 1, 4, &temporary, 1, length)
            vDSP_vsmul(temporary, 1, &coefficient, &temporary, 1, length)
            vDSP_vadd(pixels, 1, temporary, 1, &pixels, 1, length)
            coefficient = 0.114
            vDSP_vfltu8(start + 2, 4, &temporary, 1, length)
            vDSP_vsmul(temporary, 1, &coefficient, &temporary, 1, length)
            vDSP_vadd(pixels, 1, temporary, 1, &pixels, 1, length)
            return true
        }
        return converted ? GrayImage(width: width, height: height, pixels: pixels) : nil
    }

    /// Computes Sobel magnitudes, preserving the scalar expression order and a zero one-pixel border.
    static func sobelMagnitude(_ image: GrayImage) -> GrayImage {
        let width = image.width
        let height = image.height
        let count = width * height
        guard width >= 3, height >= 3 else {
            return GrayImage(width: width, height: height, pixels: [Float](repeating: 0, count: count))
        }
        var horizontal = [Float](repeating: 0, count: count)
        var vertical = horizontal
        sobelComponents(image.pixels, width: width, height: height, horizontal: &horizontal, vertical: &vertical)
        let length = vDSP_Length(count)
        vDSP_vsq(horizontal, 1, &horizontal, 1, length)
        vDSP_vsq(vertical, 1, &vertical, 1, length)
        vDSP_vadd(horizontal, 1, vertical, 1, &horizontal, 1, length)
        for index in 0..<count { horizontal[index] = horizontal[index].squareRoot() }
        for x in 0..<width {
            horizontal[x] = 0
            horizontal[(height - 1) * width + x] = 0
        }
        for y in 0..<height {
            horizontal[y * width] = 0
            horizontal[y * width + width - 1] = 0
        }
        return GrayImage(width: width, height: height, pixels: horizontal)
    }

    private static func sobelComponents(
        _ pixels: [Float],
        width: Int,
        height: Int,
        horizontal: inout [Float],
        vertical: inout [Float]
    ) {
        let count = width * height
        let length = vDSP_Length(count - 2 * width - 2)
        var two: Float = 2
        var first = [Float](repeating: 0, count: count)
        var second = first
        pixels.withUnsafeBufferPointer { source in
            first.withUnsafeMutableBufferPointer { firstBuffer in
                second.withUnsafeMutableBufferPointer { secondBuffer in
                    horizontal.withUnsafeMutableBufferPointer { horizontalBuffer in
                        vertical.withUnsafeMutableBufferPointer { verticalBuffer in
                            // The caller validated at least 3x3 pixels and allocated all five planes.
                            guard let sourceStart = source.baseAddress,
                                  let firstStart = firstBuffer.baseAddress,
                                  let secondStart = secondBuffer.baseAddress,
                                  let horizontalStart = horizontalBuffer.baseAddress,
                                  let verticalStart = verticalBuffer.baseAddress else {
                                preconditionFailure("Sobel requires nonempty pixel planes")
                            }
                            let sourcePixel = sourceStart + width + 1
                            let firstPixel = firstStart + width + 1
                            let secondPixel = secondStart + width + 1
                            let horizontalPixel = horizontalStart + width + 1
                            let verticalPixel = verticalStart + width + 1
                            vDSP_vsma(sourcePixel + 1, 1, &two, sourcePixel - width + 1, 1, firstPixel, 1, length)
                            vDSP_vadd(firstPixel, 1, sourcePixel + width + 1, 1, firstPixel, 1, length)
                            vDSP_vsma(sourcePixel - 1, 1, &two, sourcePixel - width - 1, 1, secondPixel, 1, length)
                            vDSP_vadd(secondPixel, 1, sourcePixel + width - 1, 1, secondPixel, 1, length)
                            vDSP_vsub(secondPixel, 1, firstPixel, 1, horizontalPixel, 1, length)
                            vDSP_vsma(sourcePixel + width, 1, &two, sourcePixel + width - 1, 1, firstPixel, 1, length)
                            vDSP_vadd(firstPixel, 1, sourcePixel + width + 1, 1, firstPixel, 1, length)
                            vDSP_vsma(sourcePixel - width, 1, &two, sourcePixel - width - 1, 1, secondPixel, 1, length)
                            vDSP_vadd(secondPixel, 1, sourcePixel - width + 1, 1, secondPixel, 1, length)
                            vDSP_vsub(secondPixel, 1, firstPixel, 1, verticalPixel, 1, length)
                        }
                    }
                }
            }
        }
    }

    /// Dilates a foreground mask, using the scalar equivalent if Accelerate rejects the filter.
    static func dilate(_ mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        guard radius > 0, width > 0, height > 0 else { return mask }
        if let filtered = boxMorphology8(
            mask.map { $0 ? 1 : 0 },
            width: width,
            height: height,
            kernel: 2 * radius + 1,
            dilate: true
        ) {
            return filtered.map { $0 != 0 }
        }
        var output = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] {
                for neighborY in max(0, y - radius)...min(height - 1, y + radius) {
                    for neighborX in max(0, x - radius)...min(width - 1, x + radius) {
                        output[neighborY * width + neighborX] = true
                    }
                }
            }
        }
        return output
    }

    /// Applies a square max or min filter to a byte plane, extending border pixels.
    /// Returns nil when dimensions are invalid or Accelerate rejects the operation.
    static func boxMorphology8(
        _ pixels: [UInt8],
        width: Int,
        height: Int,
        kernel: Int,
        dilate: Bool
    ) -> [UInt8]? {
        guard width > 0, height > 0, kernel >= 1 else { return nil }
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels.count == count else { return nil }
        var input = pixels
        var output = [UInt8](repeating: 0, count: count)
        let error: vImage_Error = input.withUnsafeMutableBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                var sourceImage = vImage_Buffer(
                    data: source.baseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width
                )
                var destinationImage = vImage_Buffer(
                    data: destination.baseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: width
                )
                let size = vImagePixelCount(kernel)
                let flags = vImage_Flags(kvImageEdgeExtend)
                return dilate
                    ? vImageMax_Planar8(&sourceImage, &destinationImage, nil, 0, 0, size, size, flags)
                    : vImageMin_Planar8(&sourceImage, &destinationImage, nil, 0, 0, size, size, flags)
            }
        }
        return error == kvImageNoError ? output : nil
    }
}
