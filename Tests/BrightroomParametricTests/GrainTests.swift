import BrightroomParametric
import CoreImage
import Foundation
import Testing

/// Public API only. Measure the texture's behavior rather than duplicating its
/// random generator; no test equates a procedural seed with Lightroom pixels.
@Suite("Grain", .serialized)
struct GrainTests {

  private static let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
  private static let context = CIContext(options: [
    .workingColorSpace: space, .workingFormat: CIFormat.RGBAf,
  ])

  @Test
  func neutralAndStoredParameters() throws {
    let source = Self.source()
    #expect(try FeatureRenderer().makeImage(from: source,
      feature: GrainFeature(amount: 0, seed: .max)) === source)
    #expect(GrainFeature(validatingAmount: .nan, radius: .absolute(1), roughness: 50, seed: 0) == nil)
    #expect(GrainFeature(validatingAmount: 20, radius: .absolute(-1), roughness: 50, seed: 0) == nil)
    #expect(GrainFeature(validatingAmount: 20, radius: .proportional(.infinity), roughness: 50, seed: 0) == nil)
    #expect(GrainFeature(validatingAmount: 20, radius: .absolute(1), roughness: 101, seed: 0) == nil)
    let stored = GrainFeature(amount: 23, radius: .proportional(0.3), roughness: 61, seed: .max)
    #expect(GrainFeature(validatingAmount: stored.amount, radius: stored.radius,
      roughness: stored.roughness, seed: stored.seed) == stored)
    let film = GrainFeature.CameraRaw(amount: 20, size: 42, roughness: 70, seed: .max)
    #expect(GrainFeature.CameraRaw(validatingAmount: film.amount, size: film.size,
      roughness: film.roughness, seed: film.seed) == film)
    #expect(GrainFeature.CameraRaw(validatingAmount: 20, size: .nan, roughness: 70, seed: 0) == nil)
    #expect(try FeatureRenderer().makeImage(from: source, feature: GrainFeature.CameraRaw(amount: 0)) === source)
  }

  @Test
  func cameraRawGrainMatchesMeasuredTextureAtTwoSourceSizes() throws {
    let film = GrainFeature.CameraRaw(amount: 20, size: 42, roughness: 70)
    for large in [false, true] {
      let extent = CGRect(x: 0, y: 0, width: large ? 6000 : 1024, height: large ? 4000 : 256)
      // Both ends of the measured midtone plateau should have similar noise.
      for level in [0.15, 0.85] {
        let linear = pow((level + 0.055) / 1.055, 2.4)
        let color = CIColor(red: linear, green: linear, blue: linear, alpha: 1, colorSpace: Self.space)!
        let image = try FeatureRenderer().makeImage(from: CIImage(color: color).cropped(to: extent), feature: film)
        let values = Self.pixels(image.cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256)))
        let red = stride(from: 0, to: values.count, by: 4).map {
          1.055 * pow(Double(values[$0]), 1 / 2.4) - 0.055 - level
        }
        #expect(abs(Self.mean(red)) < 0.001)
        #expect((large ? 0.011...0.013 : 0.026...0.029).contains(sqrt(Self.variance(red))))
        #expect((large ? 0.81...0.86 : 0.02...0.07).contains(Self.correlation(red)))
      }
    }
  }

  @Test
  func cameraRawLargeSizeSoftensChromaticEdgesAndPreservesAlpha() throws {
    let extent = CGRect(x: 0, y: 0, width: 6000, height: 4000)
    func patch(_ r: Double, _ g: Double, width: CGFloat) -> CIImage {
      let color = CIColor(red: r, green: g, blue: 0.18, alpha: 0.5, colorSpace: Self.space)!
      return CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: width, height: extent.height))
    }
    let input = patch(0.36, 0.15, width: 3000).composited(over:
      patch(0.15, 0.36, width: 3000).transformed(by: .init(translationX: 3000, y: 0)))
    let film = GrainFeature.CameraRaw(amount: 20, size: 42, roughness: 70, seed: .max)
    let image = try FeatureRenderer().makeImage(from: input, feature: film)
    #expect(image.extent == extent)
    let row = Self.pixels(image.cropped(to: CGRect(x: 2996, y: 500, width: 8, height: 1)))
    // A common grain sample cancels in the difference of two encoded ROMM channels.
    let chroma = (0..<8).map { pixel in
      let offset = 4 * pixel
      let alpha = Double(row[offset + 3])
      #expect(abs(alpha - 0.5) < 0.00001)
      let r = Double(row[offset]) / alpha
      let g = Double(row[offset + 1]) / alpha
      let b = Double(row[offset + 2]) / alpha
      let red = 0.63169122 * r + 0.21392818 * g + 0.15438059 * b
      let green = 0.08320432 * r + 0.88585751 * g + 0.03093817 * b
      return 1.055 * (pow(red, 1 / 2.4) - pow(green, 1 / 2.4))
    }
    let edgeFraction = (chroma[3] - chroma[0]) / (chroma[7] - chroma[0])
    #expect((0.14...0.18).contains(edgeFraction))
  }

  @Test(arguments: [false, true])
  func everySeedBitAndPartialRenderingAreStable(cameraRaw: Bool) throws {
    let source = Self.source(size: 128)
    func make(_ seed: UInt32) -> AnyImageEffect {
      cameraRaw ? AnyImageEffect(GrainFeature.CameraRaw(amount: 50, size: 73, roughness: 65, seed: seed))
        : AnyImageEffect(GrainFeature(amount: 50, seed: seed))
    }
    let feature = make(.max)
    let image = try FeatureRenderer().makeImage(from: source, feature: feature)
    #expect(image.extent == source.extent)
    let whole = Self.pixels(image)
    let repeated = Self.pixels(try FeatureRenderer().makeImage(from: source, feature: feature))
    #expect(Self.difference(whole, repeated) == 0)
    let tile = Self.pixels(image.cropped(to: CGRect(x: 32, y: 32, width: 64, height: 64)))
    var maximum: Float = 0
    for y in 0..<64 {
      for x in 0..<64 {
        maximum = max(maximum, abs(tile[(y * 64 + x) * 4] - whole[((y + 32) * 128 + x + 32) * 4]))
      }
    }
    #expect(maximum < 0.00001)
    for seed: UInt32 in [.max - 1, .max - 65536] {
      let other = Self.pixels(try FeatureRenderer().makeImage(from: source,
        feature: make(seed)))
      #expect(Self.difference(whole, other) > 0.01)
    }
  }

  @Test
  func amountChangesVarianceAndRadiusChangesSpatialCorrelation() throws {
    let low = try Self.red(GrainFeature(amount: 20, radius: .absolute(0.5), roughness: 0))
    let high = try Self.red(GrainFeature(amount: 40, radius: .absolute(0.5), roughness: 0))
    let larger = try Self.red(GrainFeature(amount: 20, radius: .absolute(2), roughness: 0))
    let ratio = sqrt(Self.variance(high) / Self.variance(low))
    #expect((1.8...2.2).contains(ratio))
    #expect(abs(Self.mean(low) - 0.18) < 0.005)
    #expect(Self.correlation(larger) > Self.correlation(low) + 0.2)
  }

  @Test
  func roughnessMakesTheDistributionLessUniform() throws {
    let uniform = try Self.red(GrainFeature(amount: 20, roughness: 0, seed: 7))
    let uneven = try Self.red(GrainFeature(amount: 20, roughness: 100, seed: 7))
    func kurtosis(_ samples: [Double]) -> Double {
      let center = Self.mean(samples)
      let variance = Self.variance(samples)
      return samples.reduce(0) { $0 + pow($1 - center, 4) } / Double(samples.count) / (variance * variance)
    }
    #expect(kurtosis(uneven) > kurtosis(uniform) + 0.3)
  }

  @Test(arguments: [false, true])
  func alphaAchromaticPixelsAndHeadroomSurvive(cameraRaw: Bool) throws {
    let feature = cameraRaw
      ? AnyImageEffect(GrainFeature.CameraRaw(amount: 60, size: 73, roughness: 65, seed: 42))
      : AnyImageEffect(GrainFeature(amount: 60, seed: 42))
    let opaque = Self.pixels(try FeatureRenderer().makeImage(from: Self.source(size: 32), feature: feature))
    let translucent = Self.pixels(try FeatureRenderer().makeImage(from: Self.source(size: 32, alpha: 0.5), feature: feature))
    let transparent = Self.pixels(try FeatureRenderer().makeImage(from: Self.source(size: 32, alpha: 0), feature: feature))
    #expect(Self.difference(opaque.map { $0 * 0.5 }, translucent) < 0.00001)
    #expect(transparent.allSatisfy { $0 == 0 })
    for i in stride(from: 0, to: opaque.count, by: 4) {
      #expect(abs(opaque[i] - opaque[i + 1]) < 0.00001)
      #expect(abs(opaque[i] - opaque[i + 2]) < 0.00001)
      #expect(opaque[i + 3] == 1)
    }
    let extended = CIImage(color: CIColor(red: -0.1, green: 0.3, blue: 1.3, alpha: 1, colorSpace: Self.space)!)
      .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
    let pixels = Self.pixels(try FeatureRenderer().makeImage(from: extended, feature: feature))
    // Grain can lift a particular sample above zero. Clipping would remove
    // the negative reds or the extended blues from the entire field.
    #expect(stride(from: 0, to: pixels.count, by: 4).contains { pixels[$0] < -0.05 })
    #expect(stride(from: 2, to: pixels.count, by: 4).contains { pixels[$0] > 1.1 })
    for level: CGFloat in [-0.1, 1.3] {
      let gray = CIImage(color: CIColor(red: level, green: level, blue: level, alpha: 1, colorSpace: Self.space)!)
        .cropped(to: extended.extent)
      let actual = Self.pixels(try FeatureRenderer().makeImage(from: gray, feature: feature))
      #expect(Self.difference(actual, Self.pixels(gray)) < 0.00002)
    }
  }

  @Test(arguments: [false, true])
  func contextColorSpaceDoesNotChangeTheTexture(cameraRaw: Bool) throws {
    let feature = cameraRaw
      ? AnyImageEffect(GrainFeature.CameraRaw(amount: 50, size: 73, roughness: 65, seed: 19))
      : AnyImageEffect(GrainFeature(amount: 50, seed: 19))
    let image = try FeatureRenderer().makeImage(from: Self.source(size: 64),
      feature: feature)
    let expected = Self.pixels(image)
    for space in [CGColorSpace.extendedLinearSRGB, CGColorSpace.sRGB] {
      let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: space)!, .workingFormat: CIFormat.RGBAf,
      ])
      #expect(Self.difference(expected, Self.pixels(image, context: context)) < 0.0001)
    }
  }

  private static func source(size: Int = 256, alpha: CGFloat = 1) -> CIImage {
    CIImage(color: CIColor(red: 0.18, green: 0.18, blue: 0.18, alpha: alpha, colorSpace: space)!)
      .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
  }

  private static func pixels(_ image: CIImage, context: CIContext = context) -> [Float] {
    var result = [Float](repeating: .nan, count: Int(image.extent.width * image.extent.height) * 4)
    context.render(image, toBitmap: &result, rowBytes: Int(image.extent.width) * 16,
      bounds: image.extent, format: .RGBAf, colorSpace: space)
    #expect(result.allSatisfy { $0.isFinite })
    return result
  }

  private static func red(_ feature: GrainFeature) throws -> [Double] {
    let data = pixels(try FeatureRenderer().makeImage(from: source(), feature: feature))
    return stride(from: 0, to: data.count, by: 4).map { Double(data[$0]) }
  }

  private static func mean(_ samples: [Double]) -> Double {
    samples.reduce(0, +) / Double(samples.count)
  }

  private static func variance(_ samples: [Double]) -> Double {
    let center = mean(samples)
    return samples.reduce(0) { $0 + ($1 - center) * ($1 - center) } / Double(samples.count)
  }

  private static func correlation(_ samples: [Double]) -> Double {
    let center = mean(samples)
    var covariance = 0.0
    for y in 0..<256 {
      for x in 0..<255 {
        let i = y * 256 + x
        covariance += (samples[i] - center) * (samples[i + 1] - center)
      }
    }
    return covariance / Double(256 * 255) / variance(samples)
  }

  private static func difference(_ a: [Float], _ b: [Float]) -> Float {
    zip(a, b).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
  }
}

/// Package-level preview contract: the canvas supplies renderScale, which hosts
/// cannot set through FeatureRenderer. Compare against a full-resolution export.
@Suite("Grain preview scale", .serialized)
struct GrainPreviewScaleTests {

  @Test(arguments: [false, true])
  func reducedPreviewFiltersTheSameFullResolutionTexture(cameraRaw: Bool) throws {
    let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf])
    let source = CIImage(color: CIColor(red: 0.18, green: 0.18, blue: 0.18, alpha: 1, colorSpace: space)!)
      .cropped(to: CGRect(x: 0, y: 0, width: 512, height: 512))
    let feature = cameraRaw
      ? AnyImageEffect(GrainFeature.CameraRaw(amount: 20, size: 42, roughness: 70, seed: 29))
      : AnyImageEffect(GrainFeature(amount: 20, radius: .absolute(0.5), roughness: 50, seed: 29))
    let full = try FeatureRenderer().makeImage(from: source, feature: feature)
      .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 0.25, "inputAspectRatio": 1])
    let input = source.transformed(by: .init(scaleX: 0.25, y: 0.25))
    let preview = try feature.apply(to: input, context: .init(chainEntryExtent: input.extent, renderScale: 0.25))
    // Ignore export-resize edges. Tone-dependent blending and nonlinear encoding
    // happen on opposite sides of resampling, so equality is not bit-exact.
    let bounds = CGRect(x: 8, y: 8, width: 112, height: 112)
    func red(_ image: CIImage) -> [Double] {
      var values = [Float](repeating: .nan, count: 112 * 112 * 4)
      context.render(image, toBitmap: &values, rowBytes: 112 * 16, bounds: bounds, format: .RGBAf, colorSpace: space)
      #expect(values.allSatisfy { $0.isFinite })
      return stride(from: 0, to: values.count, by: 4).map { Double(values[$0]) }
    }
    let expected = red(full)
    let actual = red(preview)
    let expectedMean = expected.reduce(0, +) / Double(expected.count)
    let actualMean = actual.reduce(0, +) / Double(actual.count)
    var covariance = 0.0
    var expectedVariance = 0.0
    var actualVariance = 0.0
    var squaredError = 0.0
    for (a, b) in zip(expected, actual) {
      covariance += (a - expectedMean) * (b - actualMean)
      expectedVariance += pow(a - expectedMean, 2)
      actualVariance += pow(b - actualMean, 2)
      squaredError += pow(a - b, 2)
    }
    #expect(sqrt(expectedVariance / Double(expected.count)) > 0.001)
    #expect(covariance / sqrt(expectedVariance * actualVariance) > 0.98)
    #expect((0.8...1.2).contains(sqrt(actualVariance / expectedVariance)))
    #expect(sqrt(squaredError / Double(expected.count)) < 0.001)
  }
}
