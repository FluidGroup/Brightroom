// Generates two 16-bit Display P3 inputs for isolating Camera Raw Texture.
import Foundation
import ImageIO
import UniformTypeIdentifiers

precondition(CommandLine.arguments.count == 2, "usage: frequency-chart new-directory")
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
precondition(!FileManager.default.fileExists(atPath: output.path), "Choose a new output directory")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

// Each 96 × 96 patch contains an integer number of periods. The wider chart
// repeats the narrow one at the same pixel pitch and with the same histogram.
let side = 96
let periods = [2.0, 4, 8, 12, 16, 24, 32, 48]
let tones = [(0.25, 0.06), (0.5, 0.035), (0.5, 0.18), (0.75, 0.06)]
let height = side * tones.count
let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
for repeats in [1, 2] {
  let width = repeats * side * periods.count
  var pixels = [UInt16](repeating: 0, count: width * height * 3)
  for y in 0..<height {
    let (level, amplitude) = tones[y / side]
    for x in 0..<width {
      let period = periods[(x / side) % periods.count]
      let value = level + amplitude * cos(2 * .pi * Double(x % side) / period)
      let code = UInt16((value * 65535).rounded()).littleEndian
      for channel in 0..<3 { pixels[(y * width + x) * 3 + channel] = code }
    }
  }
  let data = pixels.withUnsafeBytes { Data($0) }
  let image = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 48,
    bytesPerRow: width * 6, space: colorSpace,
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue).union(.byteOrder16Little),
    provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
  let file = output.appendingPathComponent("frequencies-\(width).tiff")
  let writer = CGImageDestinationCreateWithURL(file as CFURL, UTType.tiff.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(writer, image, [kCGImagePropertyOrientation: 1] as CFDictionary)
  precondition(CGImageDestinationFinalize(writer))
}
