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
import StateGraph

import BrightroomParametric

/// The pixels an editor shows for one source image: a small thumbnail and the
/// downsampled editing source.
package struct PreviewSource: Equatable, Sendable {

  /// The source image these pixels were prepared from. Its `pixelSize` is the
  /// domain documents of this image are authored in.
  package let source: SourceImage

  /// A small oriented thumbnail (short side at most 180 pixels), used for
  /// previews such as filter swatches.
  package let thumbnail: CIImage

  /// The oriented, downsampled editing source (zero origin). It is
  /// GPU-resident when a Metal device is available.
  package let image: CIImage
}

/// Prepares the preview pixels of one source image for BrightroomUI's editors.
///
/// Package access: editors in BrightroomUI (`ImageEditorCanvas`,
/// `ImageEditor`) create a loader for their document's source image through
/// `PreviewSourceReader` and keep it while they are shown. Apps never create
/// one; a custom editor displays `SourceImage.makeCIImage(maxPixelSize:)`.
///
/// The loader holds no edit and no history: `EditingDocument` does. It only
/// decodes the image once into a `PreviewSource`, which the editor's views
/// share. Release it when the editor goes away; the document keeps only the
/// lightweight `SourceImage`.
@MainActor
package final class PreviewSourceLoader {

  // MARK: - Nested Types

  /// Where the loader is in preparing its `PreviewSource`.
  package enum Phase: Equatable {
    /// `load()` has not been called.
    case idle
    /// The image is being decoded and uploaded.
    case loading
    /// The preview is ready.
    case loaded(PreviewSource)
    /// Preparation failed, for example because the image's pixels cannot be
    /// decoded although its header was readable, or because the file behind
    /// the image changed. Editors show the failure and keep an exit available.
    /// The loader does not retry.
    case failed
  }

  // MARK: - State Properties

  /// Published on the main actor: `.idle`, then `.loading` once `load()` is
  /// called, then `.loaded` or `.failed`.
  @GraphStored package private(set) var phase: Phase = .idle

  /// The prepared preview; nil until `phase` is `.loaded`.
  package var previewSource: PreviewSource? {
    guard case .loaded(let previewSource) = phase else {
      return nil
    }
    return previewSource
  }

  // MARK: - Stored Properties

  /// The source image this loader prepares.
  package let source: SourceImage

  private let prepare: @Sendable (SourceImage) async -> PreviewSource?

  /// The one preparation every `load()` call awaits; nil until the first
  /// call.
  private var preparation: Task<Void, Never>?

  // MARK: - Initializers

  /// Creates a loader that prepares `source` once `load()` is called.
  package convenience init(source: SourceImage) {
    self.init(source: source, prepare: { await PreviewSource.make(from: $0) })
  }

  /// Creates a loader that prepares `source` with `prepare`, which returns nil
  /// on failure. Tests use it to count, delay, or fail the preparation.
  init(
    source: SourceImage,
    prepare: @escaping @Sendable (SourceImage) async -> PreviewSource?
  ) {
    self.source = source
    self.prepare = prepare
  }

  // MARK: - Loading

  /// Prepares the preview, and returns once `phase` is `.loaded` or
  /// `.failed`.
  ///
  /// The first call starts one preparation off the main actor at once,
  /// without waiting for the main actor to be free; every call, concurrent or
  /// later, awaits that same preparation, so the image is decoded once. The
  /// preparation is not tied to any caller's task: cancelling a caller (a
  /// SwiftUI `.task` whose view disappeared) neither cancels it for the others
  /// nor leaves `phase` at `.loading`; the cancelled caller still returns when
  /// the preparation ends. A started preparation always runs to its end.
  package func load() async {
    if preparation == nil {
      phase = .loading
      let source = source
      let prepare = prepare
      // Detached, so the decode starts now rather than when the main actor
      // next runs a task (an editor's presentation animation can hold it for
      // tens of milliseconds), and so no caller's cancellation reaches it.
      let decoding = Task.detached(priority: Task.currentPriority) {
        await prepare(source)
      }
      // Publishes `phase` on the main actor once the decode ends.
      preparation = Task { [weak self] in
        let previewSource = await decoding.value
        // Defensive only: every `load()` caller keeps the loader alive until
        // this task ends, so releasing the editor does not end the decode
        // early.
        guard let self else {
          return
        }
        if let previewSource {
          phase = .loaded(previewSource)
        } else {
          phase = .failed
        }
      }
    }
    await preparation?.value
  }

  deinit {
    EngineLog.debug("[PreviewSourceLoader] deinit")
  }
}

extension PreviewSource {

  /// The editing source is downsampled so that its SHORT side is at most this
  /// value; the long side scales with the aspect ratio and is larger for
  /// anything but a square (a 4032×3024 photo loads at 3413×2560). A source
  /// whose short side is already below it — a wide panorama, say — is not
  /// downsampled at all. See
  /// `ImageDecoding.makeResizedCGImage(from:shortSideLength:)`.
  ///
  /// The canvas preview bake cap
  /// `EditingCanvasImageProcessing.contentBakeMaxPixelSize` (BrightroomUI)
  /// carries the same number but caps the LONGEST side, so the two resolutions
  /// coincide only for square content; otherwise the bake resamples somewhat
  /// below the editing source. Keep the numbers together anyway: they express
  /// one intent, and neither module can enforce the relation at compile time.
  static let previewShortSideLength: CGFloat = 2560

  /// The largest short side of `thumbnail`; a smaller source is not
  /// upscaled.
  static let thumbnailShortSideLength: CGFloat = 180

  /// Decodes `source` into a thumbnail and an editing source, and uploads the
  /// editing source to the GPU; nil when the pixels cannot be decoded.
  ///
  /// Runs off the calling actor: decoding and the upload's wait block.
  @concurrent
  static func make(from source: SourceImage) async -> PreviewSource? {
    let storage = source.storage
    let orientation = storage.orientation

    guard
      let thumbnailCGImage = storage.makeResizedCGImage(shortSideLength: thumbnailShortSideLength),
      let editingSourceCGImage = storage.makeResizedCGImage(shortSideLength: previewShortSideLength)
    else {
      EngineLog.error(.preview, "Failed to prepare the editing source.")
      return nil
    }

    assert(editingSourceCGImage.colorSpace != nil)

    /**
     Upload the editing source into a persistent GPU texture *before* the
     loader publishes `.loaded` (which reveals the editing canvas). See
     `PreviewTextureUpload`. Without Metal, the CPU-backed image is the
     editing source.
     */
    let image = PreviewTextureUpload.makeGPUResidentSource(
      cgImage: editingSourceCGImage,
      orientation: orientation
    ) ?? editingSourceCGImage._makeCIImage(orientation: orientation)

    return PreviewSource(
      source: source,
      thumbnail: thumbnailCGImage._makeCIImage(orientation: orientation),
      image: image
    )
  }
}
