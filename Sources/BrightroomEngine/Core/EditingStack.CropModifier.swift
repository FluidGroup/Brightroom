//
// Copyright (c) 2021 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
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

import BrightroomParametric

extension EditingStack {
  public struct CropModifier {
    /// `(image, current crop, oriented image size, completion(new crop))`.
    ///
    /// `CropFeature` carries no image size, so the oriented source size is
    /// passed alongside it. The completion crop keeps the input crop's identity,
    /// rotation, and straighten — only its rect changes.
    public typealias Closure = (CIImage, CropFeature, CGSize, @escaping (CropFeature) -> Void) -> Void

    private let modifier: Closure

    public init(modify: @escaping Closure) {
      modifier = modify
    }

    func run(
      _ image: CIImage,
      crop: CropFeature,
      imageSize: CGSize,
      completion: @escaping (CropFeature) -> Void
    ) {
      modifier(image, crop, imageSize) { result in
        completion(result)
      }
    }

    public static func faceDetection(paddingBias: CGFloat = 1.3, aspectRatio: PixelAspectRatio? = nil) -> Self {
      return .init { image, crop, imageSize, completion in

        // Rebuild a crop from a y-down display rect, sharing the engine's
        // pixel-snap and preserving the crop's identity / rotation / straighten.
        func makeCrop(displayRect: CGRect) -> CropFeature {
          CropFeature(
            id: crop.id,
            displayCropRect: displayRect,
            imageSize: imageSize,
            rotation: crop.rotation,
            straighten: crop.straightenRadians
          )
        }

        var fallbackCrop: CropFeature {
          guard let aspectRatio = aspectRatio else {
            return crop
          }
          return makeCrop(
            displayRect: CropGeometry.cropRect(toFitAspectRatio: aspectRatio, in: imageSize)
          )
        }

        let request = VNDetectFaceRectanglesRequest { request, error in

          if let error = error {
            EngineLog.debug(error)
            completion(fallbackCrop)
            return
          }

          guard let results = request.results as? [VNFaceObservation] else {
            completion(fallbackCrop)
            return
          }

          guard let first = results.first else {
            completion(fallbackCrop)
            return
          }

          let box = first.boundingBox

          let denormalizedRect = VNImageRectForNormalizedRect(box, Int(imageSize.width), Int(imageSize.height))

          let paddingRect = denormalizedRect.insetBy(dx: -denormalizedRect.width * paddingBias, dy: -denormalizedRect.height * paddingBias)

          let normalizedRect = VNNormalizedRectForImageRect(paddingRect, Int(imageSize.width), Int(imageSize.height))

          let displayRect = CropGeometry.cropRect(
            toFitBoundingBox: normalizedRect,
            within: crop.displayCropRect(imageSize: imageSize),
            in: imageSize,
            respectingAspectRatio: aspectRatio ?? PixelAspectRatio(imageSize)
          )
          completion(makeCrop(displayRect: displayRect))
        }

        request.revision = VNDetectFaceRectanglesRequestRevision2
#if targetEnvironment(simulator)
        request.usesCPUOnly = true
#endif
        let handler = VNImageRequestHandler(ciImage: image, orientation: .up, options: [:])
        do {
          try handler.perform([request])
        } catch {
          EngineLog.error(.stack, "Face detection start failed : \(error)")
        }
      }
    }
  }
}
