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

extension EditingStack {
  public struct CropModifier {
    public typealias Closure = (CIImage, EditingCrop, @escaping (EditingCrop) -> Void) -> Void
    
    private let modifier: Closure
    
    public init(modify: @escaping Closure) {
      modifier = modify
    }
    
    func run(_ image: CIImage, editingCrop: EditingCrop, completion: @escaping (EditingCrop) -> Void) {
      modifier(image, editingCrop) { result in
        completion(result)
      }
    }
    
    public static func faceDetection(paddingBias: CGFloat = 1.3, aspectRatio: PixelAspectRatio? = nil) -> Self {
      return .init { image, crop, completion in
        
        let request = VNDetectFaceRectanglesRequest { request, error in
          
          if let error = error {
            EngineLog.debug(error)
            completion(crop)
            return
          }
          
          guard let results = request.results as? [VNFaceObservation] else {
            completion(crop)
            return
          }
          
          guard let first = results.first else {
            completion(crop)
            return
          }
          
          var new = crop
          let box = first.boundingBox
          
          let denormalizedRect = VNImageRectForNormalizedRect(box, Int(crop.imageSize.width), Int(crop.imageSize.height))
          
          let paddingRect = denormalizedRect.insetBy(dx: -denormalizedRect.width * paddingBias, dy: -denormalizedRect.height * paddingBias)
          
          let normalizedRect = VNNormalizedRectForImageRect(paddingRect, Int(crop.imageSize.width), Int(crop.imageSize.height))
          
          new.updateCropExtent(byBoundingBox: normalizedRect, respectingApectRatio: aspectRatio)
          completion(new)
        }
        
        request.revision = VNDetectFaceRectanglesRequestRevision2
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
