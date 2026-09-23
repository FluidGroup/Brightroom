//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

/// Evaluates a ``ToneCurve`` using its canonical shape-preserving cubic spline.
///
/// Each authored interval becomes a cubic Bézier segment. Interior tangents use
/// a weighted harmonic mean when adjacent slopes have the same sign and become
/// zero at a local extremum. Control outputs are constrained to the interval's
/// authored output range, preventing the preview and render lookup table from
/// overshooting either endpoint.
///
/// Moving an endpoint inward makes it a clipping threshold: inputs beyond that
/// endpoint return its output unchanged. An endpoint that remains at normalized
/// Input 0 or 1 instead extends linearly using its spline tangent, preserving
/// negative and super-white working values. Outputs are not otherwise clamped.
public struct ToneCurveEvaluator: Equatable, Sendable {

  /// One normalized input/output coordinate used by a spline segment.
  public struct Coordinate: Equatable, Sendable {

    /// The normalized coordinate on the horizontal input axis.
    public let input: Double

    /// The coordinate on the vertical output axis.
    public let output: Double
  }

  /// One cubic Bézier interval in the canonical spline.
  public struct Segment: Equatable, Sendable {

    /// The authored coordinate that begins the interval.
    public let start: Coordinate

    /// The first cubic control coordinate.
    public let firstControl: Coordinate

    /// The second cubic control coordinate.
    public let secondControl: Coordinate

    /// The authored coordinate that ends the interval.
    public let end: Coordinate

    /// Evaluates this interval at an input coordinate.
    ///
    /// Inputs outside the interval are constrained to the nearest interval
    /// endpoint. Use ``ToneCurveEvaluator/output(at:)`` for endpoint-tangent
    /// extrapolation beyond the complete curve.
    public func output(at input: Double) -> Double {
      let inputDistance = end.input - start.input
      let progress = min(max((input - start.input) / inputDistance, 0), 1)

      // De Casteljau interpolation remains exact at both authored endpoints.
      let firstLevel0 = Self.interpolate(
        start.output,
        firstControl.output,
        progress: progress
      )
      let firstLevel1 = Self.interpolate(
        firstControl.output,
        secondControl.output,
        progress: progress
      )
      let firstLevel2 = Self.interpolate(
        secondControl.output,
        end.output,
        progress: progress
      )
      let secondLevel0 = Self.interpolate(
        firstLevel0,
        firstLevel1,
        progress: progress
      )
      let secondLevel1 = Self.interpolate(
        firstLevel1,
        firstLevel2,
        progress: progress
      )
      return Self.interpolate(
        secondLevel0,
        secondLevel1,
        progress: progress
      )
    }

    fileprivate init(
      start: Coordinate,
      firstControl: Coordinate,
      secondControl: Coordinate,
      end: Coordinate
    ) {
      self.start = start
      self.firstControl = firstControl
      self.secondControl = secondControl
      self.end = end
    }

    private static func interpolate(
      _ start: Double,
      _ end: Double,
      progress: Double
    ) -> Double {
      start + (end - start) * progress
    }
  }

  /// Ordered cubic intervals covering the authored input domain.
  public let segments: [Segment]

  /// The spline derivative at the black endpoint.
  public let lowerEndpointTangent: Double

  /// The spline derivative at the white endpoint.
  public let upperEndpointTangent: Double

  /// The derivative used below the authored domain.
  ///
  /// This is zero when the black endpoint has moved above normalized Input 0,
  /// producing a flat clipping plateau. Otherwise it equals
  /// ``lowerEndpointTangent``.
  public let lowerExtrapolationTangent: Double

  /// The derivative used above the authored domain.
  ///
  /// This is zero when the white endpoint has moved below normalized Input 1,
  /// producing a flat clipping plateau. Otherwise it equals
  /// ``upperEndpointTangent``.
  public let upperExtrapolationTangent: Double

  /// Builds the canonical spline for an authored curve.
  public init(curve: ToneCurve) {
    let tangents = Self.tangents(points: curve.points)
    segments = curve.points.indices.dropLast().map { index in
      let start = curve.points[index]
      let end = curve.points[index + 1]
      let inputDistance = end.input - start.input
      let minimumOutput = min(start.output, end.output)
      let maximumOutput = max(start.output, end.output)
      let firstControlOutput = min(
        max(
          start.output + tangents[index] * inputDistance / 3,
          minimumOutput
        ),
        maximumOutput
      )
      let secondControlOutput = min(
        max(
          end.output - tangents[index + 1] * inputDistance / 3,
          minimumOutput
        ),
        maximumOutput
      )

      return Segment(
        start: Coordinate(input: start.input, output: start.output),
        firstControl: Coordinate(
          input: start.input + inputDistance / 3,
          output: firstControlOutput
        ),
        secondControl: Coordinate(
          input: end.input - inputDistance / 3,
          output: secondControlOutput
        ),
        end: Coordinate(input: end.input, output: end.output)
      )
    }

    if let firstSegment = segments.first,
      let lastSegment = segments.last
    {
      let lowerEndpointTangent = Self.slope(
        from: firstSegment.start,
        to: firstSegment.firstControl
      )
      let upperEndpointTangent = Self.slope(
        from: lastSegment.secondControl,
        to: lastSegment.end
      )
      self.lowerEndpointTangent = lowerEndpointTangent
      self.upperEndpointTangent = upperEndpointTangent
      if firstSegment.start.input > ToneCurve.normalizedRange.lowerBound {
        lowerExtrapolationTangent = 0
      } else {
        lowerExtrapolationTangent = lowerEndpointTangent
      }
      if lastSegment.end.input < ToneCurve.normalizedRange.upperBound {
        upperExtrapolationTangent = 0
      } else {
        upperExtrapolationTangent = upperEndpointTangent
      }
    } else {
      lowerEndpointTangent = 0
      upperEndpointTangent = 0
      lowerExtrapolationTangent = 0
      upperExtrapolationTangent = 0
    }
  }

  /// Returns the spline output for an input coordinate.
  ///
  /// Authored intervals use cubic evaluation. Beyond an inward endpoint, the
  /// nearest endpoint output is held constant. Endpoints still at Input 0 or 1
  /// use their spline derivative for extended-range extrapolation.
  public func output(at input: Double) -> Double {
    guard let firstSegment = segments.first,
      let lastSegment = segments.last
    else {
      return input
    }

    if input < firstSegment.start.input {
      return firstSegment.start.output
        + lowerExtrapolationTangent * (input - firstSegment.start.input)
    }
    if input > lastSegment.end.input {
      return lastSegment.end.output
        + upperExtrapolationTangent * (input - lastSegment.end.input)
    }

    let segment =
      segments.first { input <= $0.end.input } ?? lastSegment
    return segment.output(at: input)
  }

  private static func tangents(points: [ToneCurve.Point]) -> [Double] {
    guard points.count > 1 else {
      return Array(repeating: 0, count: points.count)
    }

    let slopes = points.indices.dropLast().map { index in
      (points[index + 1].output - points[index].output)
        / (points[index + 1].input - points[index].input)
    }
    var tangents = Array(repeating: 0.0, count: points.count)
    tangents[0] = slopes[0]
    tangents[points.count - 1] = slopes[slopes.count - 1]

    guard points.count > 2 else { return tangents }
    for index in 1..<(points.count - 1) {
      let previousSlope = slopes[index - 1]
      let nextSlope = slopes[index]
      guard previousSlope * nextSlope > 0 else {
        tangents[index] = 0
        continue
      }

      let previousDistance = points[index].input - points[index - 1].input
      let nextDistance = points[index + 1].input - points[index].input
      let previousWeight = 2 * nextDistance + previousDistance
      let nextWeight = nextDistance + 2 * previousDistance
      tangents[index] =
        (previousWeight + nextWeight)
        / (previousWeight / previousSlope + nextWeight / nextSlope)
    }
    return tangents
  }

  private static func slope(
    from start: Coordinate,
    to end: Coordinate
  ) -> Double {
    (end.output - start.output) / (end.input - start.input)
  }
}
