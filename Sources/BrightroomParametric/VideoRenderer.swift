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

/// Renders features over video assets.
///
/// `VideoRenderer` keeps video processing in the Core Image domain. It
/// does not decode, encode, or export movies by itself; callers pass the
/// returned `AVMutableVideoComposition` to `AVPlayerItem` or
/// `AVAssetExportSession`.
public struct VideoRenderer: Sendable {

  /// How the video composition should choose its render canvas.
  public enum RenderSizeMode: Equatable, Sendable {

    /// Preserve AVFoundation's source render size.
    case source

    /// Resolve the render size by applying the feature to a synthetic frame
    /// with the source render size.
    case featureOutput

    /// Use an explicitly supplied render size.
    case custom(CGSize)
  }

  private let featureRenderer = FeatureRenderer()

  /// Creates a video renderer.
  public init() {}

  /// Applies a feature to a single video frame.
  ///
  /// - Parameters:
  ///   - sourceImage: The frame image supplied by AVFoundation.
  ///   - feature: The feature to evaluate.
  ///   - renderExtent: The optional output canvas. When specified, the feature
  ///     output is placed at the canvas origin and cropped/expanded to that
  ///     extent using a transparent Core Image background.
  ///   - presentationTime: The presentation time represented by `sourceImage`.
  ///     The default keeps direct single-frame evaluation deterministic.
  /// - Returns: A Core Image recipe for the filtered frame.
  public func makeImage(
    from sourceImage: CIImage,
    feature: some Feature,
    renderExtent: CGRect? = nil,
    presentationTime: CMTime = .zero
  ) throws -> CIImage {
    let output = try featureRenderer.makeImage(
      from: sourceImage,
      feature: feature,
      presentationTime: presentationTime
    )
    guard let renderExtent else {
      return output
    }
    return output.placed(in: renderExtent)
  }

  /// Resolves the render size for a video composition of a feature.
  ///
  /// `featureOutput` performs a dry run with a transparent frame so domain
  /// features such as crop can decide the final canvas size without decoding a
  /// real video frame.
  package func resolveRenderSize(
    sourceRenderSize: CGSize,
    feature: some Feature,
    mode: RenderSizeMode
  ) throws -> CGSize {
    guard sourceRenderSize.isValidRenderSize else {
      throw VideoRendererError.invalidSourceRenderSize(sourceRenderSize)
    }

    switch mode {
    case .source:
      return sourceRenderSize

    case let .custom(renderSize):
      guard renderSize.isValidRenderSize else {
        throw VideoRendererError.invalidRenderSize(renderSize)
      }
      return renderSize

    case .featureOutput:
      let sourceExtent = CGRect(origin: .zero, size: sourceRenderSize)
      let dryRunInput = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
        .cropped(to: sourceExtent)
      let output = try featureRenderer.makeImage(from: dryRunInput, feature: feature)
      let renderSize = output.extent.size
      guard renderSize.isValidRenderSize else {
        throw VideoRendererError.invalidRenderSize(renderSize)
      }
      return renderSize
    }
  }

  /// Creates a Core Image backed video composition that applies a feature to
  /// every frame.
  ///
  /// Each frame evaluates the feature at the frame's composition time. The
  /// returned composition can be assigned to `AVPlayerItem.videoComposition`
  /// or `AVAssetExportSession.videoComposition`.
  public func makeVideoComposition(
    for asset: AVAsset,
    feature: some Feature,
    renderSizeMode: RenderSizeMode = .featureOutput,
    ciContext: CIContext? = nil
  ) throws -> AVMutableVideoComposition {
    let sizingComposition = AVMutableVideoComposition(asset: asset) { request in
      request.finish(with: request.sourceImage, context: nil)
    }
    let renderSize = try resolveRenderSize(
      sourceRenderSize: Self.sourceRenderSize(
        for: asset,
        sizingComposition: sizingComposition
      ),
      feature: feature,
      mode: renderSizeMode
    )
    let renderExtent = CGRect(origin: .zero, size: renderSize)

    let composition = AVMutableVideoComposition(asset: asset) { request in
      do {
        let output = try makeImage(
          from: request.sourceImage,
          feature: feature,
          renderExtent: renderExtent,
          presentationTime: request.compositionTime
        )
        request.finish(with: output, context: ciContext)
      } catch {
        request.finish(with: error)
      }
    }
    composition.renderSize = renderSize
    guard composition.renderSize.isValidRenderSize else {
      throw VideoRendererError.invalidRenderSize(composition.renderSize)
    }
    return composition
  }

  private static func sourceRenderSize(
    for asset: AVAsset,
    sizingComposition: AVMutableVideoComposition
  ) -> CGSize {
    if sizingComposition.renderSize.isValidRenderSize {
      return sizingComposition.renderSize
    }

    if let composition = asset as? AVComposition,
       composition.naturalSize.isValidRenderSize
    {
      return composition.naturalSize
    }

    return sizingComposition.renderSize
  }
}

/// Errors thrown while preparing video rendering.
public enum VideoRendererError: Error, Equatable, Sendable {

  /// AVFoundation could not provide a usable source render size.
  case invalidSourceRenderSize(CGSize)

  /// The requested or resolved output render size is invalid.
  case invalidRenderSize(CGSize)
}

private extension CIImage {

  func placed(in renderExtent: CGRect) -> CIImage {
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

  var isValidRenderSize: Bool {
    width.isFinite
      && height.isFinite
      && width > 0
      && height > 0
  }
}
