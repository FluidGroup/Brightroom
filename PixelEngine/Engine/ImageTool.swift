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

  public static func createPreviewSizeImage(
    source inputImage: CIImage,
    size: CGSize
    ) -> CIImage? {

    let size = AVMakeRect(aspectRatio: inputImage.extent.size, insideRect: CGRect(origin: .zero, size: size)).size

    var targetSize = size
    targetSize.height.round()
    targetSize.width.round()

    UIGraphicsBeginImageContext(targetSize)

    UIImage(ciImage: inputImage).draw(in: CGRect(origin: .zero, size: targetSize))
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
