//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import CoreImage
import Foundation

// Structural features produced by `FeatureBuilder`. Each one is an
// `ImageEffect` exactly when all of its parts are.

// MARK: - EmptyFeature

/// A feature that leaves the image unchanged.
public struct EmptyFeature: ImageEffect, Equatable {

  /// Creates an empty feature.
  public init() {}

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    image
  }
}

// MARK: - TupleFeature

/// A fixed sequence of features evaluated in order.
///
/// `FeatureBuilder` produces this for a body with several members.
public struct TupleFeature<each Element: Feature>: Feature {

  /// The members, in evaluation order.
  public var elements: (repeat each Element)

  /// Creates a sequence of the provided features.
  public init(_ elements: repeat each Element) {
    self.elements = (repeat each elements)
  }

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    let context = context.resolvingChainEntry(for: image)
    var image = image
    for element in repeat each elements {
      image = try element.apply(to: image, context: context)
    }
    return image
  }
}

extension TupleFeature: ImageEffect where repeat each Element: ImageEffect {}

extension TupleFeature: Equatable where repeat each Element: Equatable {

  public static func == (lhs: Self, rhs: Self) -> Bool {
    for (left, right) in repeat (each lhs.elements, each rhs.elements) {
      guard left == right else {
        return false
      }
    }
    return true
  }
}

// MARK: - EitherFeature

/// One of two features, chosen by an `if`/`else` or `switch` in a body.
public enum EitherFeature<First: Feature, Second: Feature>: Feature {

  /// The first branch.
  case first(First)

  /// The second branch.
  case second(Second)

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    switch self {
    case let .first(feature):
      try feature.apply(to: image, context: context)
    case let .second(feature):
      try feature.apply(to: image, context: context)
    }
  }
}

extension EitherFeature: ImageEffect where First: ImageEffect, Second: ImageEffect {}

extension EitherFeature: Equatable where First: Equatable, Second: Equatable {}

// MARK: - Optional

/// An optional feature: `nil` leaves the image unchanged.
extension Optional: Feature where Wrapped: Feature {

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    guard let self else {
      return image
    }
    return try self.apply(to: image, context: context)
  }
}

extension Optional: ImageEffect where Wrapped: ImageEffect {}

// MARK: - Array

/// A list of features evaluated in order.
extension Array: Feature where Element: Feature {

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    let context = context.resolvingChainEntry(for: image)
    return try reduce(image) { image, feature in
      try feature.apply(to: image, context: context)
    }
  }
}

extension Array: ImageEffect where Element: ImageEffect {}
