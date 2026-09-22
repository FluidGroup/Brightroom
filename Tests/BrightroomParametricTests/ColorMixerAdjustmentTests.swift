import Foundation
import Testing

@testable import BrightroomParametric

@Suite("Color Mixer adjustment")
struct ColorMixerAdjustmentTests {

  @Test
  func bandsHaveStableFixedOrder() {
    #expect(
      ColorMixerBand.allCases == [
        .red, .orange, .yellow, .green, .aqua, .blue, .purple, .magenta,
      ])
    #expect(ColorMixerBand.allCases.map(\.rawValue) == Array(0..<8))
  }

  @Test
  func valuesClampOnInitializationAndMutation() {
    var value = ColorMixerBandAdjustment(hue: 101, saturation: -101, luminance: 200)
    #expect(value == ColorMixerBandAdjustment(hue: 100, saturation: -100, luminance: 100))
    value.hue = -1_000
    value.saturation = 1_000
    value.luminance = -1_000
    #expect(value == ColorMixerBandAdjustment(hue: -100, saturation: 100, luminance: -100))
  }

  @Test
  func typedSubscriptMutatesExactlyOneFixedSlot() {
    var adjustment = ColorMixerAdjustment.neutral
    adjustment[.aqua] = ColorMixerBandAdjustment(hue: 25, saturation: 40, luminance: -10)
    #expect(adjustment.isNeutral == false)
    #expect(adjustment.aqua == adjustment[.aqua])
    for band in ColorMixerBand.allCases where band != .aqua {
      #expect(adjustment[band].isNeutral)
    }
  }

  @Test
  func neutralHasNoRenderPlanAndFeatureIsDisabled() {
    #expect(ColorMixerAdjustment.neutral.isNeutral)
    #expect(ColorMixerRenderPlan(adjustment: .neutral) == nil)
    let feature = ColorMixerFeature(adjustment: .neutral)
    #expect(feature.isEnabled == false)
    #expect(feature.algorithm == .oklch)
    #expect(feature.id.rawValue == "brightroom.color-mixer")
  }

  @Test
  func previewIdentityUsesTheNormalizedRenderParameters() throws {
    var first = ColorMixerAdjustment.neutral
    first.red.hue = 10
    var equivalent = ColorMixerAdjustment.neutral
    equivalent.red.hue = 10.0.nextUp
    var changed = ColorMixerAdjustment.neutral
    changed.red.hue = 11

    let firstIdentity = try #require(
      ColorMixerRenderIdentity(activeAdjustment: first)
    )
    let equivalentIdentity = try #require(
      ColorMixerRenderIdentity(activeAdjustment: equivalent)
    )
    let changedIdentity = try #require(
      ColorMixerRenderIdentity(activeAdjustment: changed)
    )
    let explicitIdentity = try #require(
      ColorMixerRenderIdentity(activeAdjustment: first, algorithm: .oklch)
    )

    #expect(
      ColorMixerRenderIdentity(activeAdjustment: .neutral) == nil
    )
    #expect(firstIdentity.semanticVersion == ColorMixerRenderPlan.semanticVersion)
    #expect(firstIdentity.algorithm == .oklch)
    #expect(firstIdentity == equivalentIdentity)
    #expect(firstIdentity == explicitIdentity)
    #expect(Set([firstIdentity, explicitIdentity]).count == 1)
    #expect(firstIdentity != changedIdentity)
  }

  @Test
  func documentRoundTripPreservesAuthoredValuesAndDerivedEnabledState() throws {
    let active = ColorMixerFeature(
      id: FeatureID(rawValue: "active-mixer"),
      adjustment: .init(red: .init(hue: 10.0.nextUp, saturation: -45, luminance: 20)),
      algorithm: .oklch
    )
    let neutral = ColorMixerFeature(id: FeatureID(rawValue: "neutral-mixer"), adjustment: .neutral)
    let document = EditingDocument(mainTree: .init(features: [.effect(active), .effect(neutral)]))
    let codec = ParametricDocumentCodec()

    let data = try codec.encode(document)
    let restored = try codec.decode(data)

    #expect(restored == document)
    guard case .effect(let restoredEffect) = restored.mainTree.features[0],
      case .effect(let restoredNeutralEffect) = restored.mainTree.features[1]
    else {
      Issue.record("Expected Color Mixer effects after decoding.")
      return
    }
    let restoredActive = try #require(restoredEffect as? ColorMixerFeature)
    let restoredNeutral = try #require(restoredNeutralEffect as? ColorMixerFeature)
    #expect(restoredActive.adjustment == active.adjustment)
    #expect(restoredActive.algorithm == .oklch)
    #expect(restoredActive.isEnabled)
    #expect(restoredNeutral.adjustment == .neutral)
    #expect(restoredNeutral.algorithm == .oklch)
    #expect(restoredNeutral.isEnabled == false)

    let encoded = String(decoding: data, as: UTF8.self)
    #expect(encoded.contains("renderPlan") == false)
    #expect(encoded.contains("isEnabled") == false)
    #expect(encoded.contains("brightroom.effect.color-mixer"))
    let envelope = try Self.firstEffectEnvelope(in: data)
    let parameters = try #require(envelope["params"] as? [String: Any])
    #expect(envelope["v"] as? Int == 2)
    #expect(parameters["algorithm"] as? String == "oklch")
  }

  @Test
  func versionOneMigratesToOKLChAndResavesWithAnExplicitAlgorithm() throws {
    // This is the old on-disk shape, independent of today's feature encoder.
    let legacyParameters = Self.versionOneParameters()
    let data = try Self.documentData(parameters: legacyParameters, version: 1)
    let codec = ParametricDocumentCodec()
    let restored = try codec.decode(data)
    let first = try #require(restored.mainTree.features.first)
    guard case .effect(let effect) = first else {
      Issue.record("Expected a migrated Color Mixer effect.")
      return
    }
    let mixer = try #require(effect as? ColorMixerFeature)
    let expected = ColorMixerFeature(
      id: .init(rawValue: "legacy-mixer"),
      adjustment: .init(
        red: .init(hue: 23, saturation: -24, luminance: 17),
        magenta: .init(saturation: 5, luminance: -8)
      ),
      algorithm: .oklch
    )

    #expect(mixer.id == expected.id)
    #expect(mixer.adjustment == expected.adjustment)
    #expect(mixer.algorithm == .oklch)
    #expect(mixer.isEnabled)
    #expect(mixer == expected)

    let resaved = try codec.encode(restored)
    let envelope = try Self.firstEffectEnvelope(in: resaved)
    let parameters = try #require(envelope["params"] as? [String: Any])
    #expect(envelope["v"] as? Int == 2)
    #expect(parameters["algorithm"] as? String == "oklch")
    #expect(try codec.decode(resaved) == restored)
  }

  @Test(arguments: InvalidAlgorithm.allCases)
  func versionTwoRequiresAKnownAlgorithm(_ invalid: InvalidAlgorithm) throws {
    var parameters = Self.versionOneParameters()
    switch invalid {
    case .missing:
      break
    case .null:
      parameters["algorithm"] = NSNull()
    case .unknown:
      parameters["algorithm"] = "unknown-algorithm"
    }
    let document = try Self.documentData(parameters: parameters, version: 2)
    let feature = try JSONSerialization.data(withJSONObject: parameters)

    #expect(throws: DecodingError.self) {
      try ParametricDocumentCodec().decode(document)
    }
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(ColorMixerFeature.self, from: feature)
    }
  }

  @Test(arguments: [3, 999])
  func futureSchemaVersionsAreRejected(_ version: Int) throws {
    var parameters = Self.versionOneParameters()
    parameters["algorithm"] = "oklch"
    let data = try Self.documentData(parameters: parameters, version: version)

    #expect(
      throws: ParametricDocumentCodecError.unsupportedSchemaVersion(
        ColorMixerFeature.featureTypeKey, version: version
      )
    ) {
      try ParametricDocumentCodec().decode(data)
    }
  }

  @Test(arguments: ["hue", "saturation", "luminance"])
  func decodingRejectsOutOfRangeAxes(_ axis: String) throws {
    let data = try Self.encodedFeature(replacingAxis: axis, with: 101.0)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(ColorMixerFeature.self, from: data)
    }
  }

  @Test(arguments: ["NaN", "Infinity", "-Infinity"])
  func decodingRejectsNonfiniteAxes(_ value: String) throws {
    let data = try Self.encodedFeature(replacingAxis: "hue", with: value)
    let decoder = JSONDecoder()
    decoder.nonConformingFloatDecodingStrategy = .convertFromString(
      positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
    )
    #expect(throws: DecodingError.self) {
      try decoder.decode(ColorMixerFeature.self, from: data)
    }
  }

  @Test
  func decodingRequiresEveryNamedBand() throws {
    let feature = ColorMixerFeature(adjustment: .neutral)
    let data = try JSONEncoder().encode(feature)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    try #require(object["algorithm"] as? String == "oklch")
    var adjustment = try #require(object["adjustment"] as? [String: Any])
    adjustment.removeValue(forKey: "magenta")
    object["adjustment"] = adjustment
    let incomplete = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(ColorMixerFeature.self, from: incomplete)
    }
  }

  private static func encodedFeature(replacingAxis axis: String, with value: Any) throws -> Data {
    let feature = ColorMixerFeature(adjustment: .neutral)
    let data = try JSONEncoder().encode(feature)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    try #require(object["algorithm"] as? String == "oklch")
    var adjustment = try #require(object["adjustment"] as? [String: Any])
    var red = try #require(adjustment["red"] as? [String: Any])
    red[axis] = value
    adjustment["red"] = red
    object["adjustment"] = adjustment
    return try JSONSerialization.data(withJSONObject: object)
  }

  /// The schema-v1 authored-value payload predating algorithm selection.
  private static func versionOneParameters() -> [String: Any] {
    [
      "id": ["rawValue": "legacy-mixer"],
      "adjustment": [
        "red": ["hue": 23, "saturation": -24, "luminance": 17],
        "orange": ["hue": 0, "saturation": 0, "luminance": 0],
        "yellow": ["hue": 0, "saturation": 0, "luminance": 0],
        "green": ["hue": 0, "saturation": 0, "luminance": 0],
        "aqua": ["hue": 0, "saturation": 0, "luminance": 0],
        "blue": ["hue": 0, "saturation": 0, "luminance": 0],
        "purple": ["hue": 0, "saturation": 0, "luminance": 0],
        "magenta": ["hue": 0, "saturation": 5, "luminance": -8],
      ],
    ]
  }

  private static func documentData(parameters: [String: Any], version: Int) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "formatVersion": 1,
      "mainTree": [
        "features": [
          [
            "kind": "effect",
            "feature": [
              "type": "brightroom.effect.color-mixer",
              "v": version,
              "params": parameters,
            ],
          ]
        ]
      ],
    ])
  }

  private static func firstEffectEnvelope(in data: Data) throws -> [String: Any] {
    let document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let tree = try #require(document["mainTree"] as? [String: Any])
    let features = try #require(tree["features"] as? [[String: Any]])
    let first = try #require(features.first)
    return try #require(first["feature"] as? [String: Any])
  }

  enum InvalidAlgorithm: CaseIterable {
    case missing
    case null
    case unknown
  }

}
