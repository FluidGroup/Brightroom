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

import Foundation

import BrightroomParametric

/// One node in the editing document: a stable identity plus the feature's
/// parameters.
///
/// `EditingStack.Edit` stores nothing but an ordered `[EditingFeature]`; the
/// list order is the evaluation order per `docs/vision-of-editing.md`. The
/// engine evaluates the list as given — which features exist, and in what
/// order, is the host UI's responsibility. Hosts address features they manage
/// through stable identities (`globalEffectsID`, `finalCropID`, or the
/// feature ids they assign) and mutate them via
/// `EditingStack.updateFeature(id:mutate:)`.
///
/// Pixel parameters use the BrightroomParametric vocabulary directly:
/// `EffectPipeline` for global effects and `LocalAdjustmentFeature`
/// (pipeline + mask tree) for masked adjustments. The crop stays the engine's
/// `EditingCrop` until the parametric domain features can express rotation
/// and straightening.
public struct EditingFeature: Equatable, Identifiable {

  public enum Payload: Equatable {
    /// Global filter chain applied to the whole image, in the open
    /// BrightroomParametric vocabulary.
    case effects(EffectPipeline)
    /// A masked adjustment authored in the pre-final-crop domain.
    ///
    /// Brush stamps follow the engine mask contract: oriented display
    /// coordinates, top-left origin, y-down. The export renderer rasterizes
    /// brush masks on the CPU in that space; feeding them to the parametric
    /// GPU compiler requires a vertical flip at that boundary.
    case localAdjustment(LocalAdjustmentFeature)
    /// A domain feature defining the visible extent. Currently only the final
    /// crop is evaluated; mid-list crops are reserved for the parametric
    /// renderer.
    case crop(EditingCrop)

    /// The payload kind, used to keep mutations kind-stable.
    public enum Kind: Equatable {
      case effects
      case localAdjustment
      case crop
    }

    public var kind: Kind {
      switch self {
      case .effects: return .effects
      case .localAdjustment: return .localAdjustment
      case .crop: return .crop
      }
    }
  }

  public var id: FeatureID
  public var payload: Payload

  public init(id: FeatureID, payload: Payload) {
    self.id = id
    self.payload = payload
  }

  /// Creates a local adjustment node, reusing the adjustment's own identity.
  public init(localAdjustment: LocalAdjustmentFeature) {
    self.id = localAdjustment.id
    self.payload = .localAdjustment(localAdjustment)
  }

  // MARK: - Known identities

  /// The identity of the global effects node in the canonical document.
  public static let globalEffectsID = FeatureID(
    rawValue: "brightroom.editing-stack.global-effects"
  )

  /// The identity of the final crop node.
  public static let finalCropID = FeatureID(
    rawValue: "brightroom.editing-stack.final-crop"
  )
}
