import Testing

@testable import BrightroomParametric

@Suite("Tone Curve values")
struct ToneCurveTests {

  @Test
  func newCurveIsTheNeutralIdentityMapping() {
    let curve = ToneCurve()

    #expect(curve.isNeutral)
    #expect(curve.points.count == 2)
    #expect(curve.points[0].id == .blackEndpoint)
    #expect(curve.points[0].input == 0)
    #expect(curve.points[0].output == 0)
    #expect(curve.points[1].id == .whiteEndpoint)
    #expect(curve.points[1].input == 1)
    #expect(curve.points[1].output == 1)
    #expect(curve.isIdentityMapping)
  }

  @Test
  func diagonalInteriorPointsAreIdentityButInwardEndpointsAreNot() throws {
    var curve = ToneCurve()
    let diagonalPointID = curve.insertPoint(input: 0.4, output: 0.4)
    _ = try #require(diagonalPointID)
    #expect(curve.isIdentityMapping)

    curve.movePoint(id: .blackEndpoint, input: 0.2, output: 0.2)
    #expect(curve.isIdentityMapping == false)
  }

  @Test
  func insertingPointsKeepsTheirInputCoordinatesOrdered() throws {
    var curve = ToneCurve()

    let insertedHighlightID = curve.insertPoint(input: 0.8, output: 0.7)
    let highlightID = try #require(insertedHighlightID)
    let insertedShadowID = curve.insertPoint(input: 0.2, output: 0.3)
    let shadowID = try #require(insertedShadowID)

    #expect(curve.points.map(\.input) == [0, 0.2, 0.8, 1])
    #expect(curve.point(id: shadowID)?.output == 0.3)
    #expect(curve.point(id: highlightID)?.output == 0.7)
    #expect(curve.isNeutral == false)
  }

  @Test
  func movingInteriorPointCannotCrossItsNeighbors() throws {
    var curve = ToneCurve()
    let insertedLowerID = curve.insertPoint(input: 0.25, output: 0.25)
    let lowerID = try #require(insertedLowerID)
    let insertedUpperID = curve.insertPoint(input: 0.75, output: 0.75)
    let upperID = try #require(insertedUpperID)

    curve.movePoint(id: lowerID, input: 1, output: 2)

    let movedPoint = try #require(curve.point(id: lowerID))
    let upperPoint = try #require(curve.point(id: upperID))
    #expect(
      movedPoint.input
        == upperPoint.input - ToneCurve.minimumInputSpacing
    )
    #expect(movedPoint.output == 1)
    #expect(curve.points.map(\.input) == curve.points.map(\.input).sorted())
  }

  @Test
  func endpointsMoveOnBothAxesWithoutCrossingTheirNeighbors() throws {
    var curve = ToneCurve()
    let lowerPointID = curve.insertPoint(input: 0.4, output: 0.4)
    _ = try #require(lowerPointID)
    let upperPointID = curve.insertPoint(input: 0.6, output: 0.6)
    _ = try #require(upperPointID)

    curve.movePoint(id: .blackEndpoint, input: 0.25, output: 0.1)
    curve.movePoint(id: .whiteEndpoint, input: 0.75, output: 0.9)

    #expect(curve.point(id: .blackEndpoint)?.input == 0.25)
    #expect(curve.point(id: .blackEndpoint)?.output == 0.1)
    #expect(curve.point(id: .whiteEndpoint)?.input == 0.75)
    #expect(curve.point(id: .whiteEndpoint)?.output == 0.9)

    curve.movePoint(id: .blackEndpoint, input: 1, output: 0.1)
    curve.movePoint(id: .whiteEndpoint, input: 0, output: 0.9)

    #expect(curve.point(id: .blackEndpoint)?.input == 0.38)
    #expect(curve.point(id: .whiteEndpoint)?.input == 0.62)
    #expect(curve.isNeutral == false)
  }

  @Test
  func onlyInteriorPointsCanBeRemoved() throws {
    var curve = ToneCurve()
    let insertedPointID = curve.insertPoint(input: 0.5, output: 0.6)
    let pointID = try #require(insertedPointID)

    let didRemoveBlackEndpoint = curve.removePoint(id: .blackEndpoint)
    let didRemoveWhiteEndpoint = curve.removePoint(id: .whiteEndpoint)
    let didRemoveInteriorPoint = curve.removePoint(id: pointID)

    #expect(didRemoveBlackEndpoint == false)
    #expect(didRemoveWhiteEndpoint == false)
    #expect(didRemoveInteriorPoint)
    #expect(curve.points.count == 2)
  }

  @Test
  func accessibleInsertionUsesTheLargestAvailableInterval() throws {
    var curve = ToneCurve()
    let firstPointID = curve.insertPoint(input: 0.25, output: 0.4)
    _ = try #require(firstPointID)

    let largestGapPointID = curve.insertPointInLargestGap()
    let insertedID = try #require(largestGapPointID)
    let insertedPoint = try #require(curve.point(id: insertedID))

    #expect(insertedPoint.input == 0.625)
    #expect(insertedPoint.output == 0.7)
  }

  @Test
  func yRGBChannelsRetainIndependentCurves() throws {
    var value = ToneCurveEditorValue()
    let redPointID = value.red.insertPoint(input: 0.4, output: 0.7)
    _ = try #require(redPointID)

    #expect(value.isNeutral == false)
    #expect(value.y.isNeutral)
    #expect(value.red.isNeutral == false)
    #expect(value.green.isNeutral)
    #expect(value.blue.isNeutral)

    value.reset(channel: .red)

    #expect(value == .neutral)
  }

  @Test
  func callerSuppliedInteriorIdentityCanLinkIndependentCurves() throws {
    var y = ToneCurve()
    let insertedPointID = y.insertPoint(input: 0.4, output: 0.6)
    let pointID = try #require(insertedPointID)
    var red = ToneCurve()

    let linkedPointID = red.insertPoint(
      id: pointID,
      input: 0.4,
      output: 0.7
    )
    let duplicatePointID = red.insertPoint(
      id: pointID,
      input: 0.6,
      output: 0.5
    )
    let endpointIdentity = red.insertPoint(
      id: .blackEndpoint,
      input: 0.6,
      output: 0.5
    )

    #expect(linkedPointID == pointID)
    #expect(red.point(id: pointID)?.output == 0.7)
    #expect(duplicatePointID == nil)
    #expect(endpointIdentity == nil)
    #expect(red.points.count == 3)
  }
}

@Suite("Tone Curve evaluation")
struct ToneCurveEvaluatorTests {

  @Test
  func neutralCurveIsIdentityInsideAndOutsideNormalizedDomain() {
    let evaluator = ToneCurveEvaluator(curve: .neutral)

    for input in [-0.5, 0, 0.25, 0.5, 1, 1.5] {
      #expect(evaluator.output(at: input) == input)
    }
  }

  @Test
  func evaluatorPassesThroughEveryAuthoredPoint() throws {
    var curve = ToneCurve()
    let shadowPointID = curve.insertPoint(input: 0.2, output: 0.65)
    _ = try #require(shadowPointID)
    let highlightPointID = curve.insertPoint(input: 0.75, output: 0.4)
    _ = try #require(highlightPointID)
    let evaluator = ToneCurveEvaluator(curve: curve)

    for point in curve.points {
      #expect(evaluator.output(at: point.input) == point.output)
    }
  }

  @Test
  func everyIntervalStaysWithinItsAuthoredOutputBounds() throws {
    var curve = ToneCurve()
    let firstPointID = curve.insertPoint(input: 0.25, output: 0.8)
    _ = try #require(firstPointID)
    let secondPointID = curve.insertPoint(input: 0.6, output: 0.2)
    _ = try #require(secondPointID)
    let evaluator = ToneCurveEvaluator(curve: curve)

    for segment in evaluator.segments {
      let minimumOutput = min(segment.start.output, segment.end.output)
      let maximumOutput = max(segment.start.output, segment.end.output)

      for sampleIndex in 0...64 {
        let progress = Double(sampleIndex) / 64
        let input =
          segment.start.input
          + (segment.end.input - segment.start.input) * progress
        let output = evaluator.output(at: input)
        #expect(output >= minimumOutput)
        #expect(output <= maximumOutput)
      }
    }
  }

  @Test
  func adjacentSegmentsHaveContinuousEndpointTangents() throws {
    var curve = ToneCurve()
    let firstPointID = curve.insertPoint(input: 0.2, output: 0.3)
    _ = try #require(firstPointID)
    let secondPointID = curve.insertPoint(input: 0.65, output: 0.75)
    _ = try #require(secondPointID)
    let evaluator = ToneCurveEvaluator(curve: curve)

    for index in evaluator.segments.indices.dropLast() {
      let lowerSegment = evaluator.segments[index]
      let upperSegment = evaluator.segments[index + 1]
      let lowerTangent = Self.slope(
        from: lowerSegment.secondControl,
        to: lowerSegment.end
      )
      let upperTangent = Self.slope(
        from: upperSegment.start,
        to: upperSegment.firstControl
      )

      #expect(abs(lowerTangent - upperTangent) < 0.000_000_001)
    }
  }

  @Test
  func movedEndpointsFlattenInputsOutsideTheAuthoredInterval() {
    var curve = ToneCurve()
    curve.movePoint(id: .blackEndpoint, input: 0.2, output: 0.1)
    curve.movePoint(id: .whiteEndpoint, input: 0.8, output: 0.9)
    let evaluator = ToneCurveEvaluator(curve: curve)

    #expect(evaluator.lowerExtrapolationTangent == 0)
    #expect(evaluator.upperExtrapolationTangent == 0)
    for input in [-0.25, 0, 0.1, 0.2] {
      #expect(evaluator.output(at: input) == 0.1)
    }
    for input in [0.8, 0.9, 1, 1.25] {
      #expect(evaluator.output(at: input) == 0.9)
    }
  }

  @Test
  func endpointsAtNormalizedBoundsRetainTheirSplineTangents() throws {
    var curve = ToneCurve()
    let insertedPointID = curve.insertPoint(input: 0.4, output: 0.7)
    _ = try #require(insertedPointID)
    let evaluator = ToneCurveEvaluator(curve: curve)

    #expect(
      evaluator.lowerExtrapolationTangent
        == evaluator.lowerEndpointTangent
    )
    #expect(
      evaluator.upperExtrapolationTangent
        == evaluator.upperEndpointTangent
    )
    #expect(
      evaluator.output(at: -0.25)
        == evaluator.lowerEndpointTangent * -0.25
    )
    #expect(
      evaluator.output(at: 1.25)
        == 1 + evaluator.upperEndpointTangent * 0.25
    )
  }

  private static func slope(
    from start: ToneCurveEvaluator.Coordinate,
    to end: ToneCurveEvaluator.Coordinate
  ) -> Double {
    (end.output - start.output) / (end.input - start.input)
  }
}
