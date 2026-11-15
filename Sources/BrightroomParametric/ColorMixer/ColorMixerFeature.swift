import CoreImage

/// An eight-band color correction. Authored bands are independent of the renderer's implementation.
public nonisolated struct ColorMixerFeature: ImageEffect, Equatable {

  public let bands: Bands
  private let renderPlan: ColorMixerRenderPlan?

  public init(bands: Bands) {
    self.bands = bands
    self.renderPlan = ColorMixerRenderPlan(bands: bands)
  }

  public func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
    guard let renderPlan else { return image }
    if let output = try context.adjustmentRendering.apply(self, to: image, context: context) {
      return output
    }
    return try ColorMixerRecipe.apply(to: image, plan: renderPlan)
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.bands == rhs.bands
  }
}
