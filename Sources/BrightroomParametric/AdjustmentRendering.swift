import CoreImage

/// Pixel calculations that can replace supported built-in adjustments.
///
/// Return `nil` only for an unsupported adjustment, to delegate to Brightroom's
/// original recipe. Throw for failures, including missing resources. Instances
/// must be immutable and safe for simultaneous renders. Never retain a context
/// or image in mutable per-render state.
public protocol AdjustmentImplementation: Sendable {

  /// Identifies every output-affecting choice, not the instance's address.
  var renderingIdentity: AdjustmentRendering.Identity { get }

  func apply(
    _ feature: ExposureFeature,
    to image: CIImage,
    context: FeatureEvaluationContext
  ) throws -> CIImage?

  /// Receives the original pair before Brightroom's interaction compensation.
  func apply(
    _ feature: HighlightsShadowsFeature,
    to image: CIImage,
    context: FeatureEvaluationContext
  ) throws -> CIImage?
}

extension AdjustmentImplementation {

  public func apply(
    _ feature: ExposureFeature,
    to image: CIImage,
    context: FeatureEvaluationContext
  ) throws -> CIImage? {
    nil
  }

  public func apply(
    _ feature: HighlightsShadowsFeature,
    to image: CIImage,
    context: FeatureEvaluationContext
  ) throws -> CIImage? {
    nil
  }
}

/// An immutable, render-owned choice, separate from feature equality and history.
public struct AdjustmentRendering: Sendable, Equatable {

  /// Semantic implementation version plus all output-affecting configuration.
  /// Hosts may store these strings in their own persistence model. They are not
  /// a registry or a serialization format, and do not load an implementation.
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

  public let identity: Identity
  package let implementation: (any AdjustmentImplementation)?

  public static let standard = Self(implementation: nil)

  /// Deliberately replaces the recipes of the implementation's supported types,
  /// including their algorithm choices. Unsupported types retain their exact
  /// original algorithms. Nothing infers whether a feature used a default.
  public static func overridingSupportedFeatures(
    with implementation: some AdjustmentImplementation
  ) -> Self {
    Self(implementation: implementation)
  }

  private init(implementation: (any AdjustmentImplementation)?) {
    self.implementation = implementation
    self.identity = implementation?.renderingIdentity ?? Identity(
      implementation: "org.brightroom.standard",
      version: "1",
      configuration: "calibration-9bd3067"
    )
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.identity == rhs.identity
  }
}
