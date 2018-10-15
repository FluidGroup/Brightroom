//
//  ImageSource.swift
//  PixelEngine
//
//  Created by muukii on 10/13/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

import CoreImage

#if canImport(UIKit)
import UIKit
#endif

public struct ImageSource {

  public let image: CIImage

  #if os(iOS)

  public init(source: UIImage) {

    let image = CIImage(image: source)!
    let fixedOriantationImage = image.oriented(forExifOrientation: imageOrientationToTiffOrientation(source.imageOrientation))

    self.init(source: fixedOriantationImage)
  }

  #endif

  public init(source: CIImage) {

    precondition(source.extent.origin == .zero)
    self.image = source
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
  }
}
