//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import CoreImage
import Foundation

/// A type-erased image effect.
///
/// Use it where the content is decided by data rather than code, such as a
/// list of effects decoded by the host (`[AnyImageEffect]` is itself an
/// `ImageEffect` that evaluates in order), or a branch that names a type
/// unavailable at the deployment target. Two erased effects are equal when
/// they wrap values of exactly the same type that compare equal.
///
/// Only `Equatable` effects can be wrapped, so documents stay comparable. A
/// host that keeps effects behind an existential stores `AnyImageEffect` or
/// `any ImageEffect & Equatable`, not `any ImageEffect`.
public struct AnyImageEffect: ImageEffect, Equatable {

  /// The wrapped effect.
  public let base: any ImageEffect

  private let isEqual: @Sendable (any ImageEffect) -> Bool

  /// Creates a type-erased effect that wraps the provided effect.
  public init<Effect: ImageEffect & Equatable>(_ effect: Effect) {
    if let erased = effect as? AnyImageEffect {
      self = erased
      return
    }
    self.base = effect
    self.isEqual = { other in
      // Compare the exact dynamic type first: a plain cast would bridge
      // `Optional` and `Array` values of different wrapped types.
      guard type(of: other) == Effect.self, let other = other as? Effect else {
        return false
      }
      return effect == other
    }
  }

  /// Rejects effects that cannot be compared.
  @available(
    *,
    unavailable,
    message: "AnyImageEffect wraps only Equatable effects, so documents stay comparable. Make the effect Equatable, or store 'any ImageEffect & Equatable' instead of 'any ImageEffect'."
  )
  public init(_ effect: any ImageEffect) {
    fatalError()
  }

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    try base.apply(to: image, context: context)
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.isEqual(rhs.base)
  }
}
