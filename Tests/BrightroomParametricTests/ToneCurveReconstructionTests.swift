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
  func restoredCurvesPreserveMovedEndpointsAndLinkedPointIdentities() throws {
    var value = ToneCurveEditorValue()
    let insertedPointID = value.y.insertPoint(input: 0.4, output: 0.55)
    let pointID = try #require(insertedPointID)
    let linkedPointID = value.red.insertPoint(id: pointID, input: 0.45, output: 0.65)
    _ = try #require(linkedPointID)
    value.y.movePoint(id: .blackEndpoint, input: 0.12, output: 0.08)
    value.red.movePoint(id: .whiteEndpoint, input: 0.88, output: 0.95)

    let restored = ToneCurveEditorValue(
      y: try Self.restore(value.y),
      red: try Self.restore(value.red),
      green: try Self.restore(value.green),
      blue: try Self.restore(value.blue)
    )

    #expect(restored == value)
    #expect(restored.y.point(id: pointID)?.input == 0.4)
    #expect(restored.red.point(id: pointID)?.input == 0.45)
    #expect(restored.y.point(id: .blackEndpoint)?.input == 0.12)
    #expect(restored.red.point(id: .whiteEndpoint)?.output == 0.95)
    #expect(ToneCurveRenderIdentity(value: restored) == ToneCurveRenderIdentity(value: value))
  }

  @Test
  func legalMinimumSpacingSurvivesFloatingPointRestoration() throws {
    var curve = ToneCurve()
    let insertedPointID = curve.insertPoint(input: 0.58, output: 0.6)
    let pointID = try #require(insertedPointID)
    curve.movePoint(id: .blackEndpoint, input: 1, output: 0.1)
    #expect(curve.point(id: pointID)?.input == 0.58)

    #expect(try Self.restore(curve) == curve)
  }

  @Test
  func restoredFeaturesRebuildEnabledStateAndNeutralBypass() throws {
    var active = ToneCurveEditorValue()
    let activePointID = active.green.insertPoint(input: 0.45, output: 0.6)
    _ = try #require(activePointID)
    var diagonal = ToneCurveEditorValue()
    let diagonalPointID = diagonal.y.insertPoint(input: 0.5, output: 0.5)
    _ = try #require(diagonalPointID)

    let restoredActive = ToneCurveFeature(
      value: .init(green: try Self.restore(active.green))
    )
    let restoredDiagonal = ToneCurveFeature(
      value: .init(y: try Self.restore(diagonal.y))
    )

    #expect(restoredActive.value == active)
    #expect(ToneCurveRenderIdentity(activeValue: restoredActive.value) != nil)
    #expect(restoredDiagonal.value == diagonal)
    // The render identity, not `ToneCurveEditorValue.isNeutral`, decides the
    // bypass: a diagonal interior point is authored but renders as identity.
    #expect(restoredDiagonal.value.isNeutral == false)
    #expect(ToneCurveRenderIdentity(activeValue: restoredDiagonal.value) == nil)

    let source = CIImage(color: .init(red: -0.1, green: 1.5, blue: 0.3, alpha: 0.5))
      .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
    let bypassed = try restoredDiagonal.apply(to: source, context: .init())
    #expect(bypassed === source)
  }

  @Test(arguments: InvalidCurve.allCases)
  func invalidPointsAreRejected(_ invalid: InvalidCurve) {
    let shadow = UUID()
    let highlight = UUID()
    var points: [(id: ToneCurve.Point.ID, input: Double, output: Double)] = [
      (.blackEndpoint, 0, 0),
      (.interior(shadow), 0.3, 0.25),
      (.interior(highlight), 0.7, 0.8),
      (.whiteEndpoint, 1, 1),
    ]
    switch invalid {
    case .tooFewPoints:
      points = [points[0]]
    case .tooManyPoints:
      let interiorCount = ToneCurve.maximumPointCount - 1
      points =
        [(.blackEndpoint, 0, 0)]
        + (1...interiorCount).map { index in
          let input = Double(index) / Double(interiorCount + 1)
          return (.interior(UUID()), input, input)
        }
        + [(.whiteEndpoint, 1, 1)]
    case .duplicateIdentity:
      points[2].id = .interior(shadow)
    case .interiorEndpointIdentity:
      points[1].id = .whiteEndpoint
    case .wrongEndpointIdentity:
      points[0].id = .interior(UUID())
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
      validating: points.map { ToneCurve.Point(id: $0.id, input: $0.input, output: $0.output) }
    )

    #expect(curve == nil)
  }

  enum InvalidCurve: CaseIterable {
    case tooFewPoints
    case tooManyPoints
    case duplicateIdentity
    case interiorEndpointIdentity
    case wrongEndpointIdentity
    case reversedOrder
    case insufficientSpacing
    case outOfRangeInput
    case outOfRangeOutput
    case nonFiniteInput
    case nonFiniteOutput
  }

  /// Round-trips a curve through the scalar fields a host would store.
  private static func restore(_ curve: ToneCurve) throws -> ToneCurve {
    let stored = curve.points.map { (id: $0.id, input: $0.input, output: $0.output) }
    return try #require(
      ToneCurve(validating: stored.map { ToneCurve.Point(id: $0.id, input: $0.input, output: $0.output) })
    )
  }
}
