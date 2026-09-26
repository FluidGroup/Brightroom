import CoreGraphics
import CoreImage
import UIKit

@testable import BrightroomEngine
@testable import BrightroomParametric
@testable import BrightroomUI

extension CropFeature {

  /// Test helper mirroring the old `EditingCrop(imageSize:cropRect:rotation:)`:
  /// builds a crop from a y-down display rect through the shared engine snapper
  /// (`CropFeature(displayCropRect:imageSize:…)`), so tests author crops in the
  /// same top-left-origin space they used before the parametric migration.
  static func test(
    imageSize: CGSize,
    cropRect: CGRect? = nil,
    rotation: QuarterTurn = .zero,
    straighten: Double = 0
  ) -> CropFeature {
    CropFeature(
      displayCropRect: cropRect ?? CGRect(origin: .zero, size: imageSize),
      imageSize: imageSize,
      rotation: rotation,
      straighten: straighten
    )
  }
}

/// A general document for renderer tests: ordered global effects, local
/// adjustments, then a crop.
///
/// It replaces the old `BrightRoomImageRenderer.Edit.make(crop:…)`, whose
/// canonical arrangement was the same `[effects, localAdjustments…, crop]`.
struct RendererTestDocument: Feature, Equatable {
  var effects: [AnyImageEffect] = []
  var localAdjustments: [LocalAdjustment<[AnyImageEffect]>] = []
  var crop: CropFeature

  var body: some Feature {
    effects
    localAdjustments
    crop
  }
}

extension MaskTree {

  /// A brush tree whose stamps are given in display coordinates (top-left
  /// origin, y-down) of a domain `domainHeight` tall.
  ///
  /// The stamps are stored in BrightroomParametric's working space through the
  /// production conversion (`EditingCanvasStrokeRecord.workingSpaceStroke`), so
  /// a test still states the display position it expects while exercising the
  /// same flip the editor commits through.
  static func test(
    displayStamps: [CGPoint],
    diameter: Double,
    hardness: Double = 1,
    opacity: Double = 1,
    isEnabled: Bool = true,
    domainHeight: CGFloat
  ) -> MaskTree {
    let record = EditingCanvasStrokeRecord(
      stamps: displayStamps,
      brush: .init(size: diameter, hardness: hardness, opacity: opacity, spacing: 0.05)
    )
    return MaskTree(
      root: .brush(
        BrushMask(
          isEnabled: isEnabled,
          strokes: [record.workingSpaceStroke(domainHeight: domainHeight)]
        )
      )
    )
  }
}

extension EditingStack {

  /// A stack whose loaded state is injected synchronously, without running the
  /// image loader. The editing source is the full-resolution oriented image.
  static func test(
    cgImage: CGImage,
    orientation: CGImagePropertyOrientation = .up
  ) -> EditingStack {
    let imageSource = ImageSource(cgImage: cgImage)
    let stack = EditingStack(imageProvider: .init(image: UIImage(cgImage: cgImage)))
    let oriented = CIImage(cgImage: cgImage).oriented(orientation)
    let editingSource = oriented.transformed(
      by: CGAffineTransform(translationX: -oriented.extent.minX, y: -oriented.extent.minY)
    )
    stack.loadedState = .init(
      imageSource: imageSource,
      metadata: .init(orientation: orientation, imageSize: editingSource.extent.size),
      thumbnailCIImage: editingSource,
      editingSourceCGImage: cgImage,
      editingSourceCIImage: editingSource
    )
    return stack
  }
}
