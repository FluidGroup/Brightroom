import Testing

@testable import BrightroomParametric

@Suite("Tone Curve values")
struct ToneCurveTests {

  @Test
  func newCurveIsTheNeutralIdentityMapping() {
    let curve = ToneCurve()

    #expect(curve.isNeutral)
    #expect(
      curve.points == [
        ToneCurve.Point(input: 0, output: 0),
        ToneCurve.Point(input: 1, output: 1),
      ]
    )
    #expect(curve.isIdentityMapping)
  }

  @Test
  func diagonalInteriorPointsAreIdentityButInwardEndpointsAreNot() throws {
    var curve = ToneCurve()
    let diagonalIndex = curve.insertPoint(input: 0.4, output: 0.4)
    _ = try #require(diagonalIndex)
    #expect(curve.isIdentityMapping)

    curve.movePoint(at: 0, input: 0.2, output: 0.2)
    #expect(curve.isIdentityMapping == false)
  }

  @Test
  func insertingPointsKeepsTheirInputCoordinatesOrdered() throws {
    var curve = ToneCurve()

    let highlightIndex = curve.insertPoint(input: 0.8, output: 0.7)
    #expect(highlightIndex == 1)
    let shadowIndex = curve.insertPoint(input: 0.2, output: 0.3)
    #expect(shadowIndex == 1)

    #expect(curve.points.map(\.input) == [0, 0.2, 0.8, 1])
    #expect(curve.points[1].output == 0.3)
    #expect(curve.points[2].output == 0.7)
    #expect(curve.isNeutral == false)
  }

  @Test
  func curvesWithTheSameCoordinatesAreEqual() throws {
    var first = ToneCurve()
    var second = ToneCurve()
    for (input, output) in [(0.3, 0.4), (0.7, 0.8)] {
      let index = first.insertPoint(input: input, output: output)
      _ = try #require(index)
    }
    for (input, output) in [(0.7, 0.8), (0.3, 0.4)] {
      let index = second.insertPoint(input: input, output: output)
      _ = try #require(index)
    }

    #expect(first == second)

    let removed = second.removePoint(at: 1)
    #expect(removed)
    let reinsertedIndex = second.insertPoint(input: 0.3, output: 0.4)
    #expect(reinsertedIndex == 1)

    #expect(first == second)
  }

  @Test
  func movingInteriorPointCannotCrossItsNeighbors() throws {
    var curve = ToneCurve()
    let insertedLowerIndex = curve.insertPoint(input: 0.25, output: 0.25)
    let lowerIndex = try #require(insertedLowerIndex)
    let insertedUpperIndex = curve.insertPoint(input: 0.75, output: 0.75)
    let upperIndex = try #require(insertedUpperIndex)
    #expect(lowerIndex == 1)
    #expect(upperIndex == 2)

    curve.movePoint(at: lowerIndex, input: 1, output: 2)

    let movedPoint = curve.points[lowerIndex]
    let upperPoint = curve.points[upperIndex]
    #expect(
      movedPoint.input
        == upperPoint.input - ToneCurve.minimumInputSpacing
    )
    #expect(movedPoint.output == 1)
    #expect(curve.points.map(\.input) == curve.points.map(\.input).sorted())
  }

  @Test
  func indexKeepsAddressingTheSamePointDuringADrag() throws {
    var curve = ToneCurve()
    let shadowIndex = curve.insertPoint(input: 0.3, output: 0.3)
    _ = try #require(shadowIndex)
    let insertedIndex = curve.insertPoint(input: 0.6, output: 0.6)
    let index = try #require(insertedIndex)

    for input in stride(from: 0.6, through: 0, by: -0.05) {
      curve.movePoint(at: index, input: input, output: 0.5)
    }
    curve.offsetPoint(at: index, inputDelta: -0.5, outputDelta: 0.1)

    #expect(curve.points.count == 4)
    #expect(curve.points[index].input == 0.3 + ToneCurve.minimumInputSpacing)
    #expect(curve.points[index].output == 0.6)
    #expect(curve.points[1] == ToneCurve.Point(input: 0.3, output: 0.3))
  }

  @Test
  func endpointsMoveOnBothAxesWithoutCrossingTheirNeighbors() throws {
    var curve = ToneCurve()
    let lowerIndex = curve.insertPoint(input: 0.4, output: 0.4)
    _ = try #require(lowerIndex)
    let upperIndex = curve.insertPoint(input: 0.6, output: 0.6)
    _ = try #require(upperIndex)
    let whiteIndex = curve.points.count - 1

    curve.movePoint(at: 0, input: 0.25, output: 0.1)
    curve.movePoint(at: whiteIndex, input: 0.75, output: 0.9)

    #expect(curve.points[0] == ToneCurve.Point(input: 0.25, output: 0.1))
    #expect(curve.points[whiteIndex] == ToneCurve.Point(input: 0.75, output: 0.9))

    curve.movePoint(at: 0, input: 1, output: 0.1)
    curve.movePoint(at: whiteIndex, input: 0, output: 0.9)

    #expect(curve.points[0].input == 0.38)
    #expect(curve.points[whiteIndex].input == 0.62)
    #expect(curve.isNeutral == false)
  }

  @Test
  func pointsPackedAgainstAnEndpointStayRestorable() throws {
    var curve = ToneCurve()
    for input in [0.5, 0.53, 0.56] {
      let index = curve.insertPoint(input: input, output: 0.5)
      _ = try #require(index)
    }
    let moves: [(index: Int, input: Double, output: Double)] = [
      (1, 0, 0.5), (2, 0, 0.5), (3, 0, 0.5),
      // `0.06 - 0.02` rounds just below `0.04`, so these moves find no
      // horizontal room. Snapping to the interval's bound used to creep the
      // points toward the black endpoint until its own bound fell below 0.
      (2, 1, 0.5), (1, 1, 0.5),
      (0, 1, 0),
    ]

    for move in moves {
      curve.movePoint(at: move.index, input: move.input, output: move.output)
      #expect(ToneCurve(validating: curve.points) != nil)
    }
    #expect(curve.points[0] == ToneCurve.Point(input: 0, output: 0))
  }

  @Test
  func pointWithNoHorizontalRoomKeepsItsInput() throws {
    // Both gaps sit at the round-off tolerance that restoration accepts.
    let gap = ToneCurve.minimumInputSpacing - 8 * Double.ulpOfOne
    var curve = try #require(
      ToneCurve(validating: [
        ToneCurve.Point(input: 0, output: 0),
        ToneCurve.Point(input: gap, output: gap),
        ToneCurve.Point(input: 2 * gap, output: 2 * gap),
        ToneCurve.Point(input: 1, output: 1),
      ])
    )

    curve.movePoint(at: 1, input: 0.5, output: 0.3)

    #expect(curve.points[1] == ToneCurve.Point(input: gap, output: 0.3))
    #expect(ToneCurve(validating: curve.points) != nil)
  }

  @Test
  func editsWithNaNCoordinatesAreIgnored() throws {
    var curve = ToneCurve()
    let insertedIndex = curve.insertPoint(input: 0.5, output: 0.5)
    let index = try #require(insertedIndex)
    let edited = curve

    curve.movePoint(at: index, input: .nan, output: 0.2)
    curve.movePoint(at: index, input: 0.4, output: .nan)
    curve.offsetPoint(at: 0, inputDelta: .nan)
    #expect(curve.insertPoint(input: 0.3, output: .nan) == nil)
    #expect(curve.insertPoint(input: .nan, output: 0.3) == nil)

    #expect(curve == edited)

    // A white endpoint move is still limited by its neighbor afterwards.
    curve.movePoint(at: 2, input: 0.1, output: 1)
    #expect(curve.points[2].input == 0.5 + ToneCurve.minimumInputSpacing)
  }

  @Test
  func onlyInteriorPointsCanBeRemoved() throws {
    var curve = ToneCurve()
    let insertedIndex = curve.insertPoint(input: 0.5, output: 0.6)
    let index = try #require(insertedIndex)

    let didRemoveBlackEndpoint = curve.removePoint(at: 0)
    let didRemoveWhiteEndpoint = curve.removePoint(at: curve.points.count - 1)
    #expect(curve.points.count == 3)
    let didRemoveInteriorPoint = curve.removePoint(at: index)

    #expect(didRemoveBlackEndpoint == false)
    #expect(didRemoveWhiteEndpoint == false)
    #expect(didRemoveInteriorPoint)
    #expect(curve == .neutral)
  }

  @Test
  func accessibleInsertionUsesTheLargestAvailableInterval() throws {
    var curve = ToneCurve()
    let firstIndex = curve.insertPoint(input: 0.25, output: 0.4)
    _ = try #require(firstIndex)

    let largestGapIndex = curve.insertPointInLargestGap()
    let insertedIndex = try #require(largestGapIndex)
    let insertedPoint = curve.points[insertedIndex]

    #expect(insertedIndex == 2)
    #expect(insertedPoint.input == 0.625)
    #expect(insertedPoint.output == 0.7)
  }

  @Test
  func yRGBChannelsRetainIndependentCurves() throws {
    var value = ToneCurveEditorValue()
    let redIndex = value.red.insertPoint(input: 0.4, output: 0.7)
    _ = try #require(redIndex)

    #expect(value.isNeutral == false)
    #expect(value.y.isNeutral)
    #expect(value.red.isNeutral == false)
    #expect(value.green.isNeutral)
    #expect(value.blue.isNeutral)

    value.reset(channel: .red)

    #expect(value == .neutral)
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
    let shadowIndex = curve.insertPoint(input: 0.2, output: 0.65)
    _ = try #require(shadowIndex)
    let highlightIndex = curve.insertPoint(input: 0.75, output: 0.4)
    _ = try #require(highlightIndex)
    let evaluator = ToneCurveEvaluator(curve: curve)

    for point in curve.points {
      #expect(evaluator.output(at: point.input) == point.output)
    }
  }

  @Test
  func everyIntervalStaysWithinItsAuthoredOutputBounds() throws {
    var curve = ToneCurve()
    let firstIndex = curve.insertPoint(input: 0.25, output: 0.8)
    _ = try #require(firstIndex)
    let secondIndex = curve.insertPoint(input: 0.6, output: 0.2)
    _ = try #require(secondIndex)
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
    let firstIndex = curve.insertPoint(input: 0.2, output: 0.3)
    _ = try #require(firstIndex)
    let secondIndex = curve.insertPoint(input: 0.65, output: 0.75)
    _ = try #require(secondIndex)
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
    curve.movePoint(at: 0, input: 0.2, output: 0.1)
    curve.movePoint(at: 1, input: 0.8, output: 0.9)
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
    let insertedIndex = curve.insertPoint(input: 0.4, output: 0.7)
    _ = try #require(insertedIndex)
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
