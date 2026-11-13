// Deterministic, synthetic tonal scenes. No photograph contributes pixels.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

precondition(CommandLine.arguments.count == 2, "usage: scene-inputs.swift output-directory")
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
precondition(!FileManager.default.fileExists(atPath: output.path))
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let space = CGColorSpace(name: CGColorSpace.displayP3)!
let width = 512
let height = 384
var index = 0
for mean in [0.12, 0.30, 0.50, 0.75] {
  for contrast in [0.15, 0.40] {
    for frequency in [1.0, 4.0] {
      var pixels = [UInt16](repeating: 0, count: width * height * 3)
      let phase = Double(index) * 0.31
      for y in 0..<height {
        for x in 0..<width {
          let u = Double(x) / Double(width - 1)
          let v = Double(y) / Double(height - 1)
          let wave = 0.52 * sin(2 * .pi * frequency * u + phase)
            + 0.31 * cos(2 * .pi * frequency * v + phase * 0.7)
            + 0.17 * sin(2 * .pi * frequency * (u + v) - phase)
          let texture = 0.025 * sin(2 * .pi * 53 * u) * cos(2 * .pi * 37 * v)
          let value = UInt16((min(max(mean + contrast * wave + texture, 0), 1) * 65535).rounded()).littleEndian
          for channel in 0..<3 { pixels[(y * width + x) * 3 + channel] = value }
        }
      }
      let data = pixels.withUnsafeBytes { Data($0) }
      let image = CGImage(width: width, height: height, bitsPerComponent: 16,
        bitsPerPixel: 48, bytesPerRow: width * 6, space: space,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue).union(.byteOrder16Little),
        provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
      let path = output.appendingPathComponent(String(format: "scene-%02d.tiff", index))
      let writer = CGImageDestinationCreateWithURL(path as CFURL, UTType.tiff.identifier as CFString, 1, nil)!
      CGImageDestinationAddImage(writer, image, [kCGImagePropertyOrientation: 1] as CFDictionary)
      precondition(CGImageDestinationFinalize(writer))
      index += 1
    }
  }
}
print("Generated \(index) synthetic scenes")
