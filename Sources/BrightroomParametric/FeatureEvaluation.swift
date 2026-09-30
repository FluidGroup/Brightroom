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

/// Values available to features while they evaluate.
///
/// The context deliberately carries no state from the rest of the edit. A feature sees its input
/// image, explicit render-time values, and shared facilities. This keeps
/// evaluation a pure function of (parameters, input, context).
public struct FeatureEvaluationContext: Sendable {

  /// The presentation time of the image being evaluated.
  ///
  /// Video renderers supply the exact AVFoundation composition time for each
  /// frame. Still-image renderers use `.zero` by default, which gives
  /// time-sensitive effects a deterministic sample without adding time to the
  /// authored feature parameters.
  public let presentationTime: CMTime

  /// The chain-entry extent: the image extent that diagonal-based radii
  /// (Gaussian blur, sharpen, unsharp mask) resolve against, expressed in the
  /// **current render pixel space**.
  ///
  /// A radius like "value 40" means "diagonal / 50 of the image". The basis
  /// must be the **source** image, not the cropped/zoomed/intermediate extent
  /// the effect happens to be applied to — otherwise a tighter crop or a
  /// zoomed viewport silently changes the blur strength. Render pipelines set
  /// this to the full source extent scaled to the resolution they are
  /// rendering at, so the radius stays a fixed fraction of the source in every
  /// path (export, preview, live viewport).
  ///
  /// `nil` falls back to the input image's own extent at the recipe level.
  /// `FeatureRenderer` never relies on that fallback: it resolves the
  /// extent ONCE at chain entry, so a mid-chain crop cannot re-base the
  /// radius. The fallback only applies to direct `apply(to:context:)` calls
  /// outside the renderers, where the input is expected to be the chain entry;
  /// a composite `Feature` resolves it from its own input before evaluating
  /// its members. Origin normalization happens only in the renderers.
  public let chainEntryExtent: CGRect?

  /// Creates an evaluation context.
  ///
  /// Package access: hosts evaluate through `FeatureRenderer`, which
  /// normalizes the chain entry's origin and fixes its extent before
  /// building the context.
  package init(
    chainEntryExtent: CGRect? = nil,
    presentationTime: CMTime = .zero
  ) {
    self.chainEntryExtent = chainEntryExtent
    self.presentationTime = presentationTime
  }

  /// Returns the extent that a diagonal-based radius must resolve against when
  /// the recipe is evaluating `image`.
  ///
  /// Every recipe with a proportional radius goes through this accessor rather
  /// than reading `chainEntryExtent` and writing its own fallback: the
  /// fallback to `image.extent` is correct ONLY when `image` is the chain entry.
  /// Applied to any mid-chain input — a cropped result, a zoomed viewport slice,
  /// an intermediate — it re-bases the radius and silently changes the strength
  /// of a committed effect, which is exactly what the pinned semantics forbid.
  public func chainEntryExtent(for image: CIImage) -> CGRect {
    chainEntryExtent ?? image.extent
  }

  /// Returns a copy that resolves diagonal-based radii against `extent`
  /// (the full source extent in the current render pixel space).
  package func withChainEntryExtent(_ extent: CGRect?) -> Self {
    .init(
      chainEntryExtent: extent,
      presentationTime: presentationTime
    )
  }
}

/// Errors thrown while evaluating features.
///
/// Every failure a built-in feature or renderer raises during evaluation is
/// one of these cases, including failures of Brightroom's own Metal kernels.
public enum FeatureEvaluationError: Error, Equatable, Sendable {

  /// A crop rectangle cannot produce a valid image extent.
  case invalidCropRect(CGRect)

  /// A color-cube feature's data does not match its dimension.
  ///
  /// `id` is the feature's lookup-table identifier.
  case invalidColorCubeData(id: String, expectedByteCount: Int, actualByteCount: Int)

  /// A union or intersection mask node has no inputs.
  case emptyMaskComposite

  /// A Metal kernel bundled with Brightroom could not be loaded.
  ///
  /// `name` is the kernel or library name; `reason` describes the underlying
  /// failure for diagnostics.
  case kernelUnavailable(name: String, reason: String)

  /// Core Image returned nil while applying the named filter or kernel.
  case imageCreationFailed(String)
}

extension FeatureEvaluationError: LocalizedError {

  public var errorDescription: String? {
    switch self {
    case let .invalidCropRect(rect):
      "The crop rectangle \(rect) cannot produce an image."
    case let .invalidColorCubeData(id, expectedByteCount, actualByteCount):
      "The color cube \"\(id)\" has \(actualByteCount) bytes of data; its dimension needs \(expectedByteCount)."
    case .emptyMaskComposite:
      "A mask union or intersection has no inputs."
    case let .kernelUnavailable(name, reason):
      "Brightroom couldn't load its \(name) kernel: \(reason)"
    case let .imageCreationFailed(name):
      "Core Image couldn't apply \(name)."
    }
  }
}
