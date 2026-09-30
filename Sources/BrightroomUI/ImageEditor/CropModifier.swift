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

/// Decides the initial crop of a newly loaded image.
///
/// It runs once, when a new document is created with
/// `EditingDocument(source:cropModifier:history:)`. An existing document is never
/// modified.
public struct CropModifier: Sendable {

  /// Receives a downsampled image (scaled up to the oriented image size, zero
  /// origin) and a crop covering the whole image, and returns the
  /// crop to start from. It runs off the main actor, on Swift concurrency's
  /// shared executor: move blocking work (such as a synchronous Vision
  /// request) to a queue of its own, as `faceDetection` does.
  public typealias Modify = @Sendable (_ image: CIImage, _ crop: CropEditingState) async -> CropEditingState

  let modify: Modify

  /// Whether this is `identity`, so a new document is created without
  /// preparing the modifier's input image.
  let isIdentity: Bool

  public init(modify: @escaping Modify) {
    self.init(isIdentity: false, modify: modify)
  }

  private init(isIdentity: Bool, modify: @escaping Modify) {
    self.isIdentity = isIdentity
    self.modify = modify
  }

  /// Leaves the full-image crop unchanged.
  public static let identity = CropModifier(isIdentity: true) { _, crop in crop }

  /// Frames the first detected face (Vision), optionally at an aspect ratio.
  ///
  /// - Parameters:
  ///   - paddingBias: The padding around the face box, as a fraction of the
  ///     box size on each side.
  ///   - aspectRatio: The ratio of the framing crop in the final output
  ///     orientation (after the crop's quarter turn). When nil, the selection
  ///     keeps the image's own aspect ratio.
  ///
  /// When no face is found, or detection fails, the crop is fitted to
  /// `aspectRatio` if one is given and left unchanged otherwise.
  public static func faceDetection(
    paddingBias: CGFloat = 1.3,
    aspectRatio: AspectRatio? = nil
  ) -> CropModifier {
    .init { image, crop in

      var fallbackCrop: CropEditingState {
        guard let aspectRatio else {
          return crop
        }
        var fitted = crop
        fitted.updateCropExtent(toFitAspectRatio: aspectRatio)
        return fitted
      }

      // A released editor no longer needs the crop.
      guard Task.isCancelled == false else {
        return crop
      }

      guard let face = await detectFirstFace(in: image) else {
        return fallbackCrop
      }

      // The document passes the full-image crop with no quarter turn or
      // straighten, which is the crop `framingFace` starts from.
      return CropEditingState(
        cropFeature: CropFeature.framingFace(
          face.boundingBox,
          imageSize: crop.imageSize,
          paddingBias: paddingBias,
          aspectRatio: aspectRatio
        ),
        imageSize: crop.imageSize
      )
    }
  }

  /// Serializes face detection off Swift concurrency's shared executor.
  private static let visionQueue = DispatchQueue(
    label: "app.muukii.Brightroom.CropModifier.vision",
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
    let width = Int(imageSize.width)
    let height = Int(imageSize.height)

    let faceRect = VNImageRectForNormalizedRect(normalizedFaceBox, width, height)
    let paddedRect = faceRect.insetBy(
      dx: -faceRect.width * paddingBias,
      dy: -faceRect.height * paddingBias
    )
    let boundingBox = VNNormalizedRectForImageRect(paddedRect, width, height)

    var framed = CropEditingState(
      cropFeature: CropFeature(
        topLeftRect: CGRect(origin: .zero, size: imageSize),
        imageSize: imageSize
      ),
      imageSize: imageSize
    )
    framed.updateCropExtent(
      toFitBoundingBox: boundingBox,
      respectingAspectRatio: aspectRatio ?? AspectRatio(imageSize)
    )
    return framed.makeCropFeature()
  }
}

extension EditingDocument where Content == ImageEditorFeature {

  /// Creates a document with no effects and a crop that covers the whole
  /// image, adjusted by `cropModifier`.
  ///
  /// Create the document before showing an editor; the editor then edits a
  /// document that already exists. The modifier's crop is the committed
  /// state, so undo does not return to the full-image crop.
  ///
  /// - Parameters:
  ///   - source: The source image to edit.
  ///   - cropModifier: The initial-crop policy. `.identity` returns without
  ///     suspending work.
  ///   - history: The history of the new document. Empty by default.
  nonisolated(nonsending)
  public init(
    source: SourceImage,
    cropModifier: CropModifier,
    history: History = History()
  ) async {
    var feature = ImageEditorFeature(imageSize: source.pixelSize)

    if cropModifier.isIdentity == false {
      let crop = CropEditingState(cropFeature: feature.crop, imageSize: source.pixelSize)
      // The input is built off the calling actor: downsampling decodes the
      // full image, which would otherwise hitch the caller (often main).
      feature.setCrop(
        await Self.runCropModifier(cropModifier, source: source, crop: crop)
      )
    }

    self.init(source: source, feature: feature, history: history)
  }

  /// The largest side of the image a crop modifier inspects.
  private static var cropModifierInputMaxPixelSize: CGFloat { 2560 }

  /// A downsampled, oriented image scaled up to the oriented pixel size with
  /// a zero origin: the domain the crop is authored in.
  private static func makeCropModifierInput(_ source: SourceImage) -> CIImage {
    let downsampled = source.makeCIImage(maxPixelSize: cropModifierInputMaxPixelSize)
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

  /// Builds the modifier's input and runs the modifier, both off the
  /// calling actor.
  @concurrent
  private static func runCropModifier(
    _ cropModifier: CropModifier,
    source: SourceImage,
    crop: CropEditingState
  ) async -> CropEditingState {
    await cropModifier.modify(makeCropModifierInput(source), crop)
  }
}
