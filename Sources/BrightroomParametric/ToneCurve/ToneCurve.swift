//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import Foundation

/// A normalized tone curve described by ordered control points.
///
/// Input and output coordinates use the closed range `0...1`. The first and
/// last points are the curve's endpoints: they cannot be removed, but every
/// point can move on both axes. Horizontal movement preserves a minimum
/// distance between neighboring points, so points never change order.
///
/// A curve is plain data. Its points are coordinate pairs without an identity
/// of their own, so two curves with the same coordinates are equal. Editing
/// operations address a point by its index in ``points``. Moves keep the
/// horizontal order, so an index stays valid for the whole of a drag. Any
/// other change can invalidate a stored index: insertion and removal shift
/// the indices after them, and ``reset()`` or assigning another curve (for
/// example on undo) replaces the points altogether.
///
/// This value stores authored control points without prescribing color-space
/// semantics. Use ``ToneCurveEvaluator`` when evaluating the curve between and
/// beyond those points.
public struct ToneCurve: Equatable, Sendable {

  /// The normalized range shared by both curve axes.
  public static let normalizedRange = 0.0...1.0

  /// The smallest horizontal distance allowed between neighboring points.
  public static let minimumInputSpacing = 0.02

  /// The fine coordinate increment offered by an editor.
  public static let fineCoordinateStep = 0.01

  /// The coarse coordinate increment offered by an editor.
  public static let coarseCoordinateStep = 0.05

  /// Keeps dense direct manipulation practical on a touch screen.
  public static let maximumPointCount = 12

  /// The two-point identity mapping used by a new channel.
  public static let neutral = ToneCurve()

  /// One control point in the normalized curve domain.
  ///
  /// A point is a plain coordinate pair. It does not enforce curve invariants
  /// on its own; ``ToneCurve/init(validating:)`` checks bounds, order, and
  /// spacing when points are assembled into a curve.
  public struct Point: Hashable, Sendable {

    /// The normalized source value on the horizontal axis.
    public var input: Double

    /// The normalized result value on the vertical axis.
    public var output: Double

    /// Creates a point from normalized coordinates.
    public init(input: Double, output: Double) {
      self.input = input
      self.output = output
    }
  }

  /// Control points ordered by strictly increasing input.
  ///
  /// The first and last points are the lower and upper endpoints.
  public private(set) var points: [Point]

  /// Whether the curve is the default two-point identity mapping.
  ///
  /// A curve with diagonal interior points is not the default, although it
  /// renders as the identity (`isIdentity`).
  public var isDefault: Bool {
    points == Self.neutralPoints
  }

  /// Whether evaluation is the identity mapping across the complete domain.
  ///
  /// Diagonal interior points do not change the mapping while both endpoints
  /// remain at normalized Input 0 and 1. An inward endpoint is never an
  /// identity, even when its own Input equals Output, because its exterior
  /// interval becomes a horizontal clipping plateau.
  public var isIdentity: Bool {
    guard points.first?.input == Self.normalizedRange.lowerBound,
      points.last?.input == Self.normalizedRange.upperBound
    else {
      return false
    }
    return points.allSatisfy { $0.input == $0.output }
  }

  /// Whether another interior point can be added to this curve.
  public var canInsertPoint: Bool {
    points.count < Self.maximumPointCount
      && largestGapIndex() != nil
  }

  /// Creates the two-point identity mapping.
  public init() {
    points = Self.neutralPoints
  }

  /// Restores authored points without changing their coordinates.
  ///
  /// Use this to rebuild a curve from values the host stored in its own format.
  /// The points must satisfy the invariants that editing operations keep:
  /// between 2 and ``maximumPointCount`` points, finite coordinates inside
  /// ``normalizedRange``, and inputs that increase by at least
  /// ``minimumInputSpacing``. The first and last points become the endpoints.
  /// Invalid points are rejected before they can reach spline evaluation; they
  /// are never repaired, reordered, or silently clamped.
  ///
  /// - Returns: `nil` when the points are not a valid authored curve.
  public init?(validating points: [Point]) {
    let hasValidPoints = points.allSatisfy { point in
      point.input.isFinite && point.output.isFinite
        && Self.normalizedRange.contains(point.input)
        && Self.normalizedRange.contains(point.output)
    }
    // Arithmetic in a legal move can round a gap infinitesimally below 0.02.
    // Accept that round-off without altering the authored coordinates. The
    // positive spacing also rejects points out of order.
    let minimumRestoredSpacing = Self.minimumInputSpacing - 8 * Double.ulpOfOne
    let hasValidSpacing = zip(points, points.dropFirst()).allSatisfy { lower, upper in
      upper.input - lower.input >= minimumRestoredSpacing
    }
    guard (2...Self.maximumPointCount).contains(points.count),
      hasValidPoints,
      hasValidSpacing
    else {
      return nil
    }
    self.points = points
  }

  /// Inserts an interior point while preserving horizontal ordering.
  ///
  /// The input is clamped into the interval between the neighboring points,
  /// keeping ``minimumInputSpacing`` on both sides, and the output is clamped
  /// to ``normalizedRange``.
  ///
  /// - Returns: The index of the new point in ``points``, or `nil` when either
  ///   coordinate is NaN, no legal interval remains, or the point-count limit
  ///   has been reached.
  @discardableResult
  public mutating func insertPoint(
    input: Double,
    output: Double
  ) -> Int? {
    guard !input.isNaN, !output.isNaN,
      points.count < Self.maximumPointCount
    else {
      return nil
    }

    let requestedInput = Self.clamped(input)
    let insertionIndex =
      points.firstIndex { $0.input > requestedInput } ?? points.endIndex
    guard insertionIndex > points.startIndex,
      insertionIndex < points.endIndex
    else {
      return nil
    }

    let lowerInput =
      points[insertionIndex - 1].input + Self.minimumInputSpacing
    let upperInput =
      points[insertionIndex].input - Self.minimumInputSpacing
    guard lowerInput <= upperInput else { return nil }

    points.insert(
      Point(
        input: min(max(requestedInput, lowerInput), upperInput),
        output: Self.clamped(output)
      ),
      at: insertionIndex
    )
    return insertionIndex
  }

  /// Adds a point to the widest horizontal interval without changing its
  /// existing straight-line mapping at that location.
  ///
  /// - Returns: The index of the new point in ``points``, or `nil` when no
  ///   interval is wide enough or the point-count limit has been reached.
  @discardableResult
  public mutating func insertPointInLargestGap() -> Int? {
    guard let lowerIndex = largestGapIndex() else { return nil }
    let lowerPoint = points[lowerIndex]
    let upperPoint = points[lowerIndex + 1]
    let input = (lowerPoint.input + upperPoint.input) / 2
    let intervalProgress =
      (input - lowerPoint.input) / (upperPoint.input - lowerPoint.input)
    let output =
      lowerPoint.output
      + (upperPoint.output - lowerPoint.output) * intervalProgress
    return insertPoint(input: input, output: output)
  }

  /// Moves one point and clamps it to the legal curve domain.
  ///
  /// The input is clamped between the neighboring points, keeping
  /// ``minimumInputSpacing``, so the point never passes a neighbor and `index`
  /// keeps addressing it. When rounding leaves the point no room to move
  /// horizontally, it keeps its current input. A move whose input or output
  /// is NaN is ignored.
  ///
  /// - Precondition: `index` is a valid index of ``points``.
  public mutating func movePoint(
    at index: Int,
    input: Double,
    output: Double
  ) {
    precondition(points.indices.contains(index), "Tone Curve point index out of range")
    guard !input.isNaN, !output.isNaN else { return }

    let lowerInput =
      index == points.startIndex
      ? Self.normalizedRange.lowerBound
      : points[index - 1].input + Self.minimumInputSpacing
    let upperInput =
      index == points.index(before: points.endIndex)
      ? Self.normalizedRange.upperBound
      : points[index + 1].input - Self.minimumInputSpacing
    // A neighbor can sit a few ulps closer than `minimumInputSpacing`, either
    // from rounding in an earlier move or in a restored curve. The interval
    // is then empty, and snapping to one of its bounds could push the point
    // out of the normalized range or too close to its other neighbor. The
    // current input already satisfies ``init(validating:)``, so keep it.
    if lowerInput <= upperInput {
      points[index].input = min(max(input, lowerInput), upperInput)
    }

    points[index].output = Self.clamped(output)
  }

  /// Offsets one point from its current coordinates, clamping like
  /// ``movePoint(at:input:output:)``.
  ///
  /// - Precondition: `index` is a valid index of ``points``.
  public mutating func offsetPoint(
    at index: Int,
    inputDelta: Double = 0,
    outputDelta: Double = 0
  ) {
    precondition(points.indices.contains(index), "Tone Curve point index out of range")
    let point = points[index]
    movePoint(
      at: index,
      input: point.input + inputDelta,
      output: point.output + outputDelta
    )
  }

  /// Removes an interior point and preserves both curve endpoints.
  ///
  /// The points after `index` move down by one position.
  ///
  /// - Precondition: `index` is a valid index of ``points``.
  /// - Returns: `false`, leaving the curve unchanged, when `index` is the
  ///   first or last point.
  @discardableResult
  public mutating func removePoint(at index: Int) -> Bool {
    precondition(points.indices.contains(index), "Tone Curve point index out of range")
    guard index != points.startIndex,
      index != points.index(before: points.endIndex)
    else {
      return false
    }
    points.remove(at: index)
    return true
  }

  /// Restores the two-point identity mapping.
  public mutating func reset() {
    self = .neutral
  }

  private static let neutralPoints = [
    Point(input: 0, output: 0),
    Point(input: 1, output: 1),
  ]

  private func largestGapIndex() -> Int? {
    guard points.count < Self.maximumPointCount else { return nil }

    var selectedIndex: Int?
    var selectedGap = Self.minimumInputSpacing * 2
    for index in points.indices.dropLast() {
      let gap = points[index + 1].input - points[index].input
      if gap >= selectedGap {
        selectedIndex = index
        selectedGap = gap
      }
    }
    return selectedIndex
  }

  private static func clamped(_ value: Double) -> Double {
    min(max(value, normalizedRange.lowerBound), normalizedRange.upperBound)
  }
}
