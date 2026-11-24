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

/// The pixels an editor shows for one source image: a small thumbnail and a
/// downsampled editing copy, decoded once.
///
/// Only a `PreviewSourceLoader` creates one. Pass it to the views that read
/// the pixels the canvas shows, such as a histogram, filter swatches or a
/// gray point; a feature they evaluate over it is authored over `source`.
/// The editing copy is GPU-resident when a Metal device is available, and
/// lives as long as the loader or any copy of this value. A document never
/// holds one: it keeps only its `SourceImage`.
public struct PreviewSource: Equatable, Sendable {

  /// The source image these pixels were prepared from. Its `pixelSize` is the
  /// domain documents of this image are authored in.
  public let source: SourceImage

  /// A small oriented thumbnail (short side at most 180 pixels), used for
  /// previews such as filter swatches.
  public let thumbnail: CIImage

  /// The oriented, downsampled editing copy (zero origin) that the canvas
  /// shows: its short side is at most 2560 pixels. It is GPU-resident when a
  /// Metal device is available.
  public let image: CIImage
}

/// Prepares the preview pixels of one source image, once: the
/// `PreviewSource` an editor's views share.
///
/// Prepare one loader for each open image and share it with every view that
/// shows the image, so the image is decoded once: pass it to
/// `ImageEditorCanvas(document:previewSourceLoader:)`, and pass its
/// `previewSource` to the views that read the canvas's pixels. In SwiftUI,
/// `PreviewSourceReader` (BrightroomUI) creates the loader and keeps it for
/// the lifetime of its identity, so give the reader an identity per source
/// image:
///
/// ```swift
/// PreviewSourceReader(source: document.source) { loader in
///   ImageEditorCanvas(document: $document, previewSourceLoader: loader)
///   if let previewSource = loader.previewSource {
///     // A histogram, filter swatches or a gray point: pass previewSource.
///   }
/// }
/// .id(document.source)
/// ```
///
/// The loader holds no edit and no history: `EditingDocument` does, and it
/// keeps only the lightweight `SourceImage`. The prepared pixels, the
/// GPU-resident editing copy included, live as long as the loader or any
/// copy of its `PreviewSource`, so release the loader when the image closes.
@MainActor
public final class PreviewSourceLoader {

  // MARK: - Nested Types

  /// Where the loader is in preparing its `PreviewSource`.
  public enum Phase: Equatable, Sendable {
    /// `load()` has not been called.
    case idle
    /// The image is being decoded and its editing copy uploaded.
    case loading
    /// The preview is ready.
    case loaded(PreviewSource)
    /// Preparation failed, for example because the image's pixels cannot be
    /// decoded although its header was readable, or because the file behind
    /// the image changed. The failure is final: the loader does not retry.
    /// Show the failure and keep a way out, as the canvas does.
    case failed
  }

  // MARK: - State Properties

  /// `.idle`, then `.loading` once `load()` is first called, then `.loaded`
  /// or `.failed`. It changes on the main actor, and a SwiftUI view that
  /// reads it updates when it changes.
  public var phase: Phase {
    currentPhase
  }

  /// The prepared preview; nil until `phase` is `.loaded`.
  public var previewSource: PreviewSource? {
    guard case .loaded(let previewSource) = phase else {
      return nil
    }
    return previewSource
  }

  /// The storage of `phase`. Private, because `@GraphStored` gives its
  /// storage node the property's access level, and a public node would let
  /// any caller set the phase.
  @GraphStored private var currentPhase: Phase = .idle

  // MARK: - Stored Properties

  /// The source image this loader prepares.
  public let source: SourceImage

  private let prepare: @Sendable (SourceImage) async -> PreviewSource?

  /// The one preparation every `load()` call awaits; nil until the first
  /// call.
  private var preparation: Task<Void, Never>?

  // MARK: - Initializers

  /// Creates a loader that prepares `source` once `load()` is called. It
  /// costs nothing until then.
  public convenience init(source: SourceImage) {
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
  ///
  /// The canvas calls it when it appears. A view that needs the pixels
  /// without a canvas calls it too, for example in `.task`.
  public func load() async {
    if preparation == nil {
      currentPhase = .loading
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
          currentPhase = .loaded(previewSource)
        } else {
          currentPhase = .failed
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
