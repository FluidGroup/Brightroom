//
//  _ImageView.swift
//  PixelEditor
//
//  Created by Muukii on 2021/03/07.
//  Copyright © 2021 muukii. All rights reserved.
//

import UIKit

final class _ImageView: UIImageView, HardwareImageViewType {
  func display(image: CIImage?) {
    func setImage(image: UIImage) {
      assert(image.scale == 1)
      self.image = image
    }
        
    guard let _image = image else {
      self.image = nil
      return
    }
    
    let uiImage: UIImage
    
    if let cgImage = _image.cgImage {
      uiImage = UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    } else {
      EditorLog.debug("[_ImageView] image does not have cgImage, displaying might be slow.")
      //      assertionFailure()
      // Displaying will be slow in iOS13
      uiImage = UIImage(
        ciImage: _image.transformed(
          by: .init(
            translationX: -_image.extent.origin.x,
            y: -_image.extent.origin.y
          )),
        scale: 1,
        orientation: .up
      )
    }
    
    setImage(image: uiImage)
  }
}
