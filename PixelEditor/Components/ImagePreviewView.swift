//
//  ImagePreviewView.swift
//  PixelEditor
//
//  Created by muukii on 10/10/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation


import protocol PixelEngine.HardwareImageViewType
import class PixelEngine.GLImageView

#if !targetEnvironment(simulator)
import class PixelEngine.MetalImageView
#endif

final class ImagePreviewView : UIView {

  let imageView: UIImageView = .init()

  var image: CIImage? {
    get {
      return imageView.image?.ciImage
    }
    set {
      imageView.image = newValue.map { UIImage(ciImage: $0, scale: UIScreen.main.scale, orientation: .up) }
    }
  }

  override init(frame: CGRect) {
    super.init(frame: .zero)

    addSubview(imageView)
    imageView.contentMode = .scaleAspectFill
    imageView.frame = bounds
    imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
  }

  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

}
