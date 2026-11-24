import CoreGraphics
import CoreImage
import Foundation
import Metal
import Testing

@testable import BrightroomEngine
import BrightroomParametric
@testable import BrightroomUI

/// `GrayPoint`: the white balance that makes a clicked area neutral, solved in the canvas working
/// space over the preview as the area enters `effects.whiteBalance`, and the clicks it rejects.
@MainActor
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct GrayPointTests {

  typealias SRGB = (red: UInt8, green: UInt8, blue: UInt8)

  /// The pixel size of the small fixtures.
  private static let imageSize = CGSize(width: 64, height: 48)

  /// A feature that keeps the whole of a small fixture and changes nothing.
  private static let wholeImage = ImageEditorFeature(
    crop: CropFeature(rect: CGRect(origin: .zero, size: imageSize))
  )

  /// The ranges `solve` stays within by default.
  private static let temperatureRange: ClosedRange<Double> = -3000...3000
  private static let tintRange: ClosedRange<Double> = -100...100

  /// A context in the canvas's working space, which the gray point solves in.
  private static let context: CIContext = {
    let options: [CIContextOption: Any] = [
      .workingColorSpace: EditingCanvasImageProcessing.workingColorSpace,
      .workingFormat: EditingCanvasImageProcessing.workingFormat,
      .cacheIntermediates: false,
    ]
    if let device = MTLCreateSystemDefaultDevice() {
      return CIContext(mtlDevice: device, options: options)
    }
    return CIContext(options: options)
  }()

  // MARK: - Solving a colour

  @Test func `A gray under a warm magenta cast is made neutral`() throws {
    let cast = try Self.render(SIMD3(repeating: 0.18), through: WhiteBalanceFeature(temperature: 1200, tint: 25))
    let balance = try #require(Self.whiteBalance(neutralizing: cast))
    let balanced = try Self.render(cast, through: balance)

    #expect(abs(balanced.x / balanced.y - 1) < 2e-3, "red / green \(balanced.x / balanced.y)")
    #expect(abs(balanced.z / balanced.y - 1) < 2e-3, "blue / green \(balanced.z / balanced.y)")
  }

  @Test func `A neutral colour needs no white balance`() {
    #expect(Self.whiteBalance(neutralizing: SIMD3(repeating: 0.18)) == nil)
    #expect(Self.whiteBalance(neutralizing: SIMD3(repeating: 0.7)) == nil)
  }

  @Test func `A cast beyond the ranges is balanced as far as they allow`() throws {
    let cast = try Self.render(SIMD3(repeating: 0.18), through: WhiteBalanceFeature(temperature: -2500, tint: -60))
    let balance = try #require(Self.whiteBalance(neutralizing: cast))

    #expect(balance.temperature == Self.temperatureRange.upperBound)
    #expect(Self.tintRange.contains(balance.tint))
  }

  @Test func `Ranges that leave out neutral are kept, even for a neutral colour`() throws {
    // The colour is balanced at the nearest temperature the range allows, not left without one.
    let balance = try #require(
      GrayPoint.whiteBalance(
        neutralizing: SIMD3(repeating: 0.18),
        temperatureRange: 200...400,
        tintRange: Self.tintRange,
        context: Self.context
      )
    )

    #expect(balance.temperature == 200)
    #expect(Self.tintRange.contains(balance.tint))
  }

  // MARK: - Solving a click

  @Test func `A click sets the white balance that makes the clicked area neutral as the canvas shows it`() async throws {
    // A turned crop, an exposure evaluated before white balance, and a white balance the result
    // replaces, so it is not measured.
    var feature = Self.wholeImage
    feature.crop.quarterTurn = .counterclockwise90
    feature.effects.exposure = ExposureFeature(ev: 0.4)
    feature.effects.whiteBalance = WhiteBalanceFeature(temperature: 900, tint: -30)
    let previewSource = try await Self.previewSource(of: SourceImage(cgImage: Self.quadrantImage()))

    // The turn brings the top-right quadrant to the top left of the output.
    let result = await GrayPoint.solve(at: CGPoint(x: 12, y: 16), in: feature, over: previewSource)
    let balance = try #require(try result.get())

    // The top-right quadrant of the preview (bottom-left origin), rendered as the canvas renders
    // it up to white balance.
    let color = try Self.averageColor(
      of: ImageEditorFeature.Effects(exposure: feature.effects.exposure, whiteBalance: balance),
      over: previewSource,
      in: CGRect(x: 45, y: 33, width: 7, height: 7)
    )
    #expect(abs(color.x / color.y - 1) < 4e-3, "red / green \(color.x / color.y)")
    #expect(abs(color.z / color.y - 1) < 4e-3, "blue / green \(color.z / color.y)")
  }

  @Test func `A click on a neutral area needs no white balance`() async throws {
    let previewSource = try await Self.previewSource(of: SourceImage(cgImage: Self.solidImage((128, 128, 128))))

    let result = await Self.solve(at: CGPoint(x: 32, y: 24), of: Self.wholeImage, over: previewSource)
    #expect(result == .success(nil))
  }

  @Test func `A click on a dark or clipped area is rejected`() async throws {
    let cases: [(SRGB, GrayPoint.Rejection)] = [
      ((0, 0, 0), .tooDark),
      ((6, 6, 6), .tooDark),
      ((255, 255, 255), .tooBright),
      ((255, 255, 240), .tooBright),
    ]
    for (color, rejection) in cases {
      let previewSource = try await Self.previewSource(of: SourceImage(cgImage: Self.solidImage(color)))

      let result = await Self.solve(at: CGPoint(x: 32, y: 24), of: Self.wholeImage, over: previewSource)
      #expect(result == .failure(rejection), "\(color)")
    }
  }

  @Test func `A click on an area whose colour is not finite is rejected`() async throws {
    // A float preview whose left half is NaN, as a float image's can be. NaN fails every
    // comparison of the darkness and clipping checks.
    let width = Int(Self.imageSize.width)
    let height = Int(Self.imageSize.height)
    var floats = [Float](repeating: 1, count: width * height * 4)
    for index in 0..<(width * height) {
      let value: Float = index % width < width / 2 ? .nan : 0.18
      floats[index * 4] = value
      floats[index * 4 + 1] = value
      floats[index * 4 + 2] = value
    }
    let image = CIImage(
      bitmapData: floats.withUnsafeBytes { Data($0) },
      bytesPerRow: width * 16,
      size: Self.imageSize,
      format: .RGBAf,
      colorSpace: EditingCanvasImageProcessing.workingColorSpace
    )
    let source = SourceImage(cgImage: try DocumentTestFixtures.makeCGImage(width: width, height: height))
    let previewSource = PreviewSource(source: source, thumbnail: image, image: image)
    // Solved as neutral, the click would remove this white balance.
    var feature = Self.wholeImage
    feature.effects.whiteBalance = WhiteBalanceFeature(temperature: 900, tint: -30)

    let result = await Self.solve(at: CGPoint(x: 10, y: 24), of: feature, over: previewSource)
    #expect(result == .failure(.outsideImage))
  }

  @Test func `A click off the crop output or off the image is rejected`() async throws {
    let previewSource = try await Self.previewSource(of: SourceImage(cgImage: Self.solidImage((128, 128, 128))))

    for point in [CGPoint(x: -1, y: 24), CGPoint(x: 64, y: 24), CGPoint(x: 32, y: 48)] {
      let result = await Self.solve(at: point, of: Self.wholeImage, over: previewSource)
      #expect(result == .failure(.outsideImage), "\(point)")
    }

    // The right half: its output is 32 points wide.
    let rightHalf = ImageEditorFeature(crop: CropFeature(rect: CGRect(x: 32, y: 0, width: 32, height: 48)))
    #expect(await Self.solve(at: CGPoint(x: 10, y: 10), of: rightHalf, over: previewSource) == .success(nil))
    #expect(await Self.solve(at: CGPoint(x: 40, y: 10), of: rightHalf, over: previewSource) == .failure(.outsideImage))
  }

  @Test func `A solved click stays within the ranges a host passes`() async throws {
    // The top-left quadrant's warm cast needs more than 300 K.
    let previewSource = try await Self.previewSource(of: SourceImage(cgImage: Self.quadrantImage()))
    let point = CGPoint(x: 16, y: 12)
    let unbounded = try #require(try await GrayPoint.solve(at: point, in: Self.wholeImage, over: previewSource).get())
    #expect(abs(unbounded.temperature) > 300, "\(unbounded)")

    let result = await GrayPoint.solve(
      at: point,
      in: Self.wholeImage,
      over: previewSource,
      temperatureRange: -300...300,
      tintRange: -1...1
    )
    let bounded = try #require(try result.get())

    #expect(bounded.temperature == (unbounded.temperature < 0 ? -300 : 300))
    #expect((-1...1).contains(bounded.tint))
  }

  @Test func `The effects before white balance are measured with the rendering passed`() async throws {
    // Four stops lift this dark gray clear of the darkness check; a rendering whose exposure
    // changes nothing leaves it too dark.
    let previewSource = try await Self.previewSource(of: SourceImage(cgImage: Self.solidImage((6, 6, 6))))
    var exposed = Self.wholeImage
    exposed.effects.exposure = ExposureFeature(ev: 4)
    let point = CGPoint(x: 32, y: 24)

    #expect(await GrayPoint.solve(at: point, in: exposed, over: previewSource) == .success(nil))
    let ignored = await GrayPoint.solve(
      at: point,
      in: exposed,
      over: previewSource,
      adjustmentRendering: Self.exposureIgnored
    )
    #expect(ignored == .failure(.tooDark))
  }

  // MARK: - The measured effects

  @Test func `The effects before white balance are those its body evaluates first`() throws {
    let effects = ImageEditorFeature.Effects(
      preset: FilterFeature(
        name: "Warm",
        id: "warm",
        effects: [AnyImageEffect(BrightnessFeature(value: 0.1))]
      ),
      exposure: ExposureFeature(ev: 0.5),
      brightness: BrightnessFeature(value: 0.1),
      whiteBalance: WhiteBalanceFeature(temperature: 600, tint: -20),
      highlights: HighlightsFeature(value: 0.3),
      shadows: ShadowsFeature(value: -0.2),
      saturation: SaturationFeature(value: 0.5),
      contrast: ContrastFeature(value: 0.1),
      blacks: BlacksFeature(amount: -30),
      colorGrading: ColorGradingFeature(midtones: .init(hue: 200, saturation: 40)),
      clarity: ClarityFeature(amount: 25),
      texture: TextureFeature(amount: -15),
      sharpen: SharpenFeature(intensity: 0.4, radius: .absolute(2)),
      unsharpMask: UnsharpMaskFeature(intensity: 0.5, radius: .absolute(3)),
      gaussianBlur: GaussianBlurFeature(radius: .proportional(10)),
      fade: FadeFeature(intensity: 0.2),
      grain: GrainFeature.CameraRaw(amount: 20, size: 40, roughness: 60, seed: 7),
      custom: [AnyImageEffect(ExposureFeature(ev: 1))]
    )
    // Every member is set, so a member added to `Effects` fails here until it is set too; then
    // `bodyOrder` lists it, and one evaluated before `whiteBalance` must join
    // `effectsBeforeWhiteBalance(_:)`.
    let unset = Mirror(reflecting: effects).children.compactMap { child -> String? in
      let value = Mirror(reflecting: child.value)
      let isOptionalOrArray = value.displayStyle == .optional || value.displayStyle == .collection
      return isOptionalOrArray && value.children.isEmpty ? child.label : nil
    }
    #expect(unset.isEmpty, "Set these members here: \(unset)")
    let bodyOrder = FeatureTreeNode.nodes(for: effects).map(\.typeName)
    let whiteBalance = try #require(bodyOrder.firstIndex(of: "WhiteBalanceFeature"))
    let measured = GrayPoint.effectsBeforeWhiteBalance(effects)

    #expect(FeatureTreeNode.nodes(for: measured).map(\.typeName) == Array(bodyOrder[..<whiteBalance]))
    #expect(
      measured == ImageEditorFeature.Effects(
        preset: effects.preset,
        exposure: effects.exposure,
        brightness: effects.brightness
      )
    )
  }

  // MARK: - Helpers

  /// The preview of `source`, prepared as the editors prepare it.
  private static func previewSource(of source: SourceImage) async throws -> PreviewSource {
    let loader = PreviewSourceLoader(source: source)
    await loader.load()
    return try #require(loader.previewSource)
  }

  private static func solve(
    at point: CGPoint,
    of feature: ImageEditorFeature,
    over previewSource: PreviewSource
  ) async -> Result<WhiteBalanceFeature?, GrayPoint.Rejection> {
    await GrayPoint.solve(at: point, in: feature, over: previewSource)
  }

  /// The white balance that makes `color` neutral within the default ranges.
  private static func whiteBalance(neutralizing color: SIMD3<Double>) -> WhiteBalanceFeature? {
    GrayPoint.whiteBalance(
      neutralizing: color,
      temperatureRange: temperatureRange,
      tintRange: tintRange,
      context: context
    )
  }

  /// A rendering whose exposure leaves the image as it is.
  private static let exposureIgnored: AdjustmentRendering = {
    var setup = AdjustmentRendering.Setup()
    setup.replace(
      ExposureFeature.self,
      with: .init(identity: .init(implementation: "test.exposure-ignored", version: "1", configuration: "")) { _, image, _ in
        image
      }
    )
    return setup.makeRendering()
  }()

  /// `color` (working-space RGB) after `balance`, in the working space.
  private static func render(_ color: SIMD3<Double>, through balance: WhiteBalanceFeature) throws -> SIMD3<Double> {
    let components: [Float] = [Float(color.x), Float(color.y), Float(color.z), 1]
    let image = CIImage(
      bitmapData: components.withUnsafeBytes { Data($0) },
      bytesPerRow: 16,
      size: CGSize(width: 1, height: 1),
      format: .RGBAf,
      colorSpace: EditingCanvasImageProcessing.workingColorSpace
    )
    return read(try balance.apply(to: image, context: FeatureEvaluationContext()))
  }

  /// The working-space colour of `effects`' output over the preview, averaged over `rect` (preview
  /// pixels, bottom-left origin), evaluated as the canvas evaluates it.
  private static func averageColor(
    of effects: ImageEditorFeature.Effects,
    over previewSource: PreviewSource,
    in rect: CGRect
  ) throws -> SIMD3<Double> {
    let preview = previewSource.image
    let output = try effects.apply(
      to: preview,
      context: FeatureEvaluationContext(
        chainEntryExtent: preview.extent,
        renderScale: EditingCanvasRenderImageFactory.renderScale(
          evaluated: preview.extent.size,
          fullResolution: previewSource.source.pixelSize
        )
      )
    )
    return read(output.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)]))
  }

  /// The pixel at the origin of `image`, in the working space.
  private static func read(_ image: CIImage) -> SIMD3<Double> {
    var pixel = [Float](repeating: 0, count: 4)
    context.render(
      image,
      toBitmap: &pixel,
      rowBytes: 16,
      bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
      format: .RGBAf,
      colorSpace: nil
    )
    return SIMD3(Double(pixel[0]), Double(pixel[1]), Double(pixel[2]))
  }

  // MARK: - Fixtures

  /// A 64 × 48 sRGB image of one colour.
  private static func solidImage(_ color: SRGB) throws -> CGImage {
    try DocumentTestFixtures.makeCGImage(
      width: Int(imageSize.width),
      height: Int(imageSize.height),
      color: CGColor(
        srgbRed: CGFloat(color.red) / 255,
        green: CGFloat(color.green) / 255,
        blue: CGFloat(color.blue) / 255,
        alpha: 1
      )
    )
  }

  /// A 64 × 48 sRGB image whose first row is its top, with a quadrant of each of four mild casts:
  /// warm at the top left, cool at the top right, green at the bottom left and magenta at the
  /// bottom right.
  private static func quadrantImage() throws -> CGImage {
    let width = Int(imageSize.width)
    let height = Int(imageSize.height)
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for row in 0..<height {
      for column in 0..<width {
        let color: SRGB = switch (row < height / 2, column < width / 2) {
        case (true, true): (140, 128, 112)
        case (true, false): (120, 128, 140)
        case (false, true): (118, 135, 118)
        case (false, false): (135, 118, 132)
        }
        let offset = (row * width + column) * 4
        bytes[offset] = color.red
        bytes[offset + 1] = color.green
        bytes[offset + 2] = color.blue
      }
    }
    let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
    let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    return try #require(CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: width * 4,
      space: sRGB,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    ))
  }
}
