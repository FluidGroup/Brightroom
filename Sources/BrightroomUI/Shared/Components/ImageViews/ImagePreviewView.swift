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

#if !COCOAPODS
import BrightroomEngine
#endif
import UIKit
import Verge

/**
 A view that displays the edited image, plus displays original image for comparison with touch-down interaction.
 */
public final class ImagePreviewView: PixelEditorCodeBasedView {
  // MARK: - Properties

  #if true
  private let imageView = _PreviewImageView()
  private let originalImageView = _PreviewImageView()
  #else
  private let imageView = MetalImageView()
  private let originalImageView = MetalImageView()
  #endif

  private let editingStack: EditingStack
  private var subscriptions = Set<VergeAnyCancellable>()

  private var loadingOverlayFactory: (() -> UIView)?
  private weak var currentLoadingOverlay: UIView?

  private var isBinding = false

  // MARK: - Initializers

  public init(editingStack: EditingStack) {
    // FIXME: Loading State

    self.editingStack = editingStack

    super.init(frame: .zero)

    originalImageView.accessibilityIdentifier = "pixel.originalImageView"

    imageView.accessibilityIdentifier = "pixel.editedImageView"

    clipsToBounds = true

    [
      originalImageView,
      imageView,
    ].forEach { imageView in
      addSubview(imageView)
      imageView.clipsToBounds = true
      imageView.contentMode = .scaleAspectFit
      imageView.isOpaque = false
      imageView.frame = bounds
      imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    originalImageView.isHidden = true

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

  public func setLoadingOverlay(factory: (() -> UIView)?) {
    _pixeleditor_ensureMainThread()
    loadingOverlayFactory = factory
  }

  override public func willMove(toWindow newWindow: UIWindow?) {
    super.willMove(toWindow: newWindow)

    if newWindow != nil {
      editingStack.start()

      if isBinding == false {
        isBinding = true
        editingStack.sinkState { [weak self] state in

          guard let self = self else { return }

          state.ifChanged(\.isLoading) { isLoading in
            self.updateLoadingOverlay(displays: isLoading)
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
    }
  }

  private func requestPreviewImage(state: EditingStack.State.Loaded) {
    let croppedImage = state.makeCroppedImage()
    imageView.display(image: croppedImage)
    imageView.postProcessing = state.currentEdit.filters.apply
    originalImageView.display(image: croppedImage)
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

  override public func layoutSubviews() {
    super.layoutSubviews()

    if let loaded = editingStack.store.state.loadedState {
      requestPreviewImage(state: loaded)
    }
  }

  override public func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesBegan(touches, with: event)
    originalImageView.isHidden = false
    imageView.isHidden = true
  }

  override public func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesEnded(touches, with: event)
    originalImageView.isHidden = true
    imageView.isHidden = false
  }

  override public func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesCancelled(touches, with: event)
    originalImageView.isHidden = true
    imageView.isHidden = false
  }
}

private final class _PreviewImageView: UIImageView, CIImageDisplaying {
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
      //      assertionFailure()
      // Displaying will be slow in iOS13

      let fixed = _image.removingExtentOffset()

      var pixelBounds = bounds
      pixelBounds.size.width *= UIScreen.main.scale
      pixelBounds.size.height *= UIScreen.main.scale

      let targetSize = Geometry.sizeThatAspectFit(size: fixed.extent.size, maxPixelSize: max(pixelBounds.width, pixelBounds.height))

      let scaleX = targetSize.width / fixed.extent.width
      let scaleY = targetSize.height / fixed.extent.height
      let scale = min(scaleX, scaleY)

      let resolvedImage = fixed
        .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    
      let processed = postProcessing(resolvedImage.removingExtentOffset())

      EditorLog.debug("[_ImageView] image color-space \(processed.colorSpace as Any)")

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
