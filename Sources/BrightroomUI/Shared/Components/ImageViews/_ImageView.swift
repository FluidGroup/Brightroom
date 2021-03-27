//
//  _ImageView.swift
//  PixelEditor
//
//  Created by Muukii on 2021/03/07.
//  Copyright © 2021 muukii. All rights reserved.
//

import UIKit

final class _ImageView: UIImageView, CIImageDisplaying {
  
  var postProcessing: (CIImage) -> CIImage = { $0 } {
    didSet {
      setNeedsDisplay()
    }
  }
  
  private let resizesOnDisplay: Bool
  
  init(resizesOnDisplay: Bool = false) {
    self.resizesOnDisplay = resizesOnDisplay
    super.init(frame: .zero)
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
        
    if let cgImage = postProcessing(_image).cgImage {
      EditorLog.debug("[_ImageView] image color-space \(cgImage.colorSpace as Any)")
      uiImage = UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    } else {
      EditorLog.debug("[_ImageView] image does not have cgImage, displaying might be slow.")
      //      assertionFailure()
      // Displaying will be slow in iOS13
      
      let fixed = _image.transformed(
        by: .init(
          translationX: -_image.extent.origin.x,
          y: -_image.extent.origin.y
        ))
      
      if resizesOnDisplay {
        var pixelBounds = bounds
        pixelBounds.size.width *= UIScreen.main.scale
        pixelBounds.size.height *= UIScreen.main.scale
        let downsampled = downsample(image: fixed, bounds: pixelBounds, contentMode: contentMode)
        
        let processed = postProcessing(downsampled)
        
        EditorLog.debug("[_ImageView] image color-space \(processed.colorSpace as Any)")
        
        uiImage = UIImage(
          ciImage: postProcessing(downsampled),
          scale: 1,
          orientation: .up
        )
      } else {
        
        let processed = postProcessing(_image)
        
        EditorLog.debug("[_ImageView] image color-space \(processed.colorSpace as Any)")
        
        uiImage = UIImage(
          ciImage: processed,
          scale: 1,
          orientation: .up
        )
      }
                   
    }
    
    assert(uiImage.scale == 1)
    self.image = uiImage

  }
}
