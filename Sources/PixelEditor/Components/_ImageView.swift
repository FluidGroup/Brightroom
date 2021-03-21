//
//  _ImageView.swift
//  PixelEditor
//
//  Created by Muukii on 2021/03/07.
//  Copyright © 2021 muukii. All rights reserved.
//

import UIKit

final class _ImageView: UIImageView, HardwareImageViewType {
  
  private var ciImage: CIImage?
  
  override var isHidden: Bool {
    didSet {
      if isHidden == false {
        update()
      }
    }
  }
  
  func display(image: CIImage?) {
            
    self.ciImage = image

    if isHidden == false {
      update()
    }
  }
  
  private func update() {

    guard let _image = ciImage else {
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

    assert(uiImage.scale == 1)
    self.image = uiImage

  }
}
