import Foundation
import Testing

// Public API only: this file plays the role of a host app that owns its
// storage format. It must not need `@testable` access.
import BrightroomParametric

/// Shows how a host app saves and restores parametric edits with its own model.
///
/// Brightroom does not define a storage format. The app below decides which
/// feature types it supports, references LUTs by its own asset IDs, validates
/// stored values through the public reconstruction APIs, and owns versioning.
@Suite("App-owned persistence example")
struct AppOwnedPersistenceExampleTests {

  @Test
  func currentEditRoundTripsThroughAppStorage() throws {
    var curves = ToneCurveEditorValue()
    let insertedPointID = curves.y.insertPoint(input: 0.4, output: 0.55)
    let pointID = try #require(insertedPointID)
    let linkedPointID = curves.red.insertPoint(id: pointID, input: 0.45, output: 0.65)
    _ = try #require(linkedPointID)
    curves.y.movePoint(id: .blackEndpoint, input: 0.12, output: 0.08)

    var mixer = ColorMixerAdjustment.neutral
    mixer.red.hue = 23
    mixer.magenta.luminance = -8

    var lut = try Self.loadLUT(assetID: "film-01")
    lut.id = FeatureID(rawValue: "look-lut")
    lut.amount = 0.6

    let edit = EffectPipeline(effects: [
      ExposureFeature(id: FeatureID(rawValue: "look-exposure"), value: 0.2),
      ToneCurveFeature(id: FeatureID(rawValue: "look-curve"), value: curves),
      ColorMixerFeature(id: FeatureID(rawValue: "look-mixer"), adjustment: mixer),
      lut,
    ])

    let data = try JSONEncoder().encode(try StoredLook(edit))
    let restored = try JSONDecoder().decode(StoredLook.self, from: data)
      .makePipeline(loadLUT: Self.loadLUT(assetID:))

    #expect(restored == edit)
    // Feature equality compares rendered values; editing state such as point
    // identities must be checked directly.
    let restoredCurve = try #require(restored.first(of: ToneCurveFeature.self))
    #expect(restoredCurve.value == curves)
    #expect(restoredCurve.value.red.point(id: pointID) != nil)
    let restoredMixer = try #require(restored.first(of: ColorMixerFeature.self))
    #expect(restoredMixer.adjustment == mixer)
    #expect(restoredMixer.algorithm == .oklch)
    let restoredLUT = try #require(restored.first(of: ColorCubeFeature.self))
    #expect(restoredLUT.amount == 0.6)
    #expect(restoredLUT.cubeData == lut.cubeData)
  }

  @Test
  func featuresOutsideTheAppModelAreReportedWhenSaving() {
    let edit = EffectPipeline(effects: [VignetteFeature(value: 0.3)])

    #expect(throws: StoredLook.Error.unsupportedFeature("VignetteFeature")) {
      try StoredLook(edit)
    }
  }

  @Test
  func invalidStoredValuesAreRejectedWhenRestoring() throws {
    var curves = ToneCurveEditorValue()
    let insertedPointID = curves.y.insertPoint(input: 0.4, output: 0.55)
    _ = try #require(insertedPointID)
    let stored = try StoredLook(
      EffectPipeline(effects: [
        ToneCurveFeature(value: curves),
        ColorMixerFeature(adjustment: .init(red: .init(hue: 10))),
      ])
    )

    var futureCurve = stored
    guard case .toneCurve(let id, _, let channels) = futureCurve.effects[0] else {
      Issue.record("Expected the stored tone curve first.")
      return
    }
    futureCurve.effects[0] = .toneCurve(
      id: id,
      semanticVersion: ToneCurveFeature.semanticVersion + 1,
      channels: channels
    )
    #expect(throws: StoredLook.Error.unsupportedToneCurveSemantics(ToneCurveFeature.semanticVersion + 1)) {
      try futureCurve.makePipeline(loadLUT: Self.loadLUT(assetID:))
    }

    var reorderedCurve = stored
    var reorderedChannels = channels
    reorderedChannels.y.reverse()
    reorderedCurve.effects[0] = .toneCurve(
      id: id,
      semanticVersion: ToneCurveFeature.semanticVersion,
      channels: reorderedChannels
    )
    #expect(throws: StoredLook.Error.invalidToneCurve) {
      try reorderedCurve.makePipeline(loadLUT: Self.loadLUT(assetID:))
    }

    guard case .colorMixer(let mixerID, _, var bands) = stored.effects[1] else {
      Issue.record("Expected the stored Color Mixer second.")
      return
    }
    var unknownAlgorithm = stored
    unknownAlgorithm.effects[1] = .colorMixer(id: mixerID, algorithm: "future", bands: bands)
    #expect(throws: StoredLook.Error.unknownColorMixerAlgorithm("future")) {
      try unknownAlgorithm.makePipeline(loadLUT: Self.loadLUT(assetID:))
    }

    bands[0].hue = 101
    var outOfRangeBand = stored
    outOfRangeBand.effects[1] = .colorMixer(id: mixerID, algorithm: "oklch", bands: bands)
    #expect(throws: StoredLook.Error.invalidColorMixerBand(bands[0].band)) {
      try outOfRangeBand.makePipeline(loadLUT: Self.loadLUT(assetID:))
    }
  }

  /// Stands in for the app's LUT catalog: an inverting 2×2×2 cube.
  private static func loadLUT(assetID: String) throws -> ColorCubeFeature {
    let dimension = 2
    var values: [Float] = []
    for blue in 0..<dimension {
      for green in 0..<dimension {
        for red in 0..<dimension {
          values += [1 - Float(red), 1 - Float(green), 1 - Float(blue), 1]
        }
      }
    }
    return ColorCubeFeature(
      name: "Film 01",
      identifier: assetID,
      dimension: dimension,
      cubeData: values.withUnsafeBufferPointer { Data(buffer: $0) }
    )
  }
}

// MARK: - The app's storage model

/// The app's saved form of one look: an ordered list of the effects it supports.
private struct StoredLook: Codable, Equatable {

  enum Error: Swift.Error, Equatable {
    case unsupportedFeature(String)
    case unsupportedToneCurveSemantics(Int)
    case invalidToneCurve
    case unknownColorMixerAlgorithm(String)
    case invalidColorMixerBand(String)
    case missingColorMixerBands
  }

  /// The app's own format version; migration of older looks is the app's job.
  var version = 1
  var effects: [StoredEffect]

  init(_ pipeline: EffectPipeline) throws {
    effects = try pipeline.effects.map(StoredEffect.init)
  }

  func makePipeline(
    loadLUT: (_ assetID: String) throws -> ColorCubeFeature
  ) throws -> EffectPipeline {
    EffectPipeline(effects: try effects.map { try $0.makeFeature(loadLUT: loadLUT) })
  }
}

private enum StoredEffect: Codable, Equatable {
  case exposure(id: String, isEnabled: Bool, value: Double)
  case toneCurve(id: String, semanticVersion: Int, channels: StoredToneCurve)
  case colorMixer(id: String, algorithm: String, bands: [StoredBand])
  /// LUT data stays in the app's asset catalog; only the reference is stored.
  case lut(id: String, isEnabled: Bool, assetID: String, amount: Double)

  init(_ effect: any ImageEffectFeatureType) throws {
    switch effect {
    case let exposure as ExposureFeature:
      self = .exposure(id: exposure.id.rawValue, isEnabled: exposure.isEnabled, value: exposure.value)
    case let curve as ToneCurveFeature:
      self = .toneCurve(
        id: curve.id.rawValue,
        semanticVersion: ToneCurveFeature.semanticVersion,
        channels: StoredToneCurve(curve.value)
      )
    case let mixer as ColorMixerFeature:
      self = .colorMixer(
        id: mixer.id.rawValue,
        algorithm: mixer.algorithm.rawValue,
        bands: ColorMixerBand.allCases.map { StoredBand(band: $0, value: mixer.adjustment[$0]) }
      )
    case let lut as ColorCubeFeature:
      self = .lut(id: lut.id.rawValue, isEnabled: lut.isEnabled, assetID: lut.identifier, amount: lut.amount)
    default:
      throw StoredLook.Error.unsupportedFeature(String(describing: type(of: effect)))
    }
  }

  func makeFeature(
    loadLUT: (_ assetID: String) throws -> ColorCubeFeature
  ) throws -> any ImageEffectFeatureType {
    switch self {
    case .exposure(let id, let isEnabled, let value):
      return ExposureFeature(id: FeatureID(rawValue: id), isEnabled: isEnabled, value: value)
    case .toneCurve(let id, let semanticVersion, let channels):
      guard semanticVersion == ToneCurveFeature.semanticVersion else {
        throw StoredLook.Error.unsupportedToneCurveSemantics(semanticVersion)
      }
      return ToneCurveFeature(id: FeatureID(rawValue: id), value: try channels.makeValue())
    case .colorMixer(let id, let identifier, let bands):
      guard let algorithm = ColorMixerFeature.Algorithm(rawValue: identifier) else {
        throw StoredLook.Error.unknownColorMixerAlgorithm(identifier)
      }
      var adjustment = ColorMixerAdjustment.neutral
      var restoredBands = Set<ColorMixerBand>()
      for stored in bands {
        let (band, value) = try stored.makeAdjustment()
        adjustment[band] = value
        restoredBands.insert(band)
      }
      guard restoredBands.count == ColorMixerBand.allCases.count, bands.count == restoredBands.count
      else {
        throw StoredLook.Error.missingColorMixerBands
      }
      return ColorMixerFeature(id: FeatureID(rawValue: id), adjustment: adjustment, algorithm: algorithm)
    case .lut(let id, let isEnabled, let assetID, let amount):
      var lut = try loadLUT(assetID)
      lut.id = FeatureID(rawValue: id)
      lut.isEnabled = isEnabled
      lut.amount = amount
      return lut
    }
  }
}

private struct StoredToneCurve: Codable, Equatable {

  struct Point: Codable, Equatable {
    enum Identity: Codable, Equatable {
      case blackEndpoint
      case whiteEndpoint
      case interior(UUID)
    }

    var id: Identity
    var input: Double
    var output: Double
  }

  var y: [Point]
  var red: [Point]
  var green: [Point]
  var blue: [Point]

  init(_ value: ToneCurveEditorValue) {
    y = Self.points(value.y)
    red = Self.points(value.red)
    green = Self.points(value.green)
    blue = Self.points(value.blue)
  }

  func makeValue() throws -> ToneCurveEditorValue {
    ToneCurveEditorValue(
      y: try Self.curve(y),
      red: try Self.curve(red),
      green: try Self.curve(green),
      blue: try Self.curve(blue)
    )
  }

  private static func points(_ curve: ToneCurve) -> [Point] {
    curve.points.map { point in
      let id: Point.Identity
      switch point.id {
      case .blackEndpoint: id = .blackEndpoint
      case .whiteEndpoint: id = .whiteEndpoint
      case .interior(let uuid): id = .interior(uuid)
      }
      return Point(id: id, input: point.input, output: point.output)
    }
  }

  private static func curve(_ points: [Point]) throws -> ToneCurve {
    let restored = points.map { point in
      let id: ToneCurve.Point.ID
      switch point.id {
      case .blackEndpoint: id = .blackEndpoint
      case .whiteEndpoint: id = .whiteEndpoint
      case .interior(let uuid): id = .interior(uuid)
      }
      return ToneCurve.Point(id: id, input: point.input, output: point.output)
    }
    // The validating initializer rejects anything the editor could not have
    // produced, instead of repairing it.
    guard let curve = ToneCurve(validating: restored) else {
      throw StoredLook.Error.invalidToneCurve
    }
    return curve
  }
}

private struct StoredBand: Codable, Equatable {
  /// The app's own band names, independent of the library's raw values.
  var band: String
  var hue: Double
  var saturation: Double
  var luminance: Double

  init(band: ColorMixerBand, value: ColorMixerBandAdjustment) {
    self.band = Self.name(of: band)
    hue = value.hue
    saturation = value.saturation
    luminance = value.luminance
  }

  func makeAdjustment() throws -> (ColorMixerBand, ColorMixerBandAdjustment) {
    guard let band = ColorMixerBand.allCases.first(where: { Self.name(of: $0) == self.band }),
      let value = ColorMixerBandAdjustment(
        validatingHue: hue,
        saturation: saturation,
        luminance: luminance
      )
    else {
      throw StoredLook.Error.invalidColorMixerBand(band)
    }
    return (band, value)
  }

  private static func name(of band: ColorMixerBand) -> String {
    switch band {
    case .red: "red"
    case .orange: "orange"
    case .yellow: "yellow"
    case .green: "green"
    case .aqua: "aqua"
    case .blue: "blue"
    case .purple: "purple"
    case .magenta: "magenta"
    }
  }
}
