//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import Foundation

/// Immutable sampled parameters consumed by the Tone Curve renderer.
///
/// The table stores normalized curve outputs rather than scene-linear values.
/// The GPU therefore uses the same stop shaper for values inside and outside
/// the authored interval, while boundary values and effective derivatives
/// provide explicit behavior without sampling beyond the table extent.
nonisolated struct ToneCurveRenderPlan: Equatable, Sendable {

  /// The number of uniformly spaced samples compiled for every channel.
  static let sampleCount = 4_096

  /// Coordinates whose equality describes render output, excluding UI point IDs.
  let identity: ToneCurveRenderIdentity

  /// Two interleaved float tables: Y/Red and Green/Blue.
  let sampleTable: ToneCurveSampleTable

  /// Outputs at normalized Input 0 and 1 in Y, Red, Green, Blue order.
  let lowerOutputs: SIMD4<Float>
  let upperOutputs: SIMD4<Float>

  /// Effective boundary derivatives in Y, Red, Green, Blue order.
  ///
  /// A zero derivative preserves an inward endpoint's clipping plateau beyond
  /// the sampled domain. Endpoints at Input 0 or 1 retain their spline tangent.
  let lowerTangents: SIMD4<Float>
  let upperTangents: SIMD4<Float>

  /// One for a channel that changes pixels, zero for an identity channel.
  let activeChannels: SIMD4<Float>

  /// Compiles four authored curves, or returns `nil` when all are identities.
  init?(value: ToneCurveEditorValue) {
    guard let identity = ToneCurveRenderIdentity(activeValue: value) else {
      return nil
    }

    let curves = [value.y, value.red, value.green, value.blue]
    let evaluators = curves.map(ToneCurveEvaluator.init(curve:))
    let active = curves.map { !$0.isIdentityMapping }

    self.identity = identity
    activeChannels = SIMD4(
      active[0] ? 1 : 0,
      active[1] ? 1 : 0,
      active[2] ? 1 : 0,
      active[3] ? 1 : 0
    )

    // Moved endpoints can sit inside 0...1. The table includes their flat
    // plateaus, so out-of-domain evaluation continues from the evaluated table
    // boundaries using the evaluator's effective derivative.
    let lower = evaluators.map { $0.output(at: 0) }
    let upper = evaluators.map { $0.output(at: 1) }
    lowerOutputs = SIMD4(
      Float(lower[0]),
      Float(lower[1]),
      Float(lower[2]),
      Float(lower[3])
    )
    upperOutputs = SIMD4(
      Float(upper[0]),
      Float(upper[1]),
      Float(upper[2]),
      Float(upper[3])
    )
    lowerTangents = SIMD4(
      Float(evaluators[0].lowerExtrapolationTangent),
      Float(evaluators[1].lowerExtrapolationTangent),
      Float(evaluators[2].lowerExtrapolationTangent),
      Float(evaluators[3].lowerExtrapolationTangent)
    )
    upperTangents = SIMD4(
      Float(evaluators[0].upperExtrapolationTangent),
      Float(evaluators[1].upperExtrapolationTangent),
      Float(evaluators[2].upperExtrapolationTangent),
      Float(evaluators[3].upperExtrapolationTangent)
    )
    sampleTable = ToneCurveSampleTable(evaluators: evaluators)
  }

  /// Evaluates the exact table interpolation that the Metal kernel consumes.
  func normalizedOutput(
    for channel: ToneCurveChannel,
    input: Double
  ) -> Double {
    let channelIndex = Self.channelIndex(channel)
    if input < 0 {
      return Double(lowerOutputs[channelIndex])
        + Double(lowerTangents[channelIndex]) * input
    }
    if input > 1 {
      return Double(upperOutputs[channelIndex])
        + Double(upperTangents[channelIndex]) * (input - 1)
    }

    let position = input * Double(Self.sampleCount - 1)
    let lowerIndex = Int(position.rounded(.down))
    let upperIndex = min(lowerIndex + 1, Self.sampleCount - 1)
    let progress = position - Double(lowerIndex)
    let lowerValue = Double(sampleTable[channel, lowerIndex])
    let upperValue = Double(sampleTable[channel, upperIndex])
    return lowerValue + (upperValue - lowerValue) * progress
  }

  /// Whether one channel requires a scene-linear shaper round trip.
  func isChannelActive(_ channel: ToneCurveChannel) -> Bool {
    activeChannels[Self.channelIndex(channel)] > 0.5
  }

  private static func channelIndex(_ channel: ToneCurveChannel) -> Int {
    switch channel {
    case .y:
      0
    case .red:
      1
    case .green:
      2
    case .blue:
      3
    }
  }
}

/// Render-significant curve coordinates with UI identity deliberately removed.
public nonisolated struct ToneCurveRenderIdentity: Hashable, Sendable {

  /// One normalized input/output pair whose point UUID has been discarded.
  struct Coordinate: Hashable, Sendable {
    let input: Double
    let output: Double
  }

  /// Increment when the shaper, channel composition, or table interpretation changes.
  let semanticVersion = ToneCurveFeature.semanticVersion
  let y: [Coordinate]
  let red: [Coordinate]
  let green: [Coordinate]
  let blue: [Coordinate]

  /// Creates a cache identity from pixel-affecting coordinates only.
  public init(value: ToneCurveEditorValue) {
    y = Self.activeCoordinates(value.y)
    red = Self.activeCoordinates(value.red)
    green = Self.activeCoordinates(value.green)
    blue = Self.activeCoordinates(value.blue)
  }

  /// Creates an identity only when at least one channel changes rendered pixels.
  ///
  /// This check copies only authored coordinates. Cache and lifecycle code can
  /// therefore identify neutral work without compiling the 4,096-sample table.
  public init?(activeValue value: ToneCurveEditorValue) {
    self.init(value: value)
    guard [y, red, green, blue].contains(where: { !$0.isEmpty }) else {
      return nil
    }
  }

  private static func coordinates(_ curve: ToneCurve) -> [Coordinate] {
    curve.points.map { point in
      Coordinate(input: point.input, output: point.output)
    }
  }

  /// Omits authored structure that cannot change this channel's pixels.
  private static func activeCoordinates(_ curve: ToneCurve) -> [Coordinate] {
    curve.isIdentityMapping ? [] : coordinates(curve)
  }
}

/// Two-channel Float32 samples stored in Core Image's `.RGf` memory order.
nonisolated struct ToneCurveSampleTable: Equatable, Sendable {

  let yRed: [SIMD2<Float>]
  let greenBlue: [SIMD2<Float>]

  init(evaluators: [ToneCurveEvaluator]) {
    precondition(evaluators.count == 4)

    var yRed: [SIMD2<Float>] = []
    var greenBlue: [SIMD2<Float>] = []
    yRed.reserveCapacity(ToneCurveRenderPlan.sampleCount)
    greenBlue.reserveCapacity(ToneCurveRenderPlan.sampleCount)

    for index in 0..<ToneCurveRenderPlan.sampleCount {
      let input = Double(index) / Double(ToneCurveRenderPlan.sampleCount - 1)
      yRed.append(
        SIMD2(
          Float(evaluators[0].output(at: input)),
          Float(evaluators[1].output(at: input))
        )
      )
      greenBlue.append(
        SIMD2(
          Float(evaluators[2].output(at: input)),
          Float(evaluators[3].output(at: input))
        )
      )
    }

    self.yRed = yRed
    self.greenBlue = greenBlue
  }

  subscript(_ channel: ToneCurveChannel, _ index: Int) -> Float {
    switch channel {
    case .y:
      yRed[index].x
    case .red:
      yRed[index].y
    case .green:
      greenBlue[index].x
    case .blue:
      greenBlue[index].y
    }
  }

  /// Packs Y/Red followed by Green/Blue into one 8,192-pixel `.RGf` row.
  func combinedData() -> Data {
    var samples = yRed
    samples.append(contentsOf: greenBlue)
    return samples.withUnsafeBufferPointer { buffer in
      Data(buffer: buffer)
    }
  }
}

/// Independent CPU reference for the YRGB processing contract.
///
/// This path evaluates the canonical spline directly and never calls the
/// sampled-table implementation used by Metal. Tests use it as the source of
/// truth for table approximation and GPU parity.
nonisolated enum ToneCurveReferenceProcessor {

  private static let displayP3Luminance = SIMD3(
    0.228_974_564_1,
    0.691_738_521_8,
    0.079_286_914_1
  )

  /// Processes one premultiplied extended-linear Display-P3 pixel.
  static func processPremultiplied(
    _ pixel: SIMD4<Double>,
    value: ToneCurveEditorValue
  ) -> SIMD4<Double> {
    let hasActiveChannel = [value.y, value.red, value.green, value.blue]
      .contains(where: Self.isActive)
    guard hasActiveChannel, pixel.w > 0 else {
      return pixel
    }

    let inputRGB = SIMD3(pixel.x, pixel.y, pixel.z) / pixel.w
    let inputY = dot(inputRGB, displayP3Luminance)
    var rgb = inputRGB
    let red = ToneCurveEvaluator(curve: value.red)
    let green = ToneCurveEvaluator(curve: value.green)
    let blue = ToneCurveEvaluator(curve: value.blue)
    let y = ToneCurveEvaluator(curve: value.y)

    if Self.isActive(value.red) {
      rgb.x = apply(red, to: rgb.x)
    }
    if Self.isActive(value.green) {
      rgb.y = apply(green, to: rgb.y)
    }
    if Self.isActive(value.blue) {
      rgb.z = apply(blue, to: rgb.z)
    }
    let curvedY = dot(rgb, displayP3Luminance)
    let outputY = Self.isActive(value.y) ? apply(y, to: inputY) : inputY
    rgb += SIMD3(repeating: outputY - curvedY)

    return SIMD4(rgb * pixel.w, pixel.w)
  }

  /// Processes one pixel through the sampled Float32 plan used by Metal.
  static func processPremultiplied(
    _ pixel: SIMD4<Double>,
    plan: ToneCurveRenderPlan
  ) -> SIMD4<Double> {
    guard pixel.w > 0 else { return pixel }

    let inputRGB = SIMD3(pixel.x, pixel.y, pixel.z) / pixel.w
    let inputY = dot(inputRGB, displayP3Luminance)
    var rgb = inputRGB
    if plan.isChannelActive(.red) {
      rgb.x = apply(.red, to: rgb.x, plan: plan)
    }
    if plan.isChannelActive(.green) {
      rgb.y = apply(.green, to: rgb.y, plan: plan)
    }
    if plan.isChannelActive(.blue) {
      rgb.z = apply(.blue, to: rgb.z, plan: plan)
    }
    let curvedY = dot(rgb, displayP3Luminance)
    let outputY =
      plan.isChannelActive(.y)
      ? apply(.y, to: inputY, plan: plan)
      : inputY
    rgb += SIMD3(repeating: outputY - curvedY)
    return SIMD4(rgb * pixel.w, pixel.w)
  }

  private static func apply(
    _ evaluator: ToneCurveEvaluator,
    to linear: Double
  ) -> Double {
    let input = ToneCurveSceneLinearShaper.normalizedCurveCoordinate(
      for: linear
    )
    return ToneCurveSceneLinearShaper.linearValue(
      forNormalizedCurveCoordinate: evaluator.output(at: input)
    )
  }

  private static func apply(
    _ channel: ToneCurveChannel,
    to linear: Double,
    plan: ToneCurveRenderPlan
  ) -> Double {
    let input = ToneCurveSceneLinearShaper.normalizedCurveCoordinate(
      for: linear
    )
    return ToneCurveSceneLinearShaper.linearValue(
      forNormalizedCurveCoordinate: plan.normalizedOutput(
        for: channel,
        input: input
      )
    )
  }

  private static func isActive(_ curve: ToneCurve) -> Bool {
    !curve.isIdentityMapping
  }

  private static func dot(
    _ lhs: SIMD3<Double>,
    _ rhs: SIMD3<Double>
  ) -> Double {
    lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
  }
}
