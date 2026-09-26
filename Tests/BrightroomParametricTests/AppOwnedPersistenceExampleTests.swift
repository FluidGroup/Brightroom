import CoreImage
import Foundation
import Testing

// Public API only: this file plays the role of a host app that owns its
// storage format. It must not need `@testable` access.
import BrightroomParametric

/// Shows how a host app saves and restores parametric edits with its own model.
///
/// Brightroom does not define a storage format. The app below composes its
/// own document (`Look`) from the features it supports, references LUTs by its
/// own asset IDs, validates stored values through the public reconstruction
/// APIs, and owns versioning. A member that is present is enabled; features
/// carry no identity, so nothing else needs storing.
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
    lut.amount = 0.6

    let look = Look(
      exposure: ExposureFeature(value: 0.2),
      toneCurve: ToneCurveFeature(value: curves),
      colorMixer: ColorMixerFeature(adjustment: mixer),
      lut: lut,
      extras: [AnyImageEffect(FadeFeature(intensity: 0.1))]
    )

    let data = try JSONEncoder().encode(try StoredLook(look))
    let restored = try JSONDecoder().decode(StoredLook.self, from: data)
      .makeLook(loadLUT: Self.loadLUT(assetID:))

    #expect(restored == look)
    // Tone Curve and Color Mixer equality compares rendered values; editing
    // state such as point identities must be checked directly.
    #expect(restored.toneCurve?.value == curves)
    #expect(restored.toneCurve?.value.red.point(id: pointID) != nil)
    #expect(restored.colorMixer?.adjustment == mixer)
    #expect(restored.colorMixer?.algorithm == .oklch)
    #expect(restored.lut?.amount == 0.6)
    #expect(restored.lut?.cubeData == lut.cubeData)

    // The restored look renders the same pixels.
    let source = CIImage(color: CIColor(red: 0.62, green: 0.34, blue: 0.21))
      .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
    let renderer = ParametricImageRenderer()
    #expect(
      try Self.bitmap(renderer.makeImage(from: source, document: restored))
        == Self.bitmap(renderer.makeImage(from: source, document: look))
    )

    // An absent member stays absent.
    var partial = look
    partial.toneCurve = nil
    partial.lut = nil
    let restoredPartial = try StoredLook(partial).makeLook(loadLUT: Self.loadLUT(assetID:))
    #expect(restoredPartial == partial)
  }

  @Test
  func featuresOutsideTheAppModelAreReportedWhenSaving() {
    let look = Look(extras: [AnyImageEffect(VignetteFeature(value: 0.3))])

    #expect(throws: StoredLook.Error.unsupportedFeature("VignetteFeature")) {
      try StoredLook(look)
    }
  }

  @Test
  func invalidStoredValuesAreRejectedWhenRestoring() throws {
    var curves = ToneCurveEditorValue()
    let insertedPointID = curves.y.insertPoint(input: 0.4, output: 0.55)
    _ = try #require(insertedPointID)
    let stored = try StoredLook(
      Look(
        toneCurve: ToneCurveFeature(value: curves),
        colorMixer: ColorMixerFeature(adjustment: .init(red: .init(hue: 10)))
      )
    )
    let storedCurve = try #require(stored.toneCurve)
    let storedMixer = try #require(stored.colorMixer)

    var futureCurve = stored
    futureCurve.toneCurve?.semanticVersion = ToneCurveFeature.semanticVersion + 1
    #expect(throws: StoredLook.Error.unsupportedToneCurveSemantics(ToneCurveFeature.semanticVersion + 1)) {
      try futureCurve.makeLook(loadLUT: Self.loadLUT(assetID:))
    }

    var reorderedCurve = stored
    var reorderedChannels = storedCurve.channels
    reorderedChannels.y.reverse()
    reorderedCurve.toneCurve?.channels = reorderedChannels
    #expect(throws: StoredLook.Error.invalidToneCurve) {
      try reorderedCurve.makeLook(loadLUT: Self.loadLUT(assetID:))
    }

    var unknownAlgorithm = stored
    unknownAlgorithm.colorMixer?.algorithm = "future"
    #expect(throws: StoredLook.Error.unknownColorMixerAlgorithm("future")) {
      try unknownAlgorithm.makeLook(loadLUT: Self.loadLUT(assetID:))
    }

    var bands = storedMixer.bands
    bands[0].hue = 101
    var outOfRangeBand = stored
    outOfRangeBand.colorMixer?.bands = bands
    #expect(throws: StoredLook.Error.invalidColorMixerBand(bands[0].band)) {
      try outOfRangeBand.makeLook(loadLUT: Self.loadLUT(assetID:))
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
    let lut = ColorCubeFeature(
      name: "Film 01",
      identifier: assetID,
      dimension: dimension,
      cubeData: values.withUnsafeBufferPointer { Data(buffer: $0) }
    )
    // Reject a catalog entry that does not match its dimension when loading,
    // not at the first render.
    try lut.validate()
    return lut
  }

  private static func bitmap(_ image: CIImage) -> [Float] {
    let width = Int(image.extent.width)
    let height = Int(image.extent.height)
    var components = [Float](repeating: 0, count: width * height * 4)
    components.withUnsafeMutableBytes { bytes in
      CIContext().render(
        image,
        toBitmap: bytes.baseAddress!,
        rowBytes: width * 4 * MemoryLayout<Float>.size,
        bounds: image.extent,
        format: .RGBAf,
        colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
      )
    }
    return components
  }
}

// MARK: - The app's document

/// The app's look: the effects it supports, in a fixed order, plus a
/// data-driven list of extras.
private struct Look: ImageEffect, Equatable {

  var exposure: ExposureFeature?
  var toneCurve: ToneCurveFeature?
  var colorMixer: ColorMixerFeature?
  var lut: ColorCubeFeature?
  var extras: [AnyImageEffect] = []

  var body: some ImageEffect {
    exposure
    toneCurve
    colorMixer
    lut
    extras
  }
}

// MARK: - The app's storage model

/// The app's saved form of one look. A present field is an enabled member.
private struct StoredLook: Codable, Equatable {

  enum Error: Swift.Error, Equatable {
    case unsupportedFeature(String)
    case unsupportedToneCurveSemantics(Int)
    case invalidToneCurve
    case unknownColorMixerAlgorithm(String)
    case invalidColorMixerBand(String)
    case missingColorMixerBands
  }

  struct StoredCurve: Codable, Equatable {
    var semanticVersion: Int
    var channels: StoredToneCurve
  }

  struct StoredMixer: Codable, Equatable {
    var algorithm: String
    var bands: [StoredBand]
  }

  /// LUT data stays in the app's asset catalog; only the reference is stored.
  struct StoredLUT: Codable, Equatable {
    var assetID: String
    var amount: Double
  }

  /// The app's own format version; migration of older looks is the app's job.
  var version = 1
  var exposure: Double?
  var toneCurve: StoredCurve?
  var colorMixer: StoredMixer?
  var lut: StoredLUT?
  var extras: [StoredEffect]

  init(_ look: Look) throws {
    exposure = look.exposure?.value
    toneCurve = look.toneCurve.map {
      StoredCurve(semanticVersion: ToneCurveFeature.semanticVersion, channels: StoredToneCurve($0.value))
    }
    colorMixer = look.colorMixer.map { mixer in
      StoredMixer(
        algorithm: mixer.algorithm.rawValue,
        bands: ColorMixerBand.allCases.map { StoredBand(band: $0, value: mixer.adjustment[$0]) }
      )
    }
    lut = look.lut.map { StoredLUT(assetID: $0.identifier, amount: $0.amount) }
    extras = try look.extras.map { try StoredEffect($0.base) }
  }

  func makeLook(
    loadLUT: (_ assetID: String) throws -> ColorCubeFeature
  ) throws -> Look {
    var look = Look()
    look.exposure = exposure.map { ExposureFeature(value: $0) }
    if let toneCurve {
      guard toneCurve.semanticVersion == ToneCurveFeature.semanticVersion else {
        throw Error.unsupportedToneCurveSemantics(toneCurve.semanticVersion)
      }
      look.toneCurve = ToneCurveFeature(value: try toneCurve.channels.makeValue())
    }
    if let colorMixer {
      look.colorMixer = try colorMixer.makeFeature()
    }
    if let lut {
      var feature = try loadLUT(lut.assetID)
      feature.amount = lut.amount
      look.lut = feature
    }
    look.extras = extras.map { $0.makeEffect() }
    return look
  }
}

extension StoredLook.StoredMixer {

  func makeFeature() throws -> ColorMixerFeature {
    guard let algorithm = ColorMixerFeature.Algorithm(rawValue: algorithm) else {
      throw StoredLook.Error.unknownColorMixerAlgorithm(algorithm)
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
    return ColorMixerFeature(adjustment: adjustment, algorithm: algorithm)
  }
}

/// A data-driven extra: the app lists the effect types it can store and
/// reaches the typed value through `AnyImageEffect.base`.
private enum StoredEffect: Codable, Equatable {
  case fade(intensity: Double)
  case saturation(value: Double)

  init(_ effect: any ImageEffect) throws {
    switch effect {
    case let fade as FadeFeature:
      self = .fade(intensity: fade.intensity)
    case let saturation as SaturationFeature:
      self = .saturation(value: saturation.value)
    default:
      throw StoredLook.Error.unsupportedFeature(String(describing: type(of: effect)))
    }
  }

  func makeEffect() -> AnyImageEffect {
    switch self {
    case .fade(let intensity):
      AnyImageEffect(FadeFeature(intensity: intensity))
    case .saturation(let value):
      AnyImageEffect(SaturationFeature(value: value))
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
