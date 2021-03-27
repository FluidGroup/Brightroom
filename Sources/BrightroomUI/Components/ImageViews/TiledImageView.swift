//
//  TiledImageView.swift
//  PixelEditor
//
//  Created by Muukii on 2021/03/18.
//  Copyright © 2021 muukii. All rights reserved.
//

import Foundation
import CoreImage
import UIKit

public final class TiledImageView: PixelEditorCodeBasedView, CIImageDisplaying {
  
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
    
    tiledLayer.tileSize = .init(width: 1280, height: 1280)
  }
  
  public override func draw(_ rect: CGRect) {
    
    guard let image = image else { return }
    
    let currentContext = UIGraphicsGetCurrentContext()!
    let ciContext = CIContext(cgContext: currentContext, options: [:])
    
    ciContext.draw(image, in: rect, from: rect)
  }
  
}
