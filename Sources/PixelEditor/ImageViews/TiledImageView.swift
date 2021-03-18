//
//  TiledImageView.swift
//  PixelEditor
//
//  Created by Muukii on 2021/03/18.
//  Copyright © 2021 muukii. All rights reserved.
//

import Foundation
import CoreImage

public final class TiledImageView: PixelEditorCodeBasedView, HardwareImageViewType {
  
  private var image: CIImage?
    
  public func display(image: CIImage?) {
    self.image = image
    setNeedsDisplay()
  }
  
  public override class var layerClass: AnyClass {
    CATiledLayer.self
  }
  
  public override init(frame: CGRect) {
    super.init(frame: frame)
    
    let tiledLayer = layer as! CATiledLayer
    
    tiledLayer.tileSize = .init(width: 256, height: 256)
  }
  
  public override func draw(_ rect: CGRect) {
    
    guard let image = image else { return }
    
    let currentContext = UIGraphicsGetCurrentContext()!
    let ciContext = CIContext(cgContext: currentContext, options: [:])
    
    ciContext.draw(image, in: rect, from: image.extent)
  }
  
}
