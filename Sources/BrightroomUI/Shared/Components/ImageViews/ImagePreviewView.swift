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

import BrightroomEngine
import SwiftUI
import UIKit

public struct SwiftUIImagePreviewView: View {

  private let editingStack: EditingStack
  private var displayBackground: ImageDisplayBackground = .transparent

  public init(editingStack: EditingStack) {
    self.editingStack = editingStack
  }

  public var body: some View {
    ZStack {
      if editingStack.loadedState != nil {
        LoadedImagePreviewRepresentable(
          editingStack: editingStack,
          displayBackground: displayBackground
        )
      } else {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .onAppear {
      editingStack.start()
    }
  }

  public func displayBackground(_ displayBackground: ImageDisplayBackground) -> Self {
    var modified = self
    modified.displayBackground = displayBackground
    return modified
  }
}

private struct LoadedImagePreviewRepresentable: UIViewRepresentable {

  let editingStack: EditingStack
  let displayBackground: ImageDisplayBackground

  func makeUIView(context: Context) -> _ImagePreviewView {
    let view = _ImagePreviewView(editingStack: editingStack)
    view.displayBackground = displayBackground.metalDisplayBackground
    view.displayCurrentEditingStackState()
    return view
  }

  func updateUIView(_ uiView: _ImagePreviewView, context: Context) {
    uiView.displayBackground = displayBackground.metalDisplayBackground
    uiView.displayCurrentEditingStackState()
  }
}

/**
 A view that displays the edited image, plus displays original image for comparison with touch-down interaction.
 */
final class _ImagePreviewView: _PixelEditorCodeBasedView {
  // MARK: - Properties

  #if false
  private let imageView = _PreviewImageView()
  private let originalImageView = _PreviewImageView()
  #else
  private let imageView = _MetalImageView()
  private let originalImageView = _MetalImageView()
  #endif

  private let editingStack: EditingStack

  private struct CachedCroppedImage {
    var editingSourceCGImage: CGImage
    var metadata: ImageProvider.ImageMetadata
    var crop: EditingCrop
    var image: CIImage
  }

  private var cachedCroppedImage: CachedCroppedImage?

  var displayBackground: _MetalImageView.DisplayBackground = .transparent {
    didSet {
      imageView.displayBackground = displayBackground
      originalImageView.displayBackground = displayBackground
    }
  }

  // MARK: - Initializers

  init(editingStack: EditingStack) {
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
      imageView.displayBackground = displayBackground
      imageView.frame = bounds
      imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    originalImageView.isHidden = true
  }

  // MARK: - Functions

  func displayCurrentEditingStackState() {
    let loadedState = editingStack.requireLoadedStateForLoadedUIView()
    UIView.performWithoutAnimation {
      requestPreviewImage(state: loadedState)
    }
  }

  private func requestPreviewImage(state: EditingStack.Loaded) {

    let croppedImage: CIImage
    if
      let cachedCroppedImage,
      state.editingSourceCGImage == cachedCroppedImage.editingSourceCGImage,
      state.metadata == cachedCroppedImage.metadata,
      state.currentEdit.crop == cachedCroppedImage.crop
    {
      croppedImage = cachedCroppedImage.image
    } else {
      croppedImage = editingStack.makeCroppedCIImage(
        sourceImage: state.editingSourceCGImage,
        crop: state.currentEdit.crop,
        orientation: state.metadata.orientation
      )
      cachedCroppedImage = .init(
        editingSourceCGImage: state.editingSourceCGImage,
        metadata: state.metadata,
        crop: state.currentEdit.crop,
        image: croppedImage
      )
    }
    imageView.display(image: croppedImage)
    imageView.postProcessing = state.currentEdit.filters.apply
    originalImageView.display(image: croppedImage)

  }

  override func layoutSubviews() {
    super.layoutSubviews()

    if editingStack.loadedState != nil {
      displayCurrentEditingStackState()
    }
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesBegan(touches, with: event)
    originalImageView.isHidden = false
    imageView.isHidden = true
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesEnded(touches, with: event)
    originalImageView.isHidden = true
    imageView.isHidden = false
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesCancelled(touches, with: event)
    originalImageView.isHidden = true
    imageView.isHidden = false
  }
}

final class _PreviewImageView: UIImageView, CIImageDisplaying {
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

    EditorLog.debug(.imageView, "Update")

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
