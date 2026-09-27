import Testing
import Foundation
import UIKit

@testable import BrightroomEngine
@testable import BrightroomParametric

struct LocalAdjustmentRenderingTests {

  @Test func `Zero radius local adjustment keeps image unchanged`() throws {
    let sourceImage = Self.makeSplitImage(width: 40, height: 20)
    let sourceCIImage = CIImage(cgImage: sourceImage)
    let layer = Self.makeBlurLayer(radius: 0, center: CGPoint(x: 20, y: 10))

    let renderedImage = try #require(
      Self.context.createCGImage(try layer.apply(to: sourceCIImage, context: FeatureEvaluationContext()), from: sourceCIImage.extent)
    )

    #expect(Self.rgba(in: sourceImage, x: 5, y: 10) == Self.rgba(in: renderedImage, x: 5, y: 10))
    #expect(Self.rgba(in: sourceImage, x: 35, y: 10) == Self.rgba(in: renderedImage, x: 35, y: 10))
  }

  @Test func `Exposure local adjustment applies only inside mask`() throws {
    let sourceImage = Self.makeSplitImage(
      width: 40,
      height: 20,
      leftWhite: 0.25,
      rightWhite: 0.25
    )
    let sourceCIImage = CIImage(cgImage: sourceImage)
    let layer = Self.makeExposureLayer(value: 1, center: CGPoint(x: 20, y: 10))

    let renderedImage = try #require(
      Self.context.createCGImage(try layer.apply(to: sourceCIImage, context: FeatureEvaluationContext()), from: sourceCIImage.extent)
    )

    #expect(
      Self.rgba(in: sourceImage, x: 5, y: 10) == Self.rgba(in: renderedImage, x: 5, y: 10)
    )
    #expect(
      Self.rgba(in: renderedImage, x: 20, y: 10).red > Self.rgba(in: sourceImage, x: 20, y: 10).red
    )
  }

  @Test func `Local adjustment mask uses working space Y coordinates`() throws {
    let sourceImage = Self.makeSolidImage(width: 40, height: 40, white: 0.25)
    let sourceCIImage = CIImage(cgImage: sourceImage)
    let layer = Self.makeExposureLayer(value: 1, center: CGPoint(x: 20, y: 6))

    let renderedImage = try #require(
      Self.context.createCGImage(
        try layer.apply(to: sourceCIImage, context: FeatureEvaluationContext()),
        from: sourceCIImage.extent
      )
    )

    // Stamps are stored in BrightroomParametric's working space (bottom-left
    // origin, y-up). `rgba(in:)` reads with a top-left origin, so a stamp at
    // working y = 6 lands on display row 40 - 6 = 34.
    let maskedPixel = Self.rgba(in: renderedImage, x: 20, y: 34)
    let mirroredPixel = Self.rgba(in: renderedImage, x: 20, y: 6)

    #expect(maskedPixel.red > mirroredPixel.red)
  }

  @Test func `Renderer applies local adjustment before crop`() async throws {
    let sourceImage = Self.makeSplitImage(width: 40, height: 20)
    let imageSource = SourceImage(cgImage: sourceImage)
    let renderer = EditingDocument(image: imageSource, feature: RendererTestDocument(localAdjustments: [
        Self.makeBlurLayer(radius: 6, center: CGPoint(x: 20, y: 10)),
      ], crop: CropFeature.test(
        imageSize: CGSize(width: 40, height: 20),
        cropRect: CGRect(x: 20, y: 0, width: 20, height: 20)
      ))
    )

    let renderedImage = try await renderer.render(
      options: .init(outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    ).cgImage
    let edgePixel = Self.rgba(in: renderedImage, x: 0, y: 10)
    let farPixel = Self.rgba(in: renderedImage, x: 19, y: 10)

    #expect(edgePixel.red < 245)
    #expect(edgePixel.red > 10)
    #expect(farPixel.red > 245)
  }

  @Test func `Renderer composes global filter and local adjustment`() async throws {
    let sourceImage = Self.makeSplitImage(
      width: 40,
      height: 20,
      leftWhite: 0.125,
      rightWhite: 0.625
    )
    let imageSource = SourceImage(cgImage: sourceImage)
    let renderer = EditingDocument(image: imageSource, feature: RendererTestDocument(effects: [AnyImageEffect(ExposureFeature(value: 0.5))], localAdjustments: [
        Self.makeBlurLayer(radius: 6, center: CGPoint(x: 20, y: 10)),
      ], crop: CropFeature.test(
        imageSize: CGSize(width: 40, height: 20),
        cropRect: CGRect(x: 0, y: 0, width: 40, height: 20)
      ))
    )

    let renderedImage = try await renderer.render(
      options: .init(outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    ).cgImage
    let edgePixel = Self.rgba(in: renderedImage, x: 20, y: 10)
    let farPixel = Self.rgba(in: renderedImage, x: 35, y: 10)

    #expect(farPixel.red > 160)
    #expect(edgePixel.red > 60)
    #expect(edgePixel.red < farPixel.red)
  }

  private static let context = CIContext()

  private static func makeBlurLayer(
    radius: CGFloat,
    center: CGPoint
  ) -> LocalAdjustmentFeature<[AnyImageEffect]> {
    LocalAdjustmentFeature(mask: makeMask(center: center)) {
      [AnyImageEffect(GaussianBlurFeature(radius: Double(radius)))]
    }
  }

  private static func makeExposureLayer(
    value: Double,
    center: CGPoint
  ) -> LocalAdjustmentFeature<[AnyImageEffect]> {
    LocalAdjustmentFeature(mask: makeMask(center: center)) {
      [AnyImageEffect(ExposureFeature(value: value))]
    }
  }

  /// A hard 18 px stamp at `center`, in working space (y-up).
  private static func makeMask(center: CGPoint) -> Mask {
    .brush(
      BrushMask(
        strokes: [
          BrushMask.Stroke(
            stampCenters: [center],
            brush: BrushMask.Brush(diameter: 18, hardness: 1, opacity: 1)
          ),
        ]
      )
    )
  }

  private static func makeSplitImage(
    width: Int,
    height: Int,
    leftWhite: CGFloat = 0,
    rightWhite: CGFloat = 1
  ) -> CGImage {
    let size = CGSize(width: width, height: height)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true

    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
      UIColor(white: leftWhite, alpha: 1).setFill()
      UIRectFill(CGRect(origin: .zero, size: size))
      UIColor(white: rightWhite, alpha: 1).setFill()
      UIRectFill(CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height))
    }.cgImage!
  }

  private static func makeSolidImage(
    width: Int,
    height: Int,
    white: CGFloat
  ) -> CGImage {
    let size = CGSize(width: width, height: height)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true

    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
      UIColor(white: white, alpha: 1).setFill()
      UIRectFill(CGRect(origin: .zero, size: size))
    }.cgImage!
  }

  private static func rgba(in image: CGImage, x: Int, y: Int) -> RGBA {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    let clampedX = min(max(x, 0), width - 1)
    let clampedY = min(max(y, 0), height - 1)
    let offset = (clampedY * width + clampedX) * 4
    return RGBA(
      red: pixels[offset],
      green: pixels[offset + 1],
      blue: pixels[offset + 2],
      alpha: pixels[offset + 3]
    )
  }

  private struct RGBA: Equatable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var alpha: UInt8
  }
}
