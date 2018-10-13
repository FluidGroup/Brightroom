//
//  ImageSource.swift
//  PixelEngine
//
//  Created by muukii on 10/13/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

public struct ImageSource {

  public let image: CIImage

  public init(source: UIImage) {

    let image = CIImage(image: source)!
    let fixedOriantationImage = image.oriented(forExifOrientation: imageOrientationToTiffOrientation(source.imageOrientation))

    self.image = fixedOriantationImage
  }

  public init(source: CIImage) {

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
