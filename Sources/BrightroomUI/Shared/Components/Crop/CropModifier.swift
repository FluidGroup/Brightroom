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
/// `PhotosCropDocument.makeInitial(for:cropModifier:)`; `PhotosCropEditingModel`
/// does this for a new session. A resumed document is not modified.
public struct CropModifier: Sendable {

  /// Receives the downsampled editing source (scaled up to the oriented image
  /// size, zero origin) and a crop covering the whole image, and returns the
  /// crop to start from. It runs off the main actor, on Swift concurrency's
  /// shared executor: move blocking work (such as a synchronous Vision
  /// request) to a queue of its own, as `faceDetection` does.
  public typealias Modify = @Sendable (_ image: CIImage, _ crop: CropEditingState) async -> CropEditingState

  let modify: Modify

  /// Whether this is `identity`, so the editor can create the document
  /// synchronously instead of preparing the modifier's input image.
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
  ///   - aspectRatio: The ratio of the framing crop. When nil, the crop keeps
  ///     the image's own aspect ratio.
  ///
  /// When no face is found, or detection fails, the crop is fitted to
  /// `aspectRatio` if one is given and left unchanged otherwise.
  public static func faceDetection(
    paddingBias: CGFloat = 1.3,
    aspectRatio: PixelAspectRatio? = nil
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

      let imageSize = crop.imageSize
      let width = Int(imageSize.width)
      let height = Int(imageSize.height)

      let faceRect = VNImageRectForNormalizedRect(face.boundingBox, width, height)
      let paddedRect = faceRect.insetBy(
        dx: -faceRect.width * paddingBias,
        dy: -faceRect.height * paddingBias
      )
      let boundingBox = VNNormalizedRectForImageRect(paddedRect, width, height)

      var framed = crop
      framed.updateCropExtent(
        toFitBoundingBox: boundingBox,
        respectingApectRatio: aspectRatio ?? PixelAspectRatio(imageSize)
      )
      return framed
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
          EditorLog.error(.cropView, "Face detection failed: \(error)")
          continuation.resume(returning: nil)
          return
        }
        continuation.resume(returning: request.results?.first)
      }
    }
  }
}

extension PhotosCropDocument {

  /// The document a new edit of a loaded image starts from: no effects, no
  /// blur mask, and a crop covering the whole image adjusted by
  /// `cropModifier`.
  ///
  /// `PhotosCropEditingModel` uses this for a new session. A host that edits
  /// through `SwiftUICropView`'s document binding can use it to apply a crop
  /// modifier, and show the view once the document exists.
  ///
  /// - Parameters:
  ///   - loadedState: The loaded image the document is authored over.
  ///   - cropModifier: The initial-crop policy. `.identity` returns without
  ///     suspending work.
  nonisolated(nonsending)
  public static func makeInitial(
    for loadedState: EditingStack.Loaded,
    cropModifier: CropModifier = .identity
  ) async -> PhotosCropDocument {
    var document = PhotosCropDocument(orientedImageSize: loadedState.imageSize)

    guard cropModifier.isIdentity == false else {
      return document
    }

    let image = makeCropModifierInput(loadedState)
    let crop = CropEditingState(cropFeature: document.crop, imageSize: loadedState.imageSize)
    document.setCrop(await runCropModifier(cropModifier, image: image, crop: crop))
    return document
  }

  /// The downsampled editing source, oriented and scaled up to the oriented
  /// image size with a zero origin: the domain the crop is authored in.
  private static func makeCropModifierInput(_ loaded: EditingStack.Loaded) -> CIImage {
    let image = CIImage(cgImage: loaded.editingSourceCGImage)
      .oriented(loaded.metadata.orientation)
    let imageSize = loaded.imageSize

    let scaled = image.transformed(
      by: .init(
        scaleX: image.extent.width < imageSize.width ? imageSize.width / image.extent.width : 1,
        y: image.extent.height < imageSize.height ? imageSize.height / image.extent.height : 1
      )
    )

    return scaled.transformed(
      by: .init(
        translationX: -scaled.extent.origin.x,
        y: -scaled.extent.origin.y
      )
    )
  }

  @concurrent
  private static func runCropModifier(
    _ cropModifier: CropModifier,
    image: CIImage,
    crop: CropEditingState
  ) async -> CropEditingState {
    await cropModifier.modify(image, crop)
  }
}
