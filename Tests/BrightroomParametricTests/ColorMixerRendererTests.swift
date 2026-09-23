import CoreImage
import Foundation
import Testing

@testable import BrightroomParametric

/// Numeric contract and GPU parity proofs for the independent Color Mixer.
@Suite("Color Mixer rendering", .serialized)
struct ColorMixerRendererTests {

  @Test
  func neutralUsesExactCPUAndCoreImageBypass() throws {
    let pixel = SIMD4<Double>(-0.2, 1.4, 0.3, 0.6)
    let image = Self.makeImage([SIMD4(-0.12, 0.84, 0.18, 0.6)])
    #expect(ColorMixerRenderPlan(adjustment: .neutral) == nil)
    #expect(try ColorMixerRenderer.apply(to: image, adjustment: .neutral) === image)
    #expect(ColorMixerReferenceProcessor.processPremultiplied(pixel, adjustment: .neutral) == pixel)
    for feature in [
      ColorMixerFeature(adjustment: .neutral),
      ColorMixerFeature(adjustment: .neutral, algorithm: .oklch),
    ] {
      #expect(feature.algorithm == .oklch)
      #expect(feature.isEnabled == false)
      #expect(try feature.apply(to: image, context: .init()) === image)
    }
  }

  @Test
  func defaultAndExplicitOKLChProduceExactlyTheSameNonneutralPixels() throws {
    let adjustment = ColorMixerAdjustment(
      red: .init(hue: 23, saturation: -24, luminance: 17),
      blue: .init(hue: -35, saturation: 40, luminance: -20)
    )
    let implicit = ColorMixerFeature(adjustment: adjustment)
    let explicit = ColorMixerFeature(adjustment: adjustment, algorithm: .oklch)
    let pixels: [SIMD4<Float>] = [
      SIMD4(0.7, 0.1, 0.05, 1),
      SIMD4(-0.1, 0.3, 1.2, 1),
      SIMD4(0.45, 0.05, 0.35, 0.5),
    ]
    let image = Self.makeImage(pixels)

    let implicitOutput = try implicit.apply(to: image, context: .init())
    let explicitOutput = try explicit.apply(to: image, context: .init())
    let implicitPixels = Self.sample(implicitOutput, count: pixels.count)
    let explicitPixels = Self.sample(explicitOutput, count: pixels.count)

    #expect(implicit.algorithm == .oklch)
    #expect(implicit.isEnabled)
    #expect(implicit == explicit)
    #expect(implicitOutput.extent == image.extent)
    #expect(explicitOutput.extent == image.extent)
    #expect(implicitPixels == explicitPixels)
    #expect(implicitPixels != Self.sample(image, count: pixels.count))
  }

  @Test
  func canonicalDisplayP3HSVAnchorsMatchStoredOKLChHues() {
    let hsvHues = [0.0, 30, 60, 120, 180, 240, 270, 300]
    for (index, hue) in hsvHues.enumerated() {
      let linear = Self.linearDisplayP3HSV(hueDegrees: hue)
      let actual = ColorMixerReferenceProcessor.okLCh(forLinearDisplayP3: linear).hue
      expectClose(
        actual, ColorMixerReferenceProcessor.bandAnchorHues[index], tolerance: 0.000_000_01)
    }
  }

  @Test
  func achromaticPixelsRemainExactlyUnaffected() throws {
    let plan = try #require(Self.plan(red: .init(hue: 100, saturation: 100, luminance: 100)))
    let gray = SIMD3<Double>(repeating: 0.18)
    #expect(ColorMixerReferenceProcessor.processStraight(gray, plan: plan) == gray)
  }

  @Test
  func onlyAdjacentBandsInfluenceEveryAnchorAndBoundariesAreContinuous() throws {
    for index in 0..<8 {
      let band = ColorMixerBand.allCases[index]
      var value = ColorMixerAdjustment.neutral
      value[band] = .init(saturation: 100)
      let plan = try #require(ColorMixerRenderPlan(adjustment: value))
      let anchor = ColorMixerReferenceProcessor.OKLCh(
        lightness: 0.7,
        chroma: 0.15,
        hue: ColorMixerReferenceProcessor.bandAnchorHues[index]
      )
      let input = ColorMixerReferenceProcessor.linearDisplayP3(anchor)
      let output = ColorMixerReferenceProcessor.processStraight(input, plan: plan)
      let result = ColorMixerReferenceProcessor.okLCh(forLinearDisplayP3: output)
      expectClose(result.chroma, 0.3, tolerance: 0.000_000_1)
    }

    let plan = try #require(Self.plan(green: .init(hue: 80, saturation: -40, luminance: 30)))
    let anchor = ColorMixerReferenceProcessor.bandAnchorHues[3]
    let below = ColorMixerReferenceProcessor.linearDisplayP3(
      .init(lightness: 0.65, chroma: 0.12, hue: anchor - 0.000_001))
    let above = ColorMixerReferenceProcessor.linearDisplayP3(
      .init(lightness: 0.65, chroma: 0.12, hue: anchor + 0.000_001))
    let left = ColorMixerReferenceProcessor.processStraight(below, plan: plan)
    let right = ColorMixerReferenceProcessor.processStraight(above, plan: plan)
    expectClose(left, right, tolerance: 0.000_005)
  }

  @Test
  func nonAdjacentBandDoesNotInfluencePixel() throws {
    let plan = try #require(
      Self.plan(blue: .init(hue: 100, saturation: 100, luminance: 100)))
    let input = ColorMixerReferenceProcessor.linearDisplayP3(
      .init(
        lightness: 0.65,
        chroma: 0.14,
        hue: ColorMixerReferenceProcessor.bandAnchorHues[ColorMixerBand.red.rawValue]
      ))

    let output = ColorMixerReferenceProcessor.processStraight(input, plan: plan)

    expectClose(output, input, tolerance: 0.000_000_1)
  }

  @Test
  func magentaRedWrapIsContinuous() throws {
    let plan = try #require(
      Self.plan(
        red: .init(hue: -60, saturation: 25, luminance: -20),
        magenta: .init(hue: 70, saturation: -30, luminance: 15)
      ))
    let boundary = Double.pi * 2
    let below = ColorMixerReferenceProcessor.linearDisplayP3(
      .init(lightness: 0.7, chroma: 0.18, hue: boundary - 0.000_001))
    let above = ColorMixerReferenceProcessor.linearDisplayP3(
      .init(lightness: 0.7, chroma: 0.18, hue: 0.000_001))
    let first = ColorMixerReferenceProcessor.processStraight(below, plan: plan)
    let second = ColorMixerReferenceProcessor.processStraight(above, plan: plan)
    expectClose(first, second, tolerance: 0.000_005)
  }

  @Test
  func hueEndpointsReachPreviousAndNextBandCenters() throws {
    let index = ColorMixerBand.green.rawValue
    let inputLCh = ColorMixerReferenceProcessor.OKLCh(
      lightness: 0.7,
      chroma: 0.18,
      hue: ColorMixerReferenceProcessor.bandAnchorHues[index]
    )
    let input = ColorMixerReferenceProcessor.linearDisplayP3(inputLCh)
    for (amount, expectedIndex) in [(-100.0, index - 1), (100.0, index + 1)] {
      let plan = try #require(Self.plan(green: .init(hue: amount)))
      let output = ColorMixerReferenceProcessor.processStraight(input, plan: plan)
      let result = ColorMixerReferenceProcessor.okLCh(forLinearDisplayP3: output)
      expectAngleClose(result.hue, ColorMixerReferenceProcessor.bandAnchorHues[expectedIndex])
    }
  }

  @Test
  func reportedRedAdjustmentMovesTowardOrange() throws {
    let plan = try #require(Self.plan(red: .init(hue: 23, saturation: -24)))
    let input = SIMD3<Double>(1, 0, 0)
    let original = ColorMixerReferenceProcessor.okLCh(forLinearDisplayP3: input)

    let output = ColorMixerReferenceProcessor.processStraight(input, plan: plan)
    let result = ColorMixerReferenceProcessor.okLCh(forLinearDisplayP3: output)

    let orangeHue = ColorMixerReferenceProcessor.bandAnchorHues[ColorMixerBand.orange.rawValue]
    let expectedHue = original.hue + 0.23 * (orangeHue - original.hue)
    expectAngleClose(result.hue, expectedHue)
    expectClose(result.chroma, original.chroma * 0.76, tolerance: 0.000_000_1)
    expectClose(result.lightness, original.lightness, tolerance: 0.000_000_1)

    let rendered = try ColorMixerRenderer.apply(
      to: Self.makeImage([SIMD4<Float>(1, 0, 0, 1)]),
      plan: plan
    )
    let metalResult = try #require(Self.sample(rendered, count: 1).first)
    expectClose(
      metalResult,
      SIMD4(output.x, output.y, output.z, 1),
      tolerance: 0.002
    )
  }

  @Test
  func saturationAndLuminanceEndpointsHaveSpecifiedScale() throws {
    let inputLCh = ColorMixerReferenceProcessor.OKLCh(
      lightness: 0.6,
      chroma: 0.2,
      hue: ColorMixerReferenceProcessor.bandAnchorHues[0]
    )
    let input = ColorMixerReferenceProcessor.linearDisplayP3(inputLCh)
    for (amount, expected) in [(-100.0, 0.0), (100.0, 0.4)] {
      let plan = try #require(Self.plan(red: .init(saturation: amount)))
      let result = ColorMixerReferenceProcessor.okLCh(
        forLinearDisplayP3: ColorMixerReferenceProcessor.processStraight(input, plan: plan)
      )
      expectClose(result.chroma, expected, tolerance: 0.000_000_1)
    }
    for (amount, expected) in [(-100.0, 0.3), (100.0, 1.2)] {
      let plan = try #require(Self.plan(red: .init(luminance: amount)))
      let result = ColorMixerReferenceProcessor.okLCh(
        forLinearDisplayP3: ColorMixerReferenceProcessor.processStraight(input, plan: plan)
      )
      expectClose(result.lightness, expected, tolerance: 0.000_000_1)
    }
  }

  @Test
  func alphaExtendedValuesAndFiniteOutputArePreserved() throws {
    let plan = try #require(Self.plan(blue: .init(hue: 90, saturation: 100, luminance: 100)))
    let pixels = [
      SIMD4<Double>(-0.12, 0.7, 1.3, 0.5),
      SIMD4<Double>(1.8, -0.2, 0.4, 1),
      SIMD4<Double>(0, 0, 0, 0),
    ]
    for pixel in pixels {
      let output = ColorMixerReferenceProcessor.processPremultiplied(pixel, plan: plan)
      let componentsAreFinite = [output.x, output.y, output.z, output.w].allSatisfy { $0.isFinite }
      #expect(output.w == pixel.w)
      #expect(componentsAreFinite)
    }
  }

  @Test
  func metalMatchesCPUReferenceWithinFloatTolerance() throws {
    let plan = try #require(
      Self.plan(
        red: .init(hue: -70, saturation: 40, luminance: -25),
        yellow: .init(hue: 100, saturation: -100, luminance: 60),
        aqua: .init(hue: -35, saturation: 100, luminance: -100),
        magenta: .init(hue: 55, saturation: -20, luminance: 100)
      ))
    let source: [SIMD4<Float>] = [
      SIMD4(0.7, 0.1, 0.05, 1),
      SIMD4(0.05, 0.7, 0.3, 1),
      SIMD4(-0.1, 0.3, 1.2, 1),
      SIMD4(0.45, 0.05, 0.35, 0.5),
      SIMD4(0.18, 0.18, 0.18, 1),
    ]
    let output = try ColorMixerRenderer.apply(to: Self.makeImage(source), plan: plan)
    let actual = Self.sample(output, count: source.count)
    for index in source.indices {
      let sourcePixel = source[index]
      let pixel = SIMD4(
        Double(sourcePixel.x),
        Double(sourcePixel.y),
        Double(sourcePixel.z),
        Double(sourcePixel.w)
      )
      let expected = ColorMixerReferenceProcessor.processPremultiplied(pixel, plan: plan)
      expectClose(actual[index], expected, tolerance: 0.002)
    }
  }

  @Test
  func persistedFeatureRebuildsTheSameMetalRecipe() throws {
    let adjustment = ColorMixerAdjustment(
      red: .init(hue: -40, saturation: 35, luminance: 20),
      blue: .init(hue: 15, saturation: -20, luminance: -30)
    )
    let feature = ColorMixerFeature(adjustment: adjustment, algorithm: .oklch)
    let restored = try JSONDecoder().decode(
      ColorMixerFeature.self, from: JSONEncoder().encode(feature)
    )
    let pixels: [SIMD4<Float>] = [SIMD4(0.7, 0.1, 0.05, 1), SIMD4(-0.1, 0.3, 1.2, 1)]
    let image = Self.makeImage(pixels)
    let output = try restored.apply(to: image, context: .init())
    let actual = Self.sample(output, count: pixels.count)
    #expect(restored.algorithm == .oklch)

    for index in pixels.indices {
      let pixel = pixels[index]
      let expected = ColorMixerReferenceProcessor.processPremultiplied(
        SIMD4(Double(pixel.x), Double(pixel.y), Double(pixel.z), Double(pixel.w)),
        adjustment: adjustment
      )
      expectClose(actual[index], expected, tolerance: 0.002)
    }
  }

  private static let context = CIContext(options: [
    .workingFormat: CIFormat.RGBAf,
    .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
    .cacheIntermediates: false,
  ])

  private static func plan(
    red: ColorMixerBandAdjustment = .init(),
    orange: ColorMixerBandAdjustment = .init(),
    yellow: ColorMixerBandAdjustment = .init(),
    green: ColorMixerBandAdjustment = .init(),
    aqua: ColorMixerBandAdjustment = .init(),
    blue: ColorMixerBandAdjustment = .init(),
    purple: ColorMixerBandAdjustment = .init(),
    magenta: ColorMixerBandAdjustment = .init()
  ) -> ColorMixerRenderPlan? {
    ColorMixerRenderPlan(
      adjustment: .init(
        red: red, orange: orange, yellow: yellow, green: green,
        aqua: aqua, blue: blue, purple: purple, magenta: magenta
      ))
  }

  private static func linearDisplayP3HSV(hueDegrees: Double) -> SIMD3<Double> {
    let sector = hueDegrees / 60
    let secondary = 1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1)
    let encoded: SIMD3<Double>
    switch sector {
    case 0..<1: encoded = SIMD3(1, secondary, 0)
    case 1..<2: encoded = SIMD3(secondary, 1, 0)
    case 2..<3: encoded = SIMD3(0, 1, secondary)
    case 3..<4: encoded = SIMD3(0, secondary, 1)
    case 4..<5: encoded = SIMD3(secondary, 0, 1)
    default: encoded = SIMD3(1, 0, secondary)
    }
    return SIMD3(Self.decode(encoded.x), Self.decode(encoded.y), Self.decode(encoded.z))
  }

  private static func decode(_ value: Double) -> Double {
    value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
  }

  private static func makeImage(_ pixels: [SIMD4<Float>]) -> CIImage {
    let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
    return CIImage(
      bitmapData: data,
      bytesPerRow: pixels.count * MemoryLayout<SIMD4<Float>>.stride,
      size: CGSize(width: pixels.count, height: 1),
      format: .RGBAf,
      colorSpace: nil
    )
  }

  private static func sample(_ image: CIImage, count: Int) -> [SIMD4<Double>] {
    var values = [Float](repeating: 0, count: count * 4)
    values.withUnsafeMutableBytes { bytes in
      context.render(
        image,
        toBitmap: bytes.baseAddress!,
        rowBytes: count * MemoryLayout<SIMD4<Float>>.stride,
        bounds: image.extent,
        format: .RGBAf,
        colorSpace: nil
      )
    }
    return (0..<count).map { index in
      let offset = index * 4
      return SIMD4(
        Double(values[offset]), Double(values[offset + 1]), Double(values[offset + 2]),
        Double(values[offset + 3]))
    }
  }
}

private func expectAngleClose(_ actual: Double, _ expected: Double, tolerance: Double = 0.000_000_1)
{
  let difference = abs(actual - expected)
  #expect(min(difference, Double.pi * 2 - difference) <= tolerance)
}

private func expectClose(_ actual: Double, _ expected: Double, tolerance: Double) {
  #expect(abs(actual - expected) <= tolerance, "Expected \(expected), got \(actual)")
}

private func expectClose(_ actual: SIMD3<Double>, _ expected: SIMD3<Double>, tolerance: Double) {
  for (lhs, rhs) in zip([actual.x, actual.y, actual.z], [expected.x, expected.y, expected.z]) {
    expectClose(lhs, rhs, tolerance: tolerance)
  }
}

private func expectClose(_ actual: SIMD4<Double>, _ expected: SIMD4<Double>, tolerance: Double) {
  for (lhs, rhs) in zip(
    [actual.x, actual.y, actual.z, actual.w], [expected.x, expected.y, expected.z, expected.w])
  {
    expectClose(lhs, rhs, tolerance: tolerance)
  }
}
