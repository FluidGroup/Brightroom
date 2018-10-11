//
//  ImageTool.swift
//  PixelEngine
//
//  Created by muukii on 10/9/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import UIKit
import CoreImage
import AVFoundation

public enum ImageTool {

  public static func resize(to pixelSize: CGSize, from image: CIImage) -> CIImage? {

    var targetSize = pixelSize
    targetSize.height.round()
    targetSize.width.round()

    if #available(iOS 12, *) {

      let scaleX = targetSize.width / image.extent.width
      let scaleY = targetSize.height / image.extent.height

      let resized = image
          .transformed(by: .init(scaleX: scaleX, y: scaleY))

      let result = resized
          .transformed(by: .init(translationX: -resized.extent.origin.x, y: -resized.extent.origin.y))
          .insertingIntermediate(cache: true)

      return result

    } else {

      UIGraphicsBeginImageContext(targetSize)

      UIImage(ciImage: image).draw(in: CGRect(origin: .zero, size: targetSize))
      let drawImage = UIGraphicsGetImageFromCurrentImageContext()

      UIGraphicsEndImageContext()

      guard
        let _drawImage = drawImage,
        let data = _drawImage.pngData(),
        let image = CIImage(data: data)
        else {
          return nil
      }

      return image
    }
  }

}
