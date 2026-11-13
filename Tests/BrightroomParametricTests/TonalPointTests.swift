import BrightroomParametric
import CoreImage
import Foundation
import Testing

/// Public API only. Independent Adobe measurements constrain the approximation;
/// rendering checks cover alpha, neutral colors, lazy graphs and working spaces.
@Suite("Whites and Blacks", .serialized)
struct TonalPointTests {

  private static let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
  private static let context = CIContext(options: [
    .workingColorSpace: space, .workingFormat: CIFormat.RGBAf,
  ])

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
  func intermediateAmountsApproximatePhotographicReferences() throws {
    // Registered photo samples at x=75/275/475/675, y=125/375 of the stride-8
    // arrays in adjustments-001. -22 Whites and +11 Blacks are not fitted knots.
    // Reference hashes and extraction coordinates are retained with the tools.
    // Positive Whites' known adaptive failure is measured by the comparison
    // loop; these passing cases do not claim general Lightroom compatibility.
    let whites = try Self.render(Self.photo, feature: WhitesFeature(amount: -22))
    let blacks = try Self.render(Self.photo, feature: BlacksFeature(amount: 11))
    #expect(Self.difference(whites, Self.photoWhites) < 0.001)
    #expect(Self.difference(blacks, Self.photoBlacks) < 0.001)
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

  @Test
  func lazyGraphsKeepTheirAuthoredParametersAfterLaterEdits() throws {
    let source = Self.image(Self.photo)
    let renderer = FeatureRenderer()
    let first = try renderer.makeImage(from: source, feature: WhitesFeature(amount: -22))
    let expected = Self.pixels(first)
    // Construct new lazy images without rendering them. Their table compilation
    // must not mutate the first image or cross-contaminate the other control.
    let later = try renderer.makeImage(from: source, feature: WhitesFeature(amount: 81))
    let blacks = try renderer.makeImage(from: source, feature: BlacksFeature(amount: 11))
    #expect(Self.difference(Self.pixels(first), expected) == 0)
    #expect(Self.difference(Self.pixels(later), expected) > 0.01)
    #expect(Self.difference(Self.pixels(blacks), Self.photoBlacks) < 0.001)
  }

  @Test
  func positiveWhitesUsesWholeImageStatisticsForPartialRenders() throws {
    func source(background: Float) -> CIImage {
      var pixels = [SIMD4<Float>](repeating: .init(background, background, background, 1), count: 256)
      for index in 120..<136 { pixels[index] = .init(0.18, 0.18, 0.18, 1) }
      return Self.image(pixels)
    }
    let feature = WhitesFeature(amount: 25)
    let dark = try FeatureRenderer().makeImage(from: source(background: 0.01), feature: feature)
    let bright = try FeatureRenderer().makeImage(from: source(background: 0.9), feature: feature)
    let expected = Self.pixels(dark)
    #expect(expected[128].x - Self.pixels(bright)[128].x > 0.005)
    let tile = dark.cropped(to: CGRect(x: 120, y: 0, width: 16, height: 1))
    #expect(Self.difference(Self.pixels(tile), Array(expected[120..<136])) < 0.0001)
    let context = CIContext(options: [
      .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .workingFormat: CIFormat.RGBAf,
    ])
    #expect(Self.difference(Self.pixels(dark, context: context), expected) < 0.0001)
    let gray = [SIMD4<Float>](repeating: .init(0.18, 0.18, 0.18, 1), count: 64)
    let solid = try Self.render(gray, feature: feature)
    let padded = try Self.render(gray + Array(repeating: .zero, count: 64), feature: feature)
    #expect(Self.difference(solid, Array(padded.prefix(64))) < 0.0001)
    #expect(padded.suffix(64).allSatisfy { $0 == .zero })
  }

  @Test
  func positiveWhitesFollowsMeasuredGrayAcrossTheSlider() throws {
    // The four registered Lightroom exports use the same 50% encoded gray
    // field. Its unadjusted linear P3 value is 0.21404.
    let gray = SIMD4<Float>(0.21404, 0.21404, 0.21404, 1)
    let measured: [(Double, Float, Float)] = [
      (25, 0.2378, 0.003), (50, 0.3265, 0.010), (75, 0.5966, 0.04), (100, 0.9995, 0.04),
    ]
    for (amount, reference, tolerance) in measured {
      let output = try Self.render([gray], feature: WhitesFeature(amount: amount))[0]
      #expect(abs(output.x - reference) < tolerance)
      #expect(abs(output.x - output.y) < 0.00001)
      #expect(abs(output.x - output.z) < 0.00001)
    }
  }

  @Test
  func maximumWhitesMatchesTheMeasuredDarkRamp() throws {
    // A horizontal 0...0.6 encoded-P3 ramp exported at Whites +100 by Lightroom.
    let row = (0..<1024).map { x -> SIMD4<Float> in
      let code = 0.6 * Double(x) / 1023
      let gray = Float(code <= 0.04045 ? code / 12.92 : pow((code + 0.055) / 1.055, 2.4))
      return .init(gray, gray, gray, 1)
    }
    let output = try Self.render(row, feature: WhitesFeature(amount: 100))
    for (x, reference): (Int, Float) in [(255, 0.25614), (511, 0.92106), (767, 1)] {
      #expect(abs(output[x].y - reference) < 0.035)
      #expect(abs(output[x].x - output[x].z) < 0.0001)
    }
  }

  @Test
  func maximumWhitesReachesTheMeasuredWhitePointOnDarkGrayFields() throws {
    // Each constant field is a separate Lightroom export from the same encoded-P3 chart series.
    for (input, reference): (Float, Float) in [(0.01002283, 0.99402), (0.05087609, 0.99819)] {
      let gray = SIMD4<Float>(input, input, input, 1)
      let value = try Self.render([gray], feature: WhitesFeature(amount: 100))[0]
      #expect(abs(value.x - reference) < 0.003)
      #expect(abs(value.x - value.z) < 0.0001)
    }
    let black = SIMD4<Float>(0, 0, 0, 1)
    #expect(try Self.render([black], feature: WhitesFeature(amount: 100))[0] == black)
  }

  @Test
  func strongWhitesMatchesTheMeasuredDarkGrayField() throws {
    let gray = SIMD4<Float>(0.010024, 0.010024, 0.010024, 1)
    let value = try Self.render([gray], feature: WhitesFeature(amount: 75))[0]
    // Lightroom Whites +75 maps a uniform 10% Display-P3 code to 0.09916 in linear light.
    #expect(abs(value.y - 0.09916) < 0.001)
    #expect(abs(value.x - value.z) < 0.0001)
  }

  @Test
  func strongWhitesMatchesTheMeasuredFieldInAnEightBitExport() throws {
    let input = Self.image([SIMD4<Float>(0.21404, 0.21404, 0.21404, 1)])
    let result = try ExportRenderer().render(from: input, feature: WhitesFeature(amount: 75),
      options: .init(outputFormat: .RGBA8, outputColorSpace: CGColorSpace(name: CGColorSpace.displayP3)!))
    let image = try result.cgImage
    #expect(image.bitsPerComponent == 8)
    // Decode the 8-bit Display-P3 output before comparing with Lightroom's linear value.
    let pixel = Self.pixels(CIImage(cgImage: image))[0]
    #expect(abs(pixel.y - 0.5966) < 0.005)
    #expect(abs(pixel.x - pixel.z) < 0.001)
  }

  @Test
  func whitesResolvesDifferentResponsesForTheSameRampLevels() throws {
    // The two Adobe exports contain the same 1,024 gray levels in different orders.
    let ramp = (0..<1024).map { index -> SIMD4<Float> in
      let code = Double(index) / 1023
      let gray = Float(code <= 0.04045 ? code / 12.92 : pow((code + 0.055) / 1.055, 2.4))
      return .init(gray, gray, gray, 1)
    }
    let permuted = ramp.indices.map { ramp[($0 * 619 + 17) % ramp.count] }
    let feature = WhitesFeature(amount: 25)
    let smooth = try Self.render(ramp, feature: feature)
    let striped = try Self.render(permuted, feature: feature)
    // Positions 767 and 74 have identical input gray and differ by 0.029 in Lightroom.
    #expect(abs(smooth[767].y - 0.55454) < 0.008)
    #expect(abs(striped[74].y - 0.58348) < 0.008)
  }

  @Test
  func strongWhitesMatchesGrayAndColorOnTheHeldOutSurroundLayout() throws {
    // Recreate the 16-bit Display-P3 chart. Lightroom rendered identical ramps over
    // two background levels. This layout was held out of the calibration resource.
    func linear(_ code: Double) -> Float {
      Float(code <= 0.04045 ? code / 12.92 : pow((code + 0.055) / 1.055, 2.4))
    }
    func field(_ code: Double, _ rect: CGRect) -> CIImage {
      let gray = CGFloat(linear(code))
      return CIImage(color: CIColor(red: gray, green: gray, blue: gray, alpha: 1, colorSpace: Self.space)!)
        .cropped(to: rect)
    }
    var source = field(0.45, CGRect(x: 0, y: 0, width: 1024, height: 512))
    for y in [352, 128] {
      let ramp = Self.image((0..<256).map { index in
        let u = Double(index) / 255
        if y == 352 {
          let gray = linear(0.05 + 0.90 * u)
          return SIMD4<Float>(gray, gray, gray, 1)
        }
        return SIMD4(linear(0.15 + 0.65 * u), linear(0.68 - 0.48 * u), linear(0.25 + 0.30 * sin(.pi * u)), 1)
      }).clampedToExtent()
      for x in [128, 640] {
        let patch = CGRect(x: x, y: y, width: 256, height: 48)
        source = field(x == 128 ? 0.88 : 0.04, patch.insetBy(dx: -48, dy: -48)).composited(over: source)
        source = ramp.transformed(by: .init(translationX: CGFloat(x), y: CGFloat(y)))
          .cropped(to: patch).composited(over: source)
      }
    }
    // Adobe reference at column 96 of the gray ramp and column 48 of the color ramp.
    for (amount, gray, color): (Double, Float, SIMD3<Float>) in [
      (75, 0.36808, .init(0.22233, 0.83824, 0.43477)),
      (100, 0.84323, .init(0.79577, 1.02357, 0.87434)),
    ] {
      let output = try FeatureRenderer().makeImage(from: source, feature: WhitesFeature(amount: amount))
      let measuredGray = Self.pixels(output.cropped(to: CGRect(x: 736, y: 376, width: 1, height: 1)))[0]
      let measuredColor = Self.pixels(output.cropped(to: CGRect(x: 688, y: 152, width: 1, height: 1)))[0]
      #expect(abs(measuredGray.y - gray) < 0.010)
      #expect(Self.difference([measuredColor], [SIMD4(color, 1)]) < 0.012)
    }
    // Lightroom's +50 TIFF reaches white at this gray on the dark surround.
    // Interpolating already-clipped calibration endpoints left it near 0.994.
    let atFifty = try FeatureRenderer().makeImage(from: source, feature: WhitesFeature(amount: 50))
    let brightGray = Self.pixels(atFifty.cropped(to: CGRect(x: 877, y: 376, width: 1, height: 1)))[0]
    #expect(Self.difference([brightGray], [.init(repeating: 1)]) < 0.002)
  }

  @Test
  func strongWhitesMatchesTheLightroomEndpointWhenColoredChannelsApproachWhite() throws {
    let output = try FeatureRenderer().makeImage(from: lightroomColorLattice(), feature: WhitesFeature(amount: 100))
    // The +100 export was held out when calibrating the scene strength from +50.
    // The source chart has two gray ramps above 32³ colors in top-down TIFF coordinates.
    let gray = Self.pixels(output.cropped(to: CGRect(x: 512, y: 255 - 32, width: 1, height: 1)))[0]
    let color = Self.pixels(output.cropped(to: CGRect(x: 652, y: 255 - 200, width: 1, height: 1)))[0]
    #expect(abs(gray.y - 0.40848) < 0.016)
    #expect(Self.difference([color], [SIMD4(0.24547, 0.69823, 0.55794, 1)]) < 0.018)
  }

  @Test
  func maximumWhitesMatchesTheUpperMidtonesOfTheLightroomGrayRamp() throws {
    let output = try FeatureRenderer().makeImage(from: lightroomColorLattice(), feature: WhitesFeature(amount: 100))
    // Mean linear green of 128 ascending gray levels in the independent Lightroom +100 export.
    let band = output.cropped(to: CGRect(x: 512, y: 255 - 32, width: 128, height: 1))
    let samples = Self.pixels(band)
    let mean = samples.reduce(Float.zero) { $0 + $1.y } / Float(samples.count)
    #expect(abs(mean - 0.526071) < 0.006)
  }

  @Test
  func maximumWhitesMatchesGreenInBrightColorsAcrossARedRamp() throws {
    let output = try FeatureRenderer().makeImage(from: lightroomColorLattice(), feature: WhitesFeature(amount: 100))
    // In the independent Lightroom TIFF the 32 red levels share green code 26/31
    // and blue code 22/31. Their mean linear Display-P3 green can exceed one.
    let band = output.cropped(to: CGRect(x: 832, y: 255 - 217, width: 32, height: 1))
    let green = Self.pixels(band).map(\.y)
    let mean = green.reduce(0, +) / Float(green.count)
    #expect(abs(mean - 1.040938) < 0.0008)
  }

  @Test
  func strongWhitesMatchesASmoothColorFieldWithSparseTails() throws {
    // Recreate the colored-plane Lightroom input, including the centered 32³
    // color grid. The outer 1% suggests a long bright tail, the inner 5% does not.
    let source = lightroomColorChart(width: 1024, height: 1024) { x, y, width, height in
      if (256..<768).contains(x), (384..<640).contains(y) {
        let index = (y - 384) / 2 * 256 + (x - 256) / 2
        return SIMD3(Double(index % 32), Double(index / 32 % 32), Double(index / 1024)) / 31
      }
      let u = (Double(x) + 0.5) / Double(width)
      let v = (Double(y) + 0.5) / Double(height)
      return SIMD3(0.12 + 0.72 * u, 0.18 + 0.54 * v, 0.20 + 0.58 * (1 - u) * (0.4 + 0.6 * v))
    }
    // Two independent field positions in the registered ProPhoto RGB exports,
    // decoded into linear Display P3. Core Image uses the opposite vertical origin.
    let samples: [(Double, SIMD4<Float>, SIMD4<Float>, Float)] = [
      (75, .init(0.448805, 0.146476, 0.212463, 1), .init(0.162807, 0.659356, 0.621615, 1), 0.008),
      (100, .init(0.850276, 0.367091, 0.472523, 1), .init(0.497101, 1.002440, 0.964033, 1), 0.012),
    ]
    for (amount, top, bottom, tolerance) in samples {
      let output = try FeatureRenderer().makeImage(from: source, feature: WhitesFeature(amount: amount))
      let upper = output.cropped(to: CGRect(x: 512, y: 1023 - 256, width: 1, height: 1))
      let lower = output.cropped(to: CGRect(x: 256, y: 1023 - 768, width: 1, height: 1))
      #expect(Self.difference(Self.pixels(upper), [top]) < tolerance)
      #expect(Self.difference(Self.pixels(lower), [bottom]) < tolerance)
    }
  }

  @Test
  func strongWhitesMeasuresTheOuterPopulationOfAContinuousColorField() throws {
    // Recreate the 16-bit input to the registered holdout-color-scene +75
    // export. Its three sinusoidal channels produce diffuse bright and dark tails.
    let source = lightroomColorChart { x, y, width, height in
      let horizontal = 2 * Double.pi * Double(x) / Double(width - 1)
      let vertical = 2 * Double.pi * Double(y) / Double(height - 1)
      return SIMD3(0.35 + 0.25 * sin(horizontal), 0.45 + 0.25 * cos(vertical),
        0.30 + 0.20 * sin(horizontal + vertical))
    }
    let output = try FeatureRenderer().makeImage(from: source, feature: WhitesFeature(amount: 75))
    // Adobe RGB values decoded in linear Display P3, at top-down TIFF coordinates.
    let samples: [(Int, Int, SIMD4<Float>, Float)] = [
      (256, 128, .init(0.80846, 0.07061, 0.01094, 1), 0.072),
      (768, 128, .init(-0.01121, 0.05075, 0.53652, 1), 0.0485),
    ]
    for (x, y, measured, tolerance) in samples {
      let pixel = output.cropped(to: CGRect(x: x, y: 255 - y, width: 1, height: 1))
      #expect(Self.difference(Self.pixels(pixel), [measured]) < tolerance)
    }
  }

  @Test
  func increasingWhitesKeepsTheLiftOnASmallBrightRegion() throws {
    // Eight percent of this textured image carries the highlights. The tail
    // estimate previously put +75 below +50 in both the dark and bright strips.
    let source = lightroomColorChart(width: 256, height: 128) { x, y, _, height in
      let code: Double
      if Double(y) / Double(height) >= 0.92 {
        let detail = 0.65 * Double(x % 64) / 63 + 0.175 * (1 - cos(2 * .pi * Double(y) / 45))
        code = 0.90 + 0.10 * detail
      } else {
        code = 0.005 + 0.075 * Double((x * 297 + y * 379) % 103) / 102
      }
      return SIMD3(repeating: (255 * code).rounded() / 255)
    }
    func grayStrips(at amount: Double) throws -> [Float] {
      let output = try FeatureRenderer().makeImage(from: source, feature: WhitesFeature(amount: amount))
      return [0, 127].flatMap { y in
        Self.pixels(output.cropped(to: CGRect(x: 0, y: y, width: 256, height: 1))).map(\.y)
      }
    }
    var previous = try grayStrips(at: 50)
    for amount in [62.5, 75, 100] {
      let current = try grayStrips(at: amount)
      #expect(zip(previous, current).allSatisfy { $1 >= $0 - 0.0001 })
      previous = current
    }
  }

  @Test
  func raisingWhitesPast75PreservesNearWhiteChannelsInHalfFloat() throws {
    let width = 256, height = 128
    let firstHighlightRow = 113
    var pixels = [SIMD4<UInt8>]()
    for y in 0..<height {
      for x in 0..<width {
        let detail = 0.65 * Double(x % 64) / 63 + 0.175 * (1 - cos(2 * .pi * Double(y) / 45))
        let gray = UInt8((255 * (y >= firstHighlightRow ? 0.9 + 0.1 * detail : 0.005 + 0.075 * detail)).rounded())
        pixels.append(.init(gray, gray, gray, 255))
      }
    }
    let source = CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: width * 4,
      size: CGSize(width: width, height: height), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    let half = CIContext(options: [.workingColorSpace: Self.space, .workingFormat: CIFormat.RGBAh])
    let renderer = FeatureRenderer()
    func highlights(at amount: Double) throws -> [SIMD4<Float>] {
      let output = try renderer.makeImage(from: source, feature: WhitesFeature(amount: amount))
      let strip = CGRect(x: 0, y: height - 1 - firstHighlightRow, width: width, height: 1)
      return Self.pixels(output.cropped(to: strip), context: half)
    }
    // Only the upper interval has the extra pass that can quantize an already bright channel.
    let lower = try highlights(at: 75)
    #expect(lower.contains { min($0.x, $0.y, $0.z) > 0.99 })
    for amount in [76.0, 100.0] {
      let upper = try highlights(at: amount)
      let minimumStep = zip(lower, upper).map { start, end in
        min(end.x - start.x, end.y - start.y, end.z - start.z)
      }.min()!
      #expect(minimumStep >= -0.0001)
    }
  }

  @Test
  func coloredWhitesMeasuresTheSameStrengthAtUniformHalfCoverage() throws {
    let source = lightroomColorLattice()
    let translucent = source.applyingFilter("CIColorMatrix", parameters: [
      "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.5),
    ])
    let renderer = FeatureRenderer()
    let whites = WhitesFeature(amount: 75)
    let opaque = try renderer.makeImage(from: source, feature: whites)
    let half = try renderer.makeImage(from: translucent, feature: whites)
    // A strip of colored pixels has the same straight RGB when every sample's
    // coverage, including the samples used for scene metering, is halved.
    let strip = CGRect(x: 640, y: 255 - 200, width: 32, height: 1)
    let expected = Self.pixels(opaque.cropped(to: strip)).map { $0 * 0.5 }
    #expect(Self.difference(Self.pixels(half.cropped(to: strip)), expected) < 0.0003)
  }

  @Test
  func strongWhitesPreservesThePositionOfTheMiddleColorChannel() throws {
    // The Lightroom color grid keeps each middle channel at the same fraction
    // between its two endpoints in linear light. Use colors between grid nodes.
    let input: [SIMD4<Float>] = [
      .init(0.013, 0.231, 0.473, 1), .init(0.921, 0.263, 0.047, 1),
      .init(0.782, 0.427, 0.014, 1), .init(0.048, 0.353, 0.867, 1),
    ]
    for amount in [50.0, 75.0] {
      let output = try Self.render(input, feature: WhitesFeature(amount: amount))
      for (source, result) in zip(input, output) {
        let fraction = (source.y - source.x) / (source.z - source.x)
        let expectedGreen = result.x + (result.z - result.x) * fraction
        #expect(abs(result.y - expectedGreen) < 0.00015)
      }
    }
  }

  @Test
  func strongWhitesKeepsChannelOrderAsBrightColorsReachWhite() throws {
    // Lightroom's ordered color endpoints meet at white on the dark-background
    // chart. The fitted surface is steep here, especially for blue patches.
    let blue = SIMD4<Float>(0.0662, 0.2571, 0.9632, 1)
    var pixels = [SIMD4<Float>](repeating: .init(0.01, 0.01, 0.01, 1), count: 512)
    pixels[256] = blue
    let result = try Self.render(pixels, feature: WhitesFeature(amount: 75))[256]
    #expect(result.x <= result.y + 0.00001)
    #expect(result.y <= result.z + 0.00001)
  }

  @Test
  func positiveWhitesNeedsAFiniteAreaToMeasure() {
    let unbounded = CIImage(color: .white)
    #expect(throws: FeatureEvaluationError.self) {
      try FeatureRenderer().makeImage(from: unbounded, feature: WhitesFeature(amount: 75))
    }
  }

  @Test
  func intermediateWhitesMovesBetweenItsMeasuredEndpoints() throws {
    // This bright ramp showed a reversal around +65 when both endpoints of
    // the transition moved with the slider.
    let ramp = (0..<256).map { index -> SIMD4<Float> in
      let code = 0.4 + 0.6 * Float(index) / 255
      let linear = pow((code + 0.055) / 1.055, 2.4)
      return .init(linear, linear, linear, 1)
    }
    let lower = try Self.render(ramp, feature: WhitesFeature(amount: 50))
    let upper = try Self.render(ramp, feature: WhitesFeature(amount: 75))
    let middle = try Self.render(ramp, feature: WhitesFeature(amount: 62.5))
    #expect(Self.difference(middle, zip(lower, upper).map { ($0 + $1) * 0.5 }) < 0.0001)
  }

  @Test
  func strongWhitesPreservesCoverageAndUsesOneDistributionForEveryTile() throws {
    let opaque = SIMD4<Float>(0.06, 0.18, 0.42, 1)
    let row = [opaque, opaque * 0.5, .zero, SIMD4(-0.3, 0.2, 1.4, 1)]
    let source = Self.image(row)
    for amount: Double in [63, 75, 100] {
      let graph = try FeatureRenderer().makeImage(from: source, feature: WhitesFeature(amount: amount))
      let full = Self.pixels(graph)
      let tile = graph.cropped(to: CGRect(x: 1, y: 0, width: 2, height: 1))
      #expect(Self.difference(Self.pixels(tile), Array(full[1...2])) < 0.0001)
      #expect(Self.difference([full[0] * 0.5], [full[1]]) < 0.0001)
      #expect(full[2] == .zero)
      #expect(full[3].w == 1 && full[3].z > 1)
    }
  }

  @Test
  func contextAndPartialRenderPreserveColorsAndExtent() throws {
    let source = Self.image(Self.photo).transformed(by: .init(translationX: 17, y: -4))
    let effects = [AnyImageEffect(WhitesFeature(amount: -22)), AnyImageEffect(BlacksFeature(amount: 11))]
    let image = try FeatureRenderer().makeImage(from: source, feature: effects)
    // The public renderer normalizes the chain entry to zero origin first.
    #expect(image.extent == CGRect(origin: .zero, size: source.extent.size))
    let expected = Self.pixels(image)
    for name in [CGColorSpace.extendedLinearSRGB, CGColorSpace.sRGB] {
      let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: name)!, .workingFormat: CIFormat.RGBAf,
      ])
      #expect(Self.difference(expected, Self.pixels(image, context: context)) < 0.0001)
    }
    let tile = image.cropped(to: CGRect(x: 2, y: 0, width: 3, height: 1))
    #expect(Self.difference(Self.pixels(tile), Array(expected[2..<5])) < 0.00001)
  }

  private static func image(_ pixels: [SIMD4<Float>]) -> CIImage {
    CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) },
      bytesPerRow: pixels.count * 16, size: CGSize(width: pixels.count, height: 1),
      format: .RGBAf, colorSpace: space)
  }

  private static func render(_ input: [SIMD4<Float>], feature: some Feature) throws -> [SIMD4<Float>] {
    pixels(try FeatureRenderer().makeImage(from: image(input), feature: feature))
  }

  private static func pixels(_ image: CIImage, context: CIContext = context) -> [SIMD4<Float>] {
    var output = [SIMD4<Float>](repeating: .init(repeating: .nan), count: Int(image.extent.width))
    context.render(image, toBitmap: &output, rowBytes: output.count * 16,
      bounds: image.extent, format: .RGBAf, colorSpace: space)
    #expect(output.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite })
    return output
  }

  private static func difference(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Float {
    #expect(a.count == b.count)
    return zip(a, b).reduce(0) { maximum, pair in
      let delta = pair.0 - pair.1
      return max(maximum, abs(delta.x), abs(delta.y), abs(delta.z), abs(delta.w))
    }
  }

  private static let photo: [SIMD4<Float>] = [
    SIMD4(0.168785915, 0.212519795, 0.323969722, 1),
    SIMD4(0.155274287, 0.010132885, 0.010359766, 1),
    SIMD4(0.234290227, 0.285035133, 0.419653952, 1),
    SIMD4(0.133989871, 0.178978935, 0.299629390, 1),
    SIMD4(0.029667741, 0.025820831, 0.038021382, 1),
    SIMD4(0.061513353, 0.050899215, 0.068768226, 1),
    SIMD4(0.057379875, 0.051199835, 0.066016629, 1),
    SIMD4(0.034257550, 0.030629998, 0.039381661, 1),
  ]

  private static let photoWhites: [SIMD4<Float>] = [
    SIMD4(0.156352058, 0.198342875, 0.305328906, 1),
    SIMD4(0.151595697, 0.009885116, 0.010110084, 1),
    SIMD4(0.215604320, 0.264802068, 0.395262599, 1),
    SIMD4(0.124869265, 0.167824283, 0.282981485, 1),
    SIMD4(0.028986907, 0.025208985, 0.037138849, 1),
    SIMD4(0.059491444, 0.049226355, 0.066529207, 1),
    SIMD4(0.055492405, 0.049537677, 0.063893728, 1),
    SIMD4(0.033402245, 0.029866053, 0.038409375, 1),
  ]

  private static let photoBlacks: [SIMD4<Float>] = [
    SIMD4(0.175532550, 0.220115781, 0.333684593, 1),
    SIMD4(0.166498423, 0.010913559, 0.011150998, 1),
    SIMD4(0.241160825, 0.292434871, 0.428478926, 1),
    SIMD4(0.139800638, 0.185996771, 0.309801400, 1),
    SIMD4(0.032047562, 0.027886635, 0.041032963, 1),
    SIMD4(0.065635473, 0.054354791, 0.073342852, 1),
    SIMD4(0.061245568, 0.054696277, 0.070446625, 1),
    SIMD4(0.036919054, 0.033049595, 0.042429641, 1),
  ]
}
