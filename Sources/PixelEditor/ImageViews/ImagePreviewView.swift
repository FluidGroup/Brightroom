//
//  ImagePreviewView.swift
//  PixelEditor
//
//  Created by muukii on 10/10/18.
//  Copyright © 2018 muukii. All rights reserved.
//

import Foundation

final class ImagePreviewView : UIView {

  let originalImageView: UIImageView = .init()
  let imageView: UIImageView = .init()
  
  var originalImage: CIImage? {
    get {
      return originalImageView.image?.ciImage
    }
    set {
      originalImageView.image = newValue
        .flatMap { $0.transformed(by: .init(translationX: -$0.extent.origin.x, y: -$0.extent.origin.y)) }
        .flatMap { UIImage(ciImage: $0, scale: UIScreen.main.scale, orientation: .up) }
      EditorLog.debug("ImagePreviewView.image set", newValue?.extent as Any)
    }
  }

  var image: CIImage? {
    get {
      return imageView.image?.ciImage
    }
    set {
      imageView.image = newValue
        .flatMap { $0.transformed(by: .init(translationX: -$0.extent.origin.x, y: -$0.extent.origin.y)) }
        .flatMap { UIImage(ciImage: $0, scale: UIScreen.main.scale, orientation: .up) }
      EditorLog.debug("ImagePreviewView.image set", newValue?.extent as Any)
    }
  }
  
  override init(frame: CGRect) {
    super.init(frame: .zero)

    [
      originalImageView,
      imageView
      ].forEach { imageView in
        addSubview(imageView)
        imageView.contentMode = .scaleAspectFill
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }
    
    originalImageView.isHidden = true
    
  }

  required init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesBegan(touches, with: event)
    originalImageView.isHidden = false
    imageView.isHidden = true
  }
  
  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesEnded(touches, with: event)
    originalImageView.isHidden = true
    imageView.isHidden = false
  }
  
  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesCancelled(touches, with: event)
    originalImageView.isHidden = true
    imageView.isHidden = false
  }
}
