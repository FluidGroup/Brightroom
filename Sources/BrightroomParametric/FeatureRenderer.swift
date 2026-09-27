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

/// Renders features over still images.
///
/// `FeatureRenderer` is the public evaluation entry point for image
/// inputs. It prepares the chain entry once and returns lazy Core Image
/// recipes (`makeImage`); callers decide when to materialize the result with a
/// `CIContext`, or use `ExportRenderer` to render pixels.
public struct FeatureRenderer: Sendable {

  /// Creates a feature renderer.
  public init() {}

  /// Evaluates a feature over a source image.
  ///
  /// `sourceImage` is the chain entry: it is translated to zero origin, and
  /// value-form radii resolve against its extent, which keeps the radius a
  /// fixed fraction of the source regardless of where crops sit in the
  /// feature. Pass `chainEntryExtent` only when `sourceImage` is NOT the
  /// chain entry (e.g. a zoomed viewport slice of a larger source).
  ///
  /// `presentationTime` defaults to `.zero` for deterministic still-image
  /// evaluation. Video paths pass the frame's exact presentation time.
  public func makeImage(
    from sourceImage: CIImage,
    feature: some Feature,
    chainEntryExtent: CGRect? = nil,
    presentationTime: CMTime = .zero
  ) throws -> CIImage {
    let image = ParametricImageGeometry.removingExtentOffset(sourceImage)

    // Resolve the chain-entry extent ONCE. Deriving it lazily
    // inside each recipe (`?? image.extent`) would re-base the radius on
    // whatever intermediate the effect happens to receive — a mid-chain crop
    // would silently change the resolved blur strength, and editing a crop
    // would retroactively change committed effects. The entry extent is the
    // declared basis; feature order cannot perturb it.
    let entryExtent: CGRect? = image.extent.isInfinite ? nil : image.extent
    let context = FeatureEvaluationContext(
      chainEntryExtent: chainEntryExtent ?? entryExtent,
      presentationTime: presentationTime
    )
    return try feature.apply(to: image, context: context)
  }

  /// Renders a mask to an alpha image covering `extent`.
  ///
  /// Brush stamps are Core Image working-space coordinates (bottom-left
  /// origin, y-up) of the domain the mask is authored in; pass that domain's
  /// extent. This is the evaluator `LocalAdjustmentFeature` composites through, so
  /// the result is exactly the alpha a local adjustment uses. Callers holding
  /// masks authored in a y-down display space flip at this boundary.
  public func makeMaskImage(for mask: Mask, extent: CGRect) throws -> CIImage {
    try MaskTreeRenderer().render(mask, extent: extent)
  }
}
