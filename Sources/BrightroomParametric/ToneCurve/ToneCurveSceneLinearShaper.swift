//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import Foundation

/// Maps scene-linear values to the normalized domain authored by the
/// Tone Curve editor.
///
/// The piecewise transform matches OpenColorIO's scene-linear
/// `GradingRGBCurve` shaper: middle gray `0.18` is zero stops, linear zero is
/// minus seven stops, and the editor's normalized `0...1` interval represents
/// minus seven through plus seven stops. Its linear toe keeps black and
/// negative working-space values finite instead of forcing them through a
/// logarithm.
nonisolated enum ToneCurveSceneLinearShaper {

  /// The normalized editor coordinate corresponding to scene-linear black.
  static let normalizedBlack = 0.0

  /// The normalized editor coordinate corresponding to 18% scene-linear gray.
  static let normalizedMiddleGray = 0.5

  /// The normalized editor coordinate corresponding to plus seven stops.
  static let normalizedUpperBound = 1.0

  private static let lowerStop = -7.0
  private static let upperStop = 7.0
  private static let stopRange = upperStop - lowerStop
  private static let middleGray = 0.18
  private static let shift = -0.000_157_849_851_665_374
  private static let linearBreak = 0.004_131_837_473_948_394_6
  private static let stopBreak = -5.5
  private static let linearToeGain = 363.034_608_563

  /// Converts an extended scene-linear value to a normalized curve input.
  static func normalizedCurveCoordinate(for linear: Double) -> Double {
    (stopValue(for: linear) - lowerStop) / stopRange
  }

  /// Converts a normalized curve output back to extended scene-linear light.
  static func linearValue(forNormalizedCurveCoordinate coordinate: Double) -> Double {
    linearValue(forStop: lowerStop + coordinate * stopRange)
  }

  /// Converts a scene-linear value to stops relative to 18% gray.
  static func stopValue(for linear: Double) -> Double {
    if linear < linearBreak {
      return linear * linearToeGain + lowerStop
    }
    return log2((linear + shift) / (middleGray + shift))
  }

  /// Converts a stop value relative to 18% gray back to scene-linear light.
  static func linearValue(forStop stop: Double) -> Double {
    if stop < stopBreak {
      return (stop - lowerStop) / linearToeGain
    }
    return exp2(stop) * (middleGray + shift) - shift
  }
}
