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

import CoreImage
import UIKit
import StateGraph

import BrightroomParametric

/// Prepares one image for interactive editing.
///
/// Package access: editors in BrightroomUI (`ImageEditorCanvas`,
/// `ImageEditor`) create a stack for their document's image and
/// keep it while they are shown. Apps never create one; a custom editor
/// displays `SourceImage.makeCIImage(maxPixelSize:)`.
///
/// The stack holds no edit and no history: the document does. It holds what
/// editing views of the image share: a small thumbnail and the downsampled,
/// GPU-resident editing source. Release it when the editor goes away; the
/// document keeps only the lightweight `SourceImage`.
///
/// - Attention: Call `start()` before reading `loadedState`.
package final class EditingStack: Hashable {

  private static let centralQueue = DispatchQueue.init(
    label: "app.muukii.Brightroom.EditingStack.central",
    qos: .default,
    attributes: .concurrent
  )

  private let backgroundQueue = DispatchQueue.init(
    label: "app.muukii.Brightroom.EditingStack",
    qos: .default,
    target: centralQueue
  )

  package static func == (lhs: EditingStack, rhs: EditingStack) -> Bool {
    lhs === rhs
  }

  package func hash(into hasher: inout Hasher) {
    ObjectIdentifier(self).hash(into: &hasher)
  }

  // MARK: - Nested Types

  /// The prepared image, published once preparation finishes.
  package struct Loaded: Equatable {

    /// The image this state was prepared from.
    package let image: SourceImage

    /// The oriented source pixel size: the domain documents of this image are
    /// authored in.
    package var imageSize: CGSize {
      image.pixelSize
    }

    /// A small oriented thumbnail, used for previews such as filter swatches.
    package let thumbnailImage: CIImage

    let editingSourceCGImage: CGImage

    /// The oriented, downsampled editing source (zero origin). It is
    /// GPU-resident when a Metal device is available.
    package let editingSourceImage: CIImage
  }

  // MARK: - State Properties

  @GraphStored var hasStarted: Bool = false

  /// Whether the image is still being prepared.
  package var isLoading: Bool {
    loadedState == nil && didFailToPrepare == false
  }

  /// The prepared image; nil until preparation finishes, and for good when
  /// it fails.
  @GraphStored package internal(set) var loadedState: Loaded? = nil

  /// Whether preparation failed, for example because the image's pixels
  /// cannot be decoded although its header was readable, or because the
  /// file behind the image changed. Editors show the failure and keep an
  /// exit available instead of waiting for `loadedState`.
  @GraphStored package internal(set) var didFailToPrepare: Bool = false

  // MARK: - Stored Properties

  /// The image this stack prepares.
  package let image: SourceImage

  private let startLock = NSLock()

  // The editing source is downsampled so that its SHORT side is at most this
  // value; the long side scales with the aspect ratio and is larger for anything
  // but a square (a 4032×3024 photo loads at 3413×2560). A source whose short
  // side is already below it — a wide panorama, say — is not downsampled at all.
  // See `ImageDecoding.makeResizedCGImage(from:shortSideLength:)`.
  //
  // The canvas preview bake cap `EditingCanvasImageProcessing.contentBakeMaxPixelSize`
  // (BrightroomUI) carries the same number but caps the LONGEST side, so the two
  // resolutions coincide only for square content; otherwise the bake resamples
  // somewhat below the editing source. Keep the numbers together anyway: they
  // express one intent, and neither module can enforce the relation at compile
  // time.
  private let editingImageMaxPixelSize: CGFloat = 2560

  // MARK: - Initializers

  /// Creates a stack that prepares `image` once `start()` is called.
  package init(image: SourceImage) {
    self.image = image
  }

  /// Starts preparing the image. Calling it again does nothing.
  ///
  /// `onPreparationCompleted` is called when preparation ends, whether it
  /// published `loadedState` or failed (`didFailToPrepare`).
  ///
  /// - Calling from background-thread supported.
  package func start(onPreparationCompleted: @escaping @MainActor () -> Void = {}) {
    guard markStartedIfNeeded() else {
      DispatchQueue.main.async {
        onPreparationCompleted()
      }
      return
    }

    backgroundQueue.async { [weak self] in
      self?.prepare(onPreparationCompleted: onPreparationCompleted)
    }
  }

  private func markStartedIfNeeded() -> Bool {
    startLock.lock()
    defer {
      startLock.unlock()
    }

    guard hasStarted == false else {
      return false
    }

    hasStarted = true
    return true
  }

  private func prepare(onPreparationCompleted: @escaping @MainActor () -> Void) {
    let storage = image.storage
    let orientation = storage.orientation

    guard
      let thumbnailCGImage = storage.makeResizedCGImage(shortSideLength: 180),
      let editingSourceCGImage = storage.makeResizedCGImage(shortSideLength: editingImageMaxPixelSize)
    else {
      EngineLog.error(.stack, "Failed to prepare the editing source.")
      didFailToPrepare = true
      DispatchQueue.main.async {
        onPreparationCompleted()
      }
      return
    }

    assert(editingSourceCGImage.colorSpace != nil)

    let cpuEditingSource = editingSourceCGImage._makeCIImage(orientation: orientation)
    let thumbnailImage = thumbnailCGImage._makeCIImage(orientation: orientation)

    /**
     Upload the editing source into a persistent GPU texture off the main
     thread *before* publishing `loadedState` (which reveals the editing
     canvas). See `EditingSourcePreparation`.
     */
    let editingSource = EditingSourcePreparation.makeGPUResidentSource(
      cgImage: editingSourceCGImage,
      orientation: orientation
    ) ?? cpuEditingSource

    loadedState = Loaded(
      image: image,
      thumbnailImage: thumbnailImage,
      editingSourceCGImage: editingSourceCGImage,
      editingSourceImage: editingSource
    )

    DispatchQueue.main.async {
      onPreparationCompleted()
    }
  }

  deinit {
    EngineLog.debug("[EditingStack] deinit")
  }
}
