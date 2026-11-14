// Copyright (c) 2026 Hiroshi Kimura (Muukii)

import BrightroomColorAdjustmentKernels
import CoreImage
import Foundation

/// Adds reproducible monochromatic grain, strongest in the middle tones.
///
/// Grain is a separate effect, so hosts choose its position in the feature
/// stack. The seed anchors its texture to full-resolution image coordinates;
/// previews filter that texture down instead of inventing larger grains.
/// Alpha and extent are preserved, and extended RGB values are not clipped.
/// Use `GrainFeature.CameraRaw` for the Amount, Size and Roughness controls
/// of a Camera Raw preset.
public nonisolated struct GrainFeature: ImageEffect, Equatable, Sendable {

  /// Grain strength from 0 through 100. Zero bypasses the effect exactly.
  public var amount: Double { didSet { amount = Self.clamp(amount) } }

  /// Smoothing radius of the grain field; zero gives pixel-sized grain.
  /// Absolute radii are full-resolution pixels, not Lightroom's Size values.
  public var radius: EffectRadius { didSet { radius = Self.clamp(radius) } }

  /// Spatial variation in grain strength, from uniform (0) to uneven (100).
  public var roughness: Double { didSet { roughness = Self.clamp(roughness) } }

  /// Reproduces the texture without depending on frame time or render order.
  public var seed: UInt32

  /// Clamps strengths to 0...100 and negative radii to zero.
  /// Nonfinite values become zero; use the validating initializer to reject them.
  public init(
    amount: Double = 0,
    radius: EffectRadius = .absolute(1),
    roughness: Double = 50,
    seed: UInt32 = 0
  ) {
    self.amount = Self.clamp(amount)
    self.radius = Self.clamp(radius)
    self.roughness = Self.clamp(roughness)
    self.seed = seed
  }

  /// Restores parameters without silently repairing invalid stored values.
  public init?(
    validatingAmount amount: Double,
    radius: EffectRadius,
    roughness: Double,
    seed: UInt32
  ) {
    guard (0...100).contains(amount), (0...100).contains(roughness) else {
      return nil
    }
    switch radius {
    case let .absolute(value), let .proportional(value):
      guard value.isFinite, value >= 0 else { return nil }
    }
    self.init(amount: amount, radius: radius, roughness: roughness, seed: seed)
  }

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    guard amount > 0 else { return image }
    let kernels = try Self.kernels.get()
    let scale = context.renderScale
    let fullRadius = radius.pixels(in: context, for: image) / scale
    let noise = try Self.noise(seed: seed)

    func field(radius: Double) -> CIImage {
      var field = noise
      if radius > 0 {
        field = field.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
      }
      // Blur lowers the variance of white noise. This continuous Gaussian
      // approximation keeps radius chiefly a size control, not a strength one.
      let normalization = sqrt(1 + 4 * .pi * radius * radius)
      field = field.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: normalization, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: normalization, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
      ])
      return Self.sampledField(field, extent: image.extent, scale: scale)
    }

    let fine = field(radius: fullRadius)
    let coarse = roughness > 0 ? field(radius: max(1, fullRadius * 4)) : fine
    return try ColorAdjustmentKernelSpace.apply(to: image, kernelName: "brightroomGrain") { image in
      guard let output = kernels.blend.apply(
        extent: image.extent,
        roiCallback: { _, rect in rect },
        arguments: [image, fine, coarse, amount / 100, roughness / 100]
      ) else {
        throw FeatureEvaluationError.imageCreationFailed("brightroomGrain")
      }
      return output.cropped(to: image.extent)
    }
  }

  /// Two independent standard normal fields anchored to full-resolution pixel centers.
  static func noise(seed: UInt32) throws -> CIImage {
    // Two 16-bit words preserve all seed bits through Core Image's float ABI.
    let words = CIVector(x: CGFloat(seed & 0xffff), y: CGFloat(seed >> 16))
    guard let field = try kernels.get().noise.apply(
      extent: .infinite, roiCallback: { _, rect in rect }, arguments: [words]
    ) else { throw FeatureEvaluationError.imageCreationFailed("brightroomGrainNoise") }
    return field
  }

  /// Filters the whole-resolution field before sampling it at preview resolution.
  static func sampledField(_ field: CIImage, extent: CGRect, scale: CGFloat) -> CIImage {
    guard scale != 1 else { return field.cropped(to: extent) }
    let bounds = extent.applying(.init(scaleX: 1 / scale, y: 1 / scale))
      .insetBy(dx: -4 / scale, dy: -4 / scale)
    return field.cropped(to: bounds).applyingFilter("CILanczosScaleTransform", parameters: [
      kCIInputScaleKey: scale, "inputAspectRatio": 1,
    ]).cropped(to: extent)
  }

  static func clamp(_ value: Double) -> Double {
    value.isFinite ? min(max(value, 0), 100) : 0
  }

  private static func clamp(_ radius: EffectRadius) -> EffectRadius {
    switch radius {
    case let .absolute(value): .absolute(value.isFinite ? max(0, value) : 0)
    case let .proportional(value): .proportional(value.isFinite ? max(0, value) : 0)
    }
  }

  private static let kernels: Result<(noise: CIKernel, blend: CIKernel), FeatureEvaluationError> = {
    do {
      let data = try ColorAdjustmentMetalLibrary.data()
      return .success((
        try CIKernel(functionName: "brightroomGrainNoise", fromMetalLibraryData: data),
        try CIKernel(functionName: "brightroomGrain", fromMetalLibraryData: data)
      ))
    } catch {
      return .failure(.kernelUnavailable(name: "Grain", reason: String(describing: error)))
    }
  }()
}
