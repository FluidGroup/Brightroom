// Copyright (c) 2026 Hiroshi Kimura (Muukii)

import CoreImage
import Foundation

extension GrainFeature {

  /// Grain parameters in Camera Raw's amount, size, and roughness units (0...100).
  ///
  /// The standard calculation uses lightweight grain with full-resolution particle
  /// sizes. A nonzero adjustment requires a finite chain-entry extent.
  public nonisolated struct CameraRaw: ImageEffect, Equatable, Sendable {

    /// Strength of the grain. Zero returns the input itself.
    public var amount: Double { didSet { amount = GrainFeature.clamp(amount) } }

    /// Particle size in the selected implementation's 0...100 scale.
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
      if let output = try context.adjustmentRendering.apply(self, to: image, context: context) {
        return output
      }
      let extent = context.chainEntryExtent(for: image)
      guard !extent.isInfinite, extent.width.isFinite, extent.height.isFinite else {
        throw FeatureEvaluationError.imageCreationFailed("Grain requires a finite chain-entry extent")
      }
      return try GrainFeature(amount: amount, radius: .absolute(size / 25), roughness: roughness, seed: seed)
        .apply(to: image, context: context.usingStandardAdjustments())
    }
  }
}
