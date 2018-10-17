//
//  ImagePreviewView.swift
//  PixelEditor
//
//  Created by muukii on 10/10/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

final class ImagePreviewView : UIView {

  let imageView: UIImageView = .init()

  var image: CIImage? {
    get {
      return imageView.image?.ciImage
    }
    set {
      imageView.image = newValue
        .flatMap { $0.transformed(by: .init(translationX: -$0.extent.origin.x, y: -$0.extent.origin.y)) }
        .flatMap { UIImage(ciImage: $0, scale: UIScreen.main.scale, orientation: .up) }
      Log.debug("ImagePreviewView.image set", newValue?.extent)
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
