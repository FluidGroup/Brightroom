import CoreGraphics
import CoreImage
import Testing

// Public API only: this file plays the role of a host app that adds an
// effect of its own to the editor's feature. It must not need `@testable`
// access.
import BrightroomEngine
import BrightroomParametric
import BrightroomUI

/// `ImageEditorFeature.Effects.custom`: effects of the host's own, evaluated
/// after the built-in adjustments and before the local blur and the final
/// crop.
struct ImageEditorCustomEffectsTests {

  private static let imageSize = CGSize(width: 64, height: 48)

  /// A feature with `first`, then `second`, then the crop: the explicit
  /// order a custom effect is checked against.
  private struct TwoEffects: Feature {
    var first: AnyImageEffect
    var second: AnyImageEffect
    var crop: CropFeature

    var body: some Feature {
      first
      second
      crop
    }
  }

  @Test func `Custom effects evaluate after the built-in adjustments and before the crop`() throws {
    let brightness = BrightnessFeature(value: 0.2)
    let exposure = ExposureFeature(ev: 1)
    let crop = CropFeature(
      topLeftRect: CGRect(x: 8, y: 4, width: 40, height: 32),
      imageSize: Self.imageSize
    )
    let feature = ImageEditorFeature(
      effects: .init(brightness: brightness, custom: [AnyImageEffect(exposure)]),
      crop: crop
    )

    let source = Self.makeSource()
    let renderer = FeatureRenderer()
    let actual = try renderer.makeImage(from: source, feature: feature)
    let expected = try renderer.makeImage(
      from: source,
      feature: TwoEffects(first: AnyImageEffect(brightness), second: AnyImageEffect(exposure), crop: crop)
    )
    #expect(actual.extent == expected.extent)
    #expect(actual.extent.size == CGSize(width: 40, height: 32))
    #expect(Self.maxDifference(actual, expected) == 0)

    // The order is visible: the custom exposure before the built-in
    // brightness renders other pixels.
    let reversed = try renderer.makeImage(
      from: source,
      feature: TwoEffects(first: AnyImageEffect(exposure), second: AnyImageEffect(brightness), crop: crop)
    )
    #expect(reversed.extent == expected.extent)
    #expect(Self.maxDifference(actual, reversed) > 8)
  }

  @Test func `A feature with custom effects compares by their values`() {
    let crop = CropFeature(rect: CGRect(origin: .zero, size: Self.imageSize))
    let built = ImageEditorFeature(
      effects: .init(custom: [AnyImageEffect(ExposureFeature(ev: 1))]),
      crop: crop
    )
    var assigned = ImageEditorFeature(crop: crop)
    assigned.effects.custom = [AnyImageEffect(ExposureFeature(ev: 1))]
    #expect(built == assigned)

    assigned.effects.custom = [AnyImageEffect(ExposureFeature(ev: 2))]
    #expect(built != assigned)
    #expect(ImageEditorFeature.Effects() == ImageEditorFeature.Effects(custom: []))
  }

  // MARK: - Helpers

  private static func makeSource() -> CIImage {
    CIFilter(
      name: "CILinearGradient",
      parameters: [
        "inputPoint0": CIVector(x: 0, y: 0),
        "inputPoint1": CIVector(x: imageSize.width, y: imageSize.height),
        "inputColor0": CIColor(red: 0.1, green: 0.2, blue: 0.3),
        "inputColor1": CIColor(red: 0.6, green: 0.5, blue: 0.4),
      ]
    )!.outputImage!.cropped(to: CGRect(origin: .zero, size: imageSize))
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
