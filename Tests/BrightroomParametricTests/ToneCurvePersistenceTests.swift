import CoreImage
import Foundation
import Testing

@testable import BrightroomParametric

/// Guards the authored-value persistence boundary independently of render caches.
@Suite("Tone Curve persistence")
struct ToneCurvePersistenceTests {

  @Test
  func authoredValueRoundTripPreservesMovedEndpointsAndLinkedPointIdentities() throws {
    var value = ToneCurveEditorValue()
    let insertedPointID = value.y.insertPoint(input: 0.4, output: 0.55)
    let pointID = try #require(insertedPointID)
    let linkedPointID = value.red.insertPoint(id: pointID, input: 0.45, output: 0.65)
    _ = try #require(linkedPointID)
    value.y.movePoint(id: .blackEndpoint, input: 0.12, output: 0.08)
    value.red.movePoint(id: .whiteEndpoint, input: 0.88, output: 0.95)

    let data = try JSONEncoder().encode(ToneCurveFeature(value: value))
    let restored = try JSONDecoder().decode(ToneCurveFeature.self, from: data).value

    #expect(restored == value)
    #expect(restored.y.point(id: pointID) != nil)
    #expect(restored.red.point(id: pointID) != nil)
    #expect(ToneCurveRenderIdentity(value: restored) == ToneCurveRenderIdentity(value: value))
  }

  @Test
  func documentRoundTripRestoresValueAndNeutralBypassWithoutPersistingCaches() throws {
    var value = ToneCurveEditorValue()
    let activePointID = value.green.insertPoint(input: 0.45, output: 0.6)
    _ = try #require(activePointID)
    let active = ToneCurveFeature(id: .init(rawValue: "active-curve"), value: value)
    var diagonal = ToneCurveEditorValue()
    let diagonalPointID = diagonal.y.insertPoint(input: 0.5, output: 0.5)
    _ = try #require(diagonalPointID)
    let identity = ToneCurveFeature(id: .init(rawValue: "identity-curve"), value: diagonal)
    let document = EditingDocument(
      mainTree: .init(features: [
        .effect(active),
        .effect(identity),
      ]))
    let codec = ParametricDocumentCodec()

    let data = try codec.encode(document)
    let restored = try codec.decode(data)
    #expect(restored == document)
    guard case .effect(let first) = restored.mainTree.features[0],
      case .effect(let second) = restored.mainTree.features[1]
    else {
      Issue.record("Restored tone curves must remain effect nodes.")
      return
    }
    let restoredActive = try #require(first as? ToneCurveFeature)
    let restoredIdentity = try #require(second as? ToneCurveFeature)
    #expect(restoredActive.value == value)
    #expect(restoredActive.isEnabled)
    #expect(restoredIdentity.value == diagonal)
    #expect(restoredIdentity.isEnabled == false)

    let source = CIImage(color: .init(red: -0.1, green: 1.5, blue: 0.3, alpha: 0.5))
      .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
    let bypassed = try restoredIdentity.apply(to: source, context: .init())
    #expect(bypassed === source)

    let parameters = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(active)) as? [String: Any]
    )
    #expect(Set(parameters.keys) == Set(["id", "value", "semanticVersion"]))
    #expect(parameters["semanticVersion"] as? Int == ToneCurveFeature.semanticVersion)
  }

  @Test
  func unknownRenderingSemanticsAreRejected() throws {
    let feature = ToneCurveFeature(value: .neutral)
    var parameters = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(feature)) as? [String: Any]
    )
    parameters["semanticVersion"] = ToneCurveFeature.semanticVersion + 1
    let data = try JSONSerialization.data(withJSONObject: parameters)

    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(ToneCurveFeature.self, from: data)
    }
  }

  @Test
  func legalMinimumSpacingSurvivesFloatingPointRoundTrip() throws {
    var curve = ToneCurve()
    let insertedPointID = curve.insertPoint(input: 0.58, output: 0.6)
    let pointID = try #require(insertedPointID)
    curve.movePoint(id: .blackEndpoint, input: 1, output: 0.1)
    #expect(curve.point(id: pointID)?.input == 0.58)

    let data = try JSONEncoder().encode(ToneCurveFeature(value: .init(y: curve)))
    #expect(try JSONDecoder().decode(ToneCurveFeature.self, from: data).value.y == curve)
  }

  @Test(arguments: InvalidCurve.allCases)
  func invalidAuthoredCurvesAreRejected(_ invalid: InvalidCurve) throws {
    var curve = ToneCurve()
    let insertedPointID = curve.insertPoint(input: 0.4, output: 0.55)
    _ = try #require(insertedPointID)
    var encoded = try #require(
      JSONSerialization.jsonObject(
        with: JSONEncoder().encode(ToneCurveFeature(value: .init(y: curve)))
      ) as? [String: Any]
    )
    var channels = try #require(encoded["value"] as? [String: Any])
    var y = try #require(channels["y"] as? [String: Any])
    var points = try #require(y["points"] as? [[String: Any]])
    switch invalid {
    case .tooFewPoints:
      points = [points[0]]
    case .tooManyPoints:
      points = Array(repeating: points[1], count: ToneCurve.maximumPointCount + 1)
    case .duplicateIdentity:
      points[1]["id"] = points[0]["id"]
    case .wrongEndpointIdentity:
      points[0]["id"] = points[1]["id"]
    case .reversedOrder:
      points.swapAt(0, 2)
    case .insufficientSpacing:
      points[1]["input"] = 0.01
    case .outOfRangeInput:
      points[1]["input"] = 1.2
    case .outOfRangeOutput:
      points[1]["output"] = -0.1
    case .nonFiniteInput:
      points[1]["input"] = "NaN"
    }
    y["points"] = points
    channels["y"] = y
    encoded["value"] = channels
    let data = try JSONSerialization.data(withJSONObject: encoded)
    let decoder = JSONDecoder()
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(
      positiveInfinity: "Infinity",
      negativeInfinity: "-Infinity",
      nan: "NaN"
    )

    #expect(throws: DecodingError.self) {
      try decoder.decode(ToneCurveFeature.self, from: data)
    }
  }

  enum InvalidCurve: CaseIterable {
    case tooFewPoints
    case tooManyPoints
    case duplicateIdentity
    case wrongEndpointIdentity
    case reversedOrder
    case insufficientSpacing
    case outOfRangeInput
    case outOfRangeOutput
    case nonFiniteInput
  }
}
