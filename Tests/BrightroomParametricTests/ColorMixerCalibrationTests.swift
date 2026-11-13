import CoreImage
import Foundation
import Testing
import BrightroomParametric

/// Public API only. Frozen PV 15.4 holdouts check the measured algorithm, while
/// alpha, neutral colors, and context tests exercise its rendering contract.
@Suite("Measured Color Mixer", .serialized)
struct ColorMixerCalibrationTests {

  private static let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
  private static let context = CIContext(options: [
    .workingColorSpace: space, .workingFormat: CIFormat.RGBAf,
  ])

  @Test
  func neutralBypassesTheGraphExactly() throws {
    let source = Self.image([SIMD4(-0.1, 0.6, 1.2, 1)])
    let feature = ColorMixerFeature(bands: .neutral, algorithm: .lightroomApproximation)
    #expect(try FeatureRenderer().makeImage(from: source, feature: feature) === source)
  }

  @Test
  func intermediateControlsApproximateIndependentAdobeReferences() throws {
    // Neither +23 Blue Luminance nor +31 Orange Hue is a calibration strength.
    // These are linear-P3 pixels from registered analytic charts, not a camera photo.
    let luminance = ColorMixerFeature(bands: .init(blue: .init(luminance: 23)),
      algorithm: .lightroomApproximation)
    let hue = ColorMixerFeature(bands: .init(orange: .init(hue: 31)),
      algorithm: .lightroomApproximation)
    for (feature, expected) in [(luminance, Self.blueLuminance), (hue, Self.orangeHue)] {
      let pixels = try Self.render(Self.source, feature: feature)
      for (actual, reference) in zip(pixels, expected) {
        #expect(Self.difference(actual, reference) < 0.008)
      }
    }
  }

  @Test
  func grayDiagonalHeadroomAndPremultiplicationSurviveNonneutralBands() throws {
    let feature = ColorMixerFeature(bands: .init(
      red: .init(hue: 80, saturation: -50, luminance: 35),
      green: .init(hue: -40, saturation: 25), blue: .init(saturation: -75, luminance: 30)),
      algorithm: .lightroomApproximation)
    let gray = [-0.2, 0, 0.18, 0.73, 1, 1.4].map { SIMD4<Float>($0, $0, $0, 1) }
    let output = try Self.render(gray, feature: feature)
    for (actual, expected) in zip(output, gray) {
      #expect(Self.difference(actual, expected) < 0.00005)
    }
    let opaque = SIMD4<Float>(0.05, 0.12, 0.4, 1)
    let translucent = opaque * 0.5
    let pixels = try Self.render([opaque, translucent, .zero], feature: feature)
    #expect(Self.difference(pixels[0] * 0.5, pixels[1]) < 0.00005)
    #expect(pixels[2] == .zero)
  }

  private static func image(_ pixels: [SIMD4<Float>]) -> CIImage {
    CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) },
      bytesPerRow: pixels.count * MemoryLayout<SIMD4<Float>>.stride,
      size: CGSize(width: pixels.count, height: 1), format: .RGBAf, colorSpace: space)
  }

  private static func render(_ pixels: [SIMD4<Float>], feature: ColorMixerFeature) throws -> [SIMD4<Float>] {
    let source = image(pixels)
    let image = try FeatureRenderer().makeImage(from: source, feature: feature)
    #expect(image.extent == source.extent)
    var output = [SIMD4<Float>](repeating: .init(repeating: .nan), count: pixels.count)
    context.render(image, toBitmap: &output, rowBytes: pixels.count * 16,
      bounds: image.extent, format: .RGBAf, colorSpace: space)
    #expect(output.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite })
    return output
  }

  private static func difference(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float {
    max(abs(a.x-b.x), abs(a.y-b.y), abs(a.z-b.z), abs(a.w-b.w))
  }

  private static let source: [SIMD4<Float>] = [
    SIMD4(0.009557330, 0.054169647, 0.373826027, 1),
    SIMD4(0.054231364, 0.123988017, 0.614832640, 1),
    SIMD4(0.199525520, 0.373816997, 0.928185821, 1),
    SIMD4(0.793764114, 0.068588398, 0.015189036, 1),
    SIMD4(0.561018288, 0.229307458, 0.041755378, 1),
    SIMD4(0.999964774, 0.009561013, 0.041756134, 1),
    SIMD4(0.333914787, 0.261586159, 0.614849448, 1),
    SIMD4(0.124109842, 0.560983360, 0.199409068, 1)
  ]

  private static let blueLuminance: [SIMD4<Float>] = [
    SIMD4(0.022474742, 0.074647106, 0.448282182, 1),
    SIMD4(0.110609449, 0.184231862, 0.702412426, 1),
    SIMD4(0.353491604, 0.499224961, 0.962772787, 1),
    SIMD4(0.793764114, 0.068588398, 0.015189036, 1),
    SIMD4(0.561018288, 0.229307458, 0.041755378, 1),
    SIMD4(0.999964774, 0.009561013, 0.041756134, 1),
    SIMD4(0.372945964, 0.300818592, 0.653026283, 1),
    SIMD4(0.124109842, 0.560983360, 0.199409068, 1)
  ]

  private static let orangeHue: [SIMD4<Float>] = [
    SIMD4(0.009557330, 0.054169647, 0.373826027, 1),
    SIMD4(0.054231364, 0.123988017, 0.614832640, 1),
    SIMD4(0.199525520, 0.373816997, 0.928185821, 1),
    SIMD4(0.791544080, 0.103820786, 0.009546576, 1),
    SIMD4(0.539240241, 0.294423312, 0.047477107, 1),
    SIMD4(0.999607563, 0.016078433, 0.038565595, 1),
    SIMD4(0.333943278, 0.261583477, 0.614849627, 1),
    SIMD4(0.124109842, 0.560983360, 0.199409068, 1)
  ]
}
