import CoreImage
import Foundation

/// Two gray ramps and a 32³ encoded Display-P3 lattice in their measured positions.
func lightroomColorLattice() -> CIImage {
  lightroomColorChart { x, y, width, _ in
    let value = Double(x) / Double(width - 1)
    if y < 64 { return .init(repeating: value) }
    if y < 128 {
      return .init(repeating: value <= 0.0031308 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055)
    }
    return .init(Double(x % 32) / 31, Double(x / 32) / 31, Double((y - 128) / 4) / 31)
  }
}

/// The 16-bit, top-down, Display P3 bitmap supplied to Lightroom for these
/// samples. Its channel order and transfer curve are part of the fixture.
func lightroomColorChart(
  width: Int = 1024, height: Int = 256,
  rgbAt: (Int, Int, Int, Int) -> SIMD3<Double>
) -> CIImage {
  var channels: [UInt16] = []
  channels.reserveCapacity(width * height * 3)
  for y in 0..<height {
    for x in 0..<width {
      let rgb = rgbAt(x, y, width, height)
      for component in 0..<3 {
        channels.append(UInt16((rgb[component] * 65535).rounded()).littleEndian)
      }
    }
  }
  let data = channels.withUnsafeBytes { Data($0) }
  let image = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 48,
    bytesPerRow: width * 6, space: CGColorSpace(name: CGColorSpace.displayP3)!,
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue).union(.byteOrder16Little),
    provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false,
    intent: .defaultIntent)!
  return CIImage(cgImage: image)
}
