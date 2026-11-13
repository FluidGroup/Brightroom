// Distinguish a fixed RGB transform, a global statistic, and spatial adaptation.
import Foundation
import ImageIO
import UniformTypeIdentifiers

precondition(CommandLine.arguments.count == 2)
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
precondition(!FileManager.default.fileExists(atPath: out.path))
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let space = CGColorSpace(name: CGColorSpace.displayP3)!
for name in ["ramp", "permuted", "near-dark", "near-light", "dark", "light"] {
  var pixels = [UInt16](repeating: 0, count: 1024 * 256 * 3)
  for y in 0..<256 {
    for x in 0..<1024 {
      var level = Double(x) / 1023
      switch name {
      case "permuted": level = Double((x * 619 + 17) % 1024) / 1023
      case "dark": if !(112..<144).contains(y) { level = 0.02 }
      case "light": if !(112..<144).contains(y) { level = 0.98 }
      case "near-dark", "near-light":
        if !(112..<144).contains(y) {
          let near = (56..<112).contains(y) || (144..<200).contains(y)
          level = (near == (name == "near-dark")) ? 0.02 : 0.98
        }
      default: break
      }
      let value = UInt16((level * 65535).rounded()).littleEndian
      for channel in 0..<3 { pixels[(y * 1024 + x) * 3 + channel] = value }
    }
  }
  let data = pixels.withUnsafeBytes { Data($0) }
  let bitmap = CGImage(width: 1024, height: 256, bitsPerComponent: 16, bitsPerPixel: 48,
    bytesPerRow: 1024 * 6, space: space,
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue).union(.byteOrder16Little),
    provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
  let writer = CGImageDestinationCreateWithURL(out.appendingPathComponent(name+".tiff") as CFURL,
    UTType.tiff.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(writer, bitmap, [kCGImagePropertyOrientation: 1] as CFDictionary)
  precondition(CGImageDestinationFinalize(writer))
}
