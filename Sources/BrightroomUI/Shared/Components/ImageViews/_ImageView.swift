//
//  _ImageView.swift
//  PixelEditor
//
//  Created by Muukii on 2021/03/07.
//  Copyright © 2021 muukii. All rights reserved.
//

import UIKit
#if !COCOAPODS
import BrightroomEngine
#endif

final class _ImageView: UIImageView, CIImageDisplaying {
  var postProcessing: (CIImage) -> CIImage = { $0 } {
    didSet {
      update()
    }
  }

  init() {
    super.init(frame: .zero)
    layer.drawsAsynchronously = true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private var ciImage: CIImage?

  override var isHidden: Bool {
    didSet {
      if isHidden == false {
        update()
      }
    }
  }

  func display(image: CIImage?) {
    ciImage = image

    if isHidden == false {
      update()
    }
  }

  private func update() {
    guard let _image = ciImage else {
      image = nil
      return
    }

    let uiImage: UIImage
    
    if let cgImage = postProcessing(_image).cgImage {
      uiImage = UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    } else {
      let processed = postProcessing(_image)
      uiImage = UIImage(
        ciImage: processed,
        scale: 1,
        orientation: .up
      )
    }

    assert(uiImage.scale == 1)
    image = uiImage
  }
}

