// ocr <png>: the text Vision reads in an image, an oracle that needs no AX, for surfaces such as a
// terminal's GL canvas whose content accessibility does not expose. Capture with `screencapture -l`.
import Foundation
import Vision

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
try VNImageRequestHandler(url: url).perform([request])
print((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n"))
