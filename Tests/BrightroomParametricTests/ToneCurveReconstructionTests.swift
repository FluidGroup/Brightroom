import CoreImage
import Foundation
import Testing

// Public API only: hosts rebuild curves from their own storage without
// `@testable` access.
import BrightroomParametric

/// Guards the validated reconstruction boundary a host uses to restore curves.
@Suite("Tone Curve reconstruction")
struct ToneCurveReconstructionTests {

  @Test
  func restoredCurvesPreserveMovedEndpointsAndInteriorPoints() throws {
    var value = ToneCurveFeature.Curves()
    let yIndex = value.y.insertPoint(input: 0.4, output: 0.55)
    _ = try #require(yIndex)
    let redIndex = value.red.insertPoint(input: 0.45, output: 0.65)
    _ = try #require(redIndex)
    value.y.movePoint(at: 0, input: 0.12, output: 0.08)
    value.red.movePoint(at: 2, input: 0.88, output: 0.95)

    let restored = ToneCurveFeature.Curves(
      y: try Self.restore(value.y),
      red: try Self.restore(value.red),
      green: try Self.restore(value.green),
      blue: try Self.restore(value.blue)
    )

    #expect(restored == value)
    #expect(restored.y.points[1].input == 0.4)
    #expect(restored.red.points[1].input == 0.45)
    #expect(restored.y.points[0].input == 0.12)
    #expect(restored.red.points[2].output == 0.95)
    #expect(ToneCurveFeature.RenderKey(curves: restored) == ToneCurveFeature.RenderKey(curves: value))
  }

  @Test
  func legalMinimumSpacingSurvivesFloatingPointRestoration() throws {
    var curve = ToneCurve()
    let insertedIndex = curve.insertPoint(input: 0.58, output: 0.6)
    let index = try #require(insertedIndex)
    curve.movePoint(at: 0, input: 1, output: 0.1)
    #expect(curve.points[index].input == 0.58)

    #expect(try Self.restore(curve) == curve)
  }

  @Test
  func restoredFeaturesRebuildEnabledStateAndNeutralBypass() throws {
    var active = ToneCurveFeature.Curves()
    let activeIndex = active.green.insertPoint(input: 0.45, output: 0.6)
    _ = try #require(activeIndex)
    var diagonal = ToneCurveFeature.Curves()
    let diagonalIndex = diagonal.y.insertPoint(input: 0.5, output: 0.5)
    _ = try #require(diagonalIndex)

    let restoredActive = ToneCurveFeature(
      curves: .init(green: try Self.restore(active.green))
    )
    let restoredDiagonal = ToneCurveFeature(
      curves: .init(y: try Self.restore(diagonal.y))
    )

    #expect(restoredActive.curves == active)
    #expect(ToneCurveFeature.RenderKey(activeCurves: restoredActive.curves) != nil)
    #expect(restoredDiagonal.curves == diagonal)
    // The render identity, not `ToneCurveFeature.Curves.isNeutral`, decides the
    // bypass: a diagonal interior point is authored but renders as identity.
    #expect(restoredDiagonal.curves.isDefault == false)
    #expect(ToneCurveFeature.RenderKey(activeCurves: restoredDiagonal.curves) == nil)

    let source = CIImage(color: .init(red: -0.1, green: 1.5, blue: 0.3, alpha: 0.5))
      .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
    let bypassed = try restoredDiagonal.apply(to: source, context: .init())
    #expect(bypassed === source)
  }

  @Test(arguments: InvalidCurve.allCases)
  func invalidPointsAreRejected(_ invalid: InvalidCurve) {
    var points: [(input: Double, output: Double)] = [
      (0, 0),
      (0.3, 0.25),
      (0.7, 0.8),
      (1, 1),
    ]
    switch invalid {
    case .tooFewPoints:
      points = [points[0]]
    case .tooManyPoints:
      let pointCount = ToneCurve.maximumPointCount + 1
      points = (0..<pointCount).map { index in
        let input = Double(index) / Double(pointCount - 1)
        return (input, input)
      }
    case .duplicateInput:
      points[2].input = points[1].input
    case .reversedOrder:
      points.swapAt(1, 2)
    case .insufficientSpacing:
      points[1].input = 0.01
    case .outOfRangeInput:
      points[3].input = 1.2
    case .outOfRangeOutput:
      points[1].output = -0.1
    case .nonFiniteInput:
      points[1].input = .nan
    case .nonFiniteOutput:
      points[2].output = .infinity
    }

    let curve = ToneCurve(
      validating: points.map { ToneCurve.Point(input: $0.input, output: $0.output) }
    )

    #expect(curve == nil)
  }

  @Test
  func inwardEndpointsAreRestoredAsTheFirstAndLastPoints() throws {
    let points = [
      ToneCurve.Point(input: 0.1, output: 0.2),
      ToneCurve.Point(input: 0.5, output: 0.4),
      ToneCurve.Point(input: 0.9, output: 0.7),
    ]

    let curve = try #require(ToneCurve(validating: points))

    #expect(curve.points == points)
    #expect(curve.isIdentity == false)
  }

  enum InvalidCurve: CaseIterable {
    case tooFewPoints
    case tooManyPoints
    case duplicateInput
    case reversedOrder
    case insufficientSpacing
    case outOfRangeInput
    case outOfRangeOutput
    case nonFiniteInput
    case nonFiniteOutput
  }

  /// Round-trips a curve through the scalar fields a host would store.
  private static func restore(_ curve: ToneCurve) throws -> ToneCurve {
    let stored = curve.points.map { (input: $0.input, output: $0.output) }
    return try #require(
      ToneCurve(validating: stored.map { ToneCurve.Point(input: $0.input, output: $0.output) })
    )
  }
}
