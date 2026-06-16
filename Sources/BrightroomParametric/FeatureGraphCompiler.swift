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
///
/// Feature evaluation is native protocol dispatch: effects and domain features
/// implement `apply(to:context:)` themselves. The compiler owns the document
/// walk, tree-level validation, local-adjustment compositing, and the
/// mask-tree renderer.
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

  /// Creates a feature graph compiler.
  public init(
    options: Options = .init(),
    kernelRegistry: ParametricKernelRegistry = .init()
  ) {
    self.options = options
    self.kernelRegistry = kernelRegistry
  }

  /// Compiles and evaluates a document from an input image.
  ///
  /// - Parameters:
  ///   - input: The source image used as the first graph node.
  ///   - document: The parametric document to evaluate.
  /// - Returns: The final image recipe and debug mask outputs.
  public func makeOutput(
    from input: CIImage,
    document: EditingDocument,
    radiusReferenceExtent: CGRect? = nil
  ) throws -> FeatureGraphOutput {
    try validate(document)

    let context = FeatureEvaluationContext(
      kernelRegistry: kernelRegistry,
      radiusReferenceExtent: radiusReferenceExtent
    )
    var image = options.normalizesInputExtent ? ParametricImageGeometry.removingExtentOffset(input) : input
    var localAdjustmentMasks: [FeatureID: CIImage] = [:]

    for feature in document.mainTree.features where feature.isEnabled {
      switch feature {
      case let .domain(domainFeature):
        image = try domainFeature.apply(to: image, context: context)

      case let .effect(effect):
        image = try effect.apply(to: image, context: context)

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

  /// Renders a mask tree to an alpha image covering the given extent.
  ///
  /// Brush stamps are interpreted in Core Image working-space coordinates
  /// (bottom-left origin, y-up). Callers holding masks authored in a y-down
  /// display space flip at this boundary.
  public func renderMask(_ tree: MaskTree, extent: CGRect) throws -> CIImage {
    try render(tree, extent: extent)
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

  func apply(
    _ localAdjustment: LocalAdjustmentFeature,
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
      try effect.apply(to: image, context: context)
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

    // Each stamp compiles to one CIImage layer. `componentMax` is associative
    // and commutative, so the stamps reduce in any grouping; folding them in a
    // balanced tree keeps the Core Image graph depth at O(log n) instead of
    // O(n). A dense brush (small spacing) emits hundreds–thousands of stamps
    // per stroke, and a linear fold built a chain that deep — slow to compile
    // and at risk of stack overflow during render. The tree keeps the same
    // node count and the same result.
    var stampImages: [CIImage] = []
    for stroke in mask.strokes {
      let radius = max(stroke.brush.diameter / 2, 0)
      for stamp in stroke.stamps {
        stampImages.append(
          try kernelRegistry.makeBrushStamp(
            extent: extent,
            center: stamp,
            radius: radius,
            hardness: stroke.brush.hardness,
            opacity: stroke.brush.opacity
          )
        )
      }
    }

    return try reduceComponentMax(stampImages, extent: extent)
  }

  /// Reduces mask layers with `componentMax` in a balanced tree so the Core
  /// Image graph depth stays O(log n). `componentMax` is associative and
  /// commutative and `componentMax(transparent, x) == x`, so the pairwise
  /// grouping produces the same alpha field as a linear fold over a transparent
  /// base.
  private func reduceComponentMax(_ images: [CIImage], extent: CGRect) throws -> CIImage {
    guard images.isEmpty == false else {
      return CIImage.parametricTransparent(extent: extent)
    }

    var level = images
    while level.count > 1 {
      var next: [CIImage] = []
      next.reserveCapacity((level.count + 1) / 2)
      var index = 0
      while index < level.count {
        if index + 1 < level.count {
          next.append(
            try blendMask(
              foreground: level[index + 1],
              background: level[index],
              kernel: .componentMax,
              extent: extent
            )
          )
        } else {
          next.append(level[index])
        }
        index += 2
      }
      level = next
    }

    return level[0].cropped(to: extent)
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
      case let .domain(domainFeature):
        try domainFeature.validate()

      case let .effect(effect):
        try effect.validate()
        try validateChildren(of: effect, insert: insert)

      case let .localAdjustment(localAdjustment):
        let enabledEffects = localAdjustment.effectPipeline.effects.filter(\.isEnabled)
        guard enabledEffects.isEmpty == false else {
          throw FeatureGraphCompilerError.emptyLocalAdjustmentEffectPipeline(localAdjustment.id)
        }

        for effect in localAdjustment.effectPipeline.effects {
          try insert(effect.id)
          try effect.validate()
          try validateChildren(of: effect, insert: insert)
        }
        try validate(localAdjustment.maskTree.root, insert: insert)
      }
    }
  }

  func validateChildren(
    of effect: any ImageEffectFeatureType,
    insert: (FeatureID) throws -> Void
  ) throws {
    for child in effect.childFeatures {
      try insert(child.id)
      if let childEffect = child as? any ImageEffectFeatureType {
        try childEffect.validate()
        try validateChildren(of: childEffect, insert: insert)
      }
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
