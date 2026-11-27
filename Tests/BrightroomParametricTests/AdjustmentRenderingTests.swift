import CoreImage
import CoreMedia
import Testing


@testable import BrightroomParametric

struct AdjustmentRenderingTests {

  @Test func standardTextureUsesTheScaledGaussianNeighborhood() throws {
    let input = try RenderingFixtures.makeSource()
    let original = RenderingFixtures.pixels(of: input)
    for scale in [0.25, 1.0] {
      let guide = input.clampedToExtent()
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 12 * scale])
        .cropped(to: input.extent)
      let blurred = RenderingFixtures.pixels(of: guide)
      for amount in [-50.0, 50.0] {
        let output = try TextureFeature(amount: amount).apply(
          to: input, context: .init(chainEntryExtent: input.extent, renderScale: scale))
        let actual = RenderingFixtures.pixels(of: output)
        var maximum: Float = 0
        for index in actual.indices where index % 4 != 3 {
          let expected = original[index] + Float(amount / 100) * (original[index] - blurred[index])
          maximum = max(maximum, abs(actual[index] - expected))
        }
        #expect(maximum < 0.00001)
      }
    }
  }


  @Test func standardCameraRawDoesNotInvokeTheGenericGrainReplacement() throws {
    enum Failure: Error { case unexpected }
    var setup = AdjustmentRendering.Setup()
    setup.replace(GrainFeature.self, with: .init(
      identity: .init(implementation: "test.grain", version: "1", configuration: "throw")
    ) { _, _, _ in throw Failure.unexpected })
    let input = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
    let output = try FeatureRenderer(adjustmentRendering: setup.makeRendering())
      .makeImage(from: input, feature: GrainFeature.CameraRaw(amount: 30))
    #expect(output.extent == input.extent)
    #expect(output !== input)
  }

  private struct Probe: Sendable {

    var rendering: AdjustmentRendering {
      var setup = AdjustmentRendering.Setup()
      setup.replace(ExposureFeature.self, with: .init(identity: renderingIdentity) { feature, image, context in
        try apply(feature, to: image, context: context)
      })
      setup.replace(HighlightsShadowsFeature.self, with: .init(identity: renderingIdentity) { feature, image, context in
        try apply(feature, to: image, context: context)
      })
      return setup.makeRendering()
    }

    let amount: Double

    var renderingIdentity: AdjustmentRendering.Identity {
      .init(implementation: "test.probe", version: "1", configuration: "amount=\(amount)")
    }

    func apply(_ feature: ExposureFeature, to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
      image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: amount])
    }

    func apply(_ feature: HighlightsShadowsFeature, to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
      #expect(feature.highlights == -11)
      #expect(feature.shadows == 30)
      #expect(context.adjustmentRendering == rendering)
      return image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: amount])
    }
  }

  private struct Unsupported: Sendable {

    var rendering: AdjustmentRendering { .standard }

    let renderingIdentity = AdjustmentRendering.Identity(implementation: "test.unsupported", version: "1", configuration: "")
  }

  private struct StandardDelegate: Sendable {

    var rendering: AdjustmentRendering {
      var setup = AdjustmentRendering.Setup()
      setup.replace(ExposureFeature.self, with: .init(identity: renderingIdentity) { feature, image, context in
        try apply(feature, to: image, context: context)
      })
      setup.replace(HighlightsShadowsFeature.self, with: .init(identity: renderingIdentity) { feature, image, context in
        try apply(feature, to: image, context: context)
      })
      return setup.makeRendering()
    }

    let renderingIdentity = AdjustmentRendering.Identity(implementation: "test.delegate", version: "1", configuration: "")

    func apply(_ feature: ExposureFeature, to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
      try feature.apply(to: image, context: context.usingStandardAdjustments())
    }

    func apply(_ feature: HighlightsShadowsFeature, to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
      try feature.apply(to: image, context: context.usingStandardAdjustments())
    }
  }

  private enum Failure: Error { case requiredResource }

  private struct Failing: Sendable {

    var rendering: AdjustmentRendering {
      var setup = AdjustmentRendering.Setup()
      setup.replace(ExposureFeature.self, with: .init(identity: renderingIdentity) { feature, image, context in
        try apply(feature, to: image, context: context)
      })
      setup.replace(HighlightsShadowsFeature.self, with: .init(identity: renderingIdentity) { feature, image, context in
        try apply(feature, to: image, context: context)
      })
      return setup.makeRendering()
    }

    let renderingIdentity = AdjustmentRendering.Identity(implementation: "test.failure", version: "1", configuration: "")

    func apply(_ feature: ExposureFeature, to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
      throw Failure.requiredResource
    }

    func apply(_ feature: HighlightsShadowsFeature, to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
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
    let rendering = Probe(amount: 0.5).rendering
    let actual = try FeatureRenderer(adjustmentRendering: rendering).makeImage(from: input, feature: Nested())
    let expected = input.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 2])
    #expect(zip(pixel(actual), pixel(expected)).allSatisfy { abs($0 - $1) < 0.0001 })
    let standard = try FeatureRenderer().makeImage(from: input, feature: Nested())
    #expect(abs(pixel(actual)[0] - pixel(standard)[0]) > 0.005)
  }

  @Test func compoundHookReceivesOriginalUncompensatedValues() throws {
    let rendering = Probe(amount: 1).rendering
    let actual = try FeatureRenderer(adjustmentRendering: rendering).makeImage(
      from: input, feature: HighlightsShadowsFeature(highlights: -11, shadows: 30))
    let expected = input.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 1])
    #expect(pixel(actual) == pixel(expected))
  }

  @Test func unsupportedAndExplicitStandardDelegationKeepOriginalRecipe() throws {
    let feature = ExposureFeature(ev: 0.5)
    let expected = try FeatureRenderer().makeImage(from: input, feature: feature)
    for rendering in [Unsupported().rendering,
                      StandardDelegate().rendering] {
      let actual = try FeatureRenderer(adjustmentRendering: rendering).makeImage(from: input, feature: feature)
      #expect(pixel(actual) == pixel(expected))
    }
    let compound = HighlightsShadowsFeature(highlights: -11, shadows: 30)
    let actual = try FeatureRenderer(adjustmentRendering: StandardDelegate().rendering)
      .makeImage(from: input, feature: compound)
    #expect(pixel(actual) == pixel(try FeatureRenderer().makeImage(from: input, feature: compound)))
  }

  @Test func failuresPropagateAcrossRenderersAndNeutralNeverCallsImplementation() throws {
    let rendering = Failing().rendering
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
    let rendering = Probe(amount: 1).rendering
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

  private struct Timed: Sendable {

    var rendering: AdjustmentRendering {
      var setup = AdjustmentRendering.Setup()
      setup.replace(ExposureFeature.self, with: .init(identity: renderingIdentity) { feature, image, context in
        try apply(feature, to: image, context: context)
      })
      return setup.makeRendering()
    }

    let renderingIdentity = AdjustmentRendering.Identity(implementation: "test.time", version: "1", configuration: "")

    func apply(_ feature: ExposureFeature, to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
      image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: context.presentationTime.seconds])
    }
  }

  @Test func videoFrameKeepsExactPresentationTime() throws {
    let rendering = Timed().rendering
    let frame = try VideoRenderer(adjustmentRendering: rendering).makeImage(
      from: input, feature: ExposureFeature(ev: 1), presentationTime: CMTime(value: 3, timescale: 2))
    let expected = input.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 1.5])
    #expect(pixel(frame) == pixel(expected))
  }

  @Test func semanticIdentityIncludesConfigurationNotInstanceAddress() {
    let a = Probe(amount: 1).rendering
    let same = Probe(amount: 1).rendering
    let different = Probe(amount: 2).rendering
    #expect(a == same)
    #expect(a != different)
    #expect(a != .standard)
    #expect(Set([a.identity, same.identity, different.identity]).count == 2)
  }
}

extension AdjustmentRenderingTests {

  @Test func setupSnapshotsAreIndependentAndReplacementIsExplicit() throws {
    func implementation(_ amount: Double) -> AdjustmentRendering.Implementation<ExposureFeature> {
      .init(identity: .init(implementation: "test.snapshot", version: "1", configuration: "\(amount)")) {
        _, image, _ in image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: amount])
      }
    }
    var setup = AdjustmentRendering.Setup()
    #expect(setup.makeRendering() == .standard)
    setup.replace(ExposureFeature.self, with: implementation(1))
    let first = setup.makeRendering()
    var copy = setup
    copy.replace(ExposureFeature.self, with: implementation(2))
    #expect(setup.makeRendering() == first)
    #expect(copy.makeRendering() != first)
    let feature = ExposureFeature(ev: 0.25)
    let original = try FeatureRenderer(adjustmentRendering: first).makeImage(from: input, feature: feature)
    let replaced = try FeatureRenderer(adjustmentRendering: copy.makeRendering()).makeImage(from: input, feature: feature)
    #expect(pixel(original) == pixel(input.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 1])))
    #expect(pixel(replaced) == pixel(input.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 2])))
  }

  @Test func identityIncludesTheSlotAndFinalChoicesNotRegistrationOrder() {
    let identity = AdjustmentRendering.Identity(implementation: "test.shared", version: "1", configuration: "model=2")
    let exposure = AdjustmentRendering.Implementation<ExposureFeature>(identity: identity) { _, image, _ in image }
    let compound = AdjustmentRendering.Implementation<HighlightsShadowsFeature>(identity: identity) { _, image, _ in image }
    var a = AdjustmentRendering.Setup()
    var b = AdjustmentRendering.Setup()
    a.replace(ExposureFeature.self, with: exposure)
    b.replace(HighlightsShadowsFeature.self, with: compound)
    #expect(a.makeRendering() != b.makeRendering())
    a.replace(HighlightsShadowsFeature.self, with: compound)
    b.replace(ExposureFeature.self, with: exposure)
    #expect(a.makeRendering() == b.makeRendering())
    a.replace(ExposureFeature.self, with: exposure)
    #expect(a.makeRendering() == b.makeRendering())
  }

  @Test func everySupportedRegistrationIsEvaluatedAndNeutralBypassesIt() throws {
    func failing<F: ImageEffect>() -> AdjustmentRendering.Implementation<F> {
      .init(identity: .init(implementation: "test.required", version: "1", configuration: "")) { _, _, _ in
        throw Failure.requiredResource
      }
    }
    var setup = AdjustmentRendering.Setup()
    setup.replace(ExposureFeature.self, with: failing())
    setup.replace(SaturationFeature.self, with: failing())
    setup.replace(VibranceFeature.self, with: failing())
    setup.replace(HighlightsFeature.self, with: failing())
    setup.replace(ShadowsFeature.self, with: failing())
    setup.replace(HighlightsShadowsFeature.self, with: failing())
    setup.replace(WhitesFeature.self, with: failing())
    setup.replace(BlacksFeature.self, with: failing())
    setup.replace(ColorMixerFeature.self, with: failing())
    setup.replace(ColorGradingFeature.self, with: failing())
    setup.replace(ClarityFeature.self, with: failing())
    setup.replace(TextureFeature.self, with: failing())
    setup.replace(DehazeFeature.self, with: failing())
    setup.replace(GrainFeature.self, with: failing())
    setup.replace(GrainFeature.CameraRaw.self, with: failing())
    let renderer = FeatureRenderer(adjustmentRendering: setup.makeRendering())
    var bands = ColorMixerFeature.Bands()
    bands[.red] = .init(hue: 10)
    let active: [AnyImageEffect] = [
      AnyImageEffect(ExposureFeature(ev: 1)),
      AnyImageEffect(SaturationFeature(value: 0.2)),
      AnyImageEffect(VibranceFeature(amount: 20)),
      AnyImageEffect(HighlightsFeature(value: 0.2)),
      AnyImageEffect(ShadowsFeature(value: 0.2)),
      AnyImageEffect(HighlightsShadowsFeature(highlights: -30, shadows: 40)),
      AnyImageEffect(WhitesFeature(amount: 20)),
      AnyImageEffect(BlacksFeature(amount: 20)),
      AnyImageEffect(ColorMixerFeature(bands: bands)),
      AnyImageEffect(ColorGradingFeature(global: .init(saturation: 10))),
      AnyImageEffect(ClarityFeature(amount: 20)),
      AnyImageEffect(TextureFeature(amount: 20)),
      AnyImageEffect(DehazeFeature(amount: 20)),
      AnyImageEffect(GrainFeature(amount: 20)),
      AnyImageEffect(GrainFeature.CameraRaw(amount: 20)),
    ]
    let neutral: [AnyImageEffect] = [
      AnyImageEffect(ExposureFeature(ev: 0)),
      AnyImageEffect(SaturationFeature(value: 0)),
      AnyImageEffect(VibranceFeature()),
      AnyImageEffect(HighlightsFeature(value: 0)),
      AnyImageEffect(ShadowsFeature(value: 0)),
      AnyImageEffect(HighlightsShadowsFeature(highlights: 0, shadows: 0)),
      AnyImageEffect(WhitesFeature(amount: 0)),
      AnyImageEffect(BlacksFeature(amount: 0)),
      AnyImageEffect(ColorMixerFeature(bands: .init())),
      AnyImageEffect(ColorGradingFeature()),
      AnyImageEffect(ClarityFeature()),
      AnyImageEffect(TextureFeature()),
      AnyImageEffect(DehazeFeature()),
      AnyImageEffect(GrainFeature(amount: 0)),
      AnyImageEffect(GrainFeature.CameraRaw(amount: 0)),
    ]
    for feature in active {
      #expect(throws: Failure.self) { try renderer.makeImage(from: input, feature: feature) }
    }
    for feature in neutral {
      #expect(try renderer.makeImage(from: input, feature: feature) === input)
    }
  }
}
