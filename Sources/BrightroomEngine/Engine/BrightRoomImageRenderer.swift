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

  /// Internal hook for tests to compare GPU and software rendering output.
  var renderingDevice: RenderingDevice = .automatic

  public let source: ImageSource
  public let orientation: CGImagePropertyOrientation

  /// The document evaluated over the oriented source.
  ///
  /// It is authored in the oriented source domain. Crop is a domain feature
  /// inside the document, so export and preview share one evaluation path.
  public let document: any Feature

  /// Creates a renderer for `document` over `source` in `orientation`.
  public init(
    source: ImageSource,
    orientation: CGImagePropertyOrientation,
    document: some Feature
  ) {
    self.source = source
    self.orientation = orientation
    self.document = document
  }

  /**
   Renders an image according to the editing.

   The heavy Core Image work runs on the renderer's private serial queue, off the
   calling actor — `nonisolated` so it never runs on a caller's global actor even
   if this type later gains isolation. See `ParametricExportRenderer.render` for
   the evaluation and output details.
   */
  @concurrent
  public nonisolated func render(options: Options = .init()) async throws -> Rendered {
    
    let source = self.source
    let orientation = self.orientation
    let document = self.document
    let device = renderingDevice

    return try Self.render(
      source: source,
      orientation: orientation,
      document: document,
      device: device,
      options: options
    )
    
  }


  /// Shared synchronous render core: loads the oriented source `CIImage` and
  /// hands it to `ParametricExportRenderer`. Static so it does not capture the
  /// non-Sendable renderer instance. Internal so size-sensitive benchmarks can
  /// measure the render work without the async/executor hop.
  static nonisolated func render(
    source: ImageSource,
    orientation: CGImagePropertyOrientation,
    document: some Feature,
    device: RenderingDevice,
    options: Options
  ) throws -> Rendered {
    let startTime = CACurrentMediaTime()

    EngineLog.debug(.renderer, "Take full resolution CIImage from ImageSource.")
    let sourceCIImage: CIImage = source.makeOriginalCIImage().oriented(orientation)

    let rendered = try ParametricExportRenderer().render(
      source: sourceCIImage,
      document: document,
      options: options,
      device: device
    )

    let duration = CACurrentMediaTime() - startTime
    EngineLog.debug(.renderer, "Rendering has completed - took \(duration * 1000)ms")

    return rendered
  }
}
