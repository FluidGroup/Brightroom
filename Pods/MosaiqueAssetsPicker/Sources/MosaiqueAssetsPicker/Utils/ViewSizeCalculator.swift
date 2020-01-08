// ViewSizeCalculator.swift
//
// Copyright (c) 2015 muukii
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

public struct ViewSizeCalculator<T : UIView> {
  
  public let sourceView: T
  public let calculateTargetView: UIView
  public let cache: NSCache<NSString, NSValue> = NSCache<NSString, NSValue>()
  
  public init(sourceView: T, calculateTargetView: (T) -> UIView) {
    
    self.sourceView = sourceView
    self.calculateTargetView = calculateTargetView(sourceView)
  }
  
  public func calculate(
    width: CGFloat?,
    height: CGFloat?,
    cacheKey: String?,
    closure: (T) -> Void) -> CGSize {
    
    let combinedCacheKey = cacheKey.map({ $0 + "|" + "\(String(describing: width)):\(String(describing: height))" })
    
    if let combinedCacheKey = combinedCacheKey {
      if let size = cache.object(forKey: combinedCacheKey as NSString)?.cgSizeValue {
        return size
      }
    }
    
    closure(sourceView)
    
    let targetSize = CGSize(
        width: width ?? UIView.layoutFittingCompressedSize.width,
        height: height ?? UIView.layoutFittingCompressedSize.height
    )
    let horizontalPriority: UILayoutPriority = width == nil ? .fittingSizeLevel : .required
    let verticalPriority: UILayoutPriority = height == nil ? .fittingSizeLevel : .required
    
    let size = calculateTargetView.systemLayoutSizeFitting(
      targetSize,
      withHorizontalFittingPriority: horizontalPriority,
      verticalFittingPriority: verticalPriority
    )
    
    if let combinedCacheKey = combinedCacheKey {
      cache.setObject(NSValue(cgSize: size), forKey: combinedCacheKey as NSString)
    }
    return size
  }
}
