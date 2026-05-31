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

import CoreGraphics
import CoreImage
import Foundation

/// Brightroom's standard feature definitions.
///
/// These definitions are not special document cases. They are registered into
/// `FeatureRegistry` the same way an app can register its own feature types.
public enum BrightroomFeatureDefinitions {

  /// Current-domain crop.
  public enum Crop: DomainFeatureDefinition {

    public static let typeID: FeatureTypeID = "brightroom.domain.crop"
    public static let currentSchemaVersion = 1

    /// Serialized crop parameters.
    public struct Payload: Codable, Equatable, Sendable {

      /// The rectangle to keep, expressed in the current domain.
      public var cropRect: CGRect

      public init(cropRect: CGRect) {
        self.cropRect = cropRect
      }
    }

    public static func validate(payload: Payload, node: FeatureNode) throws {
      guard payload.cropRect.isParametricValidExtent else {
        throw FeatureGraphCompilerError.invalidCropRect(node.id, payload.cropRect)
      }
    }

    public static func apply(
      payload: Payload,
      node: FeatureNode,
      to image: CIImage,
      context: FeatureEvaluationContext
    ) throws -> CIImage {
      let cropRect = payload.cropRect
      let absoluteCropRect = cropRect.offsetBy(
        dx: image.extent.minX,
        dy: image.extent.minY
      )
      return image
        .cropped(to: absoluteCropRect)
        .transformed(
          by: CGAffineTransform(
            translationX: -absoluteCropRect.minX,
            y: -absoluteCropRect.minY
          )
        )
    }
  }

  /// A named group of extent-preserving image effects.
  public enum Preset: ImageEffectFeatureDefinition {

    public static let typeID: FeatureTypeID = "brightroom.effect.preset"
    public static let currentSchemaVersion = 1

    /// Serialized preset parameters.
    public struct Payload: Codable, Equatable, Sendable {

      /// The display name associated with the preset.
      public var name: String

      /// The stable preset identifier.
      public var identifier: String

      /// The effect nodes evaluated inside the preset, in order.
      public var effects: [FeatureNode]

      public init(
        name: String,
        identifier: String,
        effects: [FeatureNode]
      ) {
        self.name = name
        self.identifier = identifier
        self.effects = effects
      }
    }

    public static func childImageEffects(payload: Payload) -> [FeatureNode] {
      payload.effects
    }

    public static func apply(
      payload: Payload,
      node: FeatureNode,
      to image: CIImage,
      context: FeatureEvaluationContext
    ) throws -> CIImage {
      try payload.effects.reduce(image) { image, effect in
        try context.featureRegistry.applyImageEffect(effect, to: image, context: context)
      }
    }
  }

  /// A color-cube lookup-table effect.
  public enum ColorCube: ImageEffectFeatureDefinition {

    public static let typeID: FeatureTypeID = "brightroom.effect.colorCube"
    public static let currentSchemaVersion = 1

    /// Serialized color-cube parameters.
    public struct Payload: Codable, Equatable, Sendable {

      /// The display name associated with the lookup table.
      public var name: String

      /// The stable lookup-table identifier.
      public var identifier: String

      /// The opacity used when compositing the color-cube result over its input.
      public var amount: Double

      /// The color-cube dimension.
      public var dimension: Int

      /// RGBA float cube data in `CIColorCubeWithColorSpace` layout.
      public var cubeData: Data

      public init(
        name: String,
        identifier: String,
        amount: Double,
        dimension: Int,
        cubeData: Data
      ) {
        self.name = name
        self.identifier = identifier
        self.amount = amount
        self.dimension = dimension
        self.cubeData = cubeData
      }
    }

    public static func validate(payload: Payload, node: FeatureNode) throws {
      let expectedByteCount = colorCubeByteCount(dimension: payload.dimension)
      guard payload.cubeData.count == expectedByteCount else {
        throw FeatureGraphCompilerError.invalidColorCubeData(
          node.id,
          expectedByteCount: expectedByteCount,
          actualByteCount: payload.cubeData.count
        )
      }
    }

    public static func apply(
      payload: Payload,
      node: FeatureNode,
      to image: CIImage,
      context: FeatureEvaluationContext
    ) throws -> CIImage {
      let filter = ParametricColorCubeHelper.makeColorCubeFilter(
        cubeData: payload.cubeData,
        dimension: payload.dimension,
        cacheKey: payload.identifier
      )
      filter.setValue(image, forKeyPath: kCIInputImageKey)

      guard let filtered = filter.outputImage else {
        throw FeatureGraphCompilerError.failedToCreateImage("CIColorCubeWithColorSpace")
      }

      let foreground = filtered.applyingFilter(
        "CIColorMatrix",
        parameters: [
          "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
          "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
          "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
          "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(payload.amount)),
          "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ]
      )

      guard let output = CIFilter(
        name: "CISourceOverCompositing",
        parameters: [
          kCIInputImageKey: foreground,
          kCIInputBackgroundImageKey: image,
        ]
      )?.outputImage else {
        throw FeatureGraphCompilerError.failedToCreateImage("CISourceOverCompositing")
      }

      return output.cropped(to: image.extent)
    }
  }

  /// Brightness adjustment.
  public enum Brightness: ImageEffectFeatureDefinition {

    public static let typeID: FeatureTypeID = "brightroom.effect.brightness"
    public static let currentSchemaVersion = 1

    public struct Payload: Codable, Equatable, Sendable {
      public var value: Double
      public init(value: Double) { self.value = value }
    }

    public static func apply(
      payload: Payload,
      node: FeatureNode,
      to image: CIImage,
      context: FeatureEvaluationContext
    ) throws -> CIImage {
      image.applyingFilter(
        "CIColorControls",
        parameters: ["inputBrightness": payload.value]
      )
      .cropped(to: image.extent)
    }
  }

  /// Contrast adjustment.
  public enum Contrast: ImageEffectFeatureDefinition {

    public static let typeID: FeatureTypeID = "brightroom.effect.contrast"
    public static let currentSchemaVersion = 1

    public struct Payload: Codable, Equatable, Sendable {
      public var value: Double
      public init(value: Double) { self.value = value }
    }

    public static func apply(
      payload: Payload,
      node: FeatureNode,
      to image: CIImage,
      context: FeatureEvaluationContext
    ) throws -> CIImage {
      image.applyingFilter(
        "CIColorControls",
        parameters: [kCIInputContrastKey: 1 + payload.value]
      )
      .cropped(to: image.extent)
    }
  }

  /// Saturation adjustment.
  public enum Saturation: ImageEffectFeatureDefinition {

    public static let typeID: FeatureTypeID = "brightroom.effect.saturation"
    public static let currentSchemaVersion = 1

    public struct Payload: Codable, Equatable, Sendable {
      public var value: Double
      public init(value: Double) { self.value = value }
    }

    public static func apply(
      payload: Payload,
      node: FeatureNode,
      to image: CIImage,
      context: FeatureEvaluationContext
    ) throws -> CIImage {
      image.applyingFilter(
        "CIColorControls",
        parameters: [kCIInputSaturationKey: 1 + payload.value]
      )
      .cropped(to: image.extent)
    }
  }

  /// Exposure adjustment.
  public enum Exposure: ImageEffectFeatureDefinition {

    public static let typeID: FeatureTypeID = "brightroom.effect.exposure"
    public static let currentSchemaVersion = 1

    public struct Payload: Codable, Equatable, Sendable {
      public var value: Double
      public init(value: Double) { self.value = value }
    }

    public static func apply(
      payload: Payload,
      node: FeatureNode,
      to image: CIImage,
      context: FeatureEvaluationContext
    ) throws -> CIImage {
      guard abs(payload.value) > 0.0001 else {
        return image
      }
      return image.applyingFilter(
        "CIExposureAdjust",
        parameters: [kCIInputEVKey: payload.value]
      )
      .cropped(to: image.extent)
    }
  }

  /// Highlight recovery adjustment.
  public enum Highlights: ImageEffectFeatureDefinition {

    public static let typeID: FeatureTypeID = "brightroom.effect.highlights"
    public static let currentSchemaVersion = 1

    public struct Payload: Codable, Equatable, Sendable {
      public var value: Double
      public init(value: Double) { self.value = value }
    }

    public static func apply(
      payload: Payload,
      node: FeatureNode,
      to image: CIImage,
      context: FeatureEvaluationContext
    ) throws -> CIImage {
      image.applyingFilter(
        "CIHighlightShadowAdjust",
        parameters: ["inputHighlightAmount": 1 - payload.value]
      )
      .cropped(to: image.extent)
    }
  }

  /// Shadow lift adjustment.
  public enum Shadows: ImageEffectFeatureDefinition {

    public static let typeID: FeatureTypeID = "brightroom.effect.shadows"
    public static let currentSchemaVersion = 1

    public struct Payload: Codable, Equatable, Sendable {
      public var value: Double
      public init(value: Double) { self.value = value }
    }

    public static func apply(
      payload: Payload,
      node: FeatureNode,
      to image: CIImage,
      context: FeatureEvaluationContext
    ) throws -> CIImage {
      image.applyingFilter(
        "CIHighlightShadowAdjust",
        parameters: ["inputShadowAmount": payload.value]
      )
      .cropped(to: image.extent)
    }
  }

  /// Highlight and shadow tint overlay.
  public enum HighlightShadowTint: ImageEffectFeatureDefinition {

    public static let typeID: FeatureTypeID = "brightroom.effect.highlightShadowTint"
    public static let currentSchemaVersion = 1

    public struct Payload: Codable, Equatable, Sendable {
      public var highlightColor: ParametricRGBAColor
      public var shadowColor: ParametricRGBAColor
      public init(
        highlightColor: ParametricRGBAColor,
        shadowColor: ParametricRGBAColor
      ) {
        self.highlightColor = highlightColor
        self.shadowColor = shadowColor
      }
    }

    public static func apply(
      payload: Payload,
      node: FeatureNode,
      to image: CIImage,
      context: FeatureEvaluationContext
    ) throws -> CIImage {
      let shadow = CIImage(color: payload.shadowColor.ciColor)
        .cropped(to: image.extent)
      guard let shadowOutput = CIFilter(
        name: "CISourceOverCompositing",
        parameters: [
          kCIInputImageKey: shadow,
          kCIInputBackgroundImageKey: image,
        ]
      )?.outputImage else {
        throw FeatureGraphCompilerError.failedToCreateImage("CISourceOverCompositing")
      }

      let highlight = CIImage(color: payload.highlightColor.ciColor)
        .cropped(to: image.extent)
      guard let highlightOutput = CIFilter(
        name: "CISourceOverCompositing",
        parameters: [
          kCIInputImageKey: highlight,
          kCIInputBackgroundImageKey: shadowOutput,
        ]
      )?.outputImage else {
        throw FeatureGraphCompilerError.failedToCreateImage("CISourceOverCompositing")
      }

      return highlightOutput.cropped(to: image.extent)
    }
  }

  /// Color temperature adjustment.
  public enum Temperature: ImageEffectFeatureDefinition {

    public static let typeID: FeatureTypeID = "brightroom.effect.temperature"
    public static let currentSchemaVersion = 1

    public struct Payload: Codable, Equatable, Sendable {
      public var value: Double
      public init(value: Double) { self.value = value }
    }

    public static func apply(
      payload: Payload,
      node: FeatureNode,
      to image: CIImage,
      context: FeatureEvaluationContext
    ) throws -> CIImage {
      image.applyingFilter(
        "CITemperatureAndTint",
        parameters: [
          "inputNeutral": CIVector(x: CGFloat(payload.value) + 6500, y: 0),
          "inputTargetNeutral": CIVector(x: 6500, y: 0),
        ]
      )
      .cropped(to: image.extent)
    }
  }

  /// Luminance sharpen adjustment.
  public enum Sharpen: ImageEffectFeatureDefinition {

    public static let typeID: FeatureTypeID = "brightroom.effect.sharpen"
    public static let currentSchemaVersion = 1

    public struct Payload: Codable, Equatable, Sendable {
      public var sharpness: Double
      public var radius: Double
      public init(sharpness: Double, radius: Double) {
        self.sharpness = sharpness
        self.radius = radius
      }
    }

    public static func apply(
      payload: Payload,
      node: FeatureNode,
      to image: CIImage,
      context: FeatureEvaluationContext
    ) throws -> CIImage {
      let radius = ParametricRadiusCalculator.radius(
        value: payload.radius,
        max: ParametricFilterConstants.gaussianBlurSliderMax,
        imageExtent: image.extent
      )
      return image.applyingFilter(
        "CISharpenLuminance",
        parameters: [
          "inputRadius": radius,
          "inputSharpness": payload.sharpness,
        ]
      )
      .cropped(to: image.extent)
    }
  }

  /// Gaussian blur adjustment.
  public enum GaussianBlur: ImageEffectFeatureDefinition {

    public static let typeID: FeatureTypeID = "brightroom.effect.gaussianBlur"
    public static let currentSchemaVersion = 1

    public struct Payload: Codable, Equatable, Sendable {
      public var radius: GaussianBlurRadius
      public init(radius: GaussianBlurRadius) {
        self.radius = radius
      }
    }

    public static func apply(
      payload: Payload,
      node: FeatureNode,
      to image: CIImage,
      context: FeatureEvaluationContext
    ) throws -> CIImage {
      let radius = resolve(payload.radius, extent: image.extent)
      guard radius > 0.0001 else {
        return image
      }
      return image
        .clamped(to: image.extent)
        .applyingFilter(
          "CIGaussianBlur",
          parameters: [kCIInputRadiusKey: radius]
        )
        .cropped(to: image.extent)
    }
  }

  /// Unsharp mask adjustment.
  public enum UnsharpMask: ImageEffectFeatureDefinition {

    public static let typeID: FeatureTypeID = "brightroom.effect.unsharpMask"
    public static let currentSchemaVersion = 1

    public struct Payload: Codable, Equatable, Sendable {
      public var intensity: Double
      public var radius: Double
      public init(intensity: Double, radius: Double) {
        self.intensity = intensity
        self.radius = radius
      }
    }

    public static func apply(
      payload: Payload,
      node: FeatureNode,
      to image: CIImage,
      context: FeatureEvaluationContext
    ) throws -> CIImage {
      let radius = ParametricRadiusCalculator.radius(
        value: payload.radius,
        max: ParametricFilterConstants.unsharpMaskRadiusSliderMax,
        imageExtent: image.extent
      )
      return image.applyingFilter(
        "CIUnsharpMask",
        parameters: [
          "inputIntensity": payload.intensity,
          "inputRadius": radius,
        ]
      )
      .cropped(to: image.extent)
    }
  }

  /// Vignette adjustment.
  public enum Vignette: ImageEffectFeatureDefinition {

    public static let typeID: FeatureTypeID = "brightroom.effect.vignette"
    public static let currentSchemaVersion = 1

    public struct Payload: Codable, Equatable, Sendable {
      public var value: Double
      public init(value: Double) { self.value = value }
    }

    public static func apply(
      payload: Payload,
      node: FeatureNode,
      to image: CIImage,
      context: FeatureEvaluationContext
    ) throws -> CIImage {
      let radius = ParametricRadiusCalculator.radius(
        value: payload.value,
        max: ParametricFilterConstants.vignetteSliderMax,
        imageExtent: image.extent
      )
      return image.applyingFilter(
        "CIVignette",
        parameters: [
          kCIInputRadiusKey: radius,
          kCIInputIntensityKey: payload.value,
        ]
      )
      .cropped(to: image.extent)
    }
  }

  /// Fade adjustment.
  public enum Fade: ImageEffectFeatureDefinition {

    public static let typeID: FeatureTypeID = "brightroom.effect.fade"
    public static let currentSchemaVersion = 1

    public struct Payload: Codable, Equatable, Sendable {
      public var intensity: Double
      public init(intensity: Double) { self.intensity = intensity }
    }

    public static func apply(
      payload: Payload,
      node: FeatureNode,
      to image: CIImage,
      context: FeatureEvaluationContext
    ) throws -> CIImage {
      let foreground = CIImage(
        color: CIColor(
          red: 1,
          green: 1,
          blue: 1,
          alpha: CGFloat(payload.intensity)
        )
      )
      .cropped(to: image.extent)

      guard let output = CIFilter(
        name: "CISourceOverCompositing",
        parameters: [
          kCIInputImageKey: foreground,
          kCIInputBackgroundImageKey: image,
        ]
      )?.outputImage else {
        throw FeatureGraphCompilerError.failedToCreateImage("CISourceOverCompositing")
      }

      return output.cropped(to: image.extent)
    }
  }

  /// Brush-stroke mask.
  public enum BrushMask: MaskFeatureDefinition {

    public static let typeID: FeatureTypeID = "brightroom.mask.brush"
    public static let currentSchemaVersion = 1

    public struct Payload: Codable, Equatable, Sendable {
      public var strokes: [BrushMaskStroke]
      public init(strokes: [BrushMaskStroke]) {
        self.strokes = strokes
      }
    }

    public static func renderMask(
      payload: Payload,
      node: FeatureNode,
      extent: CGRect,
      context: FeatureEvaluationContext
    ) throws -> CIImage {
      guard node.isEnabled else {
        return CIImage.parametricTransparent(extent: extent)
      }

      var accumulated = CIImage.parametricTransparent(extent: extent)
      for stroke in payload.strokes {
        let radius = max(stroke.brush.diameter / 2, 0)
        for stamp in stroke.stamps {
          let stampImage = try context.kernelRegistry.makeBrushStamp(
            extent: extent,
            center: stamp,
            radius: radius,
            hardness: stroke.brush.hardness,
            opacity: stroke.brush.opacity
          )
          accumulated = try blendMask(
            foreground: stampImage,
            background: accumulated,
            kernel: .componentMax,
            extent: extent
          )
        }
      }
      return accumulated.cropped(to: extent)
    }
  }

  /// Inverted mask.
  public enum InvertMask: MaskFeatureDefinition {

    public static let typeID: FeatureTypeID = "brightroom.mask.invert"
    public static let currentSchemaVersion = 1

    public struct Payload: Codable, Equatable, Sendable {
      public var input: FeatureNode
      public init(input: FeatureNode) {
        self.input = input
      }
    }

    public static func childMasks(payload: Payload) -> [FeatureNode] {
      [payload.input]
    }

    public static func renderMask(
      payload: Payload,
      node: FeatureNode,
      extent: CGRect,
      context: FeatureEvaluationContext
    ) throws -> CIImage {
      let inputImage = try context.featureRegistry.renderMask(payload.input, extent: extent, context: context)
      guard node.isEnabled else {
        return inputImage
      }
      return inputImage.applyingFilter(
        "CIColorMatrix",
        parameters: [
          "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
          "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
          "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
          "inputAVector": CIVector(x: 0, y: 0, z: 0, w: -1),
          "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 1),
        ]
      )
      .cropped(to: extent)
    }
  }

  /// Feathered mask.
  public enum FeatherMask: MaskFeatureDefinition {

    public static let typeID: FeatureTypeID = "brightroom.mask.feather"
    public static let currentSchemaVersion = 1

    public struct Payload: Codable, Equatable, Sendable {
      public var input: FeatureNode
      public var radius: Double
      public init(input: FeatureNode, radius: Double) {
        self.input = input
        self.radius = radius
      }
    }

    public static func childMasks(payload: Payload) -> [FeatureNode] {
      [payload.input]
    }

    public static func renderMask(
      payload: Payload,
      node: FeatureNode,
      extent: CGRect,
      context: FeatureEvaluationContext
    ) throws -> CIImage {
      let inputImage = try context.featureRegistry.renderMask(payload.input, extent: extent, context: context)
      guard node.isEnabled, payload.radius > 0.0001 else {
        return inputImage
      }
      return inputImage
        .clamped(to: extent)
        .applyingFilter(
          "CIGaussianBlur",
          parameters: [kCIInputRadiusKey: payload.radius]
        )
        .cropped(to: extent)
    }
  }

  /// Union mask compositor.
  public enum UnionMask: MaskFeatureDefinition {

    public static let typeID: FeatureTypeID = "brightroom.mask.union"
    public static let currentSchemaVersion = 1

    public struct Payload: Codable, Equatable, Sendable {
      public var nodes: [FeatureNode]
      public init(nodes: [FeatureNode]) {
        self.nodes = nodes
      }
    }

    public static func validate(payload: Payload, node: FeatureNode) throws {
      guard payload.nodes.isEmpty == false else {
        throw FeatureGraphCompilerError.emptyMaskComposite(node.id)
      }
    }

    public static func childMasks(payload: Payload) -> [FeatureNode] {
      payload.nodes
    }

    public static func renderMask(
      payload: Payload,
      node: FeatureNode,
      extent: CGRect,
      context: FeatureEvaluationContext
    ) throws -> CIImage {
      guard node.isEnabled else {
        return CIImage.parametricTransparent(extent: extent)
      }
      return try payload.nodes.reduce(CIImage.parametricTransparent(extent: extent)) { accumulated, node in
        let next = try context.featureRegistry.renderMask(node, extent: extent, context: context)
        return try blendMask(
          foreground: next,
          background: accumulated,
          kernel: .componentMax,
          extent: extent
        )
      }
    }
  }

  /// Intersection mask compositor.
  public enum IntersectMask: MaskFeatureDefinition {

    public static let typeID: FeatureTypeID = "brightroom.mask.intersect"
    public static let currentSchemaVersion = 1

    public struct Payload: Codable, Equatable, Sendable {
      public var nodes: [FeatureNode]
      public init(nodes: [FeatureNode]) {
        self.nodes = nodes
      }
    }

    public static func validate(payload: Payload, node: FeatureNode) throws {
      guard payload.nodes.isEmpty == false else {
        throw FeatureGraphCompilerError.emptyMaskComposite(node.id)
      }
    }

    public static func childMasks(payload: Payload) -> [FeatureNode] {
      payload.nodes
    }

    public static func renderMask(
      payload: Payload,
      node: FeatureNode,
      extent: CGRect,
      context: FeatureEvaluationContext
    ) throws -> CIImage {
      guard node.isEnabled else {
        return CIImage.parametricTransparent(extent: extent)
      }
      guard let first = payload.nodes.first else {
        throw FeatureGraphCompilerError.emptyMaskComposite(node.id)
      }
      var accumulated = try context.featureRegistry.renderMask(first, extent: extent, context: context)
      for node in payload.nodes.dropFirst() {
        let next = try context.featureRegistry.renderMask(node, extent: extent, context: context)
        accumulated = try blendMask(
          foreground: next,
          background: accumulated,
          kernel: .componentMultiply,
          extent: extent
        )
      }
      return accumulated.cropped(to: extent)
    }
  }

  /// Subtract mask compositor.
  public enum SubtractMask: MaskFeatureDefinition {

    public static let typeID: FeatureTypeID = "brightroom.mask.subtract"
    public static let currentSchemaVersion = 1

    public struct Payload: Codable, Equatable, Sendable {
      public var base: FeatureNode
      public var removing: FeatureNode
      public init(base: FeatureNode, removing: FeatureNode) {
        self.base = base
        self.removing = removing
      }
    }

    public static func childMasks(payload: Payload) -> [FeatureNode] {
      [payload.base, payload.removing]
    }

    public static func renderMask(
      payload: Payload,
      node: FeatureNode,
      extent: CGRect,
      context: FeatureEvaluationContext
    ) throws -> CIImage {
      let base = try context.featureRegistry.renderMask(payload.base, extent: extent, context: context)
      guard node.isEnabled else {
        return base
      }
      let removing = try context.featureRegistry.renderMask(payload.removing, extent: extent, context: context)
      return try context.kernelRegistry.subtractMask(
        base: base,
        removing: removing,
        extent: extent
      )
    }
  }
}

public extension FeatureRegistry {

  /// Brightroom's standard registry.
  ///
  /// Apps can start with this registry and register their own feature
  /// definitions beside Brightroom's definitions.
  static var brightroomDefault: FeatureRegistry {
    var registry = FeatureRegistry()
    registry.registerDomainFeature(BrightroomFeatureDefinitions.Crop.self)
    registry.registerImageEffect(BrightroomFeatureDefinitions.Preset.self)
    registry.registerImageEffect(BrightroomFeatureDefinitions.ColorCube.self)
    registry.registerImageEffect(BrightroomFeatureDefinitions.Brightness.self)
    registry.registerImageEffect(BrightroomFeatureDefinitions.Contrast.self)
    registry.registerImageEffect(BrightroomFeatureDefinitions.Saturation.self)
    registry.registerImageEffect(BrightroomFeatureDefinitions.Exposure.self)
    registry.registerImageEffect(BrightroomFeatureDefinitions.Highlights.self)
    registry.registerImageEffect(BrightroomFeatureDefinitions.Shadows.self)
    registry.registerImageEffect(BrightroomFeatureDefinitions.HighlightShadowTint.self)
    registry.registerImageEffect(BrightroomFeatureDefinitions.Temperature.self)
    registry.registerImageEffect(BrightroomFeatureDefinitions.Sharpen.self)
    registry.registerImageEffect(BrightroomFeatureDefinitions.GaussianBlur.self)
    registry.registerImageEffect(BrightroomFeatureDefinitions.UnsharpMask.self)
    registry.registerImageEffect(BrightroomFeatureDefinitions.Vignette.self)
    registry.registerImageEffect(BrightroomFeatureDefinitions.Fade.self)
    registry.registerMask(BrightroomFeatureDefinitions.BrushMask.self)
    registry.registerMask(BrightroomFeatureDefinitions.InvertMask.self)
    registry.registerMask(BrightroomFeatureDefinitions.FeatherMask.self)
    registry.registerMask(BrightroomFeatureDefinitions.UnionMask.self)
    registry.registerMask(BrightroomFeatureDefinitions.IntersectMask.self)
    registry.registerMask(BrightroomFeatureDefinitions.SubtractMask.self)
    return registry
  }
}

private func resolve(_ radius: GaussianBlurRadius, extent: CGRect) -> Double {
  switch radius {
  case let .absolute(value):
    value
  case let .editingStackFilterValue(value):
    ParametricRadiusCalculator.radius(
      value: value,
      max: ParametricFilterConstants.gaussianBlurSliderMax,
      imageExtent: extent
    )
  }
}

private func colorCubeByteCount(dimension: Int) -> Int {
  dimension * dimension * dimension * 4 * MemoryLayout<Float>.size
}

private func blendMask(
  foreground: CIImage,
  background: CIImage,
  kernel: CIBlendKernel,
  extent: CGRect
) throws -> CIImage {
  guard let output = kernel.apply(
    foreground: foreground,
    background: background
  ) else {
    throw FeatureGraphCompilerError.failedToCreateImage("CIBlendKernel")
  }
  return output.cropped(to: extent)
}

private extension ParametricRGBAColor {

  var ciColor: CIColor {
    CIColor(
      red: CGFloat(red),
      green: CGFloat(green),
      blue: CGFloat(blue),
      alpha: CGFloat(alpha)
    )
  }
}

private extension CGRect {

  var isParametricValidExtent: Bool {
    origin.x.isFinite
      && origin.y.isFinite
      && size.width.isFinite
      && size.height.isFinite
      && size.width > 0
      && size.height > 0
  }
}
