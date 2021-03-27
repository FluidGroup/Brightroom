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
import Vision

/// A representation of cropping extent in Image.
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
    
    public var angle: CGFloat {
      switch self {
      case .angle_0:
        return 0
      case .angle_90:
        return -CGFloat.pi / 2
      case .angle_180:
        return -CGFloat.pi
      case .angle_270:
        return CGFloat.pi / 2
      }
    }
    
    public var transform: CGAffineTransform {
      .init(rotationAngle: angle)
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
    
  /// The dimensions in pixel for the image.
  /// Applied image-orientation.
  public var imageSize: CGSize
  
  /// The rectangle that specifies the extent of the cropping.
  public private(set) var cropExtent: CGRect
  
  /// The angle that specifies rotation for the image.
  public var rotation: Rotation = .angle_0
  
  public private(set) var scaleToRestore: CGFloat
  
  public init(from ciImage: CIImage) {
    self.init(
      imageSize: .init(image: ciImage),
      cropRect: .init(origin: .zero, size: ciImage.extent.size)
    )
  }
  
  public init(imageSize: CGSize) {
    self.init(imageSize: imageSize, cropRect: .init(origin: .zero, size: imageSize), rotation: .angle_0)
  }
  
  public init(imageSize: CGSize, cropRect: CGRect, rotation: Rotation = .angle_0, scaleToRestore: CGFloat = 1) {
    self.imageSize = imageSize
    self.cropExtent = Self.normalizeRect(rect: cropRect, in: imageSize, respectingAspectRatio: nil)
    self.rotation = rotation
    self.scaleToRestore = scaleToRestore
  }
  
  public func makeInitial() -> Self {
    .init(imageSize: imageSize, cropRect: .init(origin: .zero, size: imageSize), scaleToRestore: scaleToRestore)
  }
  
  public func scaled(maxPixelSize: CGFloat) -> Self {
    
    let scaledImageSize = imageSize.scaled(maxPixelSize: maxPixelSize)
            
    let scale = scaledImageSize.width / imageSize.width
    
    var new = scaled(scale)
    new.imageSize = scaledImageSize
    new.scaleToRestore = imageSize.width / scaledImageSize.width
        
    return new
  }
  
  public func restoreFromScaled() -> Self {
    var s = scaled(scaleToRestore)
    s.scaleToRestore = 1
    return s
  }
  
  private func scaled(_ scale: CGFloat) -> Self {
    
    var modified = self
    
    var cropExtent = modified.cropExtent
    var imageSize = modified.imageSize
    
    cropExtent.origin.x *= scale
    cropExtent.origin.y *= scale
    cropExtent.size.width *= scale
    cropExtent.size.height *= scale
        
    imageSize.width *= scale
    imageSize.height *= scale
    imageSize.width.round(.down)
    imageSize.height.round(.down)
    
    // TODO: Consider
//    modified.cropExtent = Self.normalizeRect(rect: cropExtent, in: imageSize, respectingAspectRatio: nil)
    modified.cropExtent = cropExtent
    modified.imageSize = imageSize
           
    return modified
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
  
  public mutating func updateCropExtentIfNeeded(by newAspectRatio: PixelAspectRatio) {
    guard PixelAspectRatio(cropExtent.size) != newAspectRatio else {
      return
    }
    updateCropExtent(by: newAspectRatio)
  }
  
  public mutating func updateCropExtent(byBoundingBox boundingBox: CGRect) {
                
    //    var proposed = cropExtent
    
//    proposed.origin.x = proposed.maxX * boundingBox.origin.x
//    proposed.origin.y = proposed.maxY * boundingBox.origin.y
//
//    proposed.size.width *= boundingBox.size.width
//    proposed.size.height *= boundingBox.size.height
    
    var boundingBox = boundingBox

    let proposed = VNImageRectForNormalizedRect(boundingBox, Int(imageSize.width), Int(imageSize.height))
        
    self.cropExtent = Self.normalizeRect(rect: proposed, in: imageSize, respectingAspectRatio: nil)
  }
    
  /// Updates cropExtent with new specified rect and normalizing value using aspectRatio(optional).
  /// cropExtent would be rounded in order to drop floating point value for fitting pixel.
  /// With specifing `respectingAspectRatio`, it fixes cropExtent's size.
  ///
  /// - Parameters:
  ///   - cropExtent:
  ///   - respectingAspectRatio:
  public mutating func updateCropExtentNormalizing(_ cropExtent: CGRect, respectingAspectRatio: PixelAspectRatio?) {
    self.cropExtent = Self.normalizeRect(rect: cropExtent, in: imageSize, respectingAspectRatio: respectingAspectRatio)
  }
  
  private static func normalizeRect(rect: CGRect, in imageSize: CGSize, respectingAspectRatio: PixelAspectRatio?) -> CGRect {
        
    var fixed = rect
    
    respectAspectRatio: do {
      
      if let aspectRatio = respectingAspectRatio {
                
        fixed.size = aspectRatio.size(byWidth: fixed.size.width)
        
      }
      
    }
    
    roundFloatingPoint: do {
          
      fixed.origin.x.round(.down)
      fixed.origin.y.round(.down)
      fixed.size.width.round(.down)
      fixed.size.height.round(.down)
      
      if fixed.origin.x < 0 {
        fixed.origin.x = 0
        fixed.size.width -= fixed.origin.x
      }
      
      if fixed.origin.y < 0 {
        fixed.origin.y = 0
        fixed.size.height -= fixed.origin.y
      }
      
      if fixed.width > imageSize.width {
        fixed.size.width = imageSize.width
      }
      
      if fixed.height > imageSize.height {
        fixed.size.height = imageSize.height
      }
      
      // FIXME:
      assert(fixed.maxX <= imageSize.width)
      assert(fixed.maxY <= imageSize.height)
      
      assert(fixed.origin.x >= 0)
      assert(fixed.origin.y >= 0)
      assert(fixed.width <= imageSize.width)
      assert(fixed.height <= imageSize.height)
      
    }
          
    #if DEBUG
    EngineLog.debug("""
      Normalizing CropExtent
      => \(fixed)
        - resultAspectRatio: \(PixelAspectRatio(fixed.size)._minimized().localizedText)
        - source: \(rect)
        - imageSize: \(imageSize)
        - respectingApectRatio: \(respectingAspectRatio.map { "\($0.width):\($0.height)" } ?? "null")
      """)
    #endif
    
    return fixed
  }
      
  /*
  @objc
  public func debugQuickLookObject() -> AnyObject? {
    
    let path = UIBezierPath(rect: CGRect(origin: .zero, size: imageSize))
    
    return path
  }
   */
}
