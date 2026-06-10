//
// Copyright (c) 2018 Muukii <muukii.app@gmail.com>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import UIKit

import BrightroomEngine

public enum MaskingBrushSize: Equatable, Sendable {
  case point(CGFloat)
  case pixel(CGFloat)
}

final class _CanvasView: _PixelEditorCodeBasedView {

  override class var layerClass: AnyClass {
    #if false
    return CATiledLayer.self
    #else
    return CALayer.self
    #endif
  }

  private var resolvedDrawnPaths: [DrawnPath] = [] {
    didSet {
      updateResolvedShapeLayers()
    }
  }

  private var resolvedShapeLayers: [CAShapeLayer] = []
  private var previewShapeLayer: CAShapeLayer?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false

    if let tiledLayer = layer as? CATiledLayer {
      tiledLayer.tileSize = .init(width: 512, height: 512)
    }
  }

  private func updateResolvedShapeLayers() {
    let layers = resolvedDrawnPaths.map { path -> CAShapeLayer in
      let layer = Self.makeShapeLayer(for: path.brush)
      layer.path = path.bezierPath.cgPath
      layer.frame = bounds
      return layer
    }

    // TODO: Get better way for performance.
    resolvedShapeLayers.forEach {
      $0.removeFromSuperlayer()
    }

    layers.forEach {
      layer.addSublayer($0)
    }
    resolvedShapeLayers = layers
  }
  
  private static func makeShapeLayer(for brush: OvalBrush) -> CAShapeLayer {
    
    let layer = CAShapeLayer()
        
    layer.lineWidth = brush.pixelSize
    layer.strokeColor = brush.color.cgColor
    layer.opacity = Float(brush.alpha)
    layer.lineCap = .round
    layer.fillColor = UIColor.clear.cgColor
    layer.drawsAsynchronously = true
    
    return layer
    
  }
  
  var previewDrawnPath: DrawnPath? {
    didSet {
      
      previewShapeLayer?.removeFromSuperlayer()
      previewShapeLayer = nil
      
      if let path = previewDrawnPath {
        let layer = Self.makeShapeLayer(for:  path.brush)
        layer.path = path.bezierPath.cgPath
        self.layer.addSublayer(layer)
        self.previewShapeLayer = layer
      }
      
      updatePreviewDrawing()
    }
  }
  
  func updatePreviewDrawing() {
        
    guard let drawnPath = previewDrawnPath else {
      return
    }
    
    let path = drawnPath.bezierPath
    let cgPath = path.cgPath
    
    self.previewShapeLayer?.path = cgPath
    
  }
  
  func setResolvedDrawnPaths(_ paths: [DrawnPath]) {
    resolvedDrawnPaths = paths
  }
   
  override func layoutSubviews() {
    super.layoutSubviews()
    resolvedShapeLayers.forEach {
      $0.frame = bounds
    }
    previewShapeLayer?.frame = bounds
  }
  
}
