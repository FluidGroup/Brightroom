// Fixed ramps under different surrounds. These are validation, not training data.
import Foundation
import ImageIO
import UniformTypeIdentifiers

precondition(CommandLine.arguments.count == 2, "usage: context-inputs output-directory")
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
precondition(!FileManager.default.fileExists(atPath: out.path), "Do not overwrite evidence")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let space = CGColorSpace(name: CGColorSpace.displayP3)!
for name in ["ramp", "dark", "light", "midgray"] {
  var pixels = [UInt16](repeating: 0, count: 1024 * 256 * 3)
  for y in 0..<256 {
    for x in 0..<1024 {
      var level: Double
      switch name {
      case "dark": level = 0.02
      case "light": level = 0.98
      case "midgray": level = 0.5
      default: level = Double(x) / 1023
      }
      if name != "midgray" && (112..<144).contains(y) { level = Double(x) / 1023 }
      for channel in 0..<3 { pixels[(y * 1024 + x) * 3 + channel] = UInt16((level * 65535).rounded()).littleEndian }
    }
  }
  let data = pixels.withUnsafeBytes { Data($0) }
  let bitmap = CGImage(width: 1024, height: 256, bitsPerComponent: 16, bitsPerPixel: 48,
    bytesPerRow: 1024 * 6, space: space,
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue).union(.byteOrder16Little),
    provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
  let file = out.appendingPathComponent(name + ".tiff")
  precondition(!FileManager.default.fileExists(atPath: file.path))
  let writer = CGImageDestinationCreateWithURL(file as CFURL, UTType.tiff.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(writer, bitmap, [kCGImagePropertyOrientation: 1] as CFDictionary)
  precondition(CGImageDestinationFinalize(writer))
}
