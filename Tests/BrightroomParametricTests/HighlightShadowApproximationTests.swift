import BrightroomParametric
import CoreImage
import Foundation
import Testing

/// Public API only. Spatial invariants, real Adobe samples, and rendering
/// behavior constrain the approximation without claiming complete parity.
@Suite("Spatial Highlights and Shadows", .serialized)
struct HighlightShadowApproximationTests {

  private static let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
  private static let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf])

  @Test
  func neutralAndLegacyRecipesRemainAvailable() throws {
    let source = Self.scene(width: 64, height: 32)
    for effect in [AnyImageEffect(HighlightsFeature(value: 0, algorithm: .lightroomApproximation)),
      AnyImageEffect(ShadowsFeature(value: .nan, algorithm: .lightroomApproximation))] {
      #expect(try FeatureRenderer().makeImage(from: source, feature: effect) === source)
    }
    let makeHighlights = HighlightsFeature.init(value:)
    let makeShadows = ShadowsFeature.init(value:)
    let highlight = try Self.render(source, feature: makeHighlights(0.37))
    let shadow = try Self.render(source, feature: makeShadows(-0.32))
    #expect(Self.error(highlight, Self.pixels(source.applyingFilter("CIHighlightShadowAdjust",
      parameters: ["inputHighlightAmount": 0.63]))) < 0.00001)
    #expect(Self.error(shadow, Self.pixels(source.applyingFilter("CIHighlightShadowAdjust",
      parameters: ["inputShadowAmount": -0.32]))) < 0.00001)
    #expect(HighlightsFeature(value: 0.3) != HighlightsFeature(value: 0.3, algorithm: .lightroomApproximation))
    #expect(Self.error(
      try Self.render(source, feature: HighlightsFeature(value: .greatestFiniteMagnitude, algorithm: .lightroomApproximation)),
      try Self.render(source, feature: HighlightsFeature(value: 1, algorithm: .lightroomApproximation))) == 0)
  }

  @Test
  func weakPositiveShadowsDependOnTheInputTone() throws {
    let width = 256
    let row = (0..<width).map { column -> SIMD4<Float> in
      let code = Float(column) / Float(width - 1)
      let linear = code <= 0.04045 ? code / 12.92 : pow((code + 0.055) / 1.055, 2.4)
      return SIMD4(linear, linear, linear, 1)
    }
    let source = Self.image(Array(repeating: row, count: 64).flatMap { $0 }, width: width)
    let base = Self.pixels(source)
    let plus50 = try Self.render(source, feature: ShadowsFeature(lightroomAmount: 50))
    func encode(_ value: Float) -> Float {
      value <= 0.0031308 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055
    }
    // Adobe ramp at encoded 1/8 and 5/8. Compare fractions of the local +50
    // response, so a change in the neighborhood model cannot mask a slider regression.
    for (amount, dark, light): (Double, Float, Float) in [(10, 0.1614, 0.2016), (25, 0.4395, 0.5025)] {
      let weak = try Self.render(source, feature: ShadowsFeature(lightroomAmount: amount))
      for (x, expected) in [(32, dark), (160, light)] {
        let index = 32 * width + x
        let start = encode(base[index].x)
        let span = encode(plus50[index].x) - start
        #expect(span > 0.001)
        #expect(abs((encode(weak[index].x) - start) / span - expected) < 0.006)
      }
    }
  }

  @Test
  func weakNegativeHighlightsFollowTheMeasuredToneDependentResponse() throws {
    let width = 1024
    let source = Self.calibrationRamp()
    let neutral = Self.pixels(source)
    let end = try Self.render(source, feature: HighlightsFeature(lightroomAmount: -50))
    // ProPhoto TIFFs decoded into linear P3. Near white, −10 produces only
    // 18% of the −50 change, while the midtone receives over 21%.
    for (amount, middle, bright, nearWhite): (Double, Float, Float, Float) in [
      (-10, 0.213, 0.196, 0.1804), (-25, 0.520, 0.495, 0.4721),
    ] {
      let output = try Self.render(source, feature: HighlightsFeature(lightroomAmount: amount))
      for (x, expected, tolerance): (Int, Float, Float) in [(512, middle, 0.025), (895, bright, 0.012), (976, nearWhite, 0.009)] {
        let i = 128 * width + x
        let span = neutral[i].x - end[i].x
        #expect(span > 0.01)
        #expect(abs((neutral[i].x - output[i].x) / span - expected) < tolerance)
      }
    }
  }

  @Test
  func weakNegativeHighlightsFollowTheMeasuredFractionAcrossColors() throws {
    let source = lightroomColorLattice()
    let neutral = try Self.exportedPixels(source, feature: HighlightsFeature(lightroomAmount: 0))
    let weak = try Self.exportedPixels(source, feature: HighlightsFeature(lightroomAmount: -25))
    let half = try Self.exportedPixels(source, feature: HighlightsFeature(lightroomAmount: -50))
    // In each Adobe export, group the 32³ colors by their unique brightest
    // channel and its encoded level (1…10, 11…20 or 21…31). Sum the change
    // before taking the ratio so near-constant patches cannot dominate it.
    let reference = [
      0.516920, 0.516974, 0.498069, 0.518213, 0.516382, 0.492051,
      0.516306, 0.512937, 0.491136,
    ]
    var loss = [SIMD2<Double>](repeating: .zero, count: reference.count)
    for blue in 0..<32 {
      for green in 0..<32 {
        for red in 0..<32 {
          let channel: Int
          if red > max(green, blue) { channel = 0 }
          else if green > max(red, blue) { channel = 1 }
          else if blue > max(red, green) { channel = 2 }
          else { continue }
          let peak = max(red, max(green, blue))
          let band = peak <= 10 ? 0 : (peak <= 20 ? 1 : 2)
          for row in 0..<4 {
            let pixel = (128 + blue * 4 + row) * 1024 + green * 32 + red
            loss[channel * 3 + band] += .init(Double(neutral[pixel][channel] - weak[pixel][channel]),
              Double(neutral[pixel][channel] - half[pixel][channel]))
          }
        }
      }
    }
    var error = 0.0
    for (pair, expected) in zip(loss, reference) {
      try #require(pair.y > 0)
      error += abs(pair.x / pair.y - expected)
    }
    #expect(error / Double(reference.count) < 0.125)
  }

  @Test
  func negativeHighlightsRetainTheBrightEndOfALimitedRange() throws {
    let image = lightroomColorChart { x, _, width, _ in
      .init(repeating: 0.6 * Double(x) / Double(width - 1))
    }
    let source = try Self.exportedPixels(image, feature: HighlightsFeature(lightroomAmount: 0))
    let adjusted = try Self.exportedPixels(image, feature: HighlightsFeature(lightroomAmount: -50))
    // The brightest 64 columns of the registered 0…0.6 gray ramp lose
    // 0.065091 in linear P3 green in the paired Lightroom exports.
    var loss = 0.0
    for row in 112..<144 {
      for column in 960..<1024 {
        let index = row * 1024 + column
        loss += Double(source[index].y - adjusted[index].y)
      }
    }
    #expect(abs(loss / (32 * 64) - 0.065091) < 0.013)
  }

  @Test
  func strongNegativeHighlightsRetainTheMeasuredNearWhiteShoulder() throws {
    let pixels = try Self.exportedPixels(Self.calibrationRamp(), feature: HighlightsFeature(lightroomAmount: -100))
    // Means from the separate Adobe −100 TIFF at input linear gray 0.95…0.99
    // and 0.99…1. All 256 rows contribute, including both image boundaries.
    func meanGreen(_ columns: Range<Int>) -> Double {
      var sum = 0.0
      for row in 0..<256 {
        for x in columns { sum += Double(pixels[row * 1024 + x].y) }
      }
      return sum / Double(256 * columns.count)
    }
    let bright = meanGreen(1001..<1019)
    let nearWhite = meanGreen(1019..<1024)
    #expect(abs(bright - 0.739103) < 0.075)
    #expect(abs(nearWhite - 0.827181) < 0.075)
    // The previous curve flattened these bands to a difference of 0.026.
    #expect(abs((nearWhite - bright) - (0.827181 - 0.739103)) < 0.03)
  }

  @Test
  func strongNegativeShadowsFollowTheIndependentMinus100Export() throws {
    let source = Self.calibrationRamp()
    let neutral = Self.pixels(source)
    let half = try Self.render(source, feature: ShadowsFeature(lightroomAmount: -50))
    let full = try Self.render(source, feature: ShadowsFeature(lightroomAmount: -100))
    // −100 was excluded from the strength fit. The Adobe −100 / −50 ratio
    // rises from 1.48 in the dark quarter of the ramp to nearly two at 7/8.
    for (x, expected): (Int, Float) in [(256, 1.4832), (512, 1.8325), (895, 2.0089)] {
      let i = 128 * 1024 + x
      let span = neutral[i].x - half[i].x
      #expect(span > 0.005)
      #expect(abs((neutral[i].x - full[i].x) / span - expected) < 0.045)
    }
  }

  /// The 1024-by-256 encoded-gray source used for the registered Lightroom slider sweeps.
  private static func calibrationRamp() -> CIImage {
    let row = (0..<1024).map { x -> SIMD4<Float> in
      let code = Float(x) / 1023
      let linear = code <= 0.04045 ? code / 12.92 : pow((code + 0.055) / 1.055, 2.4)
      return SIMD4(linear, linear, linear, 1)
    }
    return image(Array(repeating: row, count: 256).flatMap { $0 }, width: 1024)
  }

  @Test
  func uniformFieldsStayUnchangedInBothWorkingFormats() throws {
    for format in [CIFormat.RGBAf, .RGBAh] {
      let context = CIContext(options: [.workingColorSpace: Self.space, .workingFormat: format])
      for gray: Float in [0.01, 0.05, 0.18, 0.75] {
        let source = Self.image(Array(repeating: SIMD4(gray, gray, gray, 1), count: 32 * 16), width: 32)
        let expected = Self.pixels(source, context: context)
        for effect in Self.effects {
          let image = try FeatureRenderer().makeImage(from: source, feature: effect)
          #expect(Self.error(Self.pixels(image, context: context), expected) < 0.0001)
        }
      }
    }
  }

  @Test
  func surroundChangesTheSameCentralPixels() throws {
    func scene(background: Float) -> CIImage {
      var pixels = [SIMD4<Float>](repeating: .init(background, background, background, 1), count: 256 * 64)
      for y in 28..<36 {
        for x in 0..<256 {
          let value = Float(x) / 255
          pixels[y * 256 + x] = .init(value, value, value, 1)
        }
      }
      return Self.image(pixels, width: 256)
    }
    let feature = HighlightsFeature(lightroomAmount: -50)
    let dark = try Self.render(scene(background: 0.002), feature: feature)
    let light = try Self.render(scene(background: 0.95), feature: feature)
    #expect(abs(dark[32 * 256 + 128].x - light[32 * 256 + 128].x) > 0.02)
  }

  @Test
  func negativeShadowsRetainTheMeasuredMidtonesAtABrightBoundary() throws {
    let image = lightroomColorChart { x, y, width, _ in
      .init(repeating: (112..<144).contains(y) ? Double(x) / Double(width - 1) : 0.98)
    }
    let neutral = try Self.exportedPixels(image, feature: ShadowsFeature(lightroomAmount: 0))
    let adjusted = try Self.exportedPixels(image, feature: ShadowsFeature(lightroomAmount: -50))
    // Mean linear-P3 green loss over 512 ramp pixels beside the 98% gray field,
    // from the two registered 16-bit Lightroom exports of adaptive-light.
    var loss = 0.0
    for offset in 0..<4 {
      for row in [112 + offset, 143 - offset] {
        for column in 448..<512 {
          let index = row * 1024 + column
          loss += Double(neutral[index].y - adjusted[index].y)
        }
      }
    }
    #expect(abs(loss / 512 - 0.068742) < 0.0095)
  }

  @Test
  func negativeShadowsRetainLightOnTheDarkSideOfABrightEdge() throws {
    // The registered adaptive-near-light input has a 32-row ramp between
    // two bright strips. The larger dark surround also contributes to the response.
    let image = lightroomColorChart { x, y, width, _ in
      if (112..<144).contains(y) { return .init(repeating: Double(x) / Double(width - 1)) }
      let bright = (56..<112).contains(y) || (144..<200).contains(y)
      return .init(repeating: bright ? 0.98 : 0.02)
    }
    let neutral = try Self.exportedPixels(image, feature: ShadowsFeature(lightroomAmount: 0))
    let shadows = try Self.exportedPixels(image, feature: ShadowsFeature(lightroomAmount: -50))
    // Mean loss in the same 64 dark ramp columns. Each pair of strips lies
    // just inside the two edges, at the indicated distance from bright gray.
    for (distance, expected) in [(0, 0.005848), (2, 0.007053)] {
      var loss = 0.0
      for offset in distance..<(distance + 2) {
        for row in [112 + offset, 143 - offset] {
          for column in 160..<224 {
            let index = row * 1024 + column
            loss += Double(neutral[index].y - shadows[index].y)
          }
        }
      }
      #expect(abs(loss / (4 * 64) - expected) < 0.00055)
    }
  }

  @Test
  func negativeHighlightsFollowTheMeasuredLossInADarkSurround() throws {
    let image = lightroomColorChart { x, y, width, _ in
      .init(repeating: (112..<144).contains(y) ? Double(x) / Double(width - 1) : 0.02)
    }
    let neutral = try Self.exportedPixels(image, feature: HighlightsFeature(lightroomAmount: 0))
    let adjusted = try Self.exportedPixels(image, feature: HighlightsFeature(lightroomAmount: -50))
    // In adaptive-dark, this strip includes the ramp and its adjoining 2% gray surround.
    // The paired 16-bit Adobe exports give a mean green-channel loss of 0.279153.
    var loss = 0.0
    for y in 96..<160 {
      for x in 768..<896 {
        let index = y * 1024 + x
        loss += Double(neutral[index].y - adjusted[index].y)
      }
    }
    #expect(abs(loss / (64 * 128) - 0.279153) < 0.005)
  }

  @Test
  func negativeHighlightsRetainTheMeasuredMidtonesBetweenDarkStrips() throws {
    let image = lightroomColorChart { x, y, width, _ in
      if (112..<144).contains(y) { return .init(repeating: Double(x) / Double(width - 1)) }
      let dark = (56..<112).contains(y) || (144..<200).contains(y)
      return .init(repeating: dark ? 0.02 : 0.98)
    }
    let neutral = try Self.exportedPixels(image, feature: HighlightsFeature(lightroomAmount: 0))
    let adjusted = try Self.exportedPixels(image, feature: HighlightsFeature(lightroomAmount: -50))
    // On the adaptive-near-dark chart both extremes are common and the intervening
    // tones occupy only the ramp. Compare all 8,192 upper-mid gray pixels in that strip.
    var loss = 0.0
    for row in 112..<144 {
      for column in 512..<768 {
        let index = row * 1024 + column
        loss += Double(neutral[index].y - adjusted[index].y)
      }
    }
    #expect(abs(loss / (32 * 256) - 0.268881) < 0.008)
  }

  @Test
  func negativeHighlightsRetainTheCommonMidtonesOfAGrayScene() throws {
    // Rebuild scene-08, a gray chart withheld from the fit. Its broad range
    // of midtones carries a much smaller loss in Lightroom than its highlights.
    let source = lightroomColorChart(width: 512, height: 384) { x, y, width, height in
      let u = Double(x) / Double(width - 1)
      let v = Double(y) / Double(height - 1)
      let phase = 8.0 * 0.31
      let wave = 0.52 * sin(2 * .pi * u + phase) + 0.31 * cos(2 * .pi * v + 0.7 * phase)
        + 0.17 * sin(2 * .pi * (u + v) - phase)
      let texture = 0.025 * sin(2 * .pi * 53 * u) * cos(2 * .pi * 37 * v)
      return .init(repeating: 0.50 + 0.15 * wave + texture)
    }
    let neutral = try Self.exportedPixels(source, feature: HighlightsFeature(lightroomAmount: 0))
    let adjusted = try Self.exportedPixels(source, feature: HighlightsFeature(lightroomAmount: -50))
    var loss = 0.0
    var count = 0
    // Select encoded P3 tones from 0.40 to 0.50 using their decoded linear bounds.
    for index in neutral.indices where (0.13286832..<0.21404114).contains(neutral[index].y) {
      loss += Double(neutral[index].y - adjusted[index].y)
      count += 1
    }
    try #require(count > 98_000)
    // Mean linear green loss over the same band in the paired 16-bit Lightroom TIFFs.
    #expect(abs(loss / Double(count) - 0.000829) < 0.0045)
  }

  @Test
  func negativeHighlightsFollowTheBrightEndOfARampInALightSurround() throws {
    let image = lightroomColorChart { x, y, width, _ in
      if (112..<144).contains(y) { return .init(repeating: Double(x) / Double(width - 1)) }
      let bright = (56..<112).contains(y) || (144..<200).contains(y)
      return .init(repeating: bright ? 0.98 : 0.02)
    }
    let neutral = try Self.exportedPixels(image, feature: HighlightsFeature(lightroomAmount: 0))
    let adjusted = try Self.exportedPixels(image, feature: HighlightsFeature(lightroomAmount: -50))
    // In the paired 16-bit Adobe exports of adaptive-near-light, the bright end
    // of the ramp and the adjoining bright strip lose 0.463848 green on average.
    var loss = 0.0
    for row in 64..<128 {
      for column in 896..<1024 {
        let index = row * 1024 + column
        loss += Double(neutral[index].y - adjusted[index].y)
      }
    }
    #expect(abs(loss / (64 * 128) - 0.463848) < 0.002)
  }

  @Test
  func negativeHighlightsMatchTheMeasuredLossInBrightGreens() throws {
    let source = lightroomColorLattice()
    let neutral = try Self.exportedPixels(source, feature: HighlightsFeature(lightroomAmount: 0))
    let adjusted = try Self.exportedPixels(source, feature: HighlightsFeature(lightroomAmount: -50))
    // These 8,192 pixels span the top eight green codes and the lower half
    // of red and blue in the paired 16-bit ProPhoto exports.
    var loss = SIMD2<Double>.zero
    for row in 128..<(128 + 16 * 4) {
      for green in 24..<32 {
        for red in 0..<16 {
          let index = row * 1024 + green * 32 + red
          let change = neutral[index] - adjusted[index]
          loss += SIMD2(Double(change.y), Double(change.z))
        }
      }
    }
    loss /= 8192
    #expect(abs(loss.x - 0.153402) < 0.028)
    #expect(abs(loss.y - 0.039379) < 0.009)
  }

  @Test
  func negativeHighlightsFollowTheMeasuredRedLossInSaturatedMidtones() throws {
    let image = lightroomColorLattice()
    let neutral = try Self.exportedPixels(image, feature: HighlightsFeature(lightroomAmount: 0))
    let adjusted = try Self.exportedPixels(image, feature: HighlightsFeature(lightroomAmount: -50))
    var loss = 0.0
    var count = 0
    for index in (128 * 1024)..<neutral.count {
      let pixel = neutral[index]
      let y = 0.22897456 * pixel.x + 0.69173852 * pixel.y + 0.07928692 * pixel.z
      guard (0.25..<0.5).contains(y), pixel.x > max(pixel.y, pixel.z),
        pixel.x - min(pixel.y, pixel.z) >= 0.5 else { continue }
      loss += Double(pixel.x - adjusted[index].x)
      count += 1
    }
    // The same source-color selection in Lightroom's neutral/−50 lattice pair contains 9,680 pixels.
    try #require(count > 9_400)
    #expect(abs(loss / Double(count) - 0.098484) < 0.0069)
  }

  @Test
  func negativeLightMatchesTheBrightSurroundOfAGrayRamp() throws {
    // The 32-row gray ramp in adaptive-light is surrounded by 98% encoded gray.
    let image = lightroomColorChart { x, y, width, _ in
      .init(repeating: (112..<144).contains(y) ? Double(x) / Double(width - 1) : 0.98)
    }
    // Each 16-row strip touches the ramp from outside. The Lightroom means in
    // its four quarters match above and below the ramp to six decimal places.
    func meanBandError(_ pixels: [SIMD4<Float>], reference: [Double]) -> Double {
      var error = 0.0
      for row in [96, 144] {
        for (quarter, expected) in reference.enumerated() {
          var sum = 0.0
          for y in row..<(row + 16) {
            let start = y * 1024 + quarter * 256
            sum += pixels[start..<(start + 256)].reduce(0.0) { $0 + Double($1.y) }
          }
          error += abs(sum / (16 * 256) - expected)
        }
      }
      return error / 8
    }
    let highlights = try Self.exportedPixels(image, feature: HighlightsFeature(lightroomAmount: -50))
    let shadows = try Self.exportedPixels(image, feature: ShadowsFeature(lightroomAmount: -50))
    #expect(meanBandError(highlights, reference: [0.706300, 0.704842, 0.713250, 0.725174]) < 0.021)
    #expect(meanBandError(shadows, reference: Array(repeating: 0.944192, count: 4)) < 0.0075)

    // In the ramp itself, Adobe's −50 output averages 0.096034 over this midtone band.
    var midtoneSum = 0.0
    for row in 112..<144 {
      let start = row * 1024 + 384
      midtoneSum += shadows[start..<(start + 128)].reduce(0.0) { $0 + Double($1.y) }
    }
    #expect(abs(midtoneSum / (32 * 128) - 0.096034) < 0.013)

    // The right half of the bright field has the same input code everywhere.
    // Adobe's −50 mean at the outer border exceeds its mean next to the ramp by 0.005482.
    func rightHalfMean(firstRow: Int) -> Double {
      var sum = 0.0
      for row in [firstRow, 256 - firstRow - 16] {
        for y in row..<(row + 16) {
          let start = y * 1024 + 512
          sum += highlights[start..<(start + 512)].reduce(0.0) { $0 + Double($1.y) }
        }
      }
      return sum / (2 * 16 * 512)
    }
    let distanceResponse = rightHalfMean(firstRow: 0) - rightHalfMean(firstRow: 96)
    #expect(abs(distanceResponse - 0.005482) < 0.010, "Far minus near mean was \(distanceResponse)")
  }

  @Test
  func independentColorSceneMatchesRetainedAdobeSamples() throws {
    let source = lightroomColorChart(rgbAt: Self.sceneColor)
    let coordinates = [(128, 128), (128, 384), (128, 640), (128, 896), (64, 256), (192, 768)]
    // `adaptive-holdout-002`, TIFF16 ProPhoto -> linear P3. This color scene
    // and these amounts are excluded from the synthetic grayscale fit.
    let expected: [SIMD4<Float>] = [
      .init(0.25204915, 0.03495590, 0.02243831, 1),
      .init(0.25146353, 0.03497626, 0.02343016, 1),
      .init(0.02683415, 0.03515353, 0.17501107, 1),
      .init(0.02726154, 0.03512031, 0.17083648, 1),
      .init(0.31966674, 0.17002513, 0.07277375, 1),
      .init(0.01038251, 0.17870161, 0.07277743, 1),
    ]
    let actual = try Self.exportedPixels(source, feature: ShadowsFeature(lightroomAmount: 17))
    let samples = coordinates.map { actual[$0.0 * 1024 + $0.1] }
    #expect(Self.error(samples, expected) < 0.013)
  }

  @Test
  func negativeHighlightsKeepTheMeasuredMeanOfTheReservedColorScene() throws {
    // Whole-frame mean of the independent −37 TIFF decoded into linear Display P3.
    let pixels = try Self.exportedPixels(lightroomColorChart(rgbAt: Self.sceneColor), feature: HighlightsFeature(lightroomAmount: -37))
    let sum = pixels.reduce(SIMD3<Double>.zero) { $0 + SIMD3(Double($1.x), Double($1.y), Double($1.z)) }
    let mean = sum / Double(pixels.count)
    let error = mean - SIMD3(0.1255578, 0.1933551, 0.0876391)
    #expect(max(abs(error.x), abs(error.y), abs(error.z)) < 0.00545)
  }

  @Test
  func negativeShadowsKeepTheMeasuredUpperMidtonesOfTheRamp() throws {
    // The third quarter of the neutral ramp in the −100 ProPhoto export.
    // Averaging the full strip includes both its darker and lighter surroundings.
    let pixels = try Self.exportedPixels(Self.calibrationRamp(), feature: ShadowsFeature(lightroomAmount: -100))
    var green = 0.0
    for row in 0..<256 {
      for column in 512..<768 { green += Double(pixels[row * 1024 + column].y) }
    }
    #expect(abs(green / (256 * 256) - 0.2876534) < 0.0045)
  }

  @Test
  func positiveShadowsLiftTheRedChannelInDarkSaturatedPatches() throws {
    let source = lightroomColorLattice()
    let neutral = try Self.exportedPixels(source, feature: ShadowsFeature(lightroomAmount: 0))
    // Mean red-channel lift in two registered 16-bit ProPhoto exports.
    // The four rows per color also sample the local variation across each patch.
    for (amount, expected, tolerance): (Double, Double, Double) in [(30, 0.10020, 0.034), (100, 0.42520, 0.16)] {
      let lifted = try Self.exportedPixels(source, feature: ShadowsFeature(lightroomAmount: amount))
      var lift = 0.0
      var count = 0
      for row in 128..<(128 + 7 * 4) {
        for green in 0..<7 {
          for red in 12...21 {
            let index = row * 1024 + green * 32 + red
            lift += Double(lifted[index].x - neutral[index].x)
            count += 1
          }
        }
      }
      #expect(abs(lift / Double(count) - expected) < tolerance)
    }
  }

  @Test
  func positiveShadowsLiftMeasuredRedMidtonesAtBothStrengths() throws {
    let source = lightroomColorLattice()
    let neutral = try Self.exportedPixels(source, feature: ShadowsFeature(lightroomAmount: 0))
    // Mean red lift across these 720 colors in the paired +30 and +100 Lightroom exports.
    for (amount, expected, tolerance): (Double, Double, Double) in [(30, 0.08209, 0.024), (100, 0.29823, 0.085)] {
      let result = try Self.exportedPixels(source, feature: ShadowsFeature(lightroomAmount: amount))
      var sum = 0.0
      for y in 128..<(128 + 9 * 4) {
        for green in 6..<14 {
          for red in 16..<26 {
            let index = y * 1024 + green * 32 + red
            sum += Double(result[index].x - neutral[index].x)
          }
        }
      }
      #expect(abs(sum / (720 * 4) - expected) < tolerance)
    }
  }

  @Test
  func negativeShadowsFollowTheMeasuredGreenLossAtMinus50() throws {
    let source = lightroomColorLattice()
    let neutral = try Self.exportedPixels(source, feature: ShadowsFeature(lightroomAmount: 0))
    let darker = try Self.exportedPixels(source, feature: ShadowsFeature(lightroomAmount: -50))
    // The 1,024 predominantly green patches lose 0.05641 on average in linear Display P3.
    var greenLoss = 0.0
    for row in 128..<(128 + 8 * 4) {
      for green in 16..<32 {
        for red in 0..<8 {
          let index = row * 1024 + green * 32 + red
          greenLoss += Double(neutral[index].y - darker[index].y)
        }
      }
    }
    #expect(abs(greenLoss / (1024 * 4) - 0.05641) < 0.002)
  }

  @Test
  func positiveShadowsRetainMeasuredColorInTheIndependentScene() throws {
    let output = try Self.exportedPixels(lightroomColorChart(rgbAt: Self.sceneColor), feature: ShadowsFeature(lightroomAmount: 17))
    // Independent +17 TIFF at the original chart resolution, decoded into linear Display-P3.
    #expect(abs(output[48 * 1024 + 384].z - 0.04057031) < 0.0005)
    #expect(abs(output[192 * 1024 + 592].x - 0.04405148) < 0.0005)
  }

  @Test
  func jointControlsFollowThePairedLightroomExport() throws {
    let source = lightroomColorLattice()
    let pair = try Self.exportedPixels(source, feature: HighlightsShadowsFeature(highlights: -35, shadows: 42))
    // Linear-P3 samples from adjust-chart-hs. Sequential, full-strength sliders
    // miss these highlights by 0.047–0.064 in the gray and green channels.
    #expect(abs(pair[32 * 1024 + 928].x - 0.7675141) < 0.018)
    #expect(abs(pair[96 * 1024 + 768].x - 0.7303579) < 0.023)
    #expect(abs(pair[176 * 1024 + 928].y - 0.8261096) < 0.028)

    // The darker part of the linear ramp measures the shadow lift with Highlights active.
    // Average the same 64 × 32 region of the paired 16-bit Lightroom export.
    var red = 0.0
    for y in 80..<112 {
      for x in 128..<192 { red += Double(pair[y * 1024 + x].x) }
    }
    #expect(abs(red / (64 * 32) - 0.2006785) < 0.009, "Mean linear-P3 red was \(red / (64 * 32))")

    // In adjust-chart-Shadows2012-100, a saturated SDR red rises past P3 white.
    let lifted = try Self.exportedPixels(source, feature: ShadowsFeature(lightroomAmount: 100))
    #expect(abs(lifted[130 * 1024 + 95].x - 1.4056) < 0.17)
  }

  @Test
  func negativeLightPreservesColorsBeyondDisplayP3Black() throws {
    let source = lightroomColorLattice()
    let highlights = try Self.exportedPixels(source, feature: HighlightsFeature(lightroomAmount: -100))
    let shadows = try Self.exportedPixels(source, feature: ShadowsFeature(lightroomAmount: -100))
    // Mean linear-P3 components of the same 256 cyan patches in the two
    // ProPhoto Lightroom exports. Each source patch starts with red = 0.
    var red = SIMD2<Double>.zero
    var highlightGreenBlue = SIMD2<Double>.zero
    for blue in 16..<32 {
      for green in 16..<32 {
        let index = (128 + 4 * blue) * 1024 + 32 * green
        red += SIMD2(Double(highlights[index].x), Double(shadows[index].x))
        highlightGreenBlue += SIMD2(Double(highlights[index].y), Double(highlights[index].z))
      }
    }
    red /= 256
    highlightGreenBlue /= 256
    #expect(abs(red.x - (-0.067050)) < 0.025, "Mean linear P3 red after Highlights was \(red.x)")
    #expect(abs(red.y - (-0.036896)) < 0.020, "Mean linear P3 red after Shadows was \(red.y)")
    #expect(abs(highlightGreenBlue.x - 0.353304) < 0.016, "Mean green after Highlights was \(highlightGreenBlue.x)")
    #expect(abs(highlightGreenBlue.y - 0.373327) < 0.012, "Mean blue after Highlights was \(highlightGreenBlue.y)")
  }

  @Test
  func strongNegativeShadowsFollowThePrimaryColorRegionsOfTheLattice() throws {
    let pixels = try Self.exportedPixels(lightroomColorLattice(), feature: ShadowsFeature(lightroomAmount: -100))
    // Red and green cover 1,024 colors each. The highest four blue codes
    // cover the bright end of the blue primary where strong Shadows diverges.
    var red = 0.0
    var green = 0.0
    for blueCode in 0..<8 {
      let row = (128 + 4 * blueCode) * 1024
      for low in 0..<8 {
        for high in 16..<32 {
          red += Double(pixels[row + 32 * low + high].x)
          green += Double(pixels[row + 32 * high + low].y)
        }
      }
    }
    #expect(abs(red / 1024 - 0.271988) < 0.075, "Mean red was \(red / 1024)")
    #expect(abs(green / 1024 - 0.456000) < 0.030, "Mean green was \(green / 1024)")
    var blue = 0.0
    for blueCode in 28..<32 {
      for greenCode in 0..<8 {
        let start = (128 + 4 * blueCode) * 1024 + 32 * greenCode
        blue += pixels[start..<(start + 8)].reduce(0.0) { $0 + Double($1.z) }
      }
    }
    #expect(abs(blue / 256 - 0.662614) < 0.075, "Mean blue was \(blue / 256)")
  }

  @Test
  func negativeShadowsFollowTheStrongIntervalOnRedAndMagenta() throws {
    let source = lightroomColorLattice()
    let half = try Self.exportedPixels(source, feature: ShadowsFeature(lightroomAmount: -50))
    let full = try Self.exportedPixels(source, feature: ShadowsFeature(lightroomAmount: -100))
    // Mean additional red loss across 1,024 distinct colors in the two
    // registered Lightroom TIFFs, measured after conversion to linear P3.
    var redLoss = 0.0
    for blue in 8..<24 {
      for green in 0..<8 {
        for red in 24..<32 {
          let index = (128 + 4 * blue) * 1024 + green * 32 + red
          redLoss += Double(half[index].x - full[index].x)
        }
      }
    }
    #expect(abs(redLoss / 1024 - 0.155045) < 0.008)
  }

  @Test
  func strongNegativeShadowsKeepBrightCyanAndPreserveMixturesBetweenPrimaries() throws {
    let source = lightroomColorLattice()
    let zero = try Self.exportedPixels(source, feature: ShadowsFeature(lightroomAmount: 0))
    let strong = try Self.exportedPixels(source, feature: ShadowsFeature(lightroomAmount: -100))
    // The eight brightest cyan patches vary red from 0 to 7/31 while green
    // and blue start at 1. Their Adobe −100 mean is still close to white in both channels.
    let cyanStart = (128 + 4 * 31) * 1024 + 32 * 31
    let cyan = strong[cyanStart..<(cyanStart + 8)].reduce(SIMD2<Double>.zero) {
      $0 + SIMD2(Double($1.y), Double($1.z))
    } / 8
    #expect(abs(cyan.x - 0.9817) < 0.04, "Mean green was \(cyan.x)")
    #expect(abs(cyan.y - 0.9804) < 0.04, "Mean blue was \(cyan.y)")

    // Lightroom's middle channel stays on the input RGB line between the two
    // edited extrema. Its measured p95 on these mixtures is below 0.00013.
    var errors: [Float] = []
    for blueCode in 0..<32 {
      let row = (128 + 4 * blueCode) * 1024
      for column in 0..<1024 {
        let input = zero[row + column]
        let channels = [0, 1, 2].sorted { input[$0] < input[$1] }
        let (low, middle, high) = (channels[0], channels[1], channels[2])
        let span = input[high] - input[low]
        guard span > 0.06 else { continue }
        let fraction = (input[middle] - input[low]) / span
        guard (0.2...0.8).contains(fraction) else { continue }
        let result = strong[row + column]
        errors.append(abs(result[middle] - (result[low] + fraction * (result[high] - result[low]))))
      }
    }
    try #require(errors.count > 10_000)
    errors.sort()
    #expect(errors[Int(ceil(0.95 * Double(errors.count))) - 1] < 0.001)
  }

  @Test
  func weakHighlightsWithLiftedShadowsPreserveTheMeasuredLightRamp() throws {
    // A10's five Light settings on the two-ramp and 32³ color chart. The
    // references are mean linear-P3 red in 64 × 16 regions of the Lightroom TIFF.
    let light = [
      AnyImageEffect(HighlightsShadowsFeature(highlights: -11, shadows: 30)),
      AnyImageEffect(WhitesFeature(amount: -22)),
      AnyImageEffect(BlacksFeature(amount: 11)),
      AnyImageEffect(SaturationFeature(lightroomAmount: 5)),
    ]
    let pixels = try Self.exportedPixels(lightroomColorLattice(), feature: light)
    for (x, reference, tolerance): (Int, Double, Double) in [(832, 0.78877, 0.021), (892, 0.84895, 0.0175)] {
      var red = 0.0
      for row in 88..<104 {
        for column in (x - 32)..<(x + 32) { red += Double(pixels[row * 1024 + column].x) }
      }
      let mean = red / (64 * 16)
      #expect(abs(mean - reference) < tolerance, "Mean linear-P3 red at x = \(x) was \(mean)")
    }
  }

  @Test
  func jointControlsPreserveTheNeutralAxesAndIndependentSignCombinations() throws {
    let source = Self.scene(width: 64, height: 32)
    let neutral = HighlightsShadowsFeature(highlights: 0, shadows: 0)
    #expect(try FeatureRenderer().makeImage(from: source, feature: neutral) === source)
    let shadow = try Self.render(source, feature: ShadowsFeature(lightroomAmount: 30))
    #expect(try Self.render(source, feature: HighlightsShadowsFeature(highlights: .nan, shadows: 30)) == shadow)
    let highlight = try Self.render(source, feature: HighlightsFeature(lightroomAmount: -37))
    #expect(try Self.render(source, feature: HighlightsShadowsFeature(highlights: -37, shadows: 0)) == highlight)
    for (h, s): (Double, Double) in [(35, 42), (-35, -42), (35, -42)] {
      let independent = [
        AnyImageEffect(ShadowsFeature(lightroomAmount: s)),
        AnyImageEffect(HighlightsFeature(lightroomAmount: h)),
      ]
      let sequential = try Self.render(source, feature: independent)
      #expect(try Self.render(source, feature: HighlightsShadowsFeature(highlights: h, shadows: s)) == sequential)
    }
    let end = try Self.render(source, feature: HighlightsShadowsFeature(highlights: -100, shadows: 100))
    #expect(try Self.render(source, feature: HighlightsShadowsFeature(highlights: -110, shadows: 120)) == end)
  }

  @Test
  func positiveShadowsLiftContinuouslyThroughTheColorAnchor() throws {
    let source = Self.scene(width: 128, height: 48)
    var previous = Self.pixels(source)
    var lastAmount = 0.0
    for amount in [0.1, 9.9, 10, 10.1, 24.9, 25, 25.1, 49.9, 50, 50.1, 75, 100] {
      let next = try Self.render(source, feature: ShadowsFeature(lightroomAmount: amount))
      if amount - lastAmount < 1 { #expect(Self.error(previous, next) < 0.002) }
      let largestDecrease = zip(previous, next).reduce(Float.zero) { maximum, pair in
        let change = pair.0 - pair.1
        return max(maximum, change.x, change.y, change.z)
      }
      #expect(largestDecrease < 0.0001)
      previous = next
      lastAmount = amount
    }
  }

  @Test
  func negativeHighlightsRecoverTheMeasuredRedInBluePatches() throws {
    let image = lightroomColorLattice()
    let neutral = try Self.exportedPixels(image, feature: HighlightsFeature(lightroomAmount: 0))
    let adjusted = try Self.exportedPixels(image, feature: HighlightsFeature(lightroomAmount: -25))

    // The registered 16-bit Adobe pair loses 0.0264165 linear P3 red across
    // these 2,048 blue patches. Their mean adjusted red lies below P3 black.
    var redLoss = 0.0
    for row in (128 + 24 * 4)..<256 {
      for green in 16..<24 {
        for red in 0..<8 {
          let index = row * 1024 + green * 32 + red
          redLoss += Double(neutral[index].x - adjusted[index].x)
        }
      }
    }
    #expect(abs(redLoss / 2048 - 0.0264165) < 0.01)
  }

  @Test
  func negativeHighlightsKeepTheMeasuredSeparationOfBrightBluePatches() throws {
    let pixels = try Self.exportedPixels(lightroomColorLattice(), feature: HighlightsFeature(lightroomAmount: -50))
    var separation = 0.0
    var count = 0
    for blue in 21..<32 {
      for green in 1..<blue {
        for red in 0..<green {
          for row in 0..<4 {
            let pixel = pixels[(128 + blue * 4 + row) * 1024 + green * 32 + red]
            separation += Double(pixel.z - pixel.x)
            count += 1
          }
        }
      }
    }
    // Mean blue minus red in the same 14,520 pixels of the 16-bit Adobe −50 export.
    #expect(abs(separation / Double(count) - 0.603668) < 0.024)
  }

  @Test
  func strongHighlightsFollowTheMeasuredSecondStepInBrightGreen() throws {
    let source = lightroomColorLattice()
    let half = try Self.exportedPixels(source, feature: HighlightsFeature(lightroomAmount: -50))
    let full = try Self.exportedPixels(source, feature: HighlightsFeature(lightroomAmount: -100))

    func meanGreenLoss(rows: Range<Int>, columns: Range<Int>) -> Double {
      var loss = 0.0
      for row in rows {
        for column in columns {
          let index = row * 1024 + column
          loss += Double(half[index].y - full[index].y)
        }
      }
      return loss / Double(rows.count * columns.count)
    }
    // The top seven green levels span every red and blue level in the 32³ chart.
    // Lightroom loses 0.158330 green there and 0.083123 in the central half of
    // the linear gray ramp between −50 and −100.
    let green = meanGreenLoss(rows: 128..<256, columns: (25 * 32)..<1024)
    let gray = meanGreenLoss(rows: 64..<128, columns: 256..<768)
    #expect(abs(green - 0.158330) < 0.021)
    #expect(abs((green - gray) - (0.158330 - 0.083123)) < 0.024)
  }

  @Test
  func strongHighlightsFollowTheMeasuredWeakIntervalInTexturedGray() throws {
    let source = lightroomColorChart(width: 128, height: 96) { x, y, _, _ in
      let detail = Double((3 * x + 5 * y) % 11) / 10
      return SIMD3(repeating: x < 64 ? 0.16 + 0.35 * detail : 0.60 + 0.24 * detail)
    }
    let neutral = try Self.exportedPixels(source, feature: HighlightsFeature(lightroomAmount: 0))
    let half = try Self.exportedPixels(source, feature: HighlightsFeature(lightroomAmount: -50))
    let full = try Self.exportedPixels(source, feature: HighlightsFeature(lightroomAmount: -100))
    // On four registered photographs the second step in this coordinate
    // predicts Adobe −100 from neutral and −50 within 0.005 at the 95th percentile.
    func odds(_ y: Double) -> Double { (y + 0.03281635) / (1.21244557 - y) }
    var errors: [Double] = []
    for index in neutral.indices {
      let input = Double(neutral[index].y)
      let midpoint = Double(half[index].y)
      guard input > 0.35, midpoint < input - 0.01 else { continue }
      let next = odds(midpoint) * odds(midpoint) / odds(input)
      let expected = (1.21244557 * next - 0.03281635) / (1 + next)
      errors.append(abs(Double(full[index].y) - expected))
    }
    try #require(errors.count > 4000)
    errors.sort()
    #expect(errors[(95 * errors.count + 99) / 100 - 1] < 0.006)
  }

  @Test
  func weakNegativeShadowsFollowTheMeasuredLossOnABrightGrayRamp() throws {
    let source = lightroomColorLattice()
    let neutral = try Self.exportedPixels(source, feature: ShadowsFeature(lightroomAmount: 0))
    let weak = try Self.exportedPixels(source, feature: ShadowsFeature(lightroomAmount: -10))
    // The second gray ramp spans linear light uniformly. In its 87.5–93.75%
    // band, the registered neutral and −10 Lightroom exports differ by 0.001962.
    var loss = 0.0
    for row in 64..<128 {
      for column in 896..<960 {
        let i = row * 1024 + column
        loss += Double(neutral[i].y - weak[i].y)
      }
    }
    #expect(abs(loss / (64 * 64) - 0.001962) < 0.00075)
  }

  @Test
  func negativeShadowsKeepsTheMeasuredBrightGraysConsistentAcrossEachRamp() throws {
    let pixels = try Self.exportedPixels(lightroomColorLattice(), feature: ShadowsFeature(lightroomAmount: -50))
    // Each column in a gray ramp repeats the same 16-bit source color in 64 rows.
    // Compare the first and last 16 rows in its bright half. The differences
    // in the Adobe export are 0.000085 and 0.000004 in linear P3 luminance.
    let luma = SIMD3<Float>(0.2289746, 0.6917385, 0.0792869)
    func luminance(_ pixel: SIMD4<Float>) -> Float {
      pixel.x * luma.x + pixel.y * luma.y + pixel.z * luma.z
    }
    for (firstRow, reference): (Int, Float) in [(0, 0.000085), (64, 0.000004)] {
      var total: Float = 0
      for column in 512..<1024 {
        var difference: Float = 0
        for row in firstRow..<(firstRow + 16) {
          difference += luminance(pixels[row * 1024 + column]) - luminance(pixels[(row + 48) * 1024 + column])
        }
        total += abs(difference / 16)
      }
      #expect(abs(total / 512 - reference) < 0.0002)
    }
  }

  @Test
  func negativeShadowsMatchesMeasuredRedAndBlueRegions() throws {
    let source = lightroomColorChart(rgbAt: Self.sceneColor)
    let image = try Self.exportedPixels(source, feature: ShadowsFeature(lightroomAmount: -32))
    let samples = [128, 384, 640, 896].map { image[128 * 1024 + $0] }
    // The same 16-bit Lightroom color chart, at Shadows -32 in linear Display-P3.
    let adobe: [SIMD4<Float>] = [
      .init(0.21656363, 0.02962820, 0.01884114, 1), .init(0.21615998, 0.02965158, 0.01970400, 1),
      .init(0.02080732, 0.02753240, 0.14023240, 1), .init(0.02115379, 0.02751212, 0.13687362, 1),
    ]
    #expect(Self.error(samples, adobe) < 0.018)
    #expect(Self.error(Array(samples.suffix(2)), Array(adobe.suffix(2))) < 0.012)
  }

  @Test
  func negativeHighlightsRetainsMeasuredColorInGreenRegions() throws {
    let source = lightroomColorChart(rgbAt: Self.sceneColor)
    let pixels = try Self.exportedPixels(source, feature: HighlightsFeature(lightroomAmount: -37))
    // Secondary-channel samples from two green regions in the Lightroom -37 export.
    #expect(abs(pixels[32 * 1024 + 896].x - 0.02202985) < 0.0008)
    #expect(abs(pixels[544].z - 0.04734176) < 0.0009)
  }

  @Test(arguments: [true, false])
  func negativeTonalControlKeepsDarkeningAcrossTheMeasuredStrengths(highlights: Bool) throws {
    let source = Self.scene(width: 128, height: 48)
    func render(_ amount: Double) throws -> [SIMD4<Float>] {
      let effect = highlights ? AnyImageEffect(HighlightsFeature(lightroomAmount: -amount))
        : AnyImageEffect(ShadowsFeature(lightroomAmount: -amount))
      return try Self.render(source, feature: effect)
    }
    var previous = try render(0)
    var lastAmount = 0.0
    for amount in [0.1, 9.9, 10, 10.1, 24.9, 25, 25.1, 37, 49.9, 50, 50.1, 75, 100] {
      let next = try render(amount)
      // The measured intervals must join continuously, including on colored
      // pixels where the individual channel changes differ.
      if amount - lastAmount < 1 {
        #expect(Self.error(previous, next) < 0.002)
      }
      let largestIncrease = zip(previous, next).reduce(Float.zero) { maximum, pair in
        let change = pair.1 - pair.0
        return max(maximum, change.x, change.y, change.z)
      }
      #expect(largestIncrease < 0.0001)
      previous = next
      lastAmount = amount
    }
  }

  @Test
  func preservesAlphaAndExtendsTheSDRBoundary() throws {
    let colors: [SIMD4<Float>] = (0..<32 * 16).map { index in
      let value = Float(index % 32) / 31
      return .init(value - 0.2, 0.1 + value * 0.6, value + 0.5, 1)
    }
    let bounded = colors.map { SIMD4<Float>(min(max($0.x, 0), 1), min(max($0.y, 0), 1), min(max($0.z, 0), 1), 1) }
    for effect in Self.effects {
      let full = try Self.render(Self.image(colors, width: 32), feature: effect)
      let half = try Self.render(Self.image(colors.map { $0 * 0.5 }, width: 32), feature: effect)
      let sdr = try Self.render(Self.image(bounded, width: 32), feature: effect)
      #expect(Self.error(full.map { $0 * 0.5 }, half) < 0.0002)
      let extended = zip(sdr, zip(colors, bounded)).map { $0.0 + $0.1.0 - $0.1.1 }
      #expect(Self.error(full, extended) < 0.0002)
      let transparent = try Self.render(Self.image(Array(repeating: .zero, count: 8), width: 8), feature: effect)
      #expect(transparent.allSatisfy { $0 == .zero })
    }
  }

  @Test
  func partialRenderingAndWorkingSpacesUseTheWholeScene() throws {
    let feature = HighlightsFeature(value: -0.23, algorithm: .lightroomApproximation)
    let source = Self.scene(width: 64, height: 32).transformed(by: .init(translationX: 17, y: -4))
    let image = try FeatureRenderer().makeImage(from: source, feature: feature)
    #expect(image.extent == CGRect(x: 0, y: 0, width: 64, height: 32))
    let expected = Self.pixels(image)
    let rect = CGRect(x: 12, y: 8, width: 24, height: 16)
    let tile = Self.pixels(image.cropped(to: rect))
    let selected = (8..<24).flatMap { y in (12..<36).map { expected[y * 64 + $0] } }
    #expect(Self.error(tile, selected) < 0.0002)
    for name in [CGColorSpace.sRGB, CGColorSpace.extendedLinearSRGB] {
      let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: name)!, .workingFormat: CIFormat.RGBAf])
      #expect(Self.error(Self.pixels(image, context: context), expected) < 0.001)
    }
  }

  @Test
  func asymmetricPartialRenderingMatchesTheWholeSceneInBothWorkingFormats() throws {
    let width = 128
    let height = 96
    var pixels = [SIMD4<Float>]()
    for y in 0..<height {
      for x in 0..<width {
        let value = 0.02 + 0.94 * Double(x) / 127
        var rgb = SIMD3<Double>(repeating: value)
        if y >= 24 {
          rgb = .init(value, 0.05 + 0.8 * Double(y) / 95, 0.1 + 0.7 * (1 - value))
        }
        if (8..<16).contains(y) { rgb.y += 0.000005 }
        if (60..<70).contains(y) && (10..<30).contains(x) { rgb = .init(-0.4, 0.2, 1.6) }
        if (70..<80).contains(y) && (10..<30).contains(x) { rgb = .init(1.3, 2, 4) }
        var alpha = 1.0
        if (80..<90).contains(y) { alpha = 0.5 }
        if (90..<93).contains(y) { alpha = 0.0000001 }
        if y >= 93 { alpha = 0 }
        pixels.append(.init(Float(rgb.x * alpha), Float(rgb.y * alpha), Float(rgb.z * alpha), Float(alpha)))
      }
    }
    let source = Self.image(pixels, width: width).transformed(by: .init(translationX: -17, y: 23))
    let crop = CGRect(x: 13, y: 17, width: 71, height: 53)
    for (format, tolerance): (CIFormat, Float) in [(.RGBAf, 0.00002), (.RGBAh, 0.002)] {
      let context = CIContext(options: [
        .workingColorSpace: Self.space, .workingFormat: format, .cacheIntermediates: false,
      ])
      for effect in Self.effects {
        let image = try FeatureRenderer().makeImage(from: source, feature: effect)
        #expect(image.extent == CGRect(x: 0, y: 0, width: width, height: height))
        let whole = Self.pixels(image, context: context)
        let partial = Self.pixels(image.cropped(to: crop), context: context)
        // Bitmap rows run top-down, so this asymmetric crop selects rows 26 through 78.
        let selected = (26..<79).flatMap { y in (13..<84).map { whole[y * width + $0] } }
        #expect(Self.error(partial, selected) <= tolerance)
      }
    }
  }

  @Test
  func reducedPreviewKeepsTheSpatialResponse() throws {
    let source = Self.scene(width: 1024, height: 256)
    let reduced = source.clampedToExtent().applyingFilter("CILanczosScaleTransform",
      parameters: [kCIInputScaleKey: 0.5, "inputAspectRatio": 1])
      .cropped(to: CGRect(x: 0, y: 0, width: 512, height: 128))
    let feature = HighlightsFeature(value: 0.37, algorithm: .lightroomApproximation)
    let full = try FeatureRenderer().makeImage(from: source, feature: feature)
    let expected = full.clampedToExtent().applyingFilter("CILanczosScaleTransform",
      parameters: [kCIInputScaleKey: 0.5, "inputAspectRatio": 1]).cropped(to: reduced.extent)
    #expect(Self.error(try Self.render(reduced, feature: feature), Self.pixels(expected)) < 0.004)
  }

  @Test
  func stackedAdjustmentsExportEveryTileOfALargeOpaqueImage() throws {
    // At 24 MP, requesting upscaled full-frame guides for both adjustments
    // exhausted the simulator's tile budget and the PNG contained transparent rows.
    let extent = CGRect(x: 0, y: 0, width: 6000, height: 4000)
    let source = Self.scene(width: 96, height: 64).clampedToExtent()
      .transformed(by: .init(scaleX: 62.5, y: 62.5)).cropped(to: extent)
    let effects = [
      AnyImageEffect(HighlightsFeature(lightroomAmount: -11)),
      AnyImageEffect(ShadowsFeature(lightroomAmount: 30)),
      AnyImageEffect(WhitesFeature(amount: 75)),
    ]
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).png")
    defer { try? FileManager.default.removeItem(at: url) }
    _ = try ExportRenderer().render(from: source, feature: effects,
      options: .init(outputFormat: .RGBA16, outputColorSpace: CGColorSpace(name: CGColorSpace.displayP3),
        output: .file(url: url, fileType: .png)))
    let exported = try #require(CIImage(contentsOf: url))
    #expect(exported.extent == extent)
    let minimum = exported.applyingFilter("CIAreaMinimum",
      parameters: [kCIInputExtentKey: CIVector(cgRect: exported.extent)])
    #expect(Self.pixels(minimum).first?.w == 1)
  }

  private static let effects = [
    AnyImageEffect(HighlightsFeature(value: 0.5, algorithm: .lightroomApproximation)),
    AnyImageEffect(HighlightsFeature(value: -0.5, algorithm: .lightroomApproximation)),
    AnyImageEffect(ShadowsFeature(value: 0.5, algorithm: .lightroomApproximation)),
    AnyImageEffect(ShadowsFeature(value: -0.5, algorithm: .lightroomApproximation)),
  ]

  private static func sceneColor(x: Int, y: Int, width: Int, height: Int) -> SIMD3<Double> {
    let u = Double(x) / Double(width - 1)
    let v = Double(y) / Double(height - 1)
    return .init(0.35 + 0.25 * sin(2 * .pi * u), 0.45 + 0.25 * cos(2 * .pi * v),
      0.30 + 0.20 * sin(2 * .pi * (u + v)))
  }

  private static func scene(width: Int, height: Int) -> CIImage {
    var pixels = [SIMD4<Float>]()
    for y in 0..<height {
      for x in 0..<width {
        let rgb = sceneColor(x: x, y: y, width: width, height: height)
        pixels.append(.init(SIMD3<Float>(rgb), 1))
      }
    }
    return image(pixels, width: width, space: CGColorSpace(name: CGColorSpace.displayP3)!)
  }

  private static func image(_ pixels: [SIMD4<Float>], width: Int, space: CGColorSpace = space) -> CIImage {
    CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
      size: CGSize(width: width, height: pixels.count / width), format: .RGBAf, colorSpace: space)
  }

  private static func render(_ source: CIImage, feature: some Feature) throws -> [SIMD4<Float>] {
    pixels(try FeatureRenderer().makeImage(from: source, feature: feature))
  }

  private static func exportedPixels(_ source: CIImage, feature: some Feature) throws -> [SIMD4<Float>] {
    let rendered = try ExportRenderer().render(from: source, feature: feature,
      options: .init(outputFormat: .RGBA16, outputColorSpace: CGColorSpace(name: CGColorSpace.rommrgb)))
    return pixels(CIImage(cgImage: try rendered.cgImage))
  }

  private static func pixels(_ image: CIImage, context: CIContext = context) -> [SIMD4<Float>] {
    var result = [SIMD4<Float>](repeating: .init(repeating: .nan), count: Int(image.extent.width * image.extent.height))
    context.render(image, toBitmap: &result, rowBytes: Int(image.extent.width) * 16,
      bounds: image.extent, format: .RGBAf, colorSpace: space)
    #expect(result.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite })
    return result
  }

  private static func error(_ a: [SIMD4<Float>], _ b: [SIMD4<Float>]) -> Float {
    #expect(a.count == b.count)
    return zip(a, b).reduce(0) { maximum, pair in
      let d = pair.0 - pair.1
      return max(maximum, abs(d.x), abs(d.y), abs(d.z), abs(d.w))
    }
  }
}
