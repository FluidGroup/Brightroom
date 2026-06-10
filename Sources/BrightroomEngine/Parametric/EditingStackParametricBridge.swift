//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import CoreImage
import Foundation
import BrightroomParametric

/// Errors thrown while converting legacy `EditingStack.Edit.Filters` into
/// parametric effect features.
public enum ParametricEditingStackBridgeError: Error, Equatable, Sendable {

  /// The bridge found an `AnyFilter` whose concrete type has no parametric
  /// representation.
  case unsupportedFilter(String)

  /// The bridge could not serialize an image-backed color cube into cube data.
  case failedToCreateColorCubeData(identifier: String, message: String)
}

public extension EffectPipeline {

  /// Creates an effect pipeline from the filters supported by
  /// `EditingStack.Edit.Filters`.
  ///
  /// The conversion preserves Brightroom's legacy filter order. `preset` and
  /// `additionalFilters` are supported when their `AnyFilter` values contain
  /// built-in Brightroom filters. Unknown custom `AnyFilter` values throw
  /// `ParametricEditingStackBridgeError.unsupportedFilter`.
  init(
    editingStackFilters filters: EditingStack.Edit.Filters,
    idPrefix: String = "editing-stack-filter"
  ) throws {
    self.init(
      effects: try ImageEffectFeature.makeFeatures(
        editingStackFilters: filters,
        idPrefix: idPrefix
      )
    )
  }
}

public extension FeatureEffectPipeline {

  /// Creates a registry-backed effect pipeline from the filters supported by
  /// `EditingStack.Edit.Filters`.
  ///
  /// The returned nodes use the same ordering as
  /// `EditingStack.Edit.Filters.makeFilters()`.
  init(
    editingStackFilters filters: EditingStack.Edit.Filters,
    idPrefix: String = "editing-stack-filter"
  ) throws {
    self.init(
      effects: try ImageEffectFeature
        .makeFeatures(editingStackFilters: filters, idPrefix: idPrefix)
        .map(FeatureNode.init(imageEffect:))
    )
  }
}

public extension ImageEffectFeature {

  /// Creates parametric effects from the filters supported by
  /// `EditingStack.Edit.Filters`.
  ///
  /// The returned effects use the same ordering as
  /// `EditingStack.Edit.Filters.makeFilters()`.
  static func makeFeatures(
    editingStackFilters filters: EditingStack.Edit.Filters,
    idPrefix: String = "editing-stack-filter"
  ) throws -> [ImageEffectFeature] {
    var idFactory = ParametricFeatureIDFactory(prefix: idPrefix)
    var effects: [ImageEffectFeature] = []

    if let preset = filters.preset {
      effects.append(
        try makeFeature(
          preset: preset,
          id: idFactory.next("preset"),
          idFactory: &idFactory
        )
      )
    }

    if let filter = filters.exposure {
      effects.append(.exposure(ExposureFeature(id: idFactory.next("exposure"), value: filter.value)))
    }

    if let filter = filters.brightness {
      effects.append(.brightness(BrightnessFeature(id: idFactory.next("brightness"), value: filter.value)))
    }

    if let filter = filters.temperature {
      effects.append(.temperature(TemperatureFeature(id: idFactory.next("temperature"), value: filter.value)))
    }

    if let filter = filters.highlights {
      effects.append(.highlights(HighlightsFeature(id: idFactory.next("highlights"), value: filter.value)))
    }

    if let filter = filters.shadows {
      effects.append(.shadows(ShadowsFeature(id: idFactory.next("shadows"), value: filter.value)))
    }

    if let filter = filters.saturation {
      effects.append(.saturation(SaturationFeature(id: idFactory.next("saturation"), value: filter.value)))
    }

    if let filter = filters.contrast {
      effects.append(.contrast(ContrastFeature(id: idFactory.next("contrast"), value: filter.value)))
    }

    if let filter = filters.sharpen {
      effects.append(
        .sharpen(
          SharpenFeature(
            id: idFactory.next("sharpen"),
            sharpness: filter.sharpness,
            radius: filter.radius
          )
        )
      )
    }

    if let filter = filters.unsharpMask {
      effects.append(
        .unsharpMask(
          UnsharpMaskFeature(
            id: idFactory.next("unsharp-mask"),
            intensity: filter.intensity,
            radius: filter.radius
          )
        )
      )
    }

    if let filter = filters.gaussianBlur {
      effects.append(
        .gaussianBlur(
          GaussianBlurFeature(
            id: idFactory.next("gaussian-blur"),
            value: filter.value
          )
        )
      )
    }

    if let filter = filters.fade {
      effects.append(.fade(FadeFeature(id: idFactory.next("fade"), intensity: filter.intensity)))
    }

    if let filter = filters.vignette {
      effects.append(.vignette(VignetteFeature(id: idFactory.next("vignette"), value: filter.value)))
    }

    for filter in filters.additionalFilters {
      effects.append(
        try makeFeature(
          anyFilter: filter,
          idFactory: &idFactory
        )
      )
    }

    return effects
  }
}

public extension ColorCubeFeature {

  /// Creates a parametric color-cube feature from Brightroom's existing
  /// `FilterColorCube`.
  ///
  /// Image-backed LUTs are serialized to cube data during conversion. Rendering
  /// then uses the stored data directly and does not materialize a CGImage.
  init(
    id: FeatureID = .init(),
    isEnabled: Bool = true,
    filter: FilterColorCube
  ) throws {
    let cubeData: Data
    switch filter.lookupTable {
    case let .cubeData(data, _):
      cubeData = data
    case let .image(imageSource, dimension):
      do {
        cubeData = try ColorCubeHelper.createColorCubeData(
          inputImage: imageSource.loadOriginalCGImage(),
          cubeDimension: dimension
        )
      } catch {
        throw ParametricEditingStackBridgeError.failedToCreateColorCubeData(
          identifier: filter.identifier,
          message: String(describing: error)
        )
      }
    }

    self.init(
      id: id,
      isEnabled: isEnabled,
      name: filter.name,
      identifier: filter.identifier,
      amount: filter.amount,
      dimension: filter.dimension,
      cubeData: cubeData
    )
  }
}

private extension ImageEffectFeature {

  static func makeFeature(
    anyFilter: AnyFilter,
    idFactory: inout ParametricFeatureIDFactory
  ) throws -> ImageEffectFeature {
    let base = anyFilter.base.base

    switch base {
    case let filter as FilterPreset:
      return try makeFeature(
        preset: filter,
        id: idFactory.next("preset"),
        idFactory: &idFactory
      )
    case let filter as FilterColorCube:
      return .colorCube(
        try ColorCubeFeature(
          id: idFactory.next("color-cube"),
          filter: filter
        )
      )
    case let filter as FilterExposure:
      return .exposure(ExposureFeature(id: idFactory.next("exposure"), value: filter.value))
    case let filter as FilterBrightness:
      return .brightness(BrightnessFeature(id: idFactory.next("brightness"), value: filter.value))
    case let filter as FilterTemperature:
      return .temperature(TemperatureFeature(id: idFactory.next("temperature"), value: filter.value))
    case let filter as FilterHighlights:
      return .highlights(HighlightsFeature(id: idFactory.next("highlights"), value: filter.value))
    case let filter as FilterShadows:
      return .shadows(ShadowsFeature(id: idFactory.next("shadows"), value: filter.value))
    case let filter as FilterHighlightShadowTint:
      return .highlightShadowTint(
        HighlightShadowTintFeature(
          id: idFactory.next("highlight-shadow-tint"),
          highlightColor: ParametricRGBAColor(color: filter.highlightColor),
          shadowColor: ParametricRGBAColor(color: filter.shadowColor)
        )
      )
    case let filter as FilterSaturation:
      return .saturation(SaturationFeature(id: idFactory.next("saturation"), value: filter.value))
    case let filter as FilterContrast:
      return .contrast(ContrastFeature(id: idFactory.next("contrast"), value: filter.value))
    case let filter as FilterSharpen:
      return .sharpen(
        SharpenFeature(
          id: idFactory.next("sharpen"),
          sharpness: filter.sharpness,
          radius: filter.radius
        )
      )
    case let filter as FilterUnsharpMask:
      return .unsharpMask(
        UnsharpMaskFeature(
          id: idFactory.next("unsharp-mask"),
          intensity: filter.intensity,
          radius: filter.radius
        )
      )
    case let filter as FilterGaussianBlur:
      return .gaussianBlur(
        GaussianBlurFeature(
          id: idFactory.next("gaussian-blur"),
          value: filter.value
        )
      )
    case let filter as FilterFade:
      return .fade(FadeFeature(id: idFactory.next("fade"), intensity: filter.intensity))
    case let filter as FilterVignette:
      return .vignette(VignetteFeature(id: idFactory.next("vignette"), value: filter.value))
    default:
      throw ParametricEditingStackBridgeError.unsupportedFilter(
        String(describing: type(of: base))
      )
    }
  }

  static func makeFeature(
    preset: FilterPreset,
    id: FeatureID,
    idFactory: inout ParametricFeatureIDFactory
  ) throws -> ImageEffectFeature {
    let effects = try preset.filters.map { filter in
      try makeFeature(anyFilter: filter, idFactory: &idFactory)
    }

    return .preset(
      PresetFeature(
        id: id,
        name: preset.name,
        identifier: preset.identifier,
        effects: effects
      )
    )
  }
}

private extension ParametricRGBAColor {

  init(color: CIColor) {
    self.init(
      red: Double(color.red),
      green: Double(color.green),
      blue: Double(color.blue),
      alpha: Double(color.alpha)
    )
  }
}

private struct ParametricFeatureIDFactory {

  var prefix: String
  private var index = 0

  init(prefix: String) {
    self.prefix = prefix
  }

  mutating func next(_ name: String) -> FeatureID {
    defer { index += 1 }
    return FeatureID(rawValue: "\(prefix)-\(index)-\(name)")
  }
}
