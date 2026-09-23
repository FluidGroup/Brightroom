//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import Foundation

/// Immutable Float32 parameters shared by the CPU reference and Metal kernel.
nonisolated struct ColorMixerRenderPlan: Equatable, Sendable {

  /// Increment when band anchors, interpolation, or color transforms change.
  static let semanticVersion = 1

  /// Selects how the normalized band corrections are evaluated.
  let algorithm: ColorMixerFeature.Algorithm

  let hue0: SIMD4<Float>
  let hue1: SIMD4<Float>
  let saturation0: SIMD4<Float>
  let saturation1: SIMD4<Float>
  let luminance0: SIMD4<Float>
  let luminance1: SIMD4<Float>

  /// Compiles normalized corrections, or returns `nil` for an exact bypass.
  init?(
    adjustment: ColorMixerAdjustment,
    algorithm: ColorMixerFeature.Algorithm = .oklch
  ) {
    guard adjustment.isNeutral == false else { return nil }
    self.algorithm = algorithm
    let values = ColorMixerBand.allCases.map { adjustment[$0] }
    hue0 = Self.pack(values[0].hue, values[1].hue, values[2].hue, values[3].hue)
    hue1 = Self.pack(values[4].hue, values[5].hue, values[6].hue, values[7].hue)
    saturation0 = Self.pack(
      values[0].saturation, values[1].saturation, values[2].saturation, values[3].saturation)
    saturation1 = Self.pack(
      values[4].saturation, values[5].saturation, values[6].saturation, values[7].saturation)
    luminance0 = Self.pack(
      values[0].luminance, values[1].luminance, values[2].luminance, values[3].luminance)
    luminance1 = Self.pack(
      values[4].luminance, values[5].luminance, values[6].luminance, values[7].luminance)
  }

  func hue(at index: Int) -> Double { Double(component(index, hue0, hue1)) }
  func saturation(at index: Int) -> Double { Double(component(index, saturation0, saturation1)) }
  func luminance(at index: Int) -> Double { Double(component(index, luminance0, luminance1)) }

  private func component(_ index: Int, _ first: SIMD4<Float>, _ second: SIMD4<Float>) -> Float {
    index < 4 ? first[index] : second[index - 4]
  }

  private static func pack(_ x: Double, _ y: Double, _ z: Double, _ w: Double) -> SIMD4<Float> {
    SIMD4(Float(x / 100), Float(y / 100), Float(z / 100), Float(w / 100))
  }
}

/// Render-significant Float32 Mixer parameters with authored storage removed.
///
/// Preview caches use the same normalized values that reach Metal. The
/// semantic version also invalidates retained results when anchors,
/// interpolation, or color transforms change without an authored-value change.
public nonisolated struct ColorMixerRenderIdentity: Hashable, Sendable {

  /// The rendering implementation represented by this identity.
  public let algorithm: ColorMixerFeature.Algorithm

  /// The color-transform semantics represented by this identity.
  public let semanticVersion = ColorMixerRenderPlan.semanticVersion
  private let values: [Float]

  /// Creates an identity only when the Mixer changes rendered pixels.
  public init?(
    activeAdjustment adjustment: ColorMixerAdjustment,
    algorithm: ColorMixerFeature.Algorithm = .oklch
  ) {
    guard let plan = ColorMixerRenderPlan(adjustment: adjustment, algorithm: algorithm) else {
      return nil
    }
    self.algorithm = plan.algorithm
    values = [
      plan.hue0.x, plan.hue0.y, plan.hue0.z, plan.hue0.w,
      plan.hue1.x, plan.hue1.y, plan.hue1.z, plan.hue1.w,
      plan.saturation0.x, plan.saturation0.y,
      plan.saturation0.z, plan.saturation0.w,
      plan.saturation1.x, plan.saturation1.y,
      plan.saturation1.z, plan.saturation1.w,
      plan.luminance0.x, plan.luminance0.y,
      plan.luminance0.z, plan.luminance0.w,
      plan.luminance1.x, plan.luminance1.y,
      plan.luminance1.z, plan.luminance1.w,
    ]
  }
}

/// Independent CPU implementation of the extended-linear Display-P3 mixer.
nonisolated enum ColorMixerReferenceProcessor {

  /// A perceptual cylindrical coordinate used by focused numeric tests.
  struct OKLCh: Equatable, Sendable {
    let lightness: Double
    let chroma: Double
    let hue: Double
  }

  /// OKLCh hue anchors obtained once from encoded Display-P3 HSV hues
  /// 0, 30, 60, 120, 180, 240, 270, and 300 degrees respectively.
  ///
  /// HSV components are decoded with the Display-P3 transfer function before
  /// the documented linear P3 -> XYZ D65 -> OKLab transform.
  static let bandAnchorHues = [
    0.505_414_761_382_065_6,
    0.892_905_268_599_234_7,
    1.923_873_110_591_965_5,
    2.541_984_013_907_575,
    3.370_888_560_950_354_5,
    4.608_577_191_206_187,
    5.174_191_934_414_567_5,
    5.785_145_756_156_107,
  ]

  /// Applies a compiled plan to one premultiplied extended-linear P3 pixel.
  static func processPremultiplied(
    _ pixel: SIMD4<Double>,
    plan: ColorMixerRenderPlan
  ) -> SIMD4<Double> {
    guard pixel.w > 0 else { return pixel }
    let straight = SIMD3(pixel.x, pixel.y, pixel.z) / pixel.w
    let output = processStraight(straight, plan: plan)
    return SIMD4(output * pixel.w, pixel.w)
  }

  /// Applies an authored value while preserving an exact neutral identity.
  static func processPremultiplied(
    _ pixel: SIMD4<Double>,
    adjustment: ColorMixerAdjustment,
    algorithm: ColorMixerFeature.Algorithm = .oklch
  ) -> SIMD4<Double> {
    guard let plan = ColorMixerRenderPlan(adjustment: adjustment, algorithm: algorithm) else {
      return pixel
    }
    return processPremultiplied(pixel, plan: plan)
  }

  /// Applies a compiled plan without alpha or gamut clipping.
  static func processStraight(
    _ rgb: SIMD3<Double>,
    plan: ColorMixerRenderPlan
  ) -> SIMD3<Double> {
    switch plan.algorithm {
    case .oklch:
      return processOKLCh(rgb, plan: plan)
    }
  }

  /// Evaluates the original OKLCh correction independently of algorithm dispatch.
  private static func processOKLCh(
    _ rgb: SIMD3<Double>,
    plan: ColorMixerRenderPlan
  ) -> SIMD3<Double> {
    var lab = xyzToOKLab(displayP3ToXYZ(rgb))
    let originalHue = positiveAngle(atan2(lab.z, lab.y))
    let chroma = hypot(lab.y, lab.z)
    let gate = smoothstep(0.01, 0.04, chroma)
    guard gate > 0 else { return rgb }

    let segment = bandSegment(for: originalHue)
    let smoothProgress = smoothstep(0, 1, segment.progress)
    let firstWeight = 1 - smoothProgress
    let secondWeight = smoothProgress
    let hueDelta =
      (firstWeight * bandHueDelta(index: segment.first, plan: plan)
        + secondWeight * bandHueDelta(index: segment.second, plan: plan)) * gate
    let saturation =
      (firstWeight * plan.saturation(at: segment.first)
        + secondWeight * plan.saturation(at: segment.second)) * gate
    let luminance =
      (firstWeight * plan.luminance(at: segment.first)
        + secondWeight * plan.luminance(at: segment.second)) * gate

    let outputHue = originalHue + hueDelta
    let outputChroma = chroma * max(0, 1 + saturation)
    lab.x *= exp2(luminance)
    lab.y = outputChroma * cos(outputHue)
    lab.z = outputChroma * sin(outputHue)
    return xyzToDisplayP3(okLabToXYZ(lab))
  }

  /// Converts an extended-linear Display-P3 value to OKLCh without clipping.
  static func okLCh(forLinearDisplayP3 rgb: SIMD3<Double>) -> OKLCh {
    let lab = xyzToOKLab(displayP3ToXYZ(rgb))
    return OKLCh(
      lightness: lab.x,
      chroma: hypot(lab.y, lab.z),
      hue: positiveAngle(atan2(lab.z, lab.y))
    )
  }

  /// Converts OKLCh to extended-linear Display-P3 without gamut mapping.
  static func linearDisplayP3(_ value: OKLCh) -> SIMD3<Double> {
    let lab = SIMD3(
      value.lightness,
      value.chroma * cos(value.hue),
      value.chroma * sin(value.hue)
    )
    return xyzToDisplayP3(okLabToXYZ(lab))
  }

  private static let twoPi = Double.pi * 2

  private static func bandSegment(for hue: Double) -> (first: Int, second: Int, progress: Double) {
    var unwrapped = hue
    if unwrapped < bandAnchorHues[0] { unwrapped += twoPi }
    for index in bandAnchorHues.indices {
      let next = (index + 1) % bandAnchorHues.count
      let lower = bandAnchorHues[index]
      let upper = next == 0 ? bandAnchorHues[0] + twoPi : bandAnchorHues[next]
      if unwrapped <= upper {
        return (index, next, (unwrapped - lower) / (upper - lower))
      }
    }
    return (7, 0, 1)
  }

  private static func bandHueDelta(index: Int, plan: ColorMixerRenderPlan) -> Double {
    let value = plan.hue(at: index)
    let previous = (index + 7) % 8
    let next = (index + 1) % 8
    let anchor = bandAnchorHues[index]
    let previousAnchor =
      previous == 7 && index == 0 ? bandAnchorHues[7] - twoPi : bandAnchorHues[previous]
    let nextAnchor = next == 0 ? bandAnchorHues[0] + twoPi : bandAnchorHues[next]
    return value < 0 ? value * (anchor - previousAnchor) : value * (nextAnchor - anchor)
  }

  private static func smoothstep(_ lower: Double, _ upper: Double, _ value: Double) -> Double {
    let t = min(max((value - lower) / (upper - lower), 0), 1)
    return t * t * (3 - 2 * t)
  }

  private static func positiveAngle(_ value: Double) -> Double { value < 0 ? value + twoPi : value }
  private static func signedCubeRoot(_ value: Double) -> Double {
    value.sign == .minus ? -pow(-value, 1 / 3) : pow(value, 1 / 3)
  }

  // CSS Color 4 64-bit Display-P3 and Oklab matrices, D65; no transfer function or gamut map.
  private static func displayP3ToXYZ(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
    SIMD3(
      0.486_570_948_648_216_2 * rgb.x + 0.265_667_693_169_093_06 * rgb.y + 0.198_217_285_234_362_5
        * rgb.z,
      0.228_974_564_069_748_8 * rgb.x + 0.691_738_521_836_506_4 * rgb.y + 0.079_286_914_093_745
        * rgb.z,
      0.045_113_381_858_902_64 * rgb.y + 1.043_944_368_900_976 * rgb.z
    )
  }

  private static func xyzToDisplayP3(_ xyz: SIMD3<Double>) -> SIMD3<Double> {
    SIMD3(
      2.493_496_911_941_425 * xyz.x - 0.931_383_617_919_123_9 * xyz.y - 0.402_710_784_450_716_84
        * xyz.z,
      -0.829_488_969_561_574_7 * xyz.x + 1.762_664_060_318_346_3 * xyz.y + 0.023_624_685_841_943_577
        * xyz.z,
      0.035_845_830_243_784_47 * xyz.x - 0.076_172_389_268_041_82 * xyz.y + 0.956_884_524_007_687_2
        * xyz.z
    )
  }

  private static func xyzToOKLab(_ xyz: SIMD3<Double>) -> SIMD3<Double> {
    let lms = SIMD3(
      0.819_022_437_996_703 * xyz.x + 0.361_906_260_052_890_4 * xyz.y - 0.128_873_781_520_987_9
        * xyz.z,
      0.032_983_653_932_388_5 * xyz.x + 0.929_286_861_586_343_4 * xyz.y + 0.036_144_666_350_642_4
        * xyz.z,
      0.048_177_189_359_624_2 * xyz.x + 0.264_239_531_752_730_8 * xyz.y + 0.633_547_828_469_430_9
        * xyz.z
    )
    let root = SIMD3(signedCubeRoot(lms.x), signedCubeRoot(lms.y), signedCubeRoot(lms.z))
    return SIMD3(
      0.210_454_268_309_314 * root.x + 0.793_617_774_702_305_4 * root.y
        - 0.004_072_043_011_619_3 * root.z,
      1.977_998_532_431_168_4 * root.x - 2.428_592_242_048_58 * root.y
        + 0.450_593_709_617_411 * root.z,
      0.025_904_042_465_547_8 * root.x + 0.782_771_712_457_529_6 * root.y
        - 0.808_675_754_923_077_4 * root.z
    )
  }

  private static func okLabToXYZ(_ lab: SIMD3<Double>) -> SIMD3<Double> {
    let root = SIMD3(
      lab.x + 0.396_337_777_376_174_9 * lab.y + 0.215_803_757_309_913_6 * lab.z,
      lab.x - 0.105_561_345_815_658_6 * lab.y - 0.063_854_172_825_813_3 * lab.z,
      lab.x - 0.089_484_177_529_811_9 * lab.y - 1.291_485_548_019_409_2 * lab.z
    )
    let lms = root * root * root
    return SIMD3(
      1.226_879_875_845_924_3 * lms.x - 0.557_814_994_460_217_1 * lms.y + 0.281_391_045_665_964_7
        * lms.z,
      -0.040_575_745_214_800_8 * lms.x + 1.112_286_803_280_317 * lms.y - 0.071_711_058_065_516_4
        * lms.z,
      -0.076_372_936_674_660_1 * lms.x - 0.421_493_332_402_243_2 * lms.y + 1.586_924_019_836_781_6
        * lms.z
    )
  }
}
