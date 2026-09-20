/// GrayImage owns row-major luminance samples in the range 0...255.
struct GrayImage {
    let width: Int
    let height: Int
    var pixels: [Float]
}
