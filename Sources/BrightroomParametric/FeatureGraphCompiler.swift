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
import CoreMedia
import Foundation

/// Compiles a parametric editing document into a Core Image graph.
///
/// The compiler returns `CIImage` recipes and does not create intermediate
/// `CGImage` or `CGContext` values. Callers choose when and how to materialize
/// the returned image through `CIContext`.
///
/// Feature evaluation is native protocol dispatch: effects and domain features
/// implement `apply(to:context:)` themselves. The compiler owns the document
/// walk, tree-level validation, and local-adjustment compositing; masks render
/// through the mask-tree renderer shared with `LocalAdjustment`.
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
  ///   - radiusReferenceExtent: The extent that proportional (value-form)
  ///     radii resolve against. `nil` (the default) uses the render pass's
  ///     CHAIN-ENTRY extent — `input`'s extent after normalization — which is
  ///     the declared semantic: a value like `40` means the same fraction of
  ///     the source no matter where crops sit in the feature list, and stays
  ///     consistent between the downsampled preview and the full-resolution
  ///     export because each pass resolves against its own entry scale. Pass
  ///     an explicit extent only when `input` is NOT the chain entry (e.g. a
  ///     zoomed viewport slice of a larger source).
  ///   - presentationTime: The presentation time represented by `input`.
  /// - Returns: The final image recipe and debug mask outputs.
  public func makeOutput(
    from input: CIImage,
    document: EditingDocument,
    radiusReferenceExtent: CGRect? = nil,
    presentationTime: CMTime = .zero
  ) throws -> FeatureGraphOutput {
    try validate(document)

    let entry = makeEntry(
      from: input,
      radiusReferenceExtent: radiusReferenceExtent,
      presentationTime: presentationTime
    )
    var image = entry.image
    let context = entry.context
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

  /// Evaluates a statically composed document from an input image.
  ///
  /// The chain entry is shared with
  /// `makeOutput(from:document:radiusReferenceExtent:presentationTime:)`, and
  /// the resulting context is passed down the whole composition.
  func makeImage(
    from input: CIImage,
    document: some Feature,
    radiusReferenceExtent: CGRect?,
    presentationTime: CMTime
  ) throws -> CIImage {
    let (image, context) = makeEntry(
      from: input,
      radiusReferenceExtent: radiusReferenceExtent,
      presentationTime: presentationTime
    )
    return try document.apply(to: image, context: context)
  }

  /// Prepares the chain entry shared by both document models.
  ///
  /// The input is translated to zero origin when
  /// `options.normalizesInputExtent` is set. An explicit
  /// `radiusReferenceExtent` wins; otherwise the normalized input extent is
  /// the basis unless it is infinite.
  private func makeEntry(
    from input: CIImage,
    radiusReferenceExtent: CGRect?,
    presentationTime: CMTime
  ) -> (image: CIImage, context: FeatureEvaluationContext) {
    let image = options.normalizesInputExtent ? ParametricImageGeometry.removingExtentOffset(input) : input

    // Resolve the radius reference ONCE at chain entry. Deriving it lazily
    // inside each recipe (`?? image.extent`) would re-base the radius on
    // whatever intermediate the effect happens to receive — a mid-chain crop
    // would silently change the resolved blur strength, and editing a crop
    // would retroactively change committed effects. The entry extent is the
    // declared basis; feature order cannot perturb it.
    let entryReferenceExtent: CGRect? = image.extent.isInfinite ? nil : image.extent
    let context = FeatureEvaluationContext(
      kernelRegistry: kernelRegistry,
      radiusReferenceExtent: radiusReferenceExtent ?? entryReferenceExtent,
      presentationTime: presentationTime
    )
    return (image, context)
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
    try MaskTreeRenderer(kernelRegistry: kernelRegistry).render(maskTree, extent: extent)
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
        // An enabled local adjustment that applies nothing stays an error: it
        // is a construction mistake worth surfacing. A disabled one is skipped
        // by evaluation, so failing it here would reject documents the preview
        // renders — toggling a layer off must not break export.
        if localAdjustment.isEnabled {
          let enabledEffects = localAdjustment.effectPipeline.effects.filter(\.isEnabled)
          guard enabledEffects.isEmpty == false else {
            throw FeatureGraphCompilerError.emptyLocalAdjustmentEffectPipeline(localAdjustment.id)
          }
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
