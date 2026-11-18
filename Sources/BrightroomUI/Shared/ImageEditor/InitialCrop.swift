//
// Copyright (c) 2026 Muukii <muukii.app@gmail.com>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.



import CoreImage
import Vision

import BrightroomEngine
import BrightroomParametric

/// Decides the crop a new document starts from.
///
/// It runs once, when a document is created with
/// `ImageEditorDocument(source:initialCrop:history:)`, and never for a
/// document rebuilt from saved values. The document pixel-aligns the crop it
/// decides with `CropFeature.pixelAligned(imageSize:)`. A policy with a
/// ratio (`aspectRatio(_:)`, `faceDetection(paddingBias:aspectRatio:)`) gets
/// exactly that ratio in whole pixels instead when its lowest terms are both
/// at most 32 (1:1, 4:5, 16:9, …): the largest whole multiple of the terms
/// that fits the framing's whole-pixel size, centered on it within half a
/// pixel and less than one term smaller in each dimension, as a crop under
/// ImageEditor's locked ratio is written. It then applies ImageEditor's
/// minimum crop size: a crop whose shorter output side is under 128 pixels
/// (or under the image's shorter side, when the image is smaller) grows
/// about its center to that size, keeping its aspect ratio (the policy's
/// ratio, or the crop's own for a custom policy) and staying inside the
/// image. A small face, for example, is framed with more of its
/// surroundings. A crop the image cannot hold at that size and ratio stays
/// as large as the image allows. Any crop size is still a valid
/// `CropFeature`; the minimum is the editor's, so a crop the host sets on
/// the document itself is not changed (see `ImageEditorCanvas`).
public struct InitialCrop: Sendable {

  /// What a custom initial crop decides from.
  public struct Input: Sendable {

    /// A downsampled preview of the source image, scaled up to `imageSize`
    /// with a zero origin, so its coordinates are the crop's. Use it to find
    /// what to frame; its detail is lower than the source's.
    public let image: CIImage

    /// The oriented pixel size of the source image
    /// (`SourceImage.pixelSize`): the input of the crop.
    public let imageSize: CGSize

    /// The crop to start from: the whole image, with no quarter turn or
    /// straighten.
    public let crop: CropFeature

    /// Creates an input, for example to unit-test a `decide` closure.
    ///
    /// The document builds the input itself when it runs a custom initial
    /// crop. To pass a `decide` closure what the document passes it, give
    /// an image whose extent is `imageSize` at a zero origin and a crop of
    /// the whole image: `CropFeature(rect: CGRect(origin: .zero, size:
    /// imageSize))`.
    ///
    /// - Parameters:
    ///   - image: The image to decide from, in the crop's coordinates.
    ///   - imageSize: The oriented pixel size of the source image.
    ///   - crop: The crop to start from.
    public init(image: CIImage, imageSize: CGSize, crop: CropFeature) {
      self.image = image
      self.imageSize = imageSize
      self.crop = crop
    }
  }

  fileprivate enum Policy: Sendable {
    case fullImage
    case aspectRatio(AspectRatio)
    case decide(@Sendable (Input) async -> CropFeature)
  }

  fileprivate let policy: Policy

  /// The output ratio the policy frames with, which a decided crop keeps
  /// when the document enlarges it to the editor's minimum size; nil keeps
  /// the crop's own ratio.
  let framingAspectRatio: AspectRatio?

  private init(policy: Policy, framingAspectRatio: AspectRatio? = nil) {
    self.policy = policy
    self.framingAspectRatio = framingAspectRatio
  }

  /// The crop `aspectRatio(_:)` decides for an image of `imageSize`, grown
  /// to the editor's minimum size: the largest selection of `aspectRatio`
  /// centered in the image, with exactly that ratio in whole pixels when
  /// its lowest terms are both at most 32 (see `InitialCrop`).
  ///
  /// ImageEditor's Reset restores it under
  /// `ImageEditor.Options.AspectRatioPolicy.fixed`.
  static func crop(fitting aspectRatio: AspectRatio, imageSize: CGSize) -> CropFeature {
    // The full-image crop has no turn or straighten, and the selection is
    // centered, so the same in y-down and y-up coordinates.
    CropFeature(
      rect: CropGeometry.cropRect(toFitAspectRatio: aspectRatio, in: imageSize, straightenRadians: 0)
    )
    .pixelAligned(imageSize: imageSize, aspectRatio: aspectRatio)
    .enlargedToEditorMinimum(imageSize: imageSize, aspectRatio: aspectRatio)
  }

  /// An initial crop that `decide` returns.
  ///
  /// `decide` runs off the main actor, on Swift concurrency's shared
  /// executor: move blocking work (such as a synchronous Vision request) to
  /// a queue of its own, as `faceDetection` does. Return a crop in
  /// `input.imageSize`; the document snaps it to whole pixels inside the
  /// image and enlarges a crop below the editor's minimum size, keeping its
  /// ratio (see `InitialCrop`). To unit-test `decide`, keep it in a
  /// property of its own and call it with an `Input` you create.
  public init(_ decide: @escaping @Sendable (_ input: Input) async -> CropFeature) {
    self.init(policy: .decide(decide))
  }

  /// The whole image.
  public static let fullImage = InitialCrop(policy: .fullImage)

  /// The largest selection of `aspectRatio`, centered in the image, as
  /// `CropFeature.fitted(to:imageSize:)` fits it, but with exactly that
  /// ratio in whole pixels when its lowest terms are both at most 32 (see
  /// `InitialCrop`): a 4:5 crop of a 4032 × 3024 photo is 2416 × 3020, not
  /// the 2418 × 3024 that snapping each edge gives.
  ///
  /// The editor does not lock the ratio; pass
  /// `ImageEditor.Options.aspectRatioPolicy` for that.
  public static func aspectRatio(_ aspectRatio: AspectRatio) -> InitialCrop {
    InitialCrop(policy: .aspectRatio(aspectRatio), framingAspectRatio: aspectRatio)
  }

  /// Frames the first face Vision detects, optionally at an aspect ratio.
  ///
  /// - Parameters:
  ///   - paddingBias: The padding around the face box, as a fraction of the
  ///     box size on each side.
  ///   - aspectRatio: The ratio of the framing crop. When nil, the crop keeps
  ///     the image's own aspect ratio.
  ///
  /// When no face is found, or detection fails, the crop is fitted to
  /// `aspectRatio` if one is given and covers the whole image otherwise.
  /// With `aspectRatio`, the crop has exactly that ratio in whole pixels
  /// when its lowest terms are both at most 32 (see `InitialCrop`). A
  /// framing smaller than the editor's minimum crop size (128 pixels on its
  /// shorter side) grows about the face's center to that size, with
  /// `aspectRatio` exactly when its lowest terms are both at most 32 (see
  /// `InitialCrop`). The editor does not lock the ratio; pass
  /// `ImageEditor.Options.aspectRatioPolicy` for that.
  public static func faceDetection(
    paddingBias: CGFloat = 1.3,
    aspectRatio: AspectRatio? = nil
  ) -> InitialCrop {
    InitialCrop(policy: .decide { input in

      // The document aligns the crop, to exactly `aspectRatio` when one is
      // given, so the framing stays continuous here.
      var fallbackCrop: CropFeature {
        guard let aspectRatio else {
          return input.crop
        }
        // Centered, so the same in y-down and y-up coordinates.
        return CropFeature(
          rect: CropGeometry.cropRect(toFitAspectRatio: aspectRatio, in: input.imageSize, straightenRadians: 0)
        )
      }

      // A released editor no longer needs the crop.
      guard Task.isCancelled == false else {
        return input.crop
      }

      guard let face = await detectFirstFace(in: input.image) else {
        return fallbackCrop
      }

      return CropFeature(
        rect: CropFeature.framingFaceSelection(
          face.boundingBox,
          imageSize: input.imageSize,
          paddingBias: paddingBias,
          aspectRatio: aspectRatio
        )
      )
    }, framingAspectRatio: aspectRatio)
  }

  /// Serializes face detection off Swift concurrency's shared executor.
  private static let visionQueue = DispatchQueue(
    label: "app.muukii.Brightroom.InitialCrop.vision",
    qos: .utility
  )

  /// The first face Vision finds in `image`, or nil when none is found or
  /// detection fails.
  ///
  /// `perform` blocks until the request finishes, so it runs on
  /// `visionQueue` instead of holding a cooperative thread.
  private static func detectFirstFace(in image: CIImage) async -> VNFaceObservation? {
    await withCheckedContinuation { continuation in
      visionQueue.async {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision2
#if targetEnvironment(simulator)
        request.usesCPUOnly = true
#endif

        let handler = VNImageRequestHandler(ciImage: image, orientation: .up, options: [:])
        do {
          try handler.perform([request])
        } catch {
          EditorLog.error(.editingCanvas, "Face detection failed: \(error)")
          continuation.resume(returning: nil)
          return
        }
        continuation.resume(returning: request.results?.first)
      }
    }
  }
}

extension CropFeature {

  /// The pixel-aligned crop that frames a face in an image of `imageSize`,
  /// starting from the full image with no quarter turn or straighten.
  ///
  /// The face box is padded by `paddingBias` of its size on each side,
  /// clipped to the image, and fitted to `aspectRatio`, or to the image's own
  /// ratio when nil.
  ///
  /// - Parameter normalizedFaceBox: A Vision bounding box: normalized to the
  ///   image, with a bottom-left origin.
  static func framingFace(
    _ normalizedFaceBox: CGRect,
    imageSize: CGSize,
    paddingBias: CGFloat,
    aspectRatio: AspectRatio?
  ) -> CropFeature {
    CropFeature(
      rect: framingFaceSelection(
        normalizedFaceBox,
        imageSize: imageSize,
        paddingBias: paddingBias,
        aspectRatio: aspectRatio
      )
    )
    .pixelAligned(imageSize: imageSize)
  }

  /// The selection `framingFace(_:imageSize:paddingBias:aspectRatio:)`
  /// aligns, in the crop's y-up coordinates, before pixel alignment.
  static func framingFaceSelection(
    _ normalizedFaceBox: CGRect,
    imageSize: CGSize,
    paddingBias: CGFloat,
    aspectRatio: AspectRatio?
  ) -> CGRect {
    // Vision's image rectangles and `CropFeature.rect` share the bottom-left
    // origin, so no flip is needed.
    let faceRect = VNImageRectForNormalizedRect(
      normalizedFaceBox,
      Int(imageSize.width),
      Int(imageSize.height)
    )
    let paddedRect = faceRect.insetBy(
      dx: -faceRect.width * paddingBias,
      dy: -faceRect.height * paddingBias
    )
    return CropGeometry.fittingRect(
      rect: paddedRect,
      in: imageSize,
      straightenRadians: 0,
      respectingAspectRatio: aspectRatio ?? AspectRatio(imageSize)
    )
  }

  /// This crop aligned to whole pixels in an input of `imageSize`, as
  /// `pixelAligned(imageSize:)` aligns it, or with exactly `aspectRatio`
  /// (the output's, after `quarterTurn`) when its lowest terms are both at
  /// most 32: the largest whole multiple of the terms that fits the
  /// selection's whole-pixel size, centered on it within half a pixel.
  func pixelAligned(imageSize: CGSize, aspectRatio: AspectRatio?) -> CropFeature {
    guard let aspectRatio else {
      return pixelAligned(imageSize: imageSize)
    }
    return CropFeature(
      topLeftRect: topLeftRect(imageSize: imageSize),
      imageSize: imageSize,
      quarterTurn: quarterTurn,
      straightenRadians: straightenRadians,
      aspectRatio: aspectRatio
    )
  }

  /// This crop grown about its center to ImageEditor's minimum crop size
  /// (`CropGuideState.minimumCropOutputSideLength(imageSize:)`), keeping
  /// `aspectRatio` (the output's, after `quarterTurn`) or, when nil, its own
  /// ratio, inside an input of `imageSize`, and pixel-aligned; returned as
  /// is when its shorter side already reaches the minimum.
  ///
  /// With a ratio whose lowest terms are both at most 32, the size is the
  /// smallest whole multiple of the terms that reaches the minimum, so the
  /// crop has exactly that ratio; otherwise the longer side is the nearest
  /// whole pixel. See `CropGeometry.rectEnlarged(toMinimumSide:…)`.
  func enlargedToEditorMinimum(imageSize: CGSize, aspectRatio: AspectRatio?) -> CropFeature {
    let selection = topLeftRect(imageSize: imageSize)
    let selectionAspectRatio = aspectRatio.map { quarterTurn.isSideways ? $0.swapped() : $0 }
      ?? AspectRatio(selection.size)
    let enlarged = CropGeometry.rectEnlarged(
      toMinimumSide: CropGuideState.minimumCropOutputSideLength(imageSize: imageSize),
      rect: selection,
      in: imageSize,
      straightenRadians: straightenRadians,
      aspectRatio: selectionAspectRatio
    )
    guard enlarged != selection else {
      return self
    }
    return CropFeature(
      topLeftRect: enlarged,
      imageSize: imageSize,
      quarterTurn: quarterTurn,
      straightenRadians: straightenRadians
    )
  }
}

extension EditingDocument where Content == ImageEditorFeature {

  /// Creates a document with no effects and the crop `initialCrop` decides.
  ///
  /// Create the document before showing an editor; the editor then edits a
  /// document that already exists. The decided crop is the committed state,
  /// so undo does not return to the full-image crop. A decided crop below
  /// ImageEditor's minimum crop size is enlarged to it (see `InitialCrop`).
  ///
  /// - Parameters:
  ///   - source: The source image to edit.
  ///   - initialCrop: The initial-crop policy. `.fullImage` and
  ///     `.aspectRatio(_:)` return without suspending work.
  ///   - history: The history of the new document. Empty by default.
  nonisolated(nonsending)
  public init(
    source: SourceImage,
    initialCrop: InitialCrop,
    history: History = History()
  ) async {
    let imageSize = source.pixelSize
    var feature = ImageEditorFeature(imageSize: imageSize)

    switch initialCrop.policy {
    case .fullImage:
      // The whole image is never below the editor's minimum, which the
      // image's shorter side caps.
      break
    case .aspectRatio(let aspectRatio):
      feature.crop = InitialCrop.crop(fitting: aspectRatio, imageSize: imageSize)
    case .decide(let decide):
      // The input is built off the calling actor: downsampling decodes the
      // full image, which would otherwise hitch the caller (often main).
      let decided = await Self.decideInitialCrop(decide, source: source, crop: feature.crop)
      feature.crop = decided
        .pixelAligned(imageSize: imageSize, aspectRatio: initialCrop.framingAspectRatio)
        .enlargedToEditorMinimum(imageSize: imageSize, aspectRatio: initialCrop.framingAspectRatio)
    }

    self.init(source: source, feature: feature, history: history)
  }

  /// The largest side of the image an initial crop inspects.
  private static var initialCropImageMaxPixelSize: CGFloat { 2560 }

  /// A downsampled, oriented image scaled up to the oriented pixel size with
  /// a zero origin: the domain the crop is authored in.
  private static func makeInitialCropImage(_ source: SourceImage) -> CIImage {
    let downsampled = source.makeCIImage(maxPixelSize: initialCropImageMaxPixelSize)
    let imageSize = source.pixelSize

    let scaled = downsampled.transformed(
      by: .init(
        scaleX: downsampled.extent.width < imageSize.width ? imageSize.width / downsampled.extent.width : 1,
        y: downsampled.extent.height < imageSize.height ? imageSize.height / downsampled.extent.height : 1
      )
    )

    return scaled.transformed(
      by: .init(
        translationX: -scaled.extent.origin.x,
        y: -scaled.extent.origin.y
      )
    )
  }

  /// Builds the input and runs `decide`, both off the calling actor.
  @concurrent
  private static func decideInitialCrop(
    _ decide: @Sendable (InitialCrop.Input) async -> CropFeature,
    source: SourceImage,
    crop: CropFeature
  ) async -> CropFeature {
    await decide(
      InitialCrop.Input(
        image: makeInitialCropImage(source),
        imageSize: source.pixelSize,
        crop: crop
      )
    )
  }
}
