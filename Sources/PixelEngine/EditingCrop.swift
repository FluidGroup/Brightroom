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

import UIKit

public struct EditingCrop: Equatable {
  public enum Rotation: Equatable, CaseIterable {
    /// 0 degree - default
    case angle_0
    
    /// 90 degree
    case angle_90
    
    /// 180 degree
    case angle_180
    
    /// 270 degree
    case angle_270
    
    public var transform: CGAffineTransform {
      switch self {
      case .angle_0:
        return .identity
      case .angle_90:
        return .init(rotationAngle: -CGFloat.pi / 2)
      case .angle_180:
        return .init(rotationAngle: -CGFloat.pi)
      case .angle_270:
        return .init(rotationAngle: CGFloat.pi / 2)
      }
    }
    
    public func next() -> Self {
      switch self {
      case .angle_0: return .angle_90
      case .angle_90: return .angle_180
      case .angle_180: return .angle_270
      case .angle_270: return .angle_0
      }
    }
  }
  
  /**
   Returns aspect ratio.
   Would not be affected by rotation.
   */
  public var preferredAspectRatio: PixelAspectRatio?
  
  /// The dimensions in pixel for the image.
  public var imageSize: CGSize
  
  /// The rectangle that specifies the extent of the cropping.
  public var cropExtent: CGRect
  
  /// The angle that specifies rotation for the image.
  public var rotation: Rotation = .angle_0
  
  public private(set) var originalWidth: CGFloat
  
  public init(from ciImage: CIImage) {
    self.init(
      imageSize: .init(image: ciImage),
      cropRect: .init(origin: .zero, size: ciImage.extent.size)
    )
  }
  
  public init(imageSize: CGSize, cropRect: CGRect, rotation: Rotation = .angle_0) {
    self.imageSize = imageSize
    cropExtent = cropRect
    self.rotation = rotation
    self.originalWidth = imageSize.width
  }
  
  public func makeInitial() -> Self {
    .init(imageSize: imageSize, cropRect: .init(origin: .zero, size: imageSize))
  }
  
  /**
   Set new aspect ratio with updating cropping extent.
   Currently, the cropping extent changes to maximum size in the size of image.
   
   - TODO: Resizing cropping extent with keeping area by new aspect ratio.
   */
  public mutating func updateCropExtent(by newAspectRatio: PixelAspectRatio) {
    let maxSize = newAspectRatio.sizeThatFits(in: imageSize)
    
    cropExtent = .init(
      origin: .init(
        x: (imageSize.width - maxSize.width) / 2,
        y: (imageSize.height - maxSize.height) / 2
      ),
      size: maxSize
    )
  }
  
  public func scaled(toWidth width: CGFloat) -> Self {
    
    let scale = CGFloat(width) / CGFloat(imageSize.width)
    
    return scaled(scale)
  }
  
  public func restoreFromScaled() -> Self {
    return scaled(toWidth: originalWidth)
  }
  
  private func scaled(_ scale: CGFloat) -> Self {
    
    var modified = self
    
    modified.cropExtent.origin.x *= scale
    modified.cropExtent.origin.y *= scale
    modified.cropExtent.size.width *= scale
    modified.cropExtent.size.height *= scale
    
    modified.imageSize.width *= scale
    modified.imageSize.height *= scale
    
    return modified
  }
  
}
