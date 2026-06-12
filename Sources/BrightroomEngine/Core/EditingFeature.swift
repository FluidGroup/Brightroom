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
/// through stable identities (`globalEffectsID`, `finalCropID`,
/// `localAdjustmentID(for:)`) and mutate them via
/// `EditingStack.updateFeature(id:mutate:)`.
public struct EditingFeature: Equatable, Identifiable {

  public enum Payload: Equatable {
    /// Global filter chain applied to the whole image.
    case globalEffects(EditingStack.Edit.Filters)
    /// A masked local adjustment authored in the pre-final-crop domain.
    case localAdjustment(EditingStack.Edit.LocalAdjustmentLayer)
    /// A domain feature defining the visible extent. Currently only the final
    /// crop is evaluated; mid-list crops are reserved for the parametric
    /// renderer.
    case crop(EditingCrop)

    /// The payload kind, used to keep mutations kind-stable.
    public enum Kind: Equatable {
      case globalEffects
      case localAdjustment
      case crop
    }

    public var kind: Kind {
      switch self {
      case .globalEffects: return .globalEffects
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

  // MARK: - Known identities

  /// The identity of the global effects node in the canonical document.
  public static let globalEffectsID = FeatureID(
    rawValue: "brightroom.editing-stack.global-effects"
  )

  /// The identity of the final crop node.
  public static let finalCropID = FeatureID(
    rawValue: "brightroom.editing-stack.final-crop"
  )

  private static let localAdjustmentIDPrefix = "brightroom.editing-stack.local-adjustment."

  /// The tree identity for a local adjustment layer.
  public static func localAdjustmentID(for id: UUID) -> FeatureID {
    FeatureID(rawValue: localAdjustmentIDPrefix + id.uuidString)
  }

  /// The local adjustment layer id encoded in a feature identity, if any.
  public static func localAdjustmentLayerID(from featureID: FeatureID) -> UUID? {
    guard featureID.rawValue.hasPrefix(localAdjustmentIDPrefix) else {
      return nil
    }

    return UUID(uuidString: String(featureID.rawValue.dropFirst(localAdjustmentIDPrefix.count)))
  }
}
