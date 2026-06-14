import XCTest
import UIKit

@testable import BrightroomEngine
@testable import BrightroomParametric

final class LocalAdjustmentRenderingTests: XCTestCase {

  func testZeroRadiusLocalAdjustmentKeepsImageUnchanged() throws {
    let sourceImage = Self.makeSplitImage(width: 40, height: 20)
    let sourceCIImage = CIImage(cgImage: sourceImage)
    let layer = Self.makeBlurLayer(radius: 0, center: CGPoint(x: 20, y: 10))

    let renderedImage = try XCTUnwrap(
      Self.context.createCGImage(try layer.engineRender(over: sourceCIImage), from: sourceCIImage.extent)
    )

    XCTAssertEqual(Self.rgba(in: sourceImage, x: 5, y: 10), Self.rgba(in: renderedImage, x: 5, y: 10))
    XCTAssertEqual(Self.rgba(in: sourceImage, x: 35, y: 10), Self.rgba(in: renderedImage, x: 35, y: 10))
  }

  func testEditingPreviewAppliesFiltersAndLocalAdjustments() throws {
    let sourceImage = Self.makeSplitImage(
      width: 40,
      height: 20,
      leftWhite: 0.25,
      rightWhite: 0.75
    )
    let sourceCIImage = CIImage(cgImage: sourceImage)
    var edit = EditingStack.Edit.test(imageSize: CGSize(width: 40, height: 20))
    edit.effects = EffectPipeline(effects: [BrightnessFeature(value: 0.2)])
    edit.localAdjustments = [
      Self.makeBlurLayer(radius: 6, center: CGPoint(x: 20, y: 10)),
    ]

    let editingPreview = edit.makePreviewImage(from: sourceCIImage, purpose: .editing)
    let editingImage = try XCTUnwrap(
      Self.context.createCGImage(editingPreview, from: sourceCIImage.extent)
    )

    XCTAssertGreaterThan(
      Self.rgba(in: editingImage, x: 5, y: 10).red,
      Self.rgba(in: sourceImage, x: 5, y: 10).red
    )
  }

  func testLoadedEditingPreviewSkipsAutomaticLocalAdjustmentRasterization() throws {
    let sourceImage = Self.makeSplitImage(
      width: 40,
      height: 20,
      leftWhite: 0.25,
      rightWhite: 0.25
    )
    let sourceCIImage = CIImage(cgImage: sourceImage)
    let imageSource = ImageSource(cgImage: sourceImage)
    let initialEdit = EditingStack.Edit.test(imageSize: CGSize(width: 40, height: 20))
    var loadedState = EditingStack.Loaded(
      imageSource: imageSource,
      metadata: .init(
        orientation: .up,
        imageSize: CGSize(width: 40, height: 20)
      ),
      initialEditing: initialEdit,
      currentEdit: initialEdit,
      thumbnailCIImage: sourceCIImage,
      editingSourceCGImage: sourceImage,
      editingSourceCIImage: sourceCIImage,
      editingPreviewCIImage: initialEdit.makePreviewImage(
        from: sourceCIImage,
        purpose: .editingBase
      )
    )
    var editWithLocalAdjustment = initialEdit
    editWithLocalAdjustment.localAdjustments = [
      Self.makeExposureLayer(value: 1, center: CGPoint(x: 20, y: 10)),
    ]

    loadedState.currentEdit = editWithLocalAdjustment

    let loadedPreviewImage = try XCTUnwrap(
      Self.context.createCGImage(loadedState.editingPreviewImage, from: sourceCIImage.extent)
    )
    let fullEditingPreviewImage = try XCTUnwrap(
      Self.context.createCGImage(
        editWithLocalAdjustment.makePreviewImage(from: sourceCIImage, purpose: .editing),
        from: sourceCIImage.extent
      )
    )

    XCTAssertEqual(
      Self.rgba(in: sourceImage, x: 20, y: 10),
      Self.rgba(in: loadedPreviewImage, x: 20, y: 10)
    )
    XCTAssertGreaterThan(
      Self.rgba(in: fullEditingPreviewImage, x: 20, y: 10).red,
      Self.rgba(in: sourceImage, x: 20, y: 10).red
    )
  }

  func testExposureLocalAdjustmentAppliesOnlyInsideMask() throws {
    let sourceImage = Self.makeSplitImage(
      width: 40,
      height: 20,
      leftWhite: 0.25,
      rightWhite: 0.25
    )
    let sourceCIImage = CIImage(cgImage: sourceImage)
    let layer = Self.makeExposureLayer(value: 1, center: CGPoint(x: 20, y: 10))

    let renderedImage = try XCTUnwrap(
      Self.context.createCGImage(try layer.engineRender(over: sourceCIImage), from: sourceCIImage.extent)
    )

    XCTAssertEqual(
      Self.rgba(in: sourceImage, x: 5, y: 10),
      Self.rgba(in: renderedImage, x: 5, y: 10)
    )
    XCTAssertGreaterThan(
      Self.rgba(in: renderedImage, x: 20, y: 10).red,
      Self.rgba(in: sourceImage, x: 20, y: 10).red
    )
  }

  func testLocalAdjustmentMaskUsesDisplayYCoordinates() throws {
    let sourceImage = Self.makeSolidImage(width: 40, height: 40, white: 0.25)
    let sourceCIImage = CIImage(cgImage: sourceImage)
    let layer = Self.makeExposureLayer(value: 1, center: CGPoint(x: 20, y: 6))

    let renderedImage = try XCTUnwrap(
      Self.context.createCGImage(try layer.engineRender(over: sourceCIImage), from: sourceCIImage.extent)
    )

    // Stamps are authored in display coordinates (top-left origin, y-down),
    // matching where the user painted on the interactive canvas. `rgba(in:)`
    // reads with the same top-left origin, so the authored position is read
    // directly — no mirroring.
    let maskedPixel = Self.rgba(in: renderedImage, x: 20, y: 6)
    let mirroredPixel = Self.rgba(in: renderedImage, x: 20, y: 34)

    XCTAssertGreaterThan(maskedPixel.red, mirroredPixel.red)
  }

  func testRendererAppliesLocalAdjustmentBeforeCrop() async throws {
    let sourceImage = Self.makeSplitImage(width: 40, height: 20)
    let imageSource = ImageSource(cgImage: sourceImage)
    let renderer = BrightRoomImageRenderer(source: imageSource, orientation: .up)

    renderer.edit = .make(
      crop: CropFeature.test(
        imageSize: CGSize(width: 40, height: 20),
        cropRect: CGRect(x: 20, y: 0, width: 20, height: 20)
      ),
      orientedImageSize: CGSize(width: 40, height: 20),
      localAdjustments: [
        Self.makeBlurLayer(radius: 6, center: CGPoint(x: 20, y: 10)),
      ]
    )

    let renderedImage = try await renderer.render(
      options: .init(workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    ).cgImage
    let edgePixel = Self.rgba(in: renderedImage, x: 0, y: 10)
    let farPixel = Self.rgba(in: renderedImage, x: 19, y: 10)

    XCTAssertLessThan(edgePixel.red, 245)
    XCTAssertGreaterThan(edgePixel.red, 10)
    XCTAssertGreaterThan(farPixel.red, 245)
  }

  func testRendererComposesGlobalFilterAndLocalAdjustment() async throws {
    let sourceImage = Self.makeSplitImage(
      width: 40,
      height: 20,
      leftWhite: 0.125,
      rightWhite: 0.625
    )
    let imageSource = ImageSource(cgImage: sourceImage)
    let renderer = BrightRoomImageRenderer(source: imageSource, orientation: .up)

    renderer.edit = .make(
      crop: CropFeature.test(
        imageSize: CGSize(width: 40, height: 20),
        cropRect: CGRect(x: 0, y: 0, width: 40, height: 20)
      ),
      orientedImageSize: CGSize(width: 40, height: 20),
      effects: EffectPipeline(effects: [ExposureFeature(value: 0.5)]),
      localAdjustments: [
        Self.makeBlurLayer(radius: 6, center: CGPoint(x: 20, y: 10)),
      ]
    )

    let renderedImage = try await renderer.render(
      options: .init(workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    ).cgImage
    let edgePixel = Self.rgba(in: renderedImage, x: 20, y: 10)
    let farPixel = Self.rgba(in: renderedImage, x: 35, y: 10)

    XCTAssertGreaterThan(farPixel.red, 160)
    XCTAssertGreaterThan(edgePixel.red, 60)
    XCTAssertLessThan(edgePixel.red, farPixel.red)
  }

  private static let context = CIContext()

  private static func makeBlurLayer(
    radius: CGFloat,
    center: CGPoint
  ) -> LocalAdjustmentFeature {
    .init(
      maskTree: MaskTree(
        root: .brush(
          BrushMask(
            strokes: [
              BrushMaskStroke(
                stamps: [center],
                brush: BrushMaskBrush(diameter: 18, hardness: 1, opacity: 1)
              ),
            ]
          )
        )
      ),
      effectPipeline: EffectPipeline(effects: [GaussianBlurFeature(radius: Double(radius))])
    )
  }

  private static func makeExposureLayer(
    value: Double,
    center: CGPoint
  ) -> LocalAdjustmentFeature {
    .init(
      maskTree: MaskTree(
        root: .brush(
          BrushMask(
            strokes: [
              BrushMaskStroke(
                stamps: [center],
                brush: BrushMaskBrush(diameter: 18, hardness: 1, opacity: 1)
              ),
            ]
          )
        )
      ),
      effectPipeline: EffectPipeline(effects: [ExposureFeature(value: value)])
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
