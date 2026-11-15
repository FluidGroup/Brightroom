import CoreImage

nonisolated enum DehazeRecipe {

  static func apply(to image: CIImage, amount: Double) throws -> CIImage {
    image.applyingFilter("CIColorControls", parameters: [
      kCIInputContrastKey: 1 + 0.5 * amount / 100,
      kCIInputSaturationKey: 1 + 0.1 * amount / 100,
    ]).cropped(to: image.extent)
  }
}
