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

import MetalKit
import UIKit
import Verge

#if !COCOAPODS
import BrightroomEngine
#endif

/// This class is meant to display an uptodate preview of the current changes pending in an EditingStack
open class EditingStackImageView: PixelEditorCodeBasedView {
  public var editingStack: EditingStack? {
    didSet {
      subscriptions = .init()
      canvasView.setResolvedDrawnPaths(.init())
      reloadFromStack()
    }
  }
//  public override var contentMode: ContentMode {
//    didSet {
//      blurryImageView.contentMode = contentMode
//      canvasView.contentMode = contentMode
//    }
//  }

  private var loadingOverlayFactory: (() -> UIView)?
  private weak var currentLoadingOverlay: UIView?
  private var subscriptions = Set<VergeAnyCancellable>()
  private let canvasView = CanvasView()
  private let blurryImageView = _ImageView()
  private let backdropImageView = _ImageView()

  public override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = true
    contentMode = .scaleAspectFit
    isOpaque = false
    autoresizingMask = [.flexibleWidth, .flexibleHeight]

    [backdropImageView, blurryImageView, canvasView].forEach {
      addSubview($0)
      $0.clipsToBounds = true
      $0.bounds = bounds
      $0.autoresizingMask = [.flexibleHeight, .flexibleWidth]
      $0.contentMode = .scaleAspectFit
    }

    blurryImageView.mask = canvasView

  defaultAppearance: do {
    setLoadingOverlay(factory: {
      LoadingBlurryOverlayView(
        effect: UIBlurEffect(style: .dark),
        activityIndicatorStyle: .whiteLarge
      )
    })
  }
  }

  // MARK: - Functions

  override public func willMove(toWindow newWindow: UIWindow?) {
    super.willMove(toWindow: newWindow)

    guard newWindow != nil else {
      return
    }
    reloadFromStack()
  }

  override public func layoutSubviews() {
    super.layoutSubviews()

    if let loaded = editingStack?.store.state.loadedState {
      requestPreviewImage(state: loaded)
    }
  }

  private func reloadFromStack() {
    guard let editingStack = self.editingStack else {
      [backdropImageView, blurryImageView].forEach {
        $0.display(image: nil)
      }
      return
    }
    editingStack.start()
    editingStack.sinkState { [weak self] state in

      guard let self = self else { return }

      state.ifChanged(\.isLoading) { isLoading in
        self.updateLoadingOverlay(displays: isLoading)
      }
      state.ifChanged(\.loadedState?.currentEdit.drawings.blurredMaskPaths) { paths in
        self.canvasView.setResolvedDrawnPaths(paths ?? [])
      }

      state.ifChanged(\.loadedState?.currentEdit.crop) { crop in
        //XXX preview crop
      }

      UIView.performWithoutAnimation {
        if let state = state._beta_map(\.loadedState) {
          if state.hasChanges({ ($0.currentEdit) }, .init(==)) {
            self.requestPreviewImage(state: state.primitive)
          }
        }
      }
    }
    .store(in: &subscriptions)
  }

  public func setLoadingOverlay(factory: (() -> UIView)?) {
    _pixeleditor_ensureMainThread()
    loadingOverlayFactory = factory
  }

  private func requestPreviewImage(state: EditingStack.State.Loaded) {
    let croppedImage = state.makeCroppedImage()
    backdropImageView.display(image: croppedImage)
    blurryImageView.display(image: BlurredMask.blur(image: croppedImage))
//    postProcessing = state.currentEdit.filters.apply ??
  }

  private func updateLoadingOverlay(displays: Bool) {
    if displays, let factory = loadingOverlayFactory {
      let loadingOverlay = factory()
      currentLoadingOverlay = loadingOverlay
      addSubview(loadingOverlay)
      AutoLayoutTools.setEdge(loadingOverlay, self)

      loadingOverlay.alpha = 0
      UIViewPropertyAnimator(duration: 0.6, dampingRatio: 1) {
        loadingOverlay.alpha = 1
      }
      .startAnimation()

    } else {
      if let view = currentLoadingOverlay {
        UIViewPropertyAnimator(duration: 0.6, dampingRatio: 1) {
          view.alpha = 0
        }&>.do {
          $0.addCompletion { _ in
            view.removeFromSuperview()
          }
          $0.startAnimation()
        }
      }
    }
  }
}
