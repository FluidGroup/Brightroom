// Independent scene statistics for evaluating adaptive tonal hypotheses.
import Foundation
import ImageIO
import UniformTypeIdentifiers
precondition(CommandLine.arguments.count == 2)
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
precondition(!FileManager.default.fileExists(atPath: out.path))
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let space = CGColorSpace(name: CGColorSpace.displayP3)!
for (name, low, high) in [
  ("flat-10", 0.1, 0.1), ("flat-25", 0.25, 0.25), ("flat-50", 0.5, 0.5),
  ("flat-75", 0.75, 0.75), ("flat-90", 0.9, 0.9),
  ("low-ramp", 0.0, 0.6), ("mid-ramp", 0.2, 0.8), ("high-ramp", 0.4, 1.0),
] {
  var pixels = [UInt16](repeating: 0, count: 1024 * 256 * 3)
  for y in 0..<256 {
    for x in 0..<1024 {
      let value = UInt16(((low + (high-low)*Double(x)/1023)*65535).rounded()).littleEndian
      for c in 0..<3 { pixels[(y*1024+x)*3+c] = value }
    }
  }
  let data = pixels.withUnsafeBytes { Data($0) }
  let bitmap = CGImage(width: 1024, height: 256, bitsPerComponent: 16, bitsPerPixel: 48,
    bytesPerRow: 1024*6, space: space,
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue).union(.byteOrder16Little),
    provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
  let writer = CGImageDestinationCreateWithURL(out.appendingPathComponent(name+".tiff") as CFURL,
    UTType.tiff.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(writer, bitmap, [kCGImagePropertyOrientation:1] as CFDictionary)
  precondition(CGImageDestinationFinalize(writer))
}
