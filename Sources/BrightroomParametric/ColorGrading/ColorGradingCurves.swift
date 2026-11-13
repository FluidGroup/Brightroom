// Copyright (c) 2026 Hiroshi Kimura (Muukii)

import Foundation

/// Reconstructs SDR grading responses measured over a neutral RGB ramp.
///
/// The bundled calibration contains channel curves, not photographs or a
/// particular preset. Blending, balance, and strength select continuous curves;
/// hue combines the primary and secondary color responses. Global and midtone
/// color use a rational response. See the acquisition and held-out validation
/// procedure in `Tools/LightroomComparison` before changing this model.
nonisolated enum ColorGradingCurves {

  private static let count = 257
  private static let colorCount = 2 * 5 * 5 * 5 * 3 * count
  private static let midtoneCount = 5 * 5 * 2 * count
  private static let luminanceCount = 3 * 5 * 5 * 5 * count

  private static let calibration: Result<[Double], FeatureEvaluationError> = {
    guard let url = Bundle.module.url(forResource: "ColorGradingCalibration", withExtension: "bin"),
      let data = try? Data(contentsOf: url),
      data.prefix(8) == Data("BRCG0001".utf8),
      data.count == 8 + 2 * (colorCount + midtoneCount + luminanceCount)
    else { return .failure(.imageCreationFailed("Color Grading calibration")) }
    return .success(data.withUnsafeBytes { bytes in
      stride(from: 8, to: data.count, by: 2).map {
        Double(UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt16.self))) / 65535
      }
    })
  }()

  /// Three concatenated 2,049-point curves, sampled uniformly in the sRGB shaper.
  /// Values are linear ProPhoto RGB; the shaper only allocates sample precision.
  static func samples(for grading: ColorGradingFeature) throws -> [Float] {
    let input = (0..<count).map { decode(Double($0) / Double(count - 1)) }
    var output = (0..<3).map { _ in input }
    if !grading.shadows.isIdentity || !grading.midtones.isIdentity || !grading.highlights.isIdentity {
      let data = try calibration.get()
      let blend = weights(grading.blending / 25)
      let balance = weights((grading.balance + 100) / 50)
      for (rangeIndex, range) in [ColorGradingFeature.Range.shadows, .midtones, .highlights].enumerated() {
        let correction = grading[range]
        guard !correction.isIdentity else { continue }
        var color = (0..<3).map { _ in input }
        if correction.saturation != 0 {
          if range == .midtones {
            let positive = curve(data, base: colorCount, axes: [(blend, 5 * 2 * count), (balance, 2 * count)])
            let negative = curve(data, base: colorCount + count, axes: [(blend, 5 * 2 * count), (balance, 2 * count)])
            let tint = hsv(correction.hue).map { (2 * $0 - 1) * correction.saturation / 100 }
            for channel in 0..<3 {
              color[channel] = input.indices.map {
                rational(input[$0], positive: positive[$0], negative: negative[$0], amount: tint[channel])
              }
            }
          } else {
            let base = (range == .shadows ? 0 : 1) * 5 * 5 * 5 * 3 * count
            let axes = [(blend, 5 * 5 * 3 * count), (balance, 5 * 3 * count),
              (weights(correction.saturation / 25), 3 * count)]
            let primaryPositive = curve(data, base: base, axes: axes)
            let primaryNegative = curve(data, base: base + count, axes: axes)
            let secondaryNegative = curve(data, base: base + 2 * count, axes: axes)
            let sector = correction.hue / 60
            let lower = Int(sector) % 6
            let fraction = sector - floor(sector)
            func anchor(_ index: Int, channel: Int) -> [Double] {
              if index.isMultiple(of: 2) {
                return channel == index / 2 ? primaryPositive : primaryNegative
              }
              return channel == ((index + 3) / 2) % 3 ? secondaryNegative : input
            }
            for channel in 0..<3 {
              let first = anchor(lower, channel: channel)
              let second = anchor((lower + 1) % 6, channel: channel)
              color[channel] = input.indices.map { first[$0] + fraction * (second[$0] - first[$0]) }
            }
          }
        }
        let luminance: [Double]
        if correction.luminance == 0 {
          luminance = input
        } else {
          luminance = curve(data,
            base: colorCount + midtoneCount + rangeIndex * 5 * 5 * 5 * count,
            axes: [(blend, 5 * 5 * count), (balance, 5 * count),
              (weights((correction.luminance + 100) / 50), count)])
        }
        for channel in 0..<3 {
          for i in input.indices {
            output[channel][i] += color[channel][i] - input[i] + luminance[i] - input[i]
          }
        }
      }
    }

    var samples = [Float]()
    samples.reserveCapacity(3 * 2049)
    for channel in 0..<3 {
      for index in 0..<2049 {
        let position = Double(index) / 8
        let lower = min(Int(position), count - 2)
        let fraction = position - Double(lower)
        let value = output[channel][lower] + fraction * (output[channel][lower + 1] - output[channel][lower])
        samples.append(Float(value))
      }
    }
    return samples
  }

  /// Bipolar channel amounts for the analytic global correction.
  static func globalTint(_ correction: ColorGradingFeature.Correction) -> [Double] {
    hsv(correction.hue).map { (2 * $0 - 1) * 0.28 * correction.saturation / 100 }
  }

  private static func rational(_ x: Double, positive: Double, negative: Double, amount: Double) -> Double {
    let p = positive - x
    let n = negative - x
    guard abs(p - n) > 0.000_000_1 else { return x }
    let b = min(max(-(p + n) / (p - n), -0.95), 0.95)
    let a = (p * (1 + b) - n * (1 - b)) / 2
    return x + amount * a / (1 + amount * b)
  }

  /// Four neighboring knots with cubic Lagrange weights. Endpoint intervals use
  /// the nearest four measured knots; no extrapolation outside the grid occurs.
  private static func weights(_ position: Double) -> [(Int, Double)] {
    let first = min(max(Int(position) - 1, 0), 1)
    return (first..<(first + 4)).map { index in
      var weight = 1.0
      for other in first..<(first + 4) where other != index {
        weight *= (position - Double(other)) / Double(index - other)
      }
      return (index, weight)
    }
  }

  /// Interpolates one curve over the authored parameter axes before GPU sampling.
  private static func curve(_ data: [Double], base: Int, axes: [([(Int, Double)], Int)]) -> [Double] {
    var offsets = [(base, 1.0)]
    for (weights, stride) in axes {
      offsets = offsets.flatMap { offset, scale in
        weights.compactMap { index, weight in
          weight == 0 ? nil : (offset + index * stride, scale * weight)
        }
      }
    }
    var result = [Double](repeating: 0, count: count)
    for (offset, weight) in offsets {
      for i in result.indices { result[i] += data[offset + i] * weight }
    }
    return result.map { min(max($0, 0), 1) }
  }

  private static func hsv(_ hue: Double) -> [Double] {
    let sector = hue / 60
    let x = 1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1)
    switch Int(sector) % 6 {
    case 0: return [1, x, 0]
    case 1: return [x, 1, 0]
    case 2: return [0, 1, x]
    case 3: return [0, x, 1]
    case 4: return [x, 0, 1]
    default: return [1, 0, x]
    }
  }

  private static func decode(_ x: Double) -> Double {
    x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
  }
}
