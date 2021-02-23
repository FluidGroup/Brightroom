//
// Copyright (c) 2018 Muukii <muukii.app@gmail.com>
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

import Foundation

import CoreImage
import Verge

#if canImport(UIKit)
import UIKit
#endif

#if canImport(Photos)
import Photos
#endif

public struct EditingImage: Equatable {
    
  let image: CIImage
  let isEditable: Bool
  
}

/**
 A stateful object that provides multiple image for EditingStack.
 */
public final class ImageProvider: Equatable, StoreComponentType {
  
  public static func == (lhs: ImageProvider, rhs: ImageProvider) -> Bool {
    lhs === rhs
  }
    
  public struct State: Equatable {
    var currentImage: EditingImage?
  }
  
  public let store: DefaultStore
  
  private var pendingAction: (ImageProvider) -> Void

  #if os(iOS)
  
  public convenience init(image uiImage: UIImage) {
    
    let image = CIImage(image: uiImage)!
    let fixedOriantationImage = image.oriented(forExifOrientation: imageOrientationToTiffOrientation(uiImage.imageOrientation))
    
    self.init(image: fixedOriantationImage)
  }
  
  #endif
  
  public init(image: CIImage) {
    
    precondition(image.extent.origin == .zero)
    self.store = .init(initialState: .init(currentImage: .init(image: image, isEditable: true)))
    self.pendingAction = { _ in }
  }
  
  #if canImport(Photos)
  
  public init(asset: PHAsset) {
        
    //TODO cancellation, Error handeling
    
    self.store = .init(initialState: .init())
        
    self.pendingAction = { `self` in
      
      let previewRequestOptions = PHImageRequestOptions()
      previewRequestOptions.deliveryMode = .highQualityFormat
      previewRequestOptions.isNetworkAccessAllowed = true
      previewRequestOptions.version = .current
      previewRequestOptions.resizeMode = .fast
      
      let finalImageRequestOptions = PHImageRequestOptions()
      finalImageRequestOptions.deliveryMode = .highQualityFormat
      finalImageRequestOptions.isNetworkAccessAllowed = true
      finalImageRequestOptions.version = .current
      finalImageRequestOptions.resizeMode = .none
      
      PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 360, height: 360), contentMode: .aspectFit, options: previewRequestOptions) { [weak self] (image, _) in
        
        guard let image = image, let self = self else { return }
        let ciImage = image.ciImage ?? CIImage(cgImage: image.cgImage!)
        
        self.commit {
          $0.currentImage = .init(image: ciImage, isEditable: false)
        }
      }
      
      PHImageManager.default().requestImage(for: asset, targetSize: PHImageManagerMaximumSize, contentMode: .aspectFit, options: finalImageRequestOptions) { [weak self] (image, _) in
        
        guard let image = image, let self = self else { return }
        let ciImage = image.ciImage ?? CIImage(cgImage: image.cgImage!)
        
        self.commit {
          $0.currentImage = .init(image: ciImage, isEditable: true)
        }
      }
      
    }
    
  }
  
  #endif
  
  func start() {
    pendingAction(self)
  }
  
}

fileprivate func imageOrientationToTiffOrientation(_ value: UIImage.Orientation) -> Int32 {
  switch value{
  case .up:
    return 1
  case .down:
    return 3
  case .left:
    return 8
  case .right:
    return 6
  case .upMirrored:
    return 2
  case .downMirrored:
    return 4
  case .leftMirrored:
    return 5
  case .rightMirrored:
    return 7
  @unknown default:
    fatalError()
  }
}
