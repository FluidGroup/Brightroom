//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
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

import AVFoundation
import CoreImage
import Foundation

/// Renders parametric feature documents for video assets.
///
/// `ParametricVideoRenderer` keeps video processing in the Core Image domain. It
/// does not decode, encode, or export movies by itself; callers pass the
/// returned `AVMutableVideoComposition` to `AVPlayerItem` or
/// `AVAssetExportSession`.
public struct ParametricVideoRenderer: Sendable {

  /// How the video composition should choose its render canvas.
  public enum RenderSizeMode: Equatable, Sendable {

    /// Preserve AVFoundation's source render size.
    case source

    /// Resolve the render size by applying the document to a synthetic frame
    /// with the source render size.
    case featureOutput

    /// Use an explicitly supplied render size.
    case custom(CGSize)
  }

  /// The image renderer used to evaluate the feature graph for each frame.
  public var imageRenderer: ParametricImageRenderer

  /// Creates a video renderer.
  public init(imageRenderer: ParametricImageRenderer = .init()) {
    self.imageRenderer = imageRenderer
  }

  /// Creates a video renderer using a specific feature graph compiler.
  public init(compiler: FeatureGraphCompiler) {
    self.imageRenderer = ParametricImageRenderer(compiler: compiler)
  }

  /// Applies a feature document to a single video frame.
  ///
  /// - Parameters:
  ///   - sourceImage: The frame image supplied by AVFoundation.
  ///   - document: The feature document to evaluate.
  ///   - renderExtent: The optional output canvas. When specified, the feature
  ///     output is placed at the canvas origin and cropped/expanded to that
  ///     extent using a transparent Core Image background.
  ///   - presentationTime: The presentation time represented by `sourceImage`.
  ///     The default keeps direct single-frame evaluation deterministic.
  /// - Returns: A Core Image recipe for the filtered frame.
  public func makeFrameImage(
    from sourceImage: CIImage,
    document: EditingDocument,
    renderExtent: CGRect? = nil,
    presentationTime: CMTime = .zero
  ) throws -> CIImage {
    let output = try imageRenderer.makeImage(
      from: sourceImage,
      document: document,
      presentationTime: presentationTime
    )

    guard let renderExtent else {
      return output
    }

    return output.parametricPlaced(in: renderExtent)
  }

  /// Resolves the render size for a video composition.
  ///
  /// `featureOutput` performs a dry run with a transparent frame so domain
  /// features such as crop can decide the final canvas size without decoding a
  /// real video frame.
  public func resolveRenderSize(
    sourceRenderSize: CGSize,
    document: EditingDocument,
    mode: RenderSizeMode
  ) throws -> CGSize {
    guard sourceRenderSize.isParametricVideoValidRenderSize else {
      throw ParametricVideoRendererError.invalidSourceRenderSize(sourceRenderSize)
    }

    switch mode {
    case .source:
      return sourceRenderSize

    case let .custom(renderSize):
      guard renderSize.isParametricVideoValidRenderSize else {
        throw ParametricVideoRendererError.invalidRenderSize(renderSize)
      }
      return renderSize

    case .featureOutput:
      let sourceExtent = CGRect(origin: .zero, size: sourceRenderSize)
      let dryRunInput = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
        .cropped(to: sourceExtent)
      let output = try imageRenderer.makeOutput(
        from: dryRunInput,
        document: document
      )
      .image
      let renderSize = output.extent.size
      guard renderSize.isParametricVideoValidRenderSize else {
        throw ParametricVideoRendererError.invalidRenderSize(renderSize)
      }
      return renderSize
    }
  }

  /// Creates a Core Image backed video composition that applies the document to
  /// every frame.
  ///
  /// The returned composition can be assigned to `AVPlayerItem.videoComposition`
  /// or `AVAssetExportSession.videoComposition`.
  public func makeVideoComposition(
    for asset: AVAsset,
    document: EditingDocument,
    renderSizeMode: RenderSizeMode = .featureOutput,
    ciContext: CIContext? = nil
  ) throws -> AVMutableVideoComposition {
    let sizingComposition = AVMutableVideoComposition(asset: asset) { request in
      request.finish(with: request.sourceImage, context: nil)
    }
    let sourceRenderSize = ParametricVideoRenderer.sourceRenderSize(
      for: asset,
      sizingComposition: sizingComposition
    )
    let renderSize = try resolveRenderSize(
      sourceRenderSize: sourceRenderSize,
      document: document,
      mode: renderSizeMode
    )
    let renderExtent = CGRect(origin: .zero, size: renderSize)
    let imageRenderer = imageRenderer

    let composition = AVMutableVideoComposition(asset: asset) { request in
      do {
        let output = try ParametricVideoRenderer(imageRenderer: imageRenderer).makeFrameImage(
          from: request.sourceImage,
          document: document,
          renderExtent: renderExtent,
          presentationTime: request.compositionTime
        )
        request.finish(with: output, context: ciContext)
      } catch {
        request.finish(with: error)
      }
    }
    composition.renderSize = renderSize
    guard composition.renderSize.isParametricVideoValidRenderSize else {
      throw ParametricVideoRendererError.invalidRenderSize(composition.renderSize)
    }
    return composition
  }

  private static func sourceRenderSize(
    for asset: AVAsset,
    sizingComposition: AVMutableVideoComposition
  ) -> CGSize {
    if sizingComposition.renderSize.isParametricVideoValidRenderSize {
      return sizingComposition.renderSize
    }

    if let composition = asset as? AVComposition,
       composition.naturalSize.isParametricVideoValidRenderSize
    {
      return composition.naturalSize
    }

    return sizingComposition.renderSize
  }
}

/// Errors thrown while preparing parametric video rendering.
public enum ParametricVideoRendererError: Error, Equatable, Sendable {

  /// AVFoundation could not provide a usable source render size.
  case invalidSourceRenderSize(CGSize)

  /// The requested or resolved output render size is invalid.
  case invalidRenderSize(CGSize)
}

private extension CIImage {

  func parametricPlaced(in renderExtent: CGRect) -> CIImage {
    let placed = transformed(
      by: CGAffineTransform(
        translationX: renderExtent.minX - extent.minX,
        y: renderExtent.minY - extent.minY
      )
    )
    let background = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
      .cropped(to: renderExtent)
    return placed
      .composited(over: background)
      .cropped(to: renderExtent)
  }
}

private extension CGSize {

  var isParametricVideoValidRenderSize: Bool {
    width.isFinite
      && height.isFinite
      && width > 0
      && height > 0
  }
}
