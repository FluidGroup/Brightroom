//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import Foundation

/// A normalized tone curve described by ordered control points.
///
/// Input and output coordinates use the closed range `0...1`. The lower and
/// upper endpoints are non-removable, but every point can move on both axes.
/// Horizontal movement preserves a minimum distance between neighboring points.
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

  /// One stable control point in the normalized curve domain.
  public struct Point: Equatable, Identifiable, Sendable {

    /// Semantic identity that remains stable while coordinates and ordinals change.
    public enum ID: Equatable, Hashable, Sendable {
      /// The non-removable lower endpoint of the authored curve interval.
      case blackEndpoint

      /// The non-removable upper endpoint of the authored curve interval.
      case whiteEndpoint

      /// A removable authored point identified independently of its coordinates.
      case interior(UUID)
    }

    /// Stable identity used for selection and collection diffing.
    public let id: ID

    /// The normalized source value on the horizontal axis.
    public fileprivate(set) var input: Double

    /// The normalized result value on the vertical axis.
    public fileprivate(set) var output: Double

    /// Whether this point is one of the two non-removable curve endpoints.
    public var isEndpoint: Bool {
      switch id {
      case .blackEndpoint, .whiteEndpoint:
        true
      case .interior:
        false
      }
    }

    /// Creates a model point for editing or validated persistence reconstruction.
    init(
      id: ID,
      input: Double,
      output: Double
    ) {
      self.id = id
      self.input = input
      self.output = output
    }
  }

  /// Ordered control points from the lower endpoint to the upper endpoint.
  public private(set) var points: [Point]

  /// Whether the curve is the two-point identity mapping.
  public var isNeutral: Bool {
    points == Self.neutralPoints
  }

  /// Whether evaluation is the identity mapping across the complete domain.
  ///
  /// Diagonal interior points do not change the mapping while both endpoints
  /// remain at normalized Input 0 and 1. An inward endpoint is never an
  /// identity, even when its own Input equals Output, because its exterior
  /// interval becomes a horizontal clipping plateau.
  public var isIdentityMapping: Bool {
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

  /// Restores authored points without changing their coordinates or identities.
  ///
  /// Saved data must preserve the same bounds, endpoint identities, and spacing
  /// enforced by editing operations. Invalid data is rejected before it can
  /// reach spline evaluation; decoding never repairs or silently clamps it.
  init?(validating points: [Point]) {
    var identities = Set<Point.ID>()
    let hasValidPoints = points.allSatisfy { point in
      point.input.isFinite && point.output.isFinite
        && Self.normalizedRange.contains(point.input)
        && Self.normalizedRange.contains(point.output)
        && identities.insert(point.id).inserted
    }
    let hasInteriorIdentities = points.dropFirst().dropLast().allSatisfy { point in
      if case .interior = point.id { return true }
      return false
    }
    // Arithmetic in a legal move can round a gap infinitesimally below 0.02.
    // Accept that round-off without altering the authored coordinates.
    let minimumDecodedSpacing = Self.minimumInputSpacing - 8 * Double.ulpOfOne
    let hasValidSpacing = zip(points, points.dropFirst()).allSatisfy { lower, upper in
      upper.input - lower.input >= minimumDecodedSpacing
    }
    guard (2...Self.maximumPointCount).contains(points.count),
      points.first?.id == .blackEndpoint,
      points.last?.id == .whiteEndpoint,
      hasValidPoints,
      hasInteriorIdentities,
      hasValidSpacing
    else {
      return nil
    }
    self.points = points
  }

  /// Returns a point by stable identity.
  public func point(id: Point.ID) -> Point? {
    points.first { $0.id == id }
  }

  /// Inserts an interior point while preserving horizontal ordering.
  ///
  /// - Returns: The point's stable identity, or `nil` when no legal interval
  ///   remains or the point-count limit has been reached.
  @discardableResult
  public mutating func insertPoint(
    input: Double,
    output: Double
  ) -> Point.ID? {
    insertPoint(
      id: .interior(UUID()),
      input: input,
      output: output
    )
  }

  /// Inserts an interior point with a caller-supplied stable identity.
  ///
  /// Editors use this overload when one logical point is shared by multiple
  /// independently stored curves. Endpoint identities and duplicate interior
  /// identities are rejected.
  ///
  /// - Returns: The supplied identity, or `nil` when it is not a new interior
  ///   identity, no legal interval remains, or the point-count limit has been
  ///   reached.
  @discardableResult
  public mutating func insertPoint(
    id: Point.ID,
    input: Double,
    output: Double
  ) -> Point.ID? {
    guard case .interior = id, point(id: id) == nil else { return nil }
    guard points.count < Self.maximumPointCount else { return nil }

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
        id: id,
        input: min(max(requestedInput, lowerInput), upperInput),
        output: Self.clamped(output)
      ),
      at: insertionIndex
    )
    return id
  }

  /// Adds a point to the widest horizontal interval without changing its
  /// existing straight-line mapping at that location.
  @discardableResult
  public mutating func insertPointInLargestGap() -> Point.ID? {
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
  public mutating func movePoint(
    id: Point.ID,
    input: Double,
    output: Double
  ) {
    guard let index = points.firstIndex(where: { $0.id == id }) else {
      return
    }

    let lowerInput =
      index == points.startIndex
      ? Self.normalizedRange.lowerBound
      : points[index - 1].input + Self.minimumInputSpacing
    let upperInput =
      index == points.index(before: points.endIndex)
      ? Self.normalizedRange.upperBound
      : points[index + 1].input - Self.minimumInputSpacing
    points[index].input = min(max(input, lowerInput), upperInput)

    points[index].output = Self.clamped(output)
  }

  /// Offsets one point from its current coordinates.
  public mutating func offsetPoint(
    id: Point.ID,
    inputDelta: Double = 0,
    outputDelta: Double = 0
  ) {
    guard let point = point(id: id) else { return }
    movePoint(
      id: id,
      input: point.input + inputDelta,
      output: point.output + outputDelta
    )
  }

  /// Removes an interior point and preserves both curve endpoints.
  @discardableResult
  public mutating func removePoint(id: Point.ID) -> Bool {
    guard case .interior = id,
      let index = points.firstIndex(where: { $0.id == id })
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
    Point(id: .blackEndpoint, input: 0, output: 0),
    Point(id: .whiteEndpoint, input: 1, output: 1),
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
