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
import SwiftUI
import UIKit
import Combine
import StateGraph

import BrightroomParametric

public enum EditingStackError: Error, Sendable {
  case unableToCreateRendererInLoading
  /// The document to render does not exist yet, for example while an editor
  /// still prepares its initial document.
  case documentUnavailable
}

/// Loads and prepares an image for editing, and renders documents from it.
///
/// The stack holds no edit and no history: the UI that edits an image owns its
/// document (a `some Feature` value) and hands it to `makeRenderer(document:)`.
/// The stack owns what every document of this image shares: the image provider,
/// the metadata and orientation, the thumbnail, and the downsampled,
/// GPU-resident editing source.
///
/// - Attention: Call `start()` before reading `loadedState`.
open class EditingStack: Hashable {

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

  public struct Options {

    public init() {}
  }

  public static func == (lhs: EditingStack, rhs: EditingStack) -> Bool {
    lhs === rhs
  }

  public func hash(into hasher: inout Hasher) {
    ObjectIdentifier(self).hash(into: &hasher)
  }

  // MARK: - Nested Types

  /// The prepared image, published once loading finishes.
  public struct Loaded: Equatable {

    // MARK: - Properties

    let imageSource: ImageSource

    public let metadata: ImageProvider.ImageMetadata

    /// The oriented source pixel size: the domain documents of this image are
    /// authored in.
    public var imageSize: CGSize {
      metadata.imageSize
    }

    /// A small oriented thumbnail, used for previews such as filter swatches.
    public let thumbnailImage: CIImage

    public let editingSourceCGImage: CGImage

    /// The oriented, downsampled editing source (zero origin). It is
    /// GPU-resident when a Metal device is available.
    public let editingSourceImage: CIImage

    // MARK: - Initializers

    init(
      imageSource: ImageSource,
      metadata: ImageProvider.ImageMetadata,
      thumbnailCIImage: CIImage,
      editingSourceCGImage: CGImage,
      editingSourceCIImage: CIImage
    ) {
      self.imageSource = imageSource
      self.metadata = metadata
      self.thumbnailImage = thumbnailCIImage
      self.editingSourceCGImage = editingSourceCGImage
      self.editingSourceImage = editingSourceCIImage
    }

    // MARK: - Functions

    public func makeOriginalCIImage() -> CIImage {
      imageSource
        .makeOriginalCIImage()
        .oriented(metadata.orientation)
        .removingExtentOffset()
    }
  }

  // MARK: - State Properties

  @GraphStored public var hasStartedEditing: Bool = false

  /**
   A Boolean value that indicates whether the image is currently loading for editing.
   */
  public var isLoading: Bool {
    loadedState == nil
  }

  /// The prepared image; nil until loading finishes.
  @GraphStored public internal(set) var loadedState: Loaded? = nil

  // MARK: - Stored Properties

  public let options: Options

  public let imageProvider: ImageProvider

  private var subscriptions: Set<AnyCancellable> = .init()
  private var imageProviderSubscription: AnyCancellable?

  private let startLock = NSLock()

  // The editing source is downsampled so that its SHORT side is at most this
  // value; the long side scales with the aspect ratio and is larger for anything
  // but a square (a 4032×3024 photo loads at 3413×2560). A source whose short
  // side is already below it — a wide panorama, say — is not downsampled at all.
  // See `ImageTool.makeResizedCGImage(from:maxPixelSizeHint:fixesOrientation:)`.
  //
  // The canvas preview bake cap `EditingCanvasImageProcessing.contentBakeMaxPixelSize`
  // (BrightroomUI) carries the same number but caps the LONGEST side, so the two
  // resolutions coincide only for square content; otherwise the bake resamples
  // somewhat below the editing source. Keep the numbers together anyway: they
  // express one intent, and neither module can enforce the relation at compile
  // time.
  private let editingImageMaxPixelSize: CGFloat = 2560

  // MARK: - Initializers

  /// Creates a stack that loads the image of `imageProvider` once `start()` is
  /// called.
  public init(
    imageProvider: ImageProvider,
    options: Options = .init()
  ) {
    self.options = options
    self.imageProvider = imageProvider
  }

  /**
   EditingStack awakes from cold state.

   - Calling from background-thread supported.
   */
  public func start(onPreparationCompleted: @escaping @MainActor () -> Void = {}) {

    /**
     Mutual exclusion
     */
    guard markStartedIfNeeded() else {
      DispatchQueue.main.async {
        onPreparationCompleted()
      }
      return
    }

    /**
     Start downloading image
     */

    backgroundQueue.async {
      self.imageProvider.start()
    }

    // Observe image provider's loaded image
    let imageProviderSub = withGraphTracking {
      withGraphTrackingMap(from: self, map: { $0.imageProvider.loadedImage }, onChange: { [weak self] image in
        guard let self, let image else { return }
        self.backgroundQueue.async {
          self.handleImageLoaded(image: image, onPreparationCompleted: onPreparationCompleted)
        }
      })
    }
    /**
     `backgroundQueue` owns the lifecycle of `imageProviderSubscription`.

     `start()` may be called from any thread, while the load completion nils this
     out on `backgroundQueue`. For an already-loaded provider the `onChange` above
     fires synchronously inside `withGraphTracking`, so the load is already
     enqueued by the time we get here — assigning directly would race with that
     nil-out. Hopping through the serial queue orders the install before the
     nil-out, so the subscription is always released rather than re-installed.
     */
    backgroundQueue.async { [weak self] in
      self?.imageProviderSubscription = imageProviderSub
    }
  }

  private func markStartedIfNeeded() -> Bool {
    startLock.lock()
    defer {
      startLock.unlock()
    }

    guard hasStartedEditing == false else {
      return false
    }

    hasStartedEditing = true
    return true
  }

  private func handleImageLoaded(
    image: ImageProvider.LoadedImage,
    onPreparationCompleted: @escaping @MainActor () -> Void
  ) {
    switch image {
    case let .editable(imageSource, metadata):

      let thumbnailCGImage = imageSource.loadThumbnailCGImage(maxPixelSize: 180)

      /**
       An image resised from original image
       */
      let editingSourceCGImage = imageSource.loadThumbnailCGImage(
        maxPixelSize: self.editingImageMaxPixelSize
      )

      assert(editingSourceCGImage.colorSpace != nil)

      /// resized
      let _editingSourceCIImage: CIImage = editingSourceCGImage._makeCIImage(
        orientation: metadata.orientation
      )

      let _thumbnailImage: CIImage = thumbnailCGImage._makeCIImage(
        orientation: metadata.orientation
      )

      assert(
        (_editingSourceCIImage.extent.width > _editingSourceCIImage.extent.height)
          == (metadata.imageSize.width > metadata.imageSize.height)
      )

      /**
       Upload the editing source into a persistent GPU texture off the main
       thread *before* publishing `loadedState` (which reveals the editing
       canvas). The canvas re-renders the source into its own viewport texture
       every frame, and zoom / pan / rotation invalidate that cache every
       frame; a `CIImage(cgImage:)` source would re-blit its bitmap CPU->GPU
       on each of those frames. A texture-backed source keeps it GPU-resident,
       eliminating that per-frame upload. Building the texture also warms Core
       Image's pipeline, so the first `draw(in:)` no longer pays the upload +
       one-time pipeline compilation on the main thread.
       */
      self.backgroundQueue.async { [weak self] in
        guard let self else { return }

        // A second provider emission must never rebuild the loaded state that
        // documents are already authored against; the first load wins.
        guard self.loadedState == nil else { return }

        // Fall back to the CPU-backed source if no Metal device is available
        // (e.g. unsupported environment); display still works, just without
        // the GPU-residency win.
        let editingSource = EditingSourcePreparation.makeGPUResidentSource(
          cgImage: editingSourceCGImage,
          orientation: metadata.orientation
        ) ?? _editingSourceCIImage

        let loaded = Loaded(
          imageSource: imageSource,
          metadata: metadata,
          thumbnailCIImage: _thumbnailImage,
          editingSourceCGImage: editingSourceCGImage,
          editingSourceCIImage: editingSource
        )

        self.loadedState = loaded
        self.imageProviderSubscription = nil

        DispatchQueue.main.async {
          onPreparationCompleted()
        }
      }
    }
  }

  deinit {
    EngineLog.debug("[EditingStack] deinit")
  }

  // MARK: - Functions

  /// Creates a renderer that evaluates `document` over the full-resolution,
  /// oriented source.
  ///
  /// `document` must be authored in the oriented source domain, whose size is
  /// `Loaded.imageSize`.
  ///
  /// - Throws: `EditingStackError.unableToCreateRendererInLoading` before the
  ///   image has loaded.
  // `sending`: the renderer is freshly created here and not retained by the
  // stack, so it forms a disconnected region the caller can hand to the
  // off-actor `render()` without a data-race risk.
  public func makeRenderer(document: some Feature) throws -> sending BrightRoomImageRenderer {

    guard let loaded = loadedState else {
      throw EditingStackError.unableToCreateRendererInLoading
    }

    // The renderer applies the orientation to the source CIImage, so the
    // document evaluates in the oriented space it is authored in.
    return BrightRoomImageRenderer(
      source: loaded.imageSource,
      orientation: loaded.metadata.orientation,
      document: document
    )
  }

  /// Creates a renderer for a document that may not exist yet, such as an
  /// editor's document while the editor prepares it.
  ///
  /// A nil document is an error rather than a request for the unedited
  /// image; to render the unedited image, pass `EmptyFeature()`.
  ///
  /// - Throws: `EditingStackError.documentUnavailable` when `document` is
  ///   nil, and `EditingStackError.unableToCreateRendererInLoading` before
  ///   the image has loaded.
  public func makeRenderer<Document: Feature>(
    document: Document?
  ) throws -> sending BrightRoomImageRenderer {
    guard let document else {
      throw EditingStackError.documentUnavailable
    }
    return try makeRenderer(document: document)
  }
}
