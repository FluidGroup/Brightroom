import CoreImage

/// An immutable set of adjustment implementations, owned by the renderer rather than the edit.
public struct AdjustmentRendering: Sendable, Equatable {

  /// Every output-affecting implementation, model and configuration change needs a new identity.
  public struct Identity: Hashable, Sendable {

    public let implementation: String
    public let version: String
    public let configuration: String

    public init(implementation: String, version: String, configuration: String) {
      self.implementation = implementation
      self.version = version
      self.configuration = configuration
    }
  }

  /// A typed calculation. Captured resources must be safe for concurrent evaluation;
  /// output-affecting state must stay immutable and be represented in the identity.
  public struct Implementation<F: ImageEffect>: Sendable {

    public let identity: Identity
    fileprivate let operation: @Sendable (F, CIImage, FeatureEvaluationContext) throws -> CIImage

    public init(
      identity: Identity,
      apply: @escaping @Sendable (F, CIImage, FeatureEvaluationContext) throws -> CIImage
    ) {
      self.identity = identity
      self.operation = apply
    }
  }

  /// Mutable only during setup. Replacing a type again makes the last explicit choice win.
  public struct Setup {

    fileprivate var implementations = Implementations()

    public init() {}

    public mutating func replace(
      _ feature: ExposureFeature.Type,
      with implementation: Implementation<ExposureFeature>
    ) {
      implementations.exposure = implementation
    }

    public mutating func replace(
      _ feature: SaturationFeature.Type,
      with implementation: Implementation<SaturationFeature>
    ) {
      implementations.saturation = implementation
    }

    public mutating func replace(
      _ feature: HighlightsFeature.Type,
      with implementation: Implementation<HighlightsFeature>
    ) {
      implementations.highlights = implementation
    }

    public mutating func replace(
      _ feature: ShadowsFeature.Type,
      with implementation: Implementation<ShadowsFeature>
    ) {
      implementations.shadows = implementation
    }

    public mutating func replace(
      _ feature: HighlightsShadowsFeature.Type,
      with implementation: Implementation<HighlightsShadowsFeature>
    ) {
      implementations.highlightsShadows = implementation
    }

    public mutating func replace(
      _ feature: WhitesFeature.Type,
      with implementation: Implementation<WhitesFeature>
    ) {
      implementations.whites = implementation
    }

    public mutating func replace(
      _ feature: BlacksFeature.Type,
      with implementation: Implementation<BlacksFeature>
    ) {
      implementations.blacks = implementation
    }

    public mutating func replace(
      _ feature: ColorMixerFeature.Type,
      with implementation: Implementation<ColorMixerFeature>
    ) {
      implementations.colorMixer = implementation
    }

    public mutating func replace(
      _ feature: ColorGradingFeature.Type,
      with implementation: Implementation<ColorGradingFeature>
    ) {
      implementations.colorGrading = implementation
    }

    public mutating func replace(
      _ feature: ClarityFeature.Type,
      with implementation: Implementation<ClarityFeature>
    ) {
      implementations.clarity = implementation
    }

    public mutating func replace(
      _ feature: TextureFeature.Type,
      with implementation: Implementation<TextureFeature>
    ) {
      implementations.texture = implementation
    }

    public mutating func replace(
      _ feature: DehazeFeature.Type,
      with implementation: Implementation<DehazeFeature>
    ) {
      implementations.dehaze = implementation
    }

    public mutating func replace(
      _ feature: GrainFeature.Type,
      with implementation: Implementation<GrainFeature>
    ) {
      implementations.grain = implementation
    }

    public mutating func replace(
      _ feature: GrainFeature.CameraRaw.Type,
      with implementation: Implementation<GrainFeature.CameraRaw>
    ) {
      implementations.cameraRawGrain = implementation
    }

    /// Takes an independent snapshot; later setup mutations do not alter existing renderers.
    public func makeRendering() -> AdjustmentRendering {
      AdjustmentRendering(implementations: implementations)
    }
  }

  fileprivate struct Implementations: Sendable {

    var exposure: Implementation<ExposureFeature>?
    var saturation: Implementation<SaturationFeature>?
    var highlights: Implementation<HighlightsFeature>?
    var shadows: Implementation<ShadowsFeature>?
    var highlightsShadows: Implementation<HighlightsShadowsFeature>?
    var whites: Implementation<WhitesFeature>?
    var blacks: Implementation<BlacksFeature>?
    var colorMixer: Implementation<ColorMixerFeature>?
    var colorGrading: Implementation<ColorGradingFeature>?
    var clarity: Implementation<ClarityFeature>?
    var texture: Implementation<TextureFeature>?
    var dehaze: Implementation<DehazeFeature>?
    var grain: Implementation<GrainFeature>?
    var cameraRawGrain: Implementation<GrainFeature.CameraRaw>?

    var identity: Identity {
      let entries: [(String, Identity?)] = [
        ("ExposureFeature", exposure?.identity),
        ("SaturationFeature", saturation?.identity),
        ("HighlightsFeature", highlights?.identity),
        ("ShadowsFeature", shadows?.identity),
        ("HighlightsShadowsFeature", highlightsShadows?.identity),
        ("WhitesFeature", whites?.identity),
        ("BlacksFeature", blacks?.identity),
        ("ColorMixerFeature", colorMixer?.identity),
        ("ColorGradingFeature", colorGrading?.identity),
        ("ClarityFeature", clarity?.identity),
        ("TextureFeature", texture?.identity),
        ("DehazeFeature", dehaze?.identity),
        ("GrainFeature", grain?.identity),
        ("GrainFeature.CameraRaw", cameraRawGrain?.identity),
      ]
      let configuration = entries.compactMap { name, identity -> String? in
        guard let identity else { return nil }
        return [name, identity.implementation, identity.version, identity.configuration]
          .map { "\($0.utf8.count):\($0)" }.joined()
      }.joined()
      return Identity(
        implementation: "org.brightroom.adjustments",
        version: "2",
        configuration: "lightweight-standard-1;" + configuration
      )
    }
  }

  public static let standard = Setup().makeRendering()

  public let identity: Identity
  private let implementations: Implementations

  private init(implementations: Implementations) {
    self.implementations = implementations
    self.identity = implementations.identity
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.identity == rhs.identity
  }

  package func apply(
    _ feature: ExposureFeature,
    to image: CIImage,
    context: FeatureEvaluationContext
  ) throws -> CIImage? {
    try implementations.exposure?.operation(feature, image, context)
  }

  package func apply(
    _ feature: SaturationFeature,
    to image: CIImage,
    context: FeatureEvaluationContext
  ) throws -> CIImage? {
    try implementations.saturation?.operation(feature, image, context)
  }

  package func apply(
    _ feature: HighlightsFeature,
    to image: CIImage,
    context: FeatureEvaluationContext
  ) throws -> CIImage? {
    try implementations.highlights?.operation(feature, image, context)
  }

  package func apply(
    _ feature: ShadowsFeature,
    to image: CIImage,
    context: FeatureEvaluationContext
  ) throws -> CIImage? {
    try implementations.shadows?.operation(feature, image, context)
  }

  package func apply(
    _ feature: HighlightsShadowsFeature,
    to image: CIImage,
    context: FeatureEvaluationContext
  ) throws -> CIImage? {
    try implementations.highlightsShadows?.operation(feature, image, context)
  }

  package func apply(
    _ feature: WhitesFeature,
    to image: CIImage,
    context: FeatureEvaluationContext
  ) throws -> CIImage? {
    try implementations.whites?.operation(feature, image, context)
  }

  package func apply(
    _ feature: BlacksFeature,
    to image: CIImage,
    context: FeatureEvaluationContext
  ) throws -> CIImage? {
    try implementations.blacks?.operation(feature, image, context)
  }

  package func apply(
    _ feature: ColorMixerFeature,
    to image: CIImage,
    context: FeatureEvaluationContext
  ) throws -> CIImage? {
    try implementations.colorMixer?.operation(feature, image, context)
  }

  package func apply(
    _ feature: ColorGradingFeature,
    to image: CIImage,
    context: FeatureEvaluationContext
  ) throws -> CIImage? {
    try implementations.colorGrading?.operation(feature, image, context)
  }

  package func apply(
    _ feature: ClarityFeature,
    to image: CIImage,
    context: FeatureEvaluationContext
  ) throws -> CIImage? {
    try implementations.clarity?.operation(feature, image, context)
  }

  package func apply(
    _ feature: TextureFeature,
    to image: CIImage,
    context: FeatureEvaluationContext
  ) throws -> CIImage? {
    try implementations.texture?.operation(feature, image, context)
  }

  package func apply(
    _ feature: DehazeFeature,
    to image: CIImage,
    context: FeatureEvaluationContext
  ) throws -> CIImage? {
    try implementations.dehaze?.operation(feature, image, context)
  }

  package func apply(
    _ feature: GrainFeature,
    to image: CIImage,
    context: FeatureEvaluationContext
  ) throws -> CIImage? {
    try implementations.grain?.operation(feature, image, context)
  }

  package func apply(
    _ feature: GrainFeature.CameraRaw,
    to image: CIImage,
    context: FeatureEvaluationContext
  ) throws -> CIImage? {
    try implementations.cameraRawGrain?.operation(feature, image, context)
  }
}
