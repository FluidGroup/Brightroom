import BrightroomParametric
import CoreImage
import Foundation
import Testing

struct TonalPointTests {

  private static let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!

  @Test
  func neutralBypassAndStoredParameters() throws {
    let source = Self.image([SIMD4(-0.1, 0.3, 1.3, 1)])
    #expect(try FeatureRenderer().makeImage(from: source, feature: WhitesFeature()) === source)
    #expect(try FeatureRenderer().makeImage(from: source, feature: BlacksFeature()) === source)
    for invalid: Double in [-101, 101, .nan, -.infinity, .infinity] {
      #expect(WhitesFeature(validatingAmount: invalid) == nil)
      #expect(BlacksFeature(validatingAmount: invalid) == nil)
    }
    for amount: Double in [-100, -27, 0, 19, 100] {
      let whites = WhitesFeature(amount: amount)
      let blacks = BlacksFeature(amount: amount)
      #expect(WhitesFeature(validatingAmount: whites.amount) == whites)
      #expect(BlacksFeature(validatingAmount: blacks.amount) == blacks)
    }
    var whites = WhitesFeature(amount: 200)
    var blacks = BlacksFeature(amount: -200)
    #expect(whites.amount == 100 && blacks.amount == -100)
    whites.amount = .nan
    blacks.amount = .infinity
    #expect(whites.amount == 0 && blacks.amount == 0)
  }


  @Test
  func signedAmountsMoveTonesAndPreserveGray() throws {
    let input = [0.03, 0.18, 0.7].map { SIMD4<Float>($0, $0, $0, 1) }
    for amount: Double in [-100, -25, 25, 100] {
      for effect in [AnyImageEffect(WhitesFeature(amount: amount)), AnyImageEffect(BlacksFeature(amount: amount))] {
        let output = try Self.render(input, feature: effect)
        for (source, pixel) in zip(input, output) {
          #expect((pixel.x - source.x) * Float(amount) > 0, "Amount \(amount), input \(source), output \(pixel)")
          #expect(abs(pixel.x - pixel.y) < 0.00001)
          #expect(abs(pixel.x - pixel.z) < 0.00001)
          #expect(pixel.w == 1)
        }
      }
    }
  }


  @Test
  func alphaAndExtendedValuesAreNotClipped() throws {
    let opaque = SIMD4<Float>(0.05, 0.12, 0.4, 1)
    for effect in [AnyImageEffect(WhitesFeature(amount: 43)), AnyImageEffect(BlacksFeature(amount: -38))] {
      let pixels = try Self.render([opaque, opaque * 0.5, .zero,
        SIMD4(-0.3, 0.2, 1.4, 1)], feature: effect)
      #expect(Self.difference([pixels[0] * 0.5], [pixels[1]]) < 0.00001)
      #expect(pixels[2] == .zero)
      #expect(pixels[3].x < 0 && pixels[3].z > 1)
    }
  }


  private static func image(_ pixels: [SIMD4<Float>]) -> CIImage {
    CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: pixels.count * 16,
      size: CGSize(width: pixels.count, height: 1), format: .RGBAf, colorSpace: space)
  }

  private static func render(_ pixels: [SIMD4<Float>], feature: some Feature) throws -> [SIMD4<Float>] {
    let graph = try FeatureRenderer().makeImage(from: image(pixels), feature: feature)
    var output = [SIMD4<Float>](repeating: .zero, count: pixels.count)
    CIContext(options: [.workingFormat: CIFormat.RGBAf, .workingColorSpace: space]).render(
      graph, toBitmap: &output, rowBytes: pixels.count * 16, bounds: graph.extent, format: .RGBAf, colorSpace: space)
    return output
  }

  private static func difference(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Float {
    zip(a, b).flatMap { left, right in (0..<4).map { abs(left[$0] - right[$0]) } }.max() ?? 0
  }
}
