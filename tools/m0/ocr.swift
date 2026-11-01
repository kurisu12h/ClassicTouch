// M0: read the labels on a screendump (as LightTouchMac's SessionKit TextReader does, with Vision).
// usage: ocr IMAGE  -> JSON lines {"text", "x", "y", "w", "h"} with x,y the label's centre, normalized, top-left origin.
import AppKit
import Foundation
import Vision

let path = CommandLine.arguments[1]
guard let image = NSImage(contentsOfFile: path),
    let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    FileHandle.standardError.write(Data("ocr: cannot read \(path)\n".utf8))
    exit(1)
}
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
request.recognitionLanguages = ["en-US"]
// the panel is small (320x480): upscale for Vision
let scale = 3.0
let w = Int(Double(cg.width) * scale), h = Int(Double(cg.height) * scale)
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
let handler = VNImageRequestHandler(cgImage: ctx.makeImage()!, options: [:])
try handler.perform([request])
for obs in request.results ?? [] {
    guard let top = obs.topCandidates(1).first else { continue }
    let b = obs.boundingBox
    let o: [String: Any] = ["text": top.string, "x": b.midX, "y": 1 - b.midY, "w": b.width, "h": b.height]
    let d = try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
    print(String(decoding: d, as: UTF8.self))
}
