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
/// decides with `CropFeature.pixelAligned(imageSize:)`.
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
  }

  fileprivate enum Policy: Sendable {
    case fullImage
    case aspectRatio(AspectRatio)
    case decide(@Sendable (Input) async -> CropFeature)
  }

  fileprivate let policy: Policy

  private init(policy: Policy) {
    self.policy = policy
  }

  /// An initial crop that `decide` returns.
  ///
  /// `decide` runs off the main actor, on Swift concurrency's shared
  /// executor: move blocking work (such as a synchronous Vision request) to
  /// a queue of its own, as `faceDetection` does. Return a crop in
  /// `input.imageSize`; the document snaps it to whole pixels inside the
  /// image.
  public init(_ decide: @escaping @Sendable (_ input: Input) async -> CropFeature) {
    self.init(policy: .decide(decide))
  }

  /// The whole image.
  public static let fullImage = InitialCrop(policy: .fullImage)

  /// The largest selection of `aspectRatio`, centered in the image. See
  /// `CropFeature.fitted(to:imageSize:)`.
  ///
  /// The editor does not lock the ratio; pass
  /// `ImageEditor.Options.aspectRatioPolicy` for that.
  public static func aspectRatio(_ aspectRatio: AspectRatio) -> InitialCrop {
    InitialCrop(policy: .aspectRatio(aspectRatio))
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
  /// `aspectRatio` if one is given and covers the whole image otherwise. The
  /// editor does not lock the ratio; pass
  /// `ImageEditor.Options.aspectRatioPolicy` for that.
  public static func faceDetection(
    paddingBias: CGFloat = 1.3,
    aspectRatio: AspectRatio? = nil
  ) -> InitialCrop {
    InitialCrop { input in

      var fallbackCrop: CropFeature {
        guard let aspectRatio else {
          return input.crop
        }
        return input.crop.fitted(to: aspectRatio, imageSize: input.imageSize)
      }

      // A released editor no longer needs the crop.
      guard Task.isCancelled == false else {
        return input.crop
      }

      guard let face = await detectFirstFace(in: input.image) else {
        return fallbackCrop
      }

      return CropFeature.framingFace(
        face.boundingBox,
        imageSize: input.imageSize,
        paddingBias: paddingBias,
        aspectRatio: aspectRatio
      )
    }
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
    let selection = CropGeometry.fittingRect(
      rect: paddedRect,
      in: imageSize,
      straightenRadians: 0,
      respectingAspectRatio: aspectRatio ?? AspectRatio(imageSize)
    )
    return CropFeature(rect: selection).pixelAligned(imageSize: imageSize)
  }
}

extension EditingDocument where Content == ImageEditorFeature {

  /// Creates a document with no effects and the crop `initialCrop` decides.
  ///
  /// Create the document before showing an editor; the editor then edits a
  /// document that already exists. The decided crop is the committed state,
  /// so undo does not return to the full-image crop.
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
      break
    case .aspectRatio(let aspectRatio):
      feature.crop = feature.crop.fitted(to: aspectRatio, imageSize: imageSize)
    case .decide(let decide):
      // The input is built off the calling actor: downsampling decodes the
      // full image, which would otherwise hitch the caller (often main).
      let decided = await Self.decideInitialCrop(decide, source: source, crop: feature.crop)
      feature.crop = decided.pixelAligned(imageSize: imageSize)
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
