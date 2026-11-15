import CoreImage
import CoreMedia
import Testing

@testable import BrightroomParametric

struct AdjustmentRenderingTests {

  private struct Probe: AdjustmentImplementation {

    let amount: Double

    var renderingIdentity: AdjustmentRendering.Identity {
      .init(implementation: "test.probe", version: "1", configuration: "amount=\(amount)")
    }

    func apply(_ feature: ExposureFeature, to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage? {
      image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: amount])
    }

    func apply(_ feature: HighlightsShadowsFeature, to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage? {
      #expect(feature.highlights == -11)
      #expect(feature.shadows == 30)
      #expect(context.adjustmentRendering.identity == renderingIdentity)
      return image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: amount])
    }
  }

  private struct Unsupported: AdjustmentImplementation {

    let renderingIdentity = AdjustmentRendering.Identity(implementation: "test.unsupported", version: "1", configuration: "")
  }

  private struct StandardDelegate: AdjustmentImplementation {

    let renderingIdentity = AdjustmentRendering.Identity(implementation: "test.delegate", version: "1", configuration: "")

    func apply(_ feature: ExposureFeature, to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage? {
      try feature.apply(to: image, context: context.usingStandardAdjustments())
    }

    func apply(_ feature: HighlightsShadowsFeature, to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage? {
      try feature.apply(to: image, context: context.usingStandardAdjustments())
    }
  }

  private enum Failure: Error { case requiredResource }

  private struct Failing: AdjustmentImplementation {

    let renderingIdentity = AdjustmentRendering.Identity(implementation: "test.failure", version: "1", configuration: "")

    func apply(_ feature: ExposureFeature, to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage? {
      throw Failure.requiredResource
    }

    func apply(_ feature: HighlightsShadowsFeature, to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage? {
      throw Failure.requiredResource
    }
  }

  private struct Nested: ImageEffect {

    var body: some ImageEffect {
      let optional: ExposureFeature? = ExposureFeature(ev: 0.25)
      optional
      [ExposureFeature(ev: 0.5)]
      AnyImageEffect(ExposureFeature(ev: -0.5))
      LocalAdjustmentFeature(mask: .inverted(.brush(BrushMask(strokes: [])))) {
        ExposureFeature(ev: 0.75)
      }
    }
  }

  private let input = CIImage(color: CIColor(red: 0.05, green: 0.1, blue: 0.15, alpha: 1))
    .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 6))

  private func pixel(_ image: CIImage) -> [Float] {
    var values = [Float](repeating: 0, count: 4)
    CIContext(options: [.workingFormat: CIFormat.RGBAf]).render(
      image, toBitmap: &values, rowBytes: 16,
      bounds: CGRect(x: 3, y: 2, width: 1, height: 1), format: .RGBAf,
      colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    )
    return values
  }

  @Test func nestedOptionalArrayErasureAndLocalContentKeepSelection() throws {
    let rendering = AdjustmentRendering.overridingSupportedFeatures(with: Probe(amount: 0.5))
    let actual = try FeatureRenderer(adjustmentRendering: rendering).makeImage(from: input, feature: Nested())
    let expected = input.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 2])
    #expect(zip(pixel(actual), pixel(expected)).allSatisfy { abs($0 - $1) < 0.0001 })
    let standard = try FeatureRenderer().makeImage(from: input, feature: Nested())
    #expect(abs(pixel(actual)[0] - pixel(standard)[0]) > 0.005)
  }

  @Test func compoundHookReceivesOriginalUncompensatedValues() throws {
    let rendering = AdjustmentRendering.overridingSupportedFeatures(with: Probe(amount: 1))
    let actual = try FeatureRenderer(adjustmentRendering: rendering).makeImage(
      from: input, feature: HighlightsShadowsFeature(highlights: -11, shadows: 30))
    let expected = input.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 1])
    #expect(pixel(actual) == pixel(expected))
  }

  @Test func unsupportedAndExplicitStandardDelegationKeepOriginalRecipe() throws {
    let feature = ExposureFeature(ev: 0.5)
    let expected = try FeatureRenderer().makeImage(from: input, feature: feature)
    for rendering in [AdjustmentRendering.overridingSupportedFeatures(with: Unsupported()),
                      .overridingSupportedFeatures(with: StandardDelegate())] {
      let actual = try FeatureRenderer(adjustmentRendering: rendering).makeImage(from: input, feature: feature)
      #expect(pixel(actual) == pixel(expected))
    }
    let compound = HighlightsShadowsFeature(highlights: -11, shadows: 30)
    let actual = try FeatureRenderer(adjustmentRendering: .overridingSupportedFeatures(with: StandardDelegate()))
      .makeImage(from: input, feature: compound)
    #expect(pixel(actual) == pixel(try FeatureRenderer().makeImage(from: input, feature: compound)))
  }

  @Test func failuresPropagateAcrossRenderersAndNeutralNeverCallsImplementation() throws {
    let rendering = AdjustmentRendering.overridingSupportedFeatures(with: Failing())
    let renderer = FeatureRenderer(adjustmentRendering: rendering)
    let neutral = try renderer.makeImage(from: input, feature: ExposureFeature(ev: 0))
    #expect(neutral === input)
    #expect(try renderer.makeImage(from: input, feature: HighlightsShadowsFeature(highlights: 0, shadows: 0)) === input)
    let feature = ExposureFeature(ev: 1)
    #expect(throws: Failure.self) { try renderer.makeImage(from: input, feature: feature) }
    #expect(throws: Failure.self) {
      try renderer.makeImage(from: input, feature: HighlightsShadowsFeature(highlights: -11, shadows: 30))
    }
    #expect(throws: Failure.self) { try ExportRenderer(adjustmentRendering: rendering).render(from: input, feature: feature) }
    let video = VideoRenderer(adjustmentRendering: rendering)
    #expect(throws: Failure.self) { try video.makeImage(from: input, feature: feature) }
    #expect(throws: Failure.self) {
      try video.resolveRenderSize(sourceRenderSize: input.extent.size, feature: feature, mode: .featureOutput)
    }
  }

  @Test func copiedContextsRetainSelectionTimeAndScale() {
    let rendering = AdjustmentRendering.overridingSupportedFeatures(with: Probe(amount: 1))
    let time = CMTime(value: 17, timescale: 24)
    let context = FeatureEvaluationContext(presentationTime: time, renderScale: 0.5, adjustmentRendering: rendering)
      .withChainEntryExtent(input.extent)
      .withRenderScale(0.25)
    #expect(context.adjustmentRendering == rendering)
    #expect(context.presentationTime == time)
    #expect(context.renderScale == 0.25)
    #expect(context.chainEntryExtent == input.extent)
    #expect(context.usingStandardAdjustments().adjustmentRendering == .standard)
    #expect(context.usingStandardAdjustments().presentationTime == time)
  }

  private struct Timed: AdjustmentImplementation {

    let renderingIdentity = AdjustmentRendering.Identity(implementation: "test.time", version: "1", configuration: "")

    func apply(_ feature: ExposureFeature, to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage? {
      image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: context.presentationTime.seconds])
    }
  }

  @Test func videoFrameKeepsExactPresentationTime() throws {
    let rendering = AdjustmentRendering.overridingSupportedFeatures(with: Timed())
    let frame = try VideoRenderer(adjustmentRendering: rendering).makeImage(
      from: input, feature: ExposureFeature(ev: 1), presentationTime: CMTime(value: 3, timescale: 2))
    let expected = input.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 1.5])
    #expect(pixel(frame) == pixel(expected))
  }

  @Test func semanticIdentityIncludesConfigurationNotInstanceAddress() {
    let a = AdjustmentRendering.overridingSupportedFeatures(with: Probe(amount: 1))
    let same = AdjustmentRendering.overridingSupportedFeatures(with: Probe(amount: 1))
    let different = AdjustmentRendering.overridingSupportedFeatures(with: Probe(amount: 2))
    #expect(a == same)
    #expect(a != different)
    #expect(a != .standard)
    #expect(Set([a.identity, same.identity, different.identity]).count == 2)
  }
}
