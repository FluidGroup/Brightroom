//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

/// Builds the static content of a feature's `body`.
///
/// Every statement becomes a member of the result and evaluates in order. The
/// result type is fully static: a block of several members becomes a
/// `TupleFeature`, `if` without `else` becomes an `Optional`, `if`/`else`
/// becomes an `EitherFeature`, and `for` becomes an `Array`.
@resultBuilder
public enum FeatureBuilder {

  /// Passes a feature through unchanged.
  public static func buildExpression<F: Feature>(_ feature: F) -> F {
    feature
  }

  /// Builds an empty body, which leaves the image unchanged.
  public static func buildBlock() -> EmptyFeature {
    EmptyFeature()
  }

  /// Builds a body with a single member.
  public static func buildBlock<F: Feature>(_ feature: F) -> F {
    feature
  }

  /// Builds a body whose members evaluate in order.
  public static func buildBlock<each F: Feature>(
    _ features: repeat each F
  ) -> TupleFeature<repeat each F> {
    TupleFeature(repeat each features)
  }

  /// Builds an `if` without `else`; a branch that is not taken is identity.
  public static func buildOptional<F: Feature>(_ feature: F?) -> F? {
    feature
  }

  /// Builds the first branch of an `if`/`else` or `switch`.
  public static func buildEither<First: Feature, Second: Feature>(
    first: First
  ) -> EitherFeature<First, Second> {
    .first(first)
  }

  /// Builds the second branch of an `if`/`else` or `switch`.
  public static func buildEither<First: Feature, Second: Feature>(
    second: Second
  ) -> EitherFeature<First, Second> {
    .second(second)
  }

  /// Builds a `for` loop; the members evaluate in iteration order.
  public static func buildArray<F: Feature>(_ features: [F]) -> [F] {
    features
  }

  /// Builds the content of an `if #available` branch of equatable image
  /// effects.
  ///
  /// The branch is erased to `AnyImageEffect`, so the body's type never names
  /// a type that is unavailable at the deployment target.
  public static func buildLimitedAvailability<Effect: ImageEffect & Equatable>(
    _ effect: Effect
  ) -> AnyImageEffect {
    AnyImageEffect(effect)
  }

  /// Builds the content of any other `if #available` branch.
  ///
  /// The branch keeps its static type. Only `AnyImageEffect` can erase a
  /// feature, so a branch that is not an equatable image effect (a domain
  /// feature such as `CropFeature`, or a composite that is not an
  /// `ImageEffect`) must not name a type unavailable at the deployment target.
  public static func buildLimitedAvailability<F: Feature>(_ feature: F) -> F {
    feature
  }
}
