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

  let imageView: UIView & HardwareImageViewType = {
    #if canImport(MetalKit) && !targetEnvironment(simulator)
    return MetalImageView()
    #else
    return GLImageView()
    #endif
  }()

  var image: CIImage? {
    get {
      return imageView.image
    }
    set {
      imageView.image = newValue
    }
  }

  override init(frame: CGRect) {
    super.init(frame: .zero)

    addSubview(imageView)
    imageView.frame = bounds
    imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
  }

  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

}
