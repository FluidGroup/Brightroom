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

  private static let ciContext = CIContext(options: [
//    .useSoftwareRenderer : false,
    .highQualityDownsample: true,
//    .workingColorSpace : CGColorSpaceCreateDeviceRGB()
    ]
  )

  public static func resize(to pixelSize: CGSize, from image: CIImage) -> CIImage? {

    var targetSize = pixelSize
    targetSize.height.round(.down)
    targetSize.width.round(.down)

    let scaleX = targetSize.width / image.extent.width
    let scaleY = targetSize.height / image.extent.height

    if false, #available(iOS 12, *) {

      // This code does not work well.
      // In UIImageView, display 1px white line.

      let resized = image
        .transformed(by: .init(scaleX: scaleX, y: scaleY))

      // TODO: round extent

      let result = resized
        .transformed(by: .init(
          translationX: -(resized.extent.minX - resized.extent.minX.rounded(.down)),
          y: -(resized.extent.minY - resized.extent.minY.rounded(.down))
          )
        )
        .insertingIntermediate()

      return result

    } else {

      return
        autoreleasepool { () -> CIImage? in

          let originalExtent = image.extent

          let format = UIGraphicsImageRendererFormat.default()
          format.scale = 1

          let _data = UIGraphicsImageRenderer.init(size: targetSize, format: format)
            .image { c in
              let cgContext = c.cgContext
              cgContext.translateBy(x: 0, y: targetSize.height)
              cgContext.scaleBy(x: 1, y: -1)
              let cgImage = ciContext.createCGImage(image, from: image.extent)!
              cgContext.draw(cgImage, in: CGRect(origin: .zero, size: targetSize))
            }
            .pngData()

          guard
            let data = _data,
            let image = CIImage(data: data)
            else {
              return nil
          }

          let r = image.transformed(by: .init(
            translationX: (originalExtent.origin.x * scaleX).rounded(.down),
            y: (originalExtent.origin.y * scaleY).rounded(.down)
            )
          )

          return r
      }

    }
  }

}
