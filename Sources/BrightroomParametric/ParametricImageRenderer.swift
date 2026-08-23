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

import CoreImage
import CoreMedia
import Foundation

/// Renders parametric feature documents for still images.
///
/// `ParametricImageRenderer` is the public rendering facade for image inputs.
/// It delegates graph construction to `FeatureGraphCompiler` and returns lazy
/// Core Image recipes; callers decide when to materialize the result with a
/// `CIContext`.
public struct ParametricImageRenderer: Sendable {

  /// The compiler used to evaluate feature graphs.
  public var compiler: FeatureGraphCompiler

  /// Creates an image renderer.
  public init(compiler: FeatureGraphCompiler = .init()) {
    self.compiler = compiler
  }

  /// Evaluates an editing document from a source image.
  ///
  /// `radiusReferenceExtent` is the full source extent in the current render
  /// pixel space; pass it from paths that evaluate on a cropped/zoomed
  /// intermediate so diagonal-based radii stay a fixed fraction of the source.
  /// `nil` (the default) is correct when `sourceImage` is the full source at
  /// render scale (export, preview composition).
  ///
  /// `presentationTime` defaults to `.zero` for deterministic still-image
  /// evaluation. Video paths pass the frame's exact presentation time.
  public func makeOutput(
    from sourceImage: CIImage,
    document: EditingDocument,
    radiusReferenceExtent: CGRect? = nil,
    presentationTime: CMTime = .zero
  ) throws -> FeatureGraphOutput {
    try compiler.makeOutput(
      from: sourceImage,
      document: document,
      radiusReferenceExtent: radiusReferenceExtent,
      presentationTime: presentationTime
    )
  }

  /// Returns only the final image recipe.
  ///
  /// `presentationTime` has the same render-time semantics as
  /// `makeOutput(from:document:radiusReferenceExtent:presentationTime:)`.
  public func makeImage(
    from sourceImage: CIImage,
    document: EditingDocument,
    radiusReferenceExtent: CGRect? = nil,
    presentationTime: CMTime = .zero
  ) throws -> CIImage {
    try makeOutput(
      from: sourceImage,
      document: document,
      radiusReferenceExtent: radiusReferenceExtent,
      presentationTime: presentationTime
    )
    .image
  }
}
