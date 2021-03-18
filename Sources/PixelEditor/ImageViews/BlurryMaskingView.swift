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

#if !COCOAPODS
import PixelEngine
#endif
import Verge

public final class BlurryMaskingView: PixelEditorCodeBasedView {
  
  var brush = OvalBrush(color: UIColor.black, width: 30)

  private let backdropImageView = MetalImageView()
  
  private let blurryImageView = MetalImageView()
  
  private let drawingView = SmoothPathDrawingView()
  
  private let maskLayer = CanvasLayer()
  
  private var subscriptions = Set<VergeAnyCancellable>()
 
  private let editingStack: EditingStack
  private let imageSize: CGSize
  private var crop: EditingCrop

  // MARK: - Initializers

  public init(editingStack: EditingStack) {
    self.editingStack = editingStack
    editingStack.start()
    
    let state = editingStack.state
    
    self.imageSize = state.imageSize
    self.crop = state.currentEdit.crop

    super.init(frame: .zero)
      
    setUp: do {
      backgroundColor = .clear
            
      addSubview(backdropImageView)
      addSubview(blurryImageView)
      addSubview(drawingView)
      
      backdropImageView.accessibilityIdentifier = "backdropImageView"
      backdropImageView.isUserInteractionEnabled = false
      backdropImageView.contentMode = .scaleAspectFit

      blurryImageView.accessibilityIdentifier = "blurryImageView"
      blurryImageView.isUserInteractionEnabled = false
      blurryImageView.contentMode = .scaleAspectFit

      blurryImageView.layer.mask = maskLayer

      maskLayer.contentsScale = UIScreen.main.scale
      maskLayer.drawsAsynchronously = true

      clipsToBounds = true
    }
    
    drawingView.handlers = drawingView.handlers&>.modify {
      $0.willBeginPan = { [unowned self] path in
        let drawnPath = DrawnPathInRect(path: DrawnPath(brush: brush, path: path), in: bounds)
        maskLayer.previewDrawnPaths = [drawnPath]
      }
      $0.panning = { [unowned self] path in
        maskLayer.setNeedsDisplay()
      }
      $0.didFinishPan = { [unowned self] path in
        maskLayer.setNeedsDisplay()
        
        let _path = (path.copy() as! UIBezierPath)
        _path.apply(.init(translationX: crop.cropExtent.minX, y: crop.cropExtent.minY))
        
        print(_path)
        
        let drawnPath = DrawnPathInRect(path: DrawnPath(brush: brush, path: _path), in: bounds)
        
        maskLayer.previewDrawnPaths = []
        editingStack.append(blurringMaskPaths: CollectionOfOne(drawnPath))
      }
    }

    editingStack.sinkState { [weak self] state in

      guard let self = self else { return }
                
      state.ifChanged(\.editingCroppedPreviewImage) { previewImage in
        
        self.crop = state.currentEdit.crop
        self.maskLayer.crop = state.currentEdit.crop
        
        UIView.performWithoutAnimation {
          self.backdropImageView.display(image: previewImage)
          self.blurryImageView.display(image: previewImage.flatMap { BlurredMask.blur(image: $0) })
        }
      }
      
      state.ifChanged(\.currentEdit.drawings.blurredMaskPaths) { paths in
        if self.maskLayer.resolvedDrawnPaths != paths {
          self.maskLayer.resolvedDrawnPaths = paths
        }
      }
      
    }
    .store(in: &subscriptions)
  }

  override public func layoutSubviews() {
    super.layoutSubviews()
        
    let fittingFrame = Geometry.rectThatAspectFit(aspectRatio: crop.cropExtent.size, boundingRect: bounds)

    backdropImageView.frame = fittingFrame
    blurryImageView.frame = fittingFrame
    drawingView.frame = fittingFrame
    maskLayer.frame = blurryImageView.bounds
  }

}

extension BlurryMaskingView {
  private final class CanvasLayer: CALayer {
    
    var crop: EditingCrop? {
      didSet {
        setNeedsDisplay()
      }
    }
    
    var previewDrawnPaths: [DrawnPathInRect] = [] {
      didSet {
        setNeedsDisplay()
      }
    }
    
    var resolvedDrawnPaths: [DrawnPathInRect] = [] {
      didSet {
        setNeedsDisplay()
      }
    }
    
    override func draw(in ctx: CGContext) {
                  
      guard let crop = crop else { return }
      
      // FIXME: If we use CATiledLayer, it calls this method by multiple times.
      
      let inRect = ctx.boundingBoxOfClipPath
          
//      ctx.boundingBoxOfClipPath
      
      resolvedDrawnPaths.forEach {
        $0.draw(in: ctx, crop: crop, canvasSize: bounds.size)
      }
      
      previewDrawnPaths.forEach {
        $0.draw(in: ctx, crop: crop, canvasSize: bounds.size)
      }
    }
  }
}
