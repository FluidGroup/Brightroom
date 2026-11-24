import CoreGraphics
import CoreImage
import Testing

// Public API only: this file plays the role of a host app that builds the
// editor's global effects. It must not need `@testable` access.
import BrightroomParametric
import BrightroomUI

/// `ImageEditorFeature.Effects`: its initializers and its evaluation order.
struct ImageEditorEffectsTests {

  private static let imageSize = CGSize(width: 160, height: 120)

  /// `effects` in the order given, then `crop`: the explicit order the
  /// editor's feature is checked against.
  private struct InOrder: Feature {
    var effects: [AnyImageEffect]
    var crop: CropFeature

    var body: some Feature {
      effects
      crop
    }
  }

  /// `blacks` follows `contrast`, and `clarity` then `texture` follow
  /// `colorGrading`, before `sharpen` and the final crop.
  @Test func `Global effects render in the order of their body`() throws {
    let exposure = ExposureFeature(ev: 0.4)
    let shadows = ShadowsFeature(value: 0.3)
    let contrast = ContrastFeature(value: 0.1)
    let blacks = BlacksFeature(amount: -40)
    let colorGrading = ColorGradingFeature(
      shadows: .init(hue: 220, saturation: 40),
      highlights: .init(hue: 40, saturation: 30)
    )
    let clarity = ClarityFeature(amount: 60)
    let texture = TextureFeature(amount: 50)
    let sharpen = SharpenFeature(intensity: 0.6, radius: .absolute(2))
    let crop = CropFeature(
      topLeftRect: CGRect(x: 16, y: 12, width: 128, height: 96),
      imageSize: Self.imageSize
    )
    let feature = ImageEditorFeature(
      effects: .init(
        exposure: exposure,
        shadows: shadows,
        contrast: contrast,
        blacks: blacks,
        colorGrading: colorGrading,
        clarity: clarity,
        texture: texture,
        sharpen: sharpen
      ),
      crop: crop
    )

    let source = Self.makeSource()
    let renderer = FeatureRenderer()
    let actual = try renderer.makeImage(from: source, feature: feature)
    let expected = try renderer.makeImage(
      from: source,
      feature: InOrder(
        effects: [
          .init(exposure), .init(shadows), .init(contrast), .init(blacks),
          .init(colorGrading), .init(clarity), .init(texture), .init(sharpen),
        ],
        crop: crop
      )
    )
    #expect(actual.extent == expected.extent)
    #expect(actual.extent.size == CGSize(width: 128, height: 96))
    #expect(Self.maxDifference(actual, expected) == 0)

    // The order is visible: blacks, clarity and texture before the other
    // adjustments render other pixels.
    let reordered = try renderer.makeImage(
      from: source,
      feature: InOrder(
        effects: [
          .init(blacks), .init(clarity), .init(texture), .init(exposure),
          .init(shadows), .init(contrast), .init(colorGrading), .init(sharpen),
        ],
        crop: crop
      )
    )
    #expect(reordered.extent == expected.extent)
    #expect(Self.maxDifference(actual, reordered) > 4)
  }

  /// Every initializer can be named in full, and builds the empty effects
  /// from nils.
  @Test func `Every initializer resolves by its full name`() {
    let plain = ImageEditorFeature.Effects.init(
      preset:exposure:brightness:whiteBalance:highlights:shadows:saturation:contrast:
      sharpen:unsharpMask:gaussianBlur:fade:custom:
    )
    let grading = ImageEditorFeature.Effects.init(
      preset:exposure:brightness:whiteBalance:highlights:shadows:saturation:contrast:
      colorGrading:sharpen:unsharpMask:gaussianBlur:fade:custom:
    )
    let grain = ImageEditorFeature.Effects.init(
      preset:exposure:brightness:whiteBalance:highlights:shadows:saturation:contrast:
      colorGrading:sharpen:unsharpMask:gaussianBlur:fade:grain:custom:
    )
    let every = ImageEditorFeature.Effects.init(
      preset:exposure:brightness:whiteBalance:highlights:shadows:saturation:contrast:
      blacks:colorGrading:clarity:texture:sharpen:unsharpMask:gaussianBlur:fade:grain:custom:
    )

    #expect(plain(nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, []) == .init())
    #expect(grading(nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, []) == .init())
    #expect(grain(nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, []) == .init())
    #expect(
      every(nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, [])
        == .init()
    )
    #expect(ImageEditorFeature.Effects(grain: nil) == .init())
  }

  @Test func `The all-member initializer sets each member it is given`() {
    let named = ImageEditorFeature.Effects(
      blacks: BlacksFeature(amount: -30),
      clarity: ClarityFeature(amount: 40),
      texture: TextureFeature(amount: 20)
    )
    var assigned = ImageEditorFeature.Effects()
    assigned.blacks = BlacksFeature(amount: -30)
    assigned.clarity = ClarityFeature(amount: 40)
    assigned.texture = TextureFeature(amount: 20)
    #expect(named == assigned)
    #expect(named != .init())

    let preset = FilterFeature(name: "Look", id: "look", effects: [AnyImageEffect(FadeFeature(intensity: 0.2))])
    let custom = [AnyImageEffect(ExposureFeature(ev: -0.2))]
    let every = ImageEditorFeature.Effects(
      preset: preset,
      exposure: ExposureFeature(ev: 0.5),
      brightness: BrightnessFeature(value: 0.1),
      whiteBalance: WhiteBalanceFeature(temperature: 300, tint: 10),
      highlights: HighlightsFeature(value: 0.4),
      shadows: ShadowsFeature(value: 0.3),
      saturation: SaturationFeature(value: 1.2),
      contrast: ContrastFeature(value: 0.1),
      blacks: BlacksFeature(amount: -30),
      colorGrading: ColorGradingFeature(global: .init(hue: 40, saturation: 20)),
      clarity: ClarityFeature(amount: 40),
      texture: TextureFeature(amount: 20),
      sharpen: SharpenFeature(intensity: 0.4, radius: .proportional(1)),
      unsharpMask: UnsharpMaskFeature(intensity: 0.5, radius: .proportional(2)),
      gaussianBlur: GaussianBlurFeature(radius: .proportional(10)),
      fade: FadeFeature(intensity: 0.3),
      grain: GrainFeature.CameraRaw(amount: 20),
      custom: custom
    )
    var everyAssigned = assigned
    everyAssigned.preset = preset
    everyAssigned.exposure = ExposureFeature(ev: 0.5)
    everyAssigned.brightness = BrightnessFeature(value: 0.1)
    everyAssigned.whiteBalance = WhiteBalanceFeature(temperature: 300, tint: 10)
    everyAssigned.highlights = HighlightsFeature(value: 0.4)
    everyAssigned.shadows = ShadowsFeature(value: 0.3)
    everyAssigned.saturation = SaturationFeature(value: 1.2)
    everyAssigned.contrast = ContrastFeature(value: 0.1)
    everyAssigned.colorGrading = ColorGradingFeature(global: .init(hue: 40, saturation: 20))
    everyAssigned.sharpen = SharpenFeature(intensity: 0.4, radius: .proportional(1))
    everyAssigned.unsharpMask = UnsharpMaskFeature(intensity: 0.5, radius: .proportional(2))
    everyAssigned.gaussianBlur = GaussianBlurFeature(radius: .proportional(10))
    everyAssigned.fade = FadeFeature(intensity: 0.3)
    everyAssigned.grain = GrainFeature.CameraRaw(amount: 20)
    everyAssigned.custom = custom
    #expect(every == everyAssigned)
  }

  // MARK: - Helpers

  private static func makeSource() -> CIImage {
    let extent = CGRect(origin: .zero, size: imageSize)
    let gradient = CIFilter(
      name: "CILinearGradient",
      parameters: [
        "inputPoint0": CIVector(x: 0, y: 0),
        "inputPoint1": CIVector(x: imageSize.width, y: imageSize.height),
        "inputColor0": CIColor(red: 0.05, green: 0.1, blue: 0.15),
        "inputColor1": CIColor(red: 0.9, green: 0.8, blue: 0.7),
      ]
    )!.outputImage!
    // A checkerboard gives the local contrast effects edges to change; they
    // leave a bare gradient almost untouched.
    let checker = CIFilter(
      name: "CICheckerboardGenerator",
      parameters: [
        "inputCenter": CIVector(x: 0, y: 0),
        "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 0.4),
        "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0),
        "inputWidth": 12,
        "inputSharpness": 1,
      ]
    )!.outputImage!
    return checker.composited(over: gradient).cropped(to: extent)
  }

  /// The largest 8-bit sRGB channel difference between two images of the
  /// same extent.
  private static func maxDifference(_ lhs: CIImage, _ rhs: CIImage) -> Int {
    let context = CIContext()
    func bytes(_ image: CIImage) -> [UInt8] {
      let width = Int(image.extent.width)
      let height = Int(image.extent.height)
      var buffer = [UInt8](repeating: 0, count: width * height * 4)
      context.render(
        image,
        toBitmap: &buffer,
        rowBytes: width * 4,
        bounds: image.extent,
        format: .RGBA8,
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
      )
      return buffer
    }
    return zip(bytes(lhs), bytes(rhs)).map { abs(Int($0) - Int($1)) }.max() ?? -1
  }
}
