// Copyright (c) 2026 Hiroshi Kimura (Muukii)

import BrightroomColorAdjustmentKernels
import CoreImage
import Foundation

/// Four display-referred point curves in ROMM/ProPhoto RGB primaries.
///
/// Coordinates use the sRGB transfer function, not ProPhoto's file encoding.
/// Natural cubic splines interpolate the authored points. The middle RGB
/// component determines where the master curve is sampled. The mapped range
/// preserves the encoded hue. Independent red, green, and blue curves follow.
///
/// This is an experimental post-development approximation of Camera Raw point
/// curves. Its master and RGB responses were measured against PV 15.4.
/// ``refineSaturation`` controls how the master curve affects color.
/// See `docs/point-curve.md` for measured coverage and remaining differences.
/// ``ToneCurveFeature`` retains its scene-linear YRGB interpretation.
///
/// Curves cover SDR values. Outside 0...1, the corresponding boundary result
/// continues with unit slope in linear light. Alpha and image extent are
/// preserved. Use a floating-point Core Image working format.
public nonisolated struct PointCurveFeature: ImageEffect, Equatable {

  /// The interpretation of the transfer function, spline, and channel order.
  public static let semanticVersion = 2

  /// The four independently authored curves, evaluated master first.
  public struct Curves: Equatable, Sendable {

    /// A shared tone adjustment that preserves the ordering of input channels.
    /// Nonmonotonic curves can reverse that ordering.
    public var master: ToneCurve

    /// The red component curve, evaluated after the master curve.
    public var red: ToneCurve

    /// The green component curve, evaluated after the master curve.
    public var green: ToneCurve

    /// The blue component curve, evaluated after the master curve.
    public var blue: ToneCurve

    /// Whether all four mappings leave every value unchanged.
    public var isIdentity: Bool {
      master.isIdentity && red.isIdentity && green.isIdentity && blue.isIdentity
    }

    /// Creates curves from normalized, validated control-point values.
    public init(
      master: ToneCurve = .neutral,
      red: ToneCurve = .neutral,
      green: ToneCurve = .neutral,
      blue: ToneCurve = .neutral
    ) {
      self.master = master
      self.red = red
      self.green = green
      self.blue = blue
    }
  }

  /// Authored coordinates; derived GPU data does not participate in equality.
  public let curves: Curves

  /// The master curve's Refine Saturation amount, in XMP units from 0 to 100.
  ///
  /// At zero, the master retains the input's encoded RGB differences as far
  /// as the SDR gamut allows. At 100 it applies the full master response.
  /// Intermediate values blend the two results before the individual RGB curves.
  public var refineSaturation: Double {
    didSet { refineSaturation = Self.clampRefinement(refineSaturation) }
  }

  private let table: CIImage?

  /// Creates a point-curve edit with the default Refine Saturation of 100.
  public init(curves: Curves = .init()) {
    self.init(curves: curves, refineSaturation: 100)
  }

  /// Compiles the curves once and clamps refinement to 0...100.
  /// A nonfinite amount uses the default of 100.
  public init(curves: Curves, refineSaturation: Double) {
    self.curves = curves
    self.refineSaturation = Self.clampRefinement(refineSaturation)
    guard !curves.isIdentity else {
      table = nil
      return
    }
    let splines = [curves.master, curves.red, curves.green, curves.blue].map(PointCurveSpline.init)
    let samples = [0, 2].flatMap { channel in
      (0..<4096).map { index in
        let input = Double(index) / 4095
        return SIMD2(Float(splines[channel].value(at: input) - input),
          Float(splines[channel + 1].value(at: input) - input))
      }
    }
    // One RGf strip avoids alpha/color semantics and any vertical interpolation
    // between independent curves: Master/Red, followed by Green/Blue. Storing
    // deltas preserves small corrections when an RGBAh context uploads data.
    // The 8,192-pixel width fits the validated iOS Core Image rendering path.
    table = CIImage(bitmapData: samples.withUnsafeBytes { Data($0) },
      bytesPerRow: samples.count * MemoryLayout<SIMD2<Float>>.stride,
      size: CGSize(width: samples.count, height: 1), format: .RGf, colorSpace: nil).samplingLinear()
  }

  /// Restores authored curves and rejects a refinement outside 0...100.
  public init?(validatingCurves curves: Curves, refineSaturation: Double) {
    guard (0...100).contains(refineSaturation) else { return nil }
    self.init(curves: curves, refineSaturation: refineSaturation)
  }

  private static func clampRefinement(_ value: Double) -> Double {
    value.isFinite ? min(max(value, 0), 100) : 100
  }

  /// Returns the input itself for an identity edit, including diagonal points.
  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    guard let table else { return image }
    let kernel = try Self.kernel.get()
    return try ColorAdjustmentKernelSpace.apply(to: image, kernelName: Self.kernelName) { input in
      guard let output = kernel.apply(extent: input.extent,
        roiCallback: { index, rect in index == 0 ? rect : table.extent },
        arguments: [input, table, curves.master.isIdentity ? 0.0 : 1.0, refineSaturation / 100]
      ) else { throw FeatureEvaluationError.imageCreationFailed(Self.kernelName) }
      return output.cropped(to: image.extent)
    }
  }

  /// Compares authored values, including redundant diagonal control points.
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.curves == rhs.curves && lhs.refineSaturation == rhs.refineSaturation
  }

  private static let kernelName = "brightroomPointCurve"
  private static let kernel: Result<CIKernel, FeatureEvaluationError> = {
    do {
      return .success(try CIKernel(functionName: kernelName,
        fromMetalLibraryData: ColorAdjustmentMetalLibrary.data()))
    } catch {
      return .failure(.kernelUnavailable(name: kernelName, reason: String(describing: error)))
    }
  }()
}

/// A natural cubic spline with zero endpoint curvature and bounded SDR output.
///
/// The tridiagonal system solves second derivatives at authored points. An
/// inward endpoint creates a constant exterior interval. This evaluator is
/// deliberately separate from ToneCurveEvaluator's shape-preserving contract.
private nonisolated struct PointCurveSpline {

  let points: [ToneCurve.Point]
  let curvature: [Double]

  init(curve: ToneCurve) {
    points = curve.points
    let count = points.count
    var diagonal = [Double](repeating: 1, count: count)
    var upper = [Double](repeating: 0, count: count)
    var right = [Double](repeating: 0, count: count)
    if count > 2 {
      for index in 1..<(count - 1) {
        let leftWidth = points[index].input - points[index - 1].input
        let rightWidth = points[index + 1].input - points[index].input
        let leftSlope = (points[index].output - points[index - 1].output) / leftWidth
        let rightSlope = (points[index + 1].output - points[index].output) / rightWidth
        let factor = leftWidth / diagonal[index - 1]
        diagonal[index] = 2 * (leftWidth + rightWidth) - factor * upper[index - 1]
        upper[index] = rightWidth
        right[index] = 6 * (rightSlope - leftSlope) - factor * right[index - 1]
      }
    }
    var result = [Double](repeating: 0, count: count)
    for index in stride(from: count - 2, through: 1, by: -1) {
      result[index] = (right[index] - upper[index] * result[index + 1]) / diagonal[index]
    }
    curvature = result
  }

  func value(at input: Double) -> Double {
    guard input > points[0].input else { return points[0].output }
    guard input < points[points.count - 1].input else { return points[points.count - 1].output }
    let upper = points.firstIndex { $0.input >= input }!
    let lower = upper - 1
    let width = points[upper].input - points[lower].input
    let right = (input - points[lower].input) / width
    let left = 1 - right
    let result = left * points[lower].output + right * points[upper].output
      + ((left * left * left - left) * curvature[lower]
        + (right * right * right - right) * curvature[upper]) * width * width / 6
    return min(max(result, 0), 1)
  }
}
