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
import QuartzCore
import UIKit

import BrightroomParametric

@available(*, deprecated, renamed: "BrightRoomImageRenderer", message: "Renamed in favor of SwiftUI.ImageRenderer")
public typealias ImageRenderer = BrightRoomImageRenderer

/// Renders an `ImageSource` through the parametric export pipeline.
///
/// This is the Engine-side adapter for `ParametricExportRenderer`: it owns the
/// image loader (`ImageSource`) and its orientation, produces the oriented
/// source `CIImage`, and delegates the actual document evaluation and output
/// (in-memory bitmap or tiled file write) to the parametric renderer. The
/// nested option/result types are kept as aliases so existing call sites and
/// tests continue to reference them through `BrightRoomImageRenderer`.
public final class BrightRoomImageRenderer {

  /// An encoded file format for `Output.file`.
  public typealias ExportFileType = ParametricExportRenderer.ExportFileType
  /// Where a render stores its result.
  public typealias Output = ParametricExportRenderer.Output
  public typealias Options = ParametricExportRenderer.Options
  public typealias RenderingError = ParametricExportRenderer.RenderingError
  /// A result of rendering (in-memory bitmap or a file on disk).
  public typealias Rendered = ParametricExportRenderer.Rendered
  public typealias Resolution = ParametricExportRenderer.Resolution

  /// Internal so tests can compare GPU and software rendering output.
  typealias RenderingDevice = ParametricExportRenderer.RenderingDevice

  public struct Edit {

    /// The parametric document evaluated by `ParametricExportRenderer`. Crop is
    /// a domain feature inside the document, so export and preview share one
    /// evaluation path.
    public var document: EditingDocument

    public init(document: EditingDocument = .init()) {
      self.document = document
    }
  }

  private static let queue = DispatchQueue.init(label: "app.muukii.Pixel.renderer")

  /// Internal hook for tests to compare GPU and software rendering output.
  var renderingDevice: RenderingDevice = .automatic

  public let source: ImageSource
  public let orientation: CGImagePropertyOrientation

  public var edit: Edit

  public init(source: ImageSource, orientation: CGImagePropertyOrientation) {
    self.source = source
    self.orientation = orientation
    edit = .init()
  }

  /**
   Renders an image according to the editing.

   The work runs on the renderer's private serial queue, off the calling actor.
   See `ParametricExportRenderer.render` for the evaluation and output details.
   */
  public func render(options: Options = .init()) async throws -> Rendered {
    try await withCheckedThrowingContinuation { continuation in
      Self.queue.async {
        do {
          continuation.resume(returning: try self.renderSynchronously(options: options))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  /// The synchronous render core shared by `render`. Loads the oriented source
  /// `CIImage` and hands it to `ParametricExportRenderer`. Internal so
  /// size-sensitive benchmarks can measure it without the async hop.
  func renderSynchronously(options: Options) throws -> Rendered {
    let startTime = CACurrentMediaTime()

    EngineLog.debug(.renderer, "Take full resolution CIImage from ImageSource.")
    let sourceCIImage: CIImage = source.makeOriginalCIImage().oriented(orientation)

    let rendered = try ParametricExportRenderer().render(
      source: sourceCIImage,
      document: edit.document,
      options: options,
      device: renderingDevice
    )

    let duration = CACurrentMediaTime() - startTime
    EngineLog.debug(.renderer, "Rendering has completed - took \(duration * 1000)ms")

    return rendered
  }
}
