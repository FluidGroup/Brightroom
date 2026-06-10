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

/// Compiles a parametric editing document into a Core Image graph.
///
/// The compiler returns `CIImage` recipes and does not create intermediate
/// `CGImage` or `CGContext` values. Callers choose when and how to materialize
/// the returned image through `CIContext`.
public struct FeatureGraphCompiler: Sendable {

  /// Rendering options for the feature graph compiler.
  public struct Options: Equatable, Sendable {

    /// A Boolean value indicating whether the input image should be translated
    /// to zero origin before the first feature is evaluated.
    public var normalizesInputExtent: Bool

    /// Creates compiler options.
    public init(normalizesInputExtent: Bool = true) {
      self.normalizesInputExtent = normalizesInputExtent
    }
  }

  /// The options used during compilation.
  public var options: Options

  /// The kernel registry used for custom Core Image operations.
  public var kernelRegistry: ParametricKernelRegistry

  /// The feature registry used to resolve registry-backed feature nodes.
  public var featureRegistry: FeatureRegistry

  /// Creates a feature graph compiler.
  public init(
    options: Options = .init(),
    kernelRegistry: ParametricKernelRegistry = .init(),
    featureRegistry: FeatureRegistry = .brightroomDefault
  ) {
    self.options = options
    self.kernelRegistry = kernelRegistry
    self.featureRegistry = featureRegistry
  }

  /// Compiles and evaluates a document from an input image.
  ///
  /// - Parameters:
  ///   - input: The source image used as the first graph node.
  ///   - document: The parametric document to evaluate.
  /// - Returns: The final image recipe and debug mask outputs.
  public func makeOutput(
    from input: CIImage,
    document: EditingDocument
  ) throws -> FeatureGraphOutput {
    try validate(document)

    var image = options.normalizesInputExtent ? ParametricImageGeometry.removingExtentOffset(input) : input
    var localAdjustmentMasks: [FeatureID: CIImage] = [:]

    for feature in document.mainTree.features where feature.isEnabled {
      switch feature {
      case let .domain(domainFeature):
        image = try apply(domainFeature, to: image)

      case let .effect(effect):
        image = try apply(effect, to: image)

      case let .localAdjustment(localAdjustment):
        let output = try apply(localAdjustment, to: image)
        image = output.image
        localAdjustmentMasks[localAdjustment.id] = output.mask
      }
    }

    return FeatureGraphOutput(
      image: image,
      localAdjustmentMasks: localAdjustmentMasks
    )
  }

  /// Compiles and evaluates a registry-backed document from an input image.
  ///
  /// - Parameters:
  ///   - input: The source image used as the first graph node.
  ///   - document: The registry-backed parametric document to evaluate.
  /// - Returns: The final image recipe and debug mask outputs.
  public func makeOutput(
    from input: CIImage,
    document: FeatureDocument
  ) throws -> FeatureGraphOutput {
    try validate(document)

    let context = FeatureEvaluationContext(
      featureRegistry: featureRegistry,
      kernelRegistry: kernelRegistry
    )
    var image = options.normalizesInputExtent ? ParametricImageGeometry.removingExtentOffset(input) : input
    var localAdjustmentMasks: [FeatureID: CIImage] = [:]

    for feature in document.mainTree.features where feature.isEnabled {
      switch feature {
      case let .domain(node):
        image = try featureRegistry.applyDomainFeature(node, to: image, context: context)

      case let .effect(node):
        image = try featureRegistry.applyImageEffect(node, to: image, context: context)

      case let .localAdjustment(localAdjustment):
        let output = try apply(localAdjustment, to: image, context: context)
        image = output.image
        localAdjustmentMasks[localAdjustment.id] = output.mask
      }
    }

    return FeatureGraphOutput(
      image: image,
      localAdjustmentMasks: localAdjustmentMasks
    )
  }
}

/// The result of compiling a parametric feature graph.
public struct FeatureGraphOutput: Sendable {

  /// The final output image recipe.
  public var image: CIImage

  /// Evaluated local adjustment masks keyed by their owning feature ID.
  public var localAdjustmentMasks: [FeatureID: CIImage]

  /// Creates compiler output.
  public init(
    image: CIImage,
    localAdjustmentMasks: [FeatureID: CIImage] = [:]
  ) {
    self.image = image
    self.localAdjustmentMasks = localAdjustmentMasks
  }
}

/// Errors thrown while compiling a parametric feature graph.
public enum FeatureGraphCompilerError: Error, Equatable, Sendable {

  /// Two features or mask nodes use the same ID.
  case duplicateID(FeatureID)

  /// A local adjustment has no enabled effect to apply.
  case emptyLocalAdjustmentEffectPipeline(FeatureID)

  /// A composite mask operation has no children.
  case emptyMaskComposite(FeatureID?)

  /// A crop rectangle cannot produce a valid image extent.
  case invalidCropRect(FeatureID, CGRect)

  /// Core Image returned nil while applying a named filter or kernel.
  case failedToCreateImage(String)

  /// A color-cube feature contains data that cannot match its dimension.
  case invalidColorCubeData(FeatureID, expectedByteCount: Int, actualByteCount: Int)
}

private extension FeatureGraphCompiler {

  func apply(_ feature: DomainFeature, to image: CIImage) throws -> CIImage {
    switch feature {
    case let .crop(crop):
      guard crop.isEnabled else {
        return image
      }
      return try apply(crop, to: image)
    }
  }

  func apply(_ crop: CropFeature, to image: CIImage) throws -> CIImage {
    let cropRect = crop.cropRect
    guard cropRect.isParametricValidExtent else {
      throw FeatureGraphCompilerError.invalidCropRect(crop.id, cropRect)
    }

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

  func apply(_ effect: ImageEffectFeature, to image: CIImage) throws -> CIImage {
    guard effect.isEnabled else {
      return image
    }

    switch effect {
    case let .preset(feature):
      guard feature.isEnabled else {
        return image
      }
      return try feature.effects.reduce(image) { image, effect in
        try apply(effect, to: image)
      }

    case let .colorCube(feature):
      guard feature.isEnabled else {
        return image
      }
      return try apply(feature, to: image)

    case let .brightness(feature):
      return image.applyingFilter(
        "CIColorControls",
        parameters: ["inputBrightness": feature.value]
      )
      .cropped(to: image.extent)

    case let .contrast(feature):
      return image.applyingFilter(
        "CIColorControls",
        parameters: [kCIInputContrastKey: 1 + feature.value]
      )
      .cropped(to: image.extent)

    case let .saturation(feature):
      return image.applyingFilter(
        "CIColorControls",
        parameters: [kCIInputSaturationKey: 1 + feature.value]
      )
      .cropped(to: image.extent)

    case let .exposure(feature):
      guard abs(feature.value) > 0.0001 else {
        return image
      }
      return image.applyingFilter(
        "CIExposureAdjust",
        parameters: [kCIInputEVKey: feature.value]
      )
      .cropped(to: image.extent)

    case let .highlights(feature):
      return image.applyingFilter(
        "CIHighlightShadowAdjust",
        parameters: ["inputHighlightAmount": 1 - feature.value]
      )
      .cropped(to: image.extent)

    case let .shadows(feature):
      return image.applyingFilter(
        "CIHighlightShadowAdjust",
        parameters: ["inputShadowAmount": feature.value]
      )
      .cropped(to: image.extent)

    case let .highlightShadowTint(feature):
      return try apply(feature, to: image)

    case let .temperature(feature):
      return image.applyingFilter(
        "CITemperatureAndTint",
        parameters: [
          "inputNeutral": CIVector(x: CGFloat(feature.value) + 6500, y: 0),
          "inputTargetNeutral": CIVector(x: 6500, y: 0),
        ]
      )
      .cropped(to: image.extent)

    case let .sharpen(feature):
      let radius = ParametricRadiusCalculator.radius(
        value: feature.radius,
        max: ParametricFilterConstants.gaussianBlurSliderMax,
        imageExtent: image.extent
      )
      return image.applyingFilter(
        "CISharpenLuminance",
        parameters: [
          "inputRadius": radius,
          "inputSharpness": feature.sharpness,
        ]
      )
      .cropped(to: image.extent)

    case let .gaussianBlur(feature):
      let radius = resolve(feature.radius, extent: image.extent)
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

    case let .unsharpMask(feature):
      let radius = ParametricRadiusCalculator.radius(
        value: feature.radius,
        max: ParametricFilterConstants.unsharpMaskRadiusSliderMax,
        imageExtent: image.extent
      )
      return image.applyingFilter(
        "CIUnsharpMask",
        parameters: [
          "inputIntensity": feature.intensity,
          "inputRadius": radius,
        ]
      )
      .cropped(to: image.extent)

    case let .vignette(feature):
      return ParametricVignetteRenderer.apply(value: feature.value, to: image)

    case let .fade(feature):
      let foreground = CIImage(
        color: CIColor(
          red: 1,
          green: 1,
          blue: 1,
          alpha: CGFloat(feature.intensity)
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

  func apply(_ feature: ColorCubeFeature, to image: CIImage) throws -> CIImage {
    let expectedByteCount = colorCubeByteCount(dimension: feature.dimension)
    guard feature.cubeData.count == expectedByteCount else {
      throw FeatureGraphCompilerError.invalidColorCubeData(
        feature.id,
        expectedByteCount: expectedByteCount,
        actualByteCount: feature.cubeData.count
      )
    }

    let filter = ParametricColorCubeHelper.makeColorCubeFilter(
      cubeData: feature.cubeData,
      dimension: feature.dimension,
      cacheKey: feature.identifier
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
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(feature.amount)),
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

  func apply(_ feature: HighlightShadowTintFeature, to image: CIImage) throws -> CIImage {
    let shadow = CIImage(color: feature.shadowColor.ciColor)
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

    let highlight = CIImage(color: feature.highlightColor.ciColor)
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

  func apply(
    _ localAdjustment: LocalAdjustmentFeature,
    to base: CIImage
  ) throws -> (image: CIImage, mask: CIImage) {
    guard localAdjustment.isEnabled else {
      return (base, CIImage.parametricTransparent(extent: base.extent))
    }

    let enabledEffects = localAdjustment.effectPipeline.effects.filter(\.isEnabled)
    guard enabledEffects.isEmpty == false else {
      throw FeatureGraphCompilerError.emptyLocalAdjustmentEffectPipeline(localAdjustment.id)
    }

    let adjusted = try enabledEffects.reduce(base) { image, effect in
      try apply(effect, to: image)
    }
    let mask = try render(localAdjustment.maskTree, extent: base.extent)

    switch localAdjustment.blendMode {
    case .alpha:
      let composited = adjusted.applyingFilter(
        "CIBlendWithAlphaMask",
        parameters: [
          kCIInputBackgroundImageKey: base,
          kCIInputMaskImageKey: mask,
        ]
      )
      .cropped(to: base.extent)
      return (composited, mask)
    }
  }

  func apply(
    _ localAdjustment: FeatureLocalAdjustment,
    to base: CIImage,
    context: FeatureEvaluationContext
  ) throws -> (image: CIImage, mask: CIImage) {
    guard localAdjustment.isEnabled else {
      return (base, CIImage.parametricTransparent(extent: base.extent))
    }

    let enabledEffects = localAdjustment.effectPipeline.effects.filter(\.isEnabled)
    guard enabledEffects.isEmpty == false else {
      throw FeatureGraphCompilerError.emptyLocalAdjustmentEffectPipeline(localAdjustment.id)
    }

    let adjusted = try enabledEffects.reduce(base) { image, effect in
      try featureRegistry.applyImageEffect(effect, to: image, context: context)
    }
    let mask = try featureRegistry.renderMask(localAdjustment.mask, extent: base.extent, context: context)

    switch localAdjustment.blendMode {
    case .alpha:
      let composited = adjusted.applyingFilter(
        "CIBlendWithAlphaMask",
        parameters: [
          kCIInputBackgroundImageKey: base,
          kCIInputMaskImageKey: mask,
        ]
      )
      .cropped(to: base.extent)
      return (composited, mask)
    }
  }

  func render(_ maskTree: MaskTree, extent: CGRect) throws -> CIImage {
    try render(maskTree.root, extent: extent)
      .cropped(to: extent)
  }

  func render(_ node: MaskNode, extent: CGRect) throws -> CIImage {
    switch node {
    case let .brush(mask):
      return try render(mask, extent: extent)

    case let .invert(input):
      let inputImage = try render(input, extent: extent)
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

    case let .feather(feather):
      let inputImage = try render(feather.input, extent: extent)
      guard feather.isEnabled, feather.radius > 0.0001 else {
        return inputImage
      }
      return inputImage
        .clamped(to: extent)
        .applyingFilter(
          "CIGaussianBlur",
          parameters: [kCIInputRadiusKey: feather.radius]
        )
        .cropped(to: extent)

    case let .union(nodes):
      guard nodes.isEmpty == false else {
        throw FeatureGraphCompilerError.emptyMaskComposite(nil)
      }
      return try nodes.reduce(CIImage.parametricTransparent(extent: extent)) { accumulated, node in
        let next = try render(node, extent: extent)
        return try blendMask(
          foreground: next,
          background: accumulated,
          kernel: .componentMax,
          extent: extent
        )
      }

    case let .intersect(nodes):
      guard let first = nodes.first else {
        throw FeatureGraphCompilerError.emptyMaskComposite(nil)
      }
      var accumulated = try render(first, extent: extent)
      for node in nodes.dropFirst() {
        let next = try render(node, extent: extent)
        accumulated = try blendMask(
          foreground: next,
          background: accumulated,
          kernel: .componentMultiply,
          extent: extent
        )
      }
      return accumulated.cropped(to: extent)

    case let .subtract(subtract):
      let base = try render(subtract.base, extent: extent)
      guard subtract.isEnabled else {
        return base
      }
      let removing = try render(subtract.removing, extent: extent)
      return try kernelRegistry.subtractMask(
        base: base,
        removing: removing,
        extent: extent
      )
    }
  }

  func render(_ mask: BrushMask, extent: CGRect) throws -> CIImage {
    guard mask.isEnabled else {
      return CIImage.parametricTransparent(extent: extent)
    }

    var accumulated = CIImage.parametricTransparent(extent: extent)

    for stroke in mask.strokes {
      let radius = max(stroke.brush.diameter / 2, 0)
      for stamp in stroke.stamps {
        let stampImage = try kernelRegistry.makeBrushStamp(
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

  func blendMask(
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
}

private extension FeatureGraphCompiler {

  func validate(_ document: EditingDocument) throws {
    var ids = Set<FeatureID>()

    func insert(_ id: FeatureID) throws {
      guard ids.insert(id).inserted else {
        throw FeatureGraphCompilerError.duplicateID(id)
      }
    }

    for feature in document.mainTree.features {
      try insert(feature.id)

      switch feature {
      case let .domain(.crop(crop)):
        guard crop.cropRect.isParametricValidExtent else {
          throw FeatureGraphCompilerError.invalidCropRect(crop.id, crop.cropRect)
        }

      case .effect:
        break

      case let .localAdjustment(localAdjustment):
        let enabledEffects = localAdjustment.effectPipeline.effects.filter(\.isEnabled)
        guard enabledEffects.isEmpty == false else {
          throw FeatureGraphCompilerError.emptyLocalAdjustmentEffectPipeline(localAdjustment.id)
        }

        for effect in localAdjustment.effectPipeline.effects {
          try validate(effect, insert: insert)
        }
        try validate(localAdjustment.maskTree.root, insert: insert)
      }
    }
  }

  func validate(_ document: FeatureDocument) throws {
    var ids = Set<FeatureID>()

    func insert(_ id: FeatureID) throws {
      guard ids.insert(id).inserted else {
        throw FeatureGraphCompilerError.duplicateID(id)
      }
    }

    for feature in document.mainTree.features {
      switch feature {
      case let .domain(node):
        try validateDomainFeature(node, insert: insert)

      case let .effect(node):
        try validateImageEffect(node, insert: insert)

      case let .localAdjustment(localAdjustment):
        try insert(localAdjustment.id)

        let enabledEffects = localAdjustment.effectPipeline.effects.filter(\.isEnabled)
        guard enabledEffects.isEmpty == false else {
          throw FeatureGraphCompilerError.emptyLocalAdjustmentEffectPipeline(localAdjustment.id)
        }

        for effect in localAdjustment.effectPipeline.effects {
          try validateImageEffect(effect, insert: insert)
        }
        try validateMask(localAdjustment.mask, insert: insert)
      }
    }
  }

  func validateDomainFeature(
    _ node: FeatureNode,
    insert: (FeatureID) throws -> Void
  ) throws {
    try insert(node.id)
    try featureRegistry.domainDefinition(for: node).validate(node)
  }

  func validateImageEffect(
    _ node: FeatureNode,
    insert: (FeatureID) throws -> Void
  ) throws {
    try insert(node.id)
    let definition = try featureRegistry.imageEffectDefinition(for: node)
    try definition.validate(node)
    for child in try definition.childImageEffects(in: node) {
      try validateImageEffect(child, insert: insert)
    }
  }

  func validateMask(
    _ node: FeatureNode,
    insert: (FeatureID) throws -> Void
  ) throws {
    try insert(node.id)
    let definition = try featureRegistry.maskDefinition(for: node)
    try definition.validate(node)
    for child in try definition.childMasks(in: node) {
      try validateMask(child, insert: insert)
    }
  }

  func validate(
    _ effect: ImageEffectFeature,
    insert: (FeatureID) throws -> Void
  ) throws {
    try insert(effect.id)

    switch effect {
    case let .preset(preset):
      for effect in preset.effects {
        try validate(effect, insert: insert)
      }

    case let .colorCube(colorCube):
      let expectedByteCount = colorCubeByteCount(dimension: colorCube.dimension)
      guard colorCube.cubeData.count == expectedByteCount else {
        throw FeatureGraphCompilerError.invalidColorCubeData(
          colorCube.id,
          expectedByteCount: expectedByteCount,
          actualByteCount: colorCube.cubeData.count
        )
      }

    case .brightness,
      .contrast,
      .saturation,
      .exposure,
      .highlights,
      .shadows,
      .highlightShadowTint,
      .temperature,
      .sharpen,
      .gaussianBlur,
      .unsharpMask,
      .vignette,
      .fade:
      break
    }
  }

  func validate(
    _ node: MaskNode,
    insert: (FeatureID) throws -> Void
  ) throws {
    switch node {
    case let .brush(mask):
      try insert(mask.id)

    case let .invert(input):
      try validate(input, insert: insert)

    case let .feather(feather):
      try insert(feather.id)
      try validate(feather.input, insert: insert)

    case let .union(nodes):
      guard nodes.isEmpty == false else {
        throw FeatureGraphCompilerError.emptyMaskComposite(nil)
      }
      for node in nodes {
        try validate(node, insert: insert)
      }

    case let .intersect(nodes):
      guard nodes.isEmpty == false else {
        throw FeatureGraphCompilerError.emptyMaskComposite(nil)
      }
      for node in nodes {
        try validate(node, insert: insert)
      }

    case let .subtract(subtract):
      try insert(subtract.id)
      try validate(subtract.base, insert: insert)
      try validate(subtract.removing, insert: insert)
    }
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
