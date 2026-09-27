import CoreGraphics
import CoreImage
import UIKit

@testable import BrightroomEngine
@testable import BrightroomParametric
@testable import BrightroomUI

extension CropFeature {

  /// Builds a canonical crop from a y-down source selection. Output rotation
  /// changes the rendered orientation without changing this selected rectangle.
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

/// A test-only primitive that applies its steps in order.
///
/// The fold oracle for order tests: it shares no code with `FeatureBuilder`,
/// `TupleFeature`, `Optional`, `EitherFeature`, `Array`, or composite `body`
/// evaluation, as long as every step is a primitive leaf. Expand a preset into
/// `preset.effects.map(\.base)` before listing it.
struct SequentialFeatures: Feature {

  var steps: [any Feature]

  init(_ steps: [any Feature]) {
    self.steps = steps
  }

  func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    try steps.reduce(image) { image, step in
      try step.apply(to: image, context: context)
    }
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
    domainHeight: CGFloat
  ) -> MaskTree {
    let record = EditingCanvasStrokeRecord(
      stamps: displayStamps,
      brush: .init(size: diameter, hardness: hardness, opacity: opacity, spacing: 0.05)
    )
    return MaskTree(
      root: .brush(
        BrushMask(
          strokes: [record.workingSpaceStroke(domainHeight: domainHeight)]
        )
      )
    )
  }
}

extension EditingStack {

  /// A stack whose loaded state is injected synchronously, without running the
  /// image preparation. The editing source is the full-resolution oriented
  /// image.
  static func test(
    cgImage: CGImage,
    orientation: CGImagePropertyOrientation = .up
  ) -> EditingStack {
    let image = SourceImage(cgImage: cgImage, orientation: orientation)
    let stack = EditingStack(image: image)
    let editingSource = image.makeCIImage()
    stack.loadedState = .init(
      image: image,
      thumbnailImage: editingSource,
      editingSourceCGImage: cgImage,
      editingSourceImage: editingSource
    )
    return stack
  }
}

extension EditingDocument {

  /// Renders synchronously on a chosen device, through the same core as
  /// `render(options:)`.
  func renderForTesting(
    options: ParametricExportRenderer.Options = .init(),
    device: ParametricExportRenderer.RenderingDevice = .automatic
  ) throws -> ParametricExportRenderer.Rendered {
    try render(options: options, device: device)
  }
}

extension UIImage {

  /// The decoded, unoriented full-resolution pixels (what the removed
  /// `ImageSource(image:).loadOriginalCGImage()` returned).
  var decodedCGImageForTesting: CGImage {
    ImageTool.makeDecodedCGImage(from: cgImage!) ?? cgImage!
  }
}

extension SourceImage {

  /// The pixels of `image` under an explicit orientation, ignoring the
  /// `UIImage`'s own `imageOrientation` (what the removed
  /// `BrightRoomImageRenderer(source: ImageSource(image:), orientation:…)`
  /// rendered).
  static func test(_ image: UIImage, orientation: CGImagePropertyOrientation = .up) -> SourceImage {
    SourceImage(cgImage: image.decodedCGImageForTesting, orientation: orientation)
  }

  /// The unoriented decoded pixels of a bitmap-backed image.
  var bitmapForTesting: CGImage {
    guard case .bitmap(let cgImage) = storage.backing else {
      preconditionFailure("Not a bitmap-backed source image.")
    }
    return cgImage
  }
}
