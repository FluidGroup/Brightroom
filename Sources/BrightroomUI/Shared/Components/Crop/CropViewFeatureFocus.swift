//
// Copyright (c) 2026 Muukii <muukii.app@gmail.com>
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

import Foundation

import BrightroomEngine
import BrightroomParametric

/// Where CropView looks and what it edits inside the EditingStack's
/// FeatureTree.
///
/// `docs/vision-of-editing.md` separates the *viewing point* (which evaluated
/// result is displayed) from the *adjustment point* (which feature the active
/// tool mutates). This type is the FeatureTree-based contract for that
/// separation: hosts pick a `FeatureTreePoint` to preview and, independently,
/// a feature node to edit. The edited node may be upstream of the viewing
/// point — painting a pre-crop mask while inspecting the final cropped output
/// is the canonical case.
///
/// Current evaluation capabilities:
/// - `viewingPoint == .output` (or any point at/after the final crop) shows
///   the final-cropped result.
/// - Points before the final crop show the pre-crop image domain. Partial
///   evaluation *within* the pre-crop features (e.g. excluding a later local
///   adjustment) lands together with the parametric renderer; until then all
///   pre-crop features participate.
/// - Crop editing always views the evaluated output through the crop frame,
///   which acts as the viewing window per the editing vision.
public struct CropViewFeatureFocus: Equatable, Sendable {

  /// The feature being edited through the canvas.
  public enum EditingTarget: Equatable, Sendable {

    /// Adjust the geometry of a crop node with the crop guide and scroll
    /// surface. Currently only the final crop node is supported.
    case crop(id: FeatureID)

    /// Paint the mask of a local adjustment node with brush gestures.
    ///
    /// When `id` is nil the layer does not exist yet: the first stroke creates
    /// it, seeded with `seedEffect`. An existing layer with the same effect
    /// identity is adopted instead when present, matching
    /// `EditingCanvasStrokeCommitPipeline` semantics.
    ///
    /// When `seedEffect` is nil, CropView uses the standard blur pipeline at
    /// layer-creation time, so hosts do not need to compute document
    /// parameters themselves.
    case localAdjustmentMask(
      id: FeatureID?,
      seedEffect: EffectPipeline?
    )
  }

  /// The point in the FeatureTree whose evaluated result the canvas displays.
  public var viewingPoint: FeatureTreePoint

  /// The feature being edited through canvas gestures, or nil when the canvas
  /// is a pure viewer.
  ///
  /// nil does not mean nothing is being edited — hosts may mutate features
  /// through controls outside the canvas (e.g. sliders writing into the
  /// global-effects node) while the canvas shows the evaluated result.
  public var editingTarget: EditingTarget?

  public init(
    viewingPoint: FeatureTreePoint = .output,
    editingTarget: EditingTarget? = nil
  ) {
    self.viewingPoint = viewingPoint
    self.editingTarget = editingTarget
  }

  // MARK: - Conveniences

  /// Edits the final crop node while viewing the evaluated output through the
  /// crop frame.
  public static let finalCrop = Self(
    viewingPoint: .output,
    editingTarget: .crop(id: EditingFeatureTree.finalCropNodeID)
  )

  /// Views the evaluated output without canvas editing.
  public static let output = Self(viewingPoint: .output)

  /// Paints a local adjustment mask while viewing the evaluated output.
  ///
  /// Pass nil (the default) to let CropView seed new layers with the standard
  /// blur pipeline at layer-creation time.
  public static func masking(
    _ seedEffect: EffectPipeline? = nil,
    id: FeatureID? = nil
  ) -> Self {
    Self(
      viewingPoint: .output,
      editingTarget: .localAdjustmentMask(id: id, seedEffect: seedEffect)
    )
  }

  // MARK: - Internal helpers

  /// Whether the crop guide surface owns interaction.
  var isCropEditing: Bool {
    if case .crop = editingTarget {
      return true
    }
    return false
  }

  /// Whether brush gestures are enabled on the tool surface.
  var isMaskEditing: Bool {
    if case .localAdjustmentMask = editingTarget {
      return true
    }
    return false
  }

  /// The explicit effect pipeline that seeds layer creation for mask editing,
  /// when the host specified one. nil while mask editing means CropView uses
  /// the standard blur pipeline.
  var maskSeedEffect: EffectPipeline? {
    if case let .localAdjustmentMask(_, seedEffect) = editingTarget {
      return seedEffect
    }
    return nil
  }

  /// The explicitly targeted local adjustment layer id, when the editing
  /// target references an existing node.
  var maskTargetLayerID: FeatureID? {
    guard
      case let .localAdjustmentMask(id?, _) = editingTarget
    else {
      return nil
    }
    return id
  }

  /// The explicitly targeted crop node id, when the focus edits crop geometry.
  var cropTargetID: FeatureID? {
    guard case let .crop(id) = editingTarget else {
      return nil
    }
    return id
  }
}
