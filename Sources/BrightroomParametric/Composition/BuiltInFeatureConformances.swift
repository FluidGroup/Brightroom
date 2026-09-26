//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

// The built-in features join the static composition model through their
// existing `apply(to:context:)` recipes (BuiltInFeatureRecipes.swift and the
// feature folders), so both document models evaluate identical Core Image
// graphs. Validation that the recipes perform (`invalidCropRect`,
// `invalidColorCubeData`) therefore also runs on this path.

// MARK: - Domain features

extension CropFeature: Feature {}

// MARK: - Image effects

extension BrightnessFeature: ImageEffect {}

extension ContrastFeature: ImageEffect {}

extension SaturationFeature: ImageEffect {}

extension ExposureFeature: ImageEffect {}

extension HighlightsFeature: ImageEffect {}

extension ShadowsFeature: ImageEffect {}

extension HighlightShadowTintFeature: ImageEffect {}

extension TemperatureFeature: ImageEffect {}

extension SharpenFeature: ImageEffect {}

extension GaussianBlurFeature: ImageEffect {}

extension UnsharpMaskFeature: ImageEffect {}

extension VignetteFeature: ImageEffect {}

extension FadeFeature: ImageEffect {}

extension ColorCubeFeature: ImageEffect {}

extension ToneCurveFeature: ImageEffect {}

extension ColorMixerFeature: ImageEffect {}

extension PresetFeature: ImageEffect {}
