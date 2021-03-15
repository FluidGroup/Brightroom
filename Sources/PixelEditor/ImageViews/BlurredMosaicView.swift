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

final class BlurredMosaicView: DryDrawingView {
  private var displayingImageExtent: CGRect?
 
  private let imageView = MetalImageView()
  private let blurrSizeSlider = UISlider()

  var brush = OvalBrush(color: UIColor.black, width: 30)

  private let maskLayer = MaskLayer()

  private var subscriptions = Set<VergeAnyCancellable>()

  private var drawnPaths: [DrawnPathInRect] = [] {
    didSet {
      updateMask()
    }
  }
  
  private let editingStack: EditingStack

  // MARK: - Initializers

  public init(editingStack: EditingStack) {
    
    self.editingStack = editingStack
    
    super.init()

    setUp: do {
      backgroundColor = .clear

      addSubview(imageView)

      imageView.contentMode = .scaleAspectFill
      imageView.layer.mask = maskLayer

      maskLayer.contentsScale = UIScreen.main.scale
      maskLayer.drawsAsynchronously = true

      clipsToBounds = true
    }

    editingStack.sinkState { [weak self] state in

      guard let self = self else { return }

      state.ifChanged(\.editingCroppedPreviewImage) { previewImage in
        UIView.performWithoutAnimation {
          self.imageView.display(image: previewImage.flatMap { BlurredMask.blur(image: $0) })
        }
      }
      
      state.ifChanged(\.currentEdit.drawings.blurredMaskPaths) { paths in
        if self.drawnPaths != paths {
          self.drawnPaths = paths
        }
      }

    }
    .store(in: &subscriptions)
  }

  override func willBeginPan(path: UIBezierPath) {
//    guard let extent = displayingImageExtent else { return }

    // TODO: Don't use bounds
    let drawnPath = DrawnPathInRect(path: DrawnPath(brush: brush, path: path), in: bounds)
    drawnPaths.append(drawnPath)
  }

  override func panning(path: UIBezierPath) {
    updateMask()
  }

  override func didFinishPan(path: UIBezierPath) {
    updateMask()
    
    editingStack.set(blurringMaskPaths: drawnPaths)
  }

  override func layoutSublayers(of layer: CALayer) {
    super.layoutSublayers(of: layer)

    maskLayer.frame = bounds
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    imageView.frame = bounds
  }

  private func updateMask() {
    maskLayer.drawnPaths = drawnPaths
  }
}

extension BlurredMosaicView {
  private final class MaskLayer: CALayer {
    var drawnPaths: [GraphicsDrawing] = [] {
      didSet {
        setNeedsDisplay()
      }
    }

    override func draw(in ctx: CGContext) {
      drawnPaths.forEach { $0.draw(in: ctx, canvasSize: bounds.size) }
    }
  }
}
