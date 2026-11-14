// Copyright (c) 2026 Hiroshi Kimura (Muukii)

import BrightroomColorAdjustmentKernels
import CoreImage
import Foundation

extension GrainFeature {

  /// Approximates film grain from the XMP `GrainAmount`, `GrainSize`, and
  /// `GrainFrequency` sliders. Provide each value directly, in 0...100.
  ///
  /// This effect adds a shared random signal to encoded ProPhoto RGB and
  /// softens image detail at larger sizes. Its texture scales with the
  /// full-resolution chain entry. The spatial and tonal responses were measured
  /// at Amount 20, Size 42 and Roughness 70. Other settings are estimates.
  /// The seed is reproducible within Brightroom. A nonzero adjustment
  /// requires a finite source extent to resolve particle size.
  public nonisolated struct CameraRaw: ImageEffect, Equatable, Sendable {

    /// Strength of the grain. Zero returns the input itself.
    public var amount: Double { didSet { amount = GrainFeature.clamp(amount) } }

    /// Particle size. Larger values can also soften detail in the input.
    public var size: Double { didSet { size = GrainFeature.clamp(size) } }

    /// Variation in particle strength, stored in XMP as `GrainFrequency`.
    public var roughness: Double { didSet { roughness = GrainFeature.clamp(roughness) } }

    /// Anchors the texture to pixel coordinates across tiles and redraws.
    public var seed: UInt32

    /// Creates a film-grain adjustment, clamping each slider to 0...100.
    public init(amount: Double, size: Double = 25, roughness: Double = 50, seed: UInt32 = 0) {
      self.amount = GrainFeature.clamp(amount)
      self.size = GrainFeature.clamp(size)
      self.roughness = GrainFeature.clamp(roughness)
      self.seed = seed
    }

    /// Restores authored slider values only if all three are in range.
    public init?(validatingAmount amount: Double, size: Double, roughness: Double, seed: UInt32) {
      guard (0...100).contains(amount), (0...100).contains(size), (0...100).contains(roughness)
      else { return nil }
      self.init(amount: amount, size: size, roughness: roughness, seed: seed)
    }

    public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
      guard amount > 0, !image.extent.isEmpty else { return image }
      let extent = context.chainEntryExtent(for: image)
      let scale = context.renderScale
      let sourceScale = sqrt(extent.width / 6000) * sqrt(extent.height / 4000) / scale
      guard !extent.isInfinite, sourceScale.isFinite else {
        throw FeatureEvaluationError.imageCreationFailed("Camera Raw grain requires a finite source extent")
      }
      // The two measured grain widths include a pixel-sized component. Area
      // supplies the rotation-invariant scale between the two source sizes.
      let sigma = hypot(0.21, 1.125 * sourceScale * size / 42)
      let deviation = 0.0648 * (amount / 100) / pow(sigma, 0.53)
      let detailSigma = 0.5 * sourceScale * max(0, size - 25) / 17 * sqrt(amount / 20) * scale
      let kernels = try Self.kernels.get()
      let noise = try GrainFeature.noise(seed: seed).applyingGaussianBlur(sigma: sigma)

      // At the measured roughness the residual is Gaussian. Vary its tails
      // while preserving unit variance, before filtering the field for previews.
      let exponent = (roughness + 70) / 140
      let moment = pow(2, exponent) * tgamma(exponent + 0.5) / sqrt(.pi)
      guard let texture = kernels.shape.apply(extent: .infinite, arguments: [
        noise, 1 / Self.gaussianNoiseDeviation(sigma: sigma), exponent, deviation / sqrt(moment),
      ]) else { throw FeatureEvaluationError.imageCreationFailed("Camera Raw grain texture") }
      let sampled = GrainFeature.sampledField(texture, extent: image.extent, scale: scale)

      return try ColorAdjustmentKernelSpace.apply(to: image, kernelName: "Camera Raw grain") { input in
        guard let encoded = kernels.encode.apply(extent: input.extent, arguments: [input]) else {
          throw FeatureEvaluationError.imageCreationFailed("Camera Raw grain encoding")
        }
        let softened = detailSigma > 0
          ? encoded.clampedToExtent().applyingGaussianBlur(sigma: detailSigma).cropped(to: input.extent)
          : encoded
        guard let output = kernels.blend.apply(extent: input.extent, arguments: [input, softened, sampled])
        else { throw FeatureEvaluationError.imageCreationFailed("Camera Raw grain blend") }
        return output
      }
    }

    /// RMS of unit white noise after a separable, pixel-integrated Gaussian.
    /// Each dimension contributes the same sum of squared weights.
    private static func gaussianNoiseDeviation(sigma: Double) -> Double {
      if sigma >= 3 { return 1 / (2 * sqrt(.pi) * sigma) }
      let denominator = sqrt(2.0) * sigma
      let radius = Int(ceil(4 * sigma))
      var energy = 0.0
      for i in -radius...radius {
        let weight = (erf((Double(i) + 0.5) / denominator) - erf((Double(i) - 0.5) / denominator)) / 2
        energy += weight * weight
      }
      return energy
    }

    private static let kernels: Result<(encode: CIColorKernel, shape: CIColorKernel, blend: CIColorKernel), FeatureEvaluationError> = {
      do {
        let data = try ColorAdjustmentMetalLibrary.data()
        return .success((
          try CIColorKernel(functionName: "brightroomGrainEncodeROMM", fromMetalLibraryData: data),
          try CIColorKernel(functionName: "brightroomGrainShape", fromMetalLibraryData: data),
          try CIColorKernel(functionName: "brightroomGrainBlendROMM", fromMetalLibraryData: data)
        ))
      } catch {
        return .failure(.kernelUnavailable(name: "Camera Raw grain", reason: String(describing: error)))
      }
    }()
  }
}
