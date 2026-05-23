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

import SwiftUI
import UIKit

import BrightroomEngine

final class _BlurryMaskingView: _PixelEditorCodeBasedView, UIScrollViewDelegate {

  private var stateBounds: CGRect = .zero
  private var proposedCrop: EditingCrop?
  private var brushSize: MaskingBrushSize = .point(30)

  private func brushPixelSize() -> CGFloat? {
    guard let proposedCrop = proposedCrop else {
      return nil
    }

    let aspectRatio = PixelAspectRatio(proposedCrop.cropExtent.size)
    let size = aspectRatio.sizeThatFits(in: stateBounds.size)

    let (min, _) = proposedCrop.calculateZoomScale(visibleSize: size)

    let scale = proposedCrop.scaleForDrawing()

    switch brushSize {
    case let .point(points):
      return points / scale / min
    case let .pixel(pixels):
      return pixels
    }
  }
  
  private final class ContainerView: _PixelEditorCodeBasedView {
    func addContent(_ view: UIView) {
      addSubview(view)
      view.frame = bounds
      view.autoresizingMask = [.flexibleHeight, .flexibleWidth]
    }
  }
  
  var isBackdropImageViewHidden: Bool {
    get {
      backingView.isImageViewHidden
    }
    set {
      backingView.isImageViewHidden = newValue
    }
  }
  
  var isBlurryImageViewHidden: Bool {
    get {
      blurryImageView.isHidden
    }
    set {
      blurryImageView.isHidden = newValue
    }
  }

  private let backingView: CropView

  private let containerView = ContainerView()

  private let blurryImageView = _ImageView()

  private let drawingView = _SmoothPathDrawingView()

  private let canvasView = _CanvasView()

  private let editingStack: EditingStack

  private var currentBrush: OvalBrush?

  // MARK: - Initializers
  
  init(editingStack: EditingStack) {

    self.editingStack = editingStack
    self.backingView = .init(
      editingStack: editingStack,
      contentInset: .zero
    )
    self.backingView.areAnimationsEnabled = false
    self.backingView.accessibilityIdentifier = "BlurryMasking"

    super.init(frame: .zero)
    
    setUp: do {
      backgroundColor = .clear
      
      addSubview(backingView)
      backingView.isGuideInteractionEnabled = false
      backingView.clipsToGuide = true
      backingView.setCropOutsideOverlay(nil)
      backingView.setCropInsideOverlay(nil)
      backingView.setOverlayInImageView(containerView)
      backingView.isScrollEnabled = false
      backingView.isZoomEnabled = false
      backingView.isAutoApplyEditingStackEnabled = false

      containerView.addContent(blurryImageView)
      containerView.addContent(canvasView)
      containerView.addContent(drawingView)
      
      blurryImageView.accessibilityIdentifier = "blurryImageView"
      blurryImageView.isUserInteractionEnabled = false
      blurryImageView.contentMode = .scaleAspectFit
      
      blurryImageView.mask = canvasView
      clipsToBounds = true
    }
    
    drawingView.handlers = drawingView.handlers&>.modify {
      $0.willBeginPan = { [unowned self] path in

        guard let pixelSize = brushPixelSize() else {
          assertionFailure("It seems currently loading state.")
          return
        }

        currentBrush = .init(color: .black, pixelSize: pixelSize)

        let drawnPath = DrawnPath(brush: currentBrush!, path: path)
        canvasView.previewDrawnPath = drawnPath
      }
      $0.panning = { [unowned self] path in
        canvasView.updatePreviewDrawing()
      }
      $0.didFinishPan = { [unowned self] path in
        canvasView.updatePreviewDrawing()

        let _path = (path.copy() as! UIBezierPath)

        let drawnPath = DrawnPath(brush: currentBrush!, path: _path)

        canvasView.previewDrawnPath = nil
        editingStack.append(blurringMaskPaths: CollectionOfOne(drawnPath))

        currentBrush = nil
      }
    }
  }

  func loadCurrentEditingStackState() {
    let loadedState = editingStack.requireLoadedStateForLoadedUIView()
    let crop = loadedState.currentEdit.crop

    backingView.load(
      image: loadedState.imageForCrop,
      crop: crop
    )

    [canvasView, drawingView].forEach { view in
      view.bounds = .init(origin: .zero, size: crop.imageSize)
      let scale = Geometry.diagonalRatio(to: crop.scrollViewContentSize(), from: crop.imageSize)
      view.transform = .init(scaleX: scale, y: scale)
      view.frame.origin = .zero
    }

    if crop != proposedCrop {
      proposedCrop = crop
    }

    blurryImageView.display(image: BlurredMask.blur(image: loadedState.editingPreviewImage))
    canvasView.setResolvedDrawnPaths(loadedState.currentEdit.drawings.blurredMaskPaths)
  }

  func setBrushSize(_ size: MaskingBrushSize) {
    brushSize = size
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    backingView.frame = bounds

    if stateBounds != bounds {
      stateBounds = bounds
    }

  }
}

public struct SwiftUIBlurryMaskingView: View {

  private let editingStack: EditingStack

  private var _brushSize: MaskingBrushSize?

  private var _isBackdropImageViewHidden: Bool?
  private var _isBlurryImageViewHidden: Bool?

  public init(
    editingStack: EditingStack
  ) {
    self.editingStack = editingStack
  }

  public var body: some View {
    ZStack {
      if editingStack.loadedState != nil {
        LoadedBlurryMaskingViewRepresentable(
          editingStack: editingStack,
          brushSize: _brushSize,
          isBackdropImageViewHidden: _isBackdropImageViewHidden,
          isBlurryImageViewHidden: _isBlurryImageViewHidden
        )
        .transition(.opacity.animation(.smooth))
      } else {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .transition(.opacity.animation(.smooth))
      }
    }
    .onAppear {
      editingStack.start()
    }
  }

  public consuming func brushSize(_ brushSize: MaskingBrushSize) -> Self {
    self._brushSize = brushSize
    return self
  }

  public consuming func hideBackdropImageView(_ isBackdropImageViewHidden: Bool) -> Self {

    self._isBackdropImageViewHidden = isBackdropImageViewHidden
    return self
  }

  public consuming func hideBlurryImageView(_ isBlurryImageViewHidden: Bool) -> Self {

    self._isBlurryImageViewHidden = isBlurryImageViewHidden
    return self
  }

}

private struct LoadedBlurryMaskingViewRepresentable: UIViewRepresentable {

  let editingStack: EditingStack
  let brushSize: MaskingBrushSize?
  let isBackdropImageViewHidden: Bool?
  let isBlurryImageViewHidden: Bool?

  func makeUIView(context: Context) -> _BlurryMaskingView {
    let view = _BlurryMaskingView(editingStack: editingStack)
    configure(view)
    view.loadCurrentEditingStackState()
    return view
  }

  func updateUIView(_ uiView: _BlurryMaskingView, context: Context) {
    configure(uiView)
    uiView.loadCurrentEditingStackState()
  }

  private func configure(_ view: _BlurryMaskingView) {
    if let brushSize {
      view.setBrushSize(brushSize)
    }
    if let isBackdropImageViewHidden {
      view.isBackdropImageViewHidden = isBackdropImageViewHidden
    }
    if let isBlurryImageViewHidden {
      view.isBlurryImageViewHidden = isBlurryImageViewHidden
    }
  }
}
