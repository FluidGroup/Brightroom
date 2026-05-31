import AVFoundation
import CoreImage
import XCTest

@testable import BrightroomEngine
@testable import BrightroomParametric

final class ParametricFeatureTreeTests: XCTestCase {

  func testDocumentCodableRoundTrip() throws {
    let document = EditingDocument(
      mainTree: MainTree(
        features: [
          .domain(
            .crop(
              CropFeature(
                id: FeatureID(rawValue: "crop-a"),
                cropRect: CGRect(x: 4, y: 5, width: 30, height: 20)
              )
            )
          ),
          .localAdjustment(
            LocalAdjustmentFeature(
              id: FeatureID(rawValue: "local-a"),
              maskTree: MaskTree(
                root: .feather(
                  MaskFeather(
                    id: FeatureID(rawValue: "feather-a"),
                    input: .brush(
                      BrushMask(
                        id: FeatureID(rawValue: "mask-a"),
                        strokes: [
                          BrushMaskStroke(
                            stamps: [CGPoint(x: 10, y: 8)],
                            brush: BrushMaskBrush(diameter: 12, hardness: 0.5, opacity: 0.75)
                          ),
                        ]
                      )
                    ),
                    radius: 2
                  )
                )
              ),
              effectPipeline: EffectPipeline(
                effects: [
                  .brightness(BrightnessFeature(id: FeatureID(rawValue: "brightness-a"), value: 0.1)),
                  .gaussianBlur(GaussianBlurFeature(id: FeatureID(rawValue: "blur-a"), radius: 3)),
                ]
              )
            )
          ),
          .effect(
            .exposure(
              ExposureFeature(id: FeatureID(rawValue: "exposure-a"), value: 0.25)
            )
          ),
          .effect(.contrast(ContrastFeature(id: FeatureID(rawValue: "contrast-a"), value: 0.08))),
          .effect(.saturation(SaturationFeature(id: FeatureID(rawValue: "saturation-a"), value: 0.12))),
          .effect(.highlights(HighlightsFeature(id: FeatureID(rawValue: "highlights-a"), value: 0.2))),
          .effect(.shadows(ShadowsFeature(id: FeatureID(rawValue: "shadows-a"), value: 0.15))),
          .effect(
            .highlightShadowTint(
              HighlightShadowTintFeature(
                id: FeatureID(rawValue: "highlight-shadow-tint-a"),
                highlightColor: ParametricRGBAColor(red: 1, green: 0.2, blue: 0.1, alpha: 0.05),
                shadowColor: ParametricRGBAColor(red: 0.1, green: 0.2, blue: 1, alpha: 0.04)
              )
            )
          ),
          .effect(.temperature(TemperatureFeature(id: FeatureID(rawValue: "temperature-a"), value: 450))),
          .effect(.sharpen(SharpenFeature(id: FeatureID(rawValue: "sharpen-a"), sharpness: 0.2, radius: 4))),
          .effect(.unsharpMask(UnsharpMaskFeature(id: FeatureID(rawValue: "unsharp-a"), intensity: 0.1, radius: 0.25))),
          .effect(.vignette(VignetteFeature(id: FeatureID(rawValue: "vignette-a"), value: 0.35))),
          .effect(.fade(FadeFeature(id: FeatureID(rawValue: "fade-a"), intensity: 0.05))),
        ]
      )
    )

    let data = try JSONEncoder().encode(document)
    let decoded = try JSONDecoder().decode(EditingDocument.self, from: data)

    XCTAssertEqual(decoded, document)
  }

  func testFeatureDocumentRoundTripAndMatchesEnumDocument() throws {
    let enumDocument = EditingDocument(
      mainTree: MainTree(
        features: [
          .domain(
            .crop(
              CropFeature(
                id: FeatureID(rawValue: "node-crop"),
                cropRect: CGRect(x: 4, y: 3, width: 36, height: 24)
              )
            )
          ),
          .localAdjustment(
            LocalAdjustmentFeature(
              id: FeatureID(rawValue: "node-local"),
              maskTree: MaskTree(
                root: .feather(
                  MaskFeather(
                    id: FeatureID(rawValue: "node-feather"),
                    input: .brush(
                      BrushMask(
                        id: FeatureID(rawValue: "node-brush"),
                        strokes: [
                          BrushMaskStroke(
                            stamps: [CGPoint(x: 16, y: 12)],
                            brush: BrushMaskBrush(diameter: 14, hardness: 0.6, opacity: 0.8)
                          ),
                        ]
                      )
                    ),
                    radius: 2
                  )
                )
              ),
              effectPipeline: EffectPipeline(
                effects: [
                  .exposure(ExposureFeature(id: FeatureID(rawValue: "node-local-exposure"), value: 0.5)),
                ]
              )
            )
          ),
          .effect(.brightness(BrightnessFeature(id: FeatureID(rawValue: "node-brightness"), value: 0.05))),
        ]
      )
    )
    let featureDocument = try FeatureDocument(editingDocument: enumDocument)
    let data = try JSONEncoder().encode(featureDocument)
    let decoded = try JSONDecoder().decode(FeatureDocument.self, from: data)
    let input = CIImage.parametricColorPatchImage(
      extent: CGRect(x: 0, y: 0, width: 48, height: 36)
    )

    let enumOutput = try Self.compiler.makeOutput(from: input, document: enumDocument)
    let featureOutput = try Self.compiler.makeOutput(from: input, document: decoded)

    XCTAssertEqual(decoded, featureDocument)
    try Self.assertImagesMatch(
      enumOutput.image,
      featureOutput.image,
      tolerance: 2
    )
  }

  func testCustomRegistryFeatureRendersLikeDefaultFeatures() throws {
    var registry = FeatureRegistry.brightroomDefault
    registry.registerImageEffect(TestRedBoostFeature.self)
    let compiler = FeatureGraphCompiler(featureRegistry: registry)
    let customFeature = try FeatureNode(
      TestRedBoostFeature.self,
      id: FeatureID(rawValue: "custom-red-boost"),
      payload: TestRedBoostFeature.Payload(amount: 0.25)
    )
    let document = FeatureDocument(
      mainTree: FeatureMainTree(
        features: [
          .effect(customFeature),
          .effect(
            try FeatureNode(
              BrightroomFeatureDefinitions.Brightness.self,
              id: FeatureID(rawValue: "registry-brightness"),
              payload: .init(value: 0.02)
            )
          ),
        ]
      )
    )
    let input = CIImage.parametricColorPatchImage(
      extent: CGRect(x: 0, y: 0, width: 32, height: 24)
    )
    let expected = input
      .applyingFilter(
        "CIColorMatrix",
        parameters: [
          "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
          "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
          "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
          "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
          "inputBiasVector": CIVector(x: 0.25, y: 0, z: 0, w: 0),
        ]
      )
      .cropped(to: input.extent)
      .applyingFilter(
        "CIColorControls",
        parameters: ["inputBrightness": 0.02]
      )
      .cropped(to: input.extent)

    let data = try JSONEncoder().encode(document)
    let decoded = try JSONDecoder().decode(FeatureDocument.self, from: data)
    let output = try compiler.makeOutput(from: input, document: decoded)

    try Self.assertImagesMatch(
      expected,
      output.image,
      tolerance: 2
    )
  }

  func testParametricImageRendererMatchesFeatureGraphCompiler() throws {
    let document = FeatureDocument(
      mainTree: FeatureMainTree(
        features: [
          .effect(
            try FeatureNode(
              BrightroomFeatureDefinitions.Brightness.self,
              id: FeatureID(rawValue: "image-renderer-brightness"),
              payload: .init(value: 0.05)
            )
          ),
          .effect(
            try FeatureNode(
              BrightroomFeatureDefinitions.Saturation.self,
              id: FeatureID(rawValue: "image-renderer-saturation"),
              payload: .init(value: 0.12)
            )
          ),
        ]
      )
    )
    let input = CIImage.parametricColorPatchImage(
      extent: CGRect(x: 0, y: 0, width: 36, height: 24)
    )
    let expected = try Self.compiler.makeOutput(
      from: input,
      document: document
    )
    .image
    let output = try ParametricImageRenderer().makeImage(
      from: input,
      document: document
    )

    try Self.assertImagesMatch(
      expected,
      output,
      tolerance: 2
    )
  }

  func testVideoFrameRendererMatchesFeatureDocumentRendering() throws {
    let document = FeatureDocument(
      mainTree: FeatureMainTree(
        features: [
          .effect(
            try FeatureNode(
              BrightroomFeatureDefinitions.Exposure.self,
              id: FeatureID(rawValue: "video-exposure"),
              payload: .init(value: 0.4)
            )
          ),
          .effect(
            try FeatureNode(
              BrightroomFeatureDefinitions.Brightness.self,
              id: FeatureID(rawValue: "video-brightness"),
              payload: .init(value: 0.04)
            )
          ),
        ]
      )
    )
    let input = CIImage.parametricColorPatchImage(
      extent: CGRect(x: 0, y: 0, width: 44, height: 30)
    )
    let expected = try Self.compiler.makeOutput(
      from: input,
      document: document
    )
    .image
    let output = try ParametricVideoRenderer().makeFrameImage(
      from: input,
      document: document
    )

    try Self.assertImagesMatch(
      expected,
      output,
      tolerance: 2
    )
  }

  func testVideoRendererResolvesCropOutputRenderSize() throws {
    let document = FeatureDocument(
      mainTree: FeatureMainTree(
        features: [
          .domain(
            try FeatureNode(
              BrightroomFeatureDefinitions.Crop.self,
              id: FeatureID(rawValue: "video-crop"),
              payload: .init(cropRect: CGRect(x: 8, y: 6, width: 24, height: 18))
            )
          ),
        ]
      )
    )

    let renderSize = try ParametricVideoRenderer().resolveRenderSize(
      sourceRenderSize: CGSize(width: 48, height: 36),
      document: document,
      mode: .featureOutput
    )

    XCTAssertEqual(renderSize, CGSize(width: 24, height: 18))
  }

  func testVideoRendererCreatesVideoComposition() throws {
    let assetSize = CGSize(width: 48, height: 36)
    let asset = try Self.makeTestVideoAsset(size: assetSize)
    defer {
      try? FileManager.default.removeItem(at: asset.url)
    }
    let document = FeatureDocument(
      mainTree: FeatureMainTree(
        features: [
          .effect(
            try FeatureNode(
              BrightroomFeatureDefinitions.Brightness.self,
              id: FeatureID(rawValue: "video-composition-brightness"),
              payload: .init(value: 0.03)
            )
          ),
        ]
      )
    )

    let composition = try ParametricVideoRenderer().makeVideoComposition(
      for: asset,
      document: document,
      renderSizeMode: .source
    )

    XCTAssertEqual(composition.renderSize, assetSize)
  }

  func testVideoFrameRendererPlacesOutputInsideRenderExtent() throws {
    let document = FeatureDocument(
      mainTree: FeatureMainTree(
        features: [
          .domain(
            try FeatureNode(
              BrightroomFeatureDefinitions.Crop.self,
              id: FeatureID(rawValue: "video-crop-place"),
              payload: .init(cropRect: CGRect(x: 8, y: 6, width: 24, height: 18))
            )
          ),
          .effect(
            try FeatureNode(
              BrightroomFeatureDefinitions.Brightness.self,
              id: FeatureID(rawValue: "video-crop-brightness"),
              payload: .init(value: 0.05)
            )
          ),
        ]
      )
    )
    let input = CIImage.parametricColorPatchImage(
      extent: CGRect(x: 0, y: 0, width: 48, height: 36)
    )
    let renderExtent = CGRect(x: 0, y: 0, width: 48, height: 36)
    let featureOutput = try Self.compiler.makeOutput(
      from: input,
      document: document
    )
    .image
    let expected = featureOutput
      .composited(
        over: CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
          .cropped(to: renderExtent)
      )
      .cropped(to: renderExtent)
    let output = try ParametricVideoRenderer().makeFrameImage(
      from: input,
      document: document,
      renderExtent: renderExtent
    )

    XCTAssertEqual(output.extent, renderExtent)
    try Self.assertImagesMatch(
      expected,
      output,
      tolerance: 2
    )
  }

  func testMultipleCropsEvaluateInCurrentDomain() throws {
    let document = EditingDocument(
      mainTree: MainTree(
        features: [
          .domain(
            .crop(
              CropFeature(
                id: FeatureID(rawValue: "crop-a"),
                cropRect: CGRect(x: 10, y: 10, width: 80, height: 80)
              )
            )
          ),
          .domain(
            .crop(
              CropFeature(
                id: FeatureID(rawValue: "crop-b"),
                cropRect: CGRect(x: 20, y: 20, width: 25, height: 30)
              )
            )
          ),
        ]
      )
    )
    let input = CIImage.parametricTestImage(
      white: 1,
      extent: CGRect(x: 0, y: 0, width: 100, height: 100)
    )

    let output = try Self.compiler.makeOutput(from: input, document: document)

    XCTAssertEqual(output.image.extent, CGRect(x: 0, y: 0, width: 25, height: 30))
  }

  func testImageEffectReceivesCurrentExtentAfterCrop() throws {
    var registry = FeatureRegistry.brightroomDefault
    registry.registerImageEffect(TestExtentProbeFeature.self)
    let compiler = FeatureGraphCompiler(featureRegistry: registry)
    let document = FeatureDocument(
      mainTree: FeatureMainTree(
        features: [
          .domain(
            try FeatureNode(
              BrightroomFeatureDefinitions.Crop.self,
              id: FeatureID(rawValue: "extent-probe-crop"),
              payload: .init(cropRect: CGRect(x: 10, y: 8, width: 40, height: 20))
            )
          ),
          .effect(
            try FeatureNode(
              TestExtentProbeFeature.self,
              id: FeatureID(rawValue: "extent-probe-effect"),
              payload: .init()
            )
          ),
        ]
      )
    )
    let input = CIImage.parametricColorPatchImage(
      extent: CGRect(x: 0, y: 0, width: 80, height: 60)
    )

    let output = try compiler.makeOutput(from: input, document: document)

    XCTAssertEqual(output.image.extent, CGRect(x: 0, y: 0, width: 40, height: 20))
    let rendered = try Self.render(output.image)
    let pixel = Self.rgba(in: rendered, x: 20, y: 10)
    XCTAssertLessThanOrEqual(abs(Int(pixel.red) - 102), 2)
    XCTAssertLessThanOrEqual(abs(Int(pixel.green) - 51), 2)
  }

  func testVignetteUsesCurrentExtentAfterCrop() throws {
    let document = FeatureDocument(
      mainTree: FeatureMainTree(
        features: [
          .domain(
            try FeatureNode(
              BrightroomFeatureDefinitions.Crop.self,
              id: FeatureID(rawValue: "vignette-crop"),
              payload: .init(cropRect: CGRect(x: 10, y: 8, width: 40, height: 20))
            )
          ),
          .effect(
            try FeatureNode(
              BrightroomFeatureDefinitions.Vignette.self,
              id: FeatureID(rawValue: "vignette-after-crop"),
              payload: .init(value: 0.5)
            )
          ),
        ]
      )
    )
    let input = CIImage.parametricColorPatchImage(
      extent: CGRect(x: 0, y: 0, width: 80, height: 60)
    )
    let cropped = input
      .cropped(to: CGRect(x: 10, y: 8, width: 40, height: 20))
      .transformed(by: CGAffineTransform(translationX: -10, y: -8))
    let expected = Self.vignetteEffectImage(value: 0.5, image: cropped)

    let output = try Self.compiler.makeOutput(from: input, document: document)

    try Self.assertImagesMatch(expected, output.image, tolerance: 2)
  }

  func testLocalAdjustmentsAndGlobalEffectEvaluateInOrder() throws {
    let localExposure = LocalAdjustmentFeature(
      id: FeatureID(rawValue: "local-exposure"),
      maskTree: MaskTree(
        root: .brush(
          BrushMask(
            id: FeatureID(rawValue: "exposure-mask"),
            strokes: [
              BrushMaskStroke(
                stamps: [CGPoint(x: 10, y: 10)],
                brush: BrushMaskBrush(diameter: 16, hardness: 1, opacity: 1)
              ),
            ]
          )
        )
      ),
      effectPipeline: EffectPipeline(
        effects: [
          .exposure(ExposureFeature(id: FeatureID(rawValue: "local-exposure-effect"), value: 1)),
        ]
      )
    )
    let localBlur = LocalAdjustmentFeature(
      id: FeatureID(rawValue: "local-blur"),
      maskTree: MaskTree(
        root: .brush(
          BrushMask(
            id: FeatureID(rawValue: "blur-mask"),
            strokes: [
              BrushMaskStroke(
                stamps: [CGPoint(x: 20, y: 10)],
                brush: BrushMaskBrush(diameter: 18, hardness: 1, opacity: 1)
              ),
            ]
          )
        )
      ),
      effectPipeline: EffectPipeline(
        effects: [
          .gaussianBlur(GaussianBlurFeature(id: FeatureID(rawValue: "blur-effect"), radius: 5)),
        ]
      )
    )
    let document = EditingDocument(
      mainTree: MainTree(
        features: [
          .localAdjustment(localExposure),
          .localAdjustment(localBlur),
          .effect(.brightness(BrightnessFeature(id: FeatureID(rawValue: "global-brightness"), value: 0.05))),
        ]
      )
    )
    let input = CIImage.parametricVerticalStripeImage(
      extent: CGRect(x: 0, y: 0, width: 40, height: 20),
      backgroundWhite: 0.15,
      stripeWhite: 0.9,
      stripeRect: CGRect(x: 22, y: 0, width: 2, height: 20)
    )

    let output = try Self.compiler.makeOutput(from: input, document: document)
    let renderedImage = try Self.render(output.image)
    let localPixel = Self.rgba(in: renderedImage, x: 10, y: 10)
    let outsidePixel = Self.rgba(in: renderedImage, x: 0, y: 10)
    let blurredNeighborPixel = Self.rgba(in: renderedImage, x: 19, y: 10)
    let stripePixel = Self.rgba(in: renderedImage, x: 22, y: 10)

    XCTAssertGreaterThan(localPixel.red, outsidePixel.red)
    XCTAssertGreaterThan(blurredNeighborPixel.red, outsidePixel.red)
    XCTAssertLessThan(blurredNeighborPixel.red, stripePixel.red)
  }

  func testEditingStackFiltersBridgeMatchesLegacyFilterRendering() throws {
    var filters = EditingStack.Edit.Filters()
    filters.exposure = {
      var filter = FilterExposure()
      filter.value = 0.15
      return filter
    }()
    filters.brightness = {
      var filter = FilterBrightness()
      filter.value = 0.03
      return filter
    }()
    filters.temperature = {
      var filter = FilterTemperature()
      filter.value = 600
      return filter
    }()
    filters.highlights = {
      var filter = FilterHighlights()
      filter.value = 0.2
      return filter
    }()
    filters.shadows = {
      var filter = FilterShadows()
      filter.value = 0.15
      return filter
    }()
    filters.saturation = {
      var filter = FilterSaturation()
      filter.value = 0.08
      return filter
    }()
    filters.contrast = {
      var filter = FilterContrast()
      filter.value = 0.04
      return filter
    }()
    filters.sharpen = {
      var filter = FilterSharpen()
      filter.sharpness = 0.2
      filter.radius = 4
      return filter
    }()
    filters.unsharpMask = {
      var filter = FilterUnsharpMask()
      filter.intensity = 0.1
      filter.radius = 0.3
      return filter
    }()
    filters.gaussianBlur = {
      var filter = FilterGaussianBlur()
      filter.value = 3
      return filter
    }()
    filters.fade = {
      var filter = FilterFade()
      filter.intensity = 0.04
      return filter
    }()
    filters.vignette = {
      var filter = FilterVignette()
      filter.value = 0.3
      return filter
    }()

    let pipeline = try EffectPipeline(
      editingStackFilters: filters,
      idPrefix: "legacy-filter"
    )
    let document = EditingDocument(
      mainTree: MainTree(features: pipeline.effects.map(MainFeature.effect))
    )
    let input = CIImage.parametricColorPatchImage(
      extent: CGRect(x: 0, y: 0, width: 80, height: 60)
    )

    let legacyImage = filters.apply(to: input)
    let output = try Self.compiler.makeOutput(from: input, document: document)

    try Self.assertImagesMatch(
      legacyImage,
      output.image,
      tolerance: 2
    )

    let featurePipeline = try FeatureEffectPipeline(
      editingStackFilters: filters,
      idPrefix: "legacy-feature-node-filter"
    )
    let featureDocument = FeatureDocument(
      mainTree: FeatureMainTree(features: featurePipeline.effects.map(FeatureTreeNode.effect))
    )
    let featureOutput = try Self.compiler.makeOutput(from: input, document: featureDocument)

    try Self.assertImagesMatch(
      legacyImage,
      featureOutput.image,
      tolerance: 2
    )
  }

  func testPresetAndAdditionalFiltersBridgeWhenFiltersAreBuiltIn() throws {
    var colorCube = FilterColorCube(
      name: "Test Cube",
      identifier: "test-cube",
      cubeData: Self.makeColorCubeData(dimension: 2),
      dimension: 2
    )
    colorCube.amount = 0.5
    let preset = FilterPreset(
      name: "Preset",
      identifier: "preset",
      filters: [colorCube.asAny()],
      userInfo: [:]
    )
    var additionalFade = FilterFade()
    additionalFade.intensity = 0.1
    var additionalTint = FilterHighlightShadowTint()
    additionalTint.highlightColor = CIColor(red: 1, green: 0.2, blue: 0.1, alpha: 0.05)
    additionalTint.shadowColor = CIColor(red: 0.1, green: 0.2, blue: 1, alpha: 0.04)

    var filters = EditingStack.Edit.Filters()
    filters.preset = preset
    filters.additionalFilters = [additionalFade.asAny(), additionalTint.asAny()]

    let pipeline = try EffectPipeline(
      editingStackFilters: filters,
      idPrefix: "preset-filter"
    )
    let document = EditingDocument(
      mainTree: MainTree(features: pipeline.effects.map(MainFeature.effect))
    )
    let input = CIImage.parametricColorPatchImage(
      extent: CGRect(x: 0, y: 0, width: 32, height: 32)
    )

    let legacyImage = filters.apply(to: input)
    let output = try Self.compiler.makeOutput(from: input, document: document)

    try Self.assertImagesMatch(
      legacyImage,
      output.image,
      tolerance: 2
    )

    let featurePipeline = try FeatureEffectPipeline(
      editingStackFilters: filters,
      idPrefix: "preset-feature-node-filter"
    )
    let featureDocument = FeatureDocument(
      mainTree: FeatureMainTree(features: featurePipeline.effects.map(FeatureTreeNode.effect))
    )
    let featureOutput = try Self.compiler.makeOutput(from: input, document: featureDocument)

    try Self.assertImagesMatch(
      legacyImage,
      featureOutput.image,
      tolerance: 2
    )
  }

  func testInvertedMaskAppliesOutsideBrush() throws {
    let document = EditingDocument(
      mainTree: MainTree(
        features: [
          .localAdjustment(
            LocalAdjustmentFeature(
              id: FeatureID(rawValue: "local-invert"),
              maskTree: MaskTree(
                root: .invert(
                  .brush(
                    BrushMask(
                      id: FeatureID(rawValue: "center-mask"),
                      strokes: [
                        BrushMaskStroke(
                          stamps: [CGPoint(x: 10, y: 10)],
                          brush: BrushMaskBrush(diameter: 12, hardness: 1, opacity: 1)
                        ),
                      ]
                    )
                  )
                )
              ),
              effectPipeline: EffectPipeline(
                effects: [
                  .exposure(ExposureFeature(id: FeatureID(rawValue: "invert-exposure"), value: 1)),
                ]
              )
            )
          ),
        ]
      )
    )
    let input = CIImage.parametricTestImage(
      white: 0.2,
      extent: CGRect(x: 0, y: 0, width: 20, height: 20)
    )

    let output = try Self.compiler.makeOutput(from: input, document: document)
    let renderedImage = try Self.render(output.image)
    let center = Self.rgba(in: renderedImage, x: 10, y: 10)
    let corner = Self.rgba(in: renderedImage, x: 1, y: 1)

    XCTAssertGreaterThan(corner.red, center.red)
  }

  func testDuplicateIDsThrowValidationError() throws {
    let id = FeatureID(rawValue: "duplicate")
    let document = EditingDocument(
      mainTree: MainTree(
        features: [
          .effect(.brightness(BrightnessFeature(id: id, value: 0.1))),
          .effect(.exposure(ExposureFeature(id: id, value: 0.1))),
        ]
      )
    )

    XCTAssertThrowsError(
      try Self.compiler.makeOutput(from: Self.smallInput, document: document)
    ) { error in
      XCTAssertEqual(error as? FeatureGraphCompilerError, .duplicateID(id))
    }
  }

  func testEmptyLocalAdjustmentPipelineThrowsValidationError() throws {
    let id = FeatureID(rawValue: "empty-local")
    let document = EditingDocument(
      mainTree: MainTree(
        features: [
          .localAdjustment(
            LocalAdjustmentFeature(
              id: id,
              maskTree: MaskTree(root: .brush(BrushMask(id: FeatureID(rawValue: "mask")))),
              effectPipeline: EffectPipeline()
            )
          ),
        ]
      )
    )

    XCTAssertThrowsError(
      try Self.compiler.makeOutput(from: Self.smallInput, document: document)
    ) { error in
      XCTAssertEqual(error as? FeatureGraphCompilerError, .emptyLocalAdjustmentEffectPipeline(id))
    }
  }

  func testMetalKernelRegistryCanCreateBrushStampRecipe() throws {
    let registry = ParametricKernelRegistry()

    let image = try registry.makeBrushStamp(
      extent: CGRect(x: 0, y: 0, width: 12, height: 12),
      center: CGPoint(x: 6, y: 6),
      radius: 4,
      hardness: 0.5,
      opacity: 1
    )

    XCTAssertEqual(image.extent, CGRect(x: 0, y: 0, width: 12, height: 12))
  }

  private static let compiler = FeatureGraphCompiler()

  private static let smallInput = CIImage.parametricTestImage(
    white: 0.5,
    extent: CGRect(x: 0, y: 0, width: 8, height: 8)
  )

  private static let context = CIContext()

  private static func render(_ image: CIImage) throws -> CGImage {
    try XCTUnwrap(Self.context.createCGImage(image, from: image.extent))
  }

  private static func rgba(in image: CGImage, x: Int, y: Int) -> RGBA {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue
    )!

    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    let index = (y * width + x) * 4
    return RGBA(
      red: pixels[index],
      green: pixels[index + 1],
      blue: pixels[index + 2],
      alpha: pixels[index + 3]
    )
  }

  private static func assertImagesMatch(
    _ lhs: CIImage,
    _ rhs: CIImage,
    tolerance: Int,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    XCTAssertEqual(lhs.extent, rhs.extent, file: file, line: line)

    let lhsImage = try render(lhs)
    let rhsImage = try render(rhs)
    XCTAssertEqual(lhsImage.width, rhsImage.width, file: file, line: line)
    XCTAssertEqual(lhsImage.height, rhsImage.height, file: file, line: line)

    let sampleXs = [4, lhsImage.width / 3, lhsImage.width / 2, max(lhsImage.width - 5, 0)]
    let sampleYs = [4, lhsImage.height / 3, lhsImage.height / 2, max(lhsImage.height - 5, 0)]

    for y in sampleYs {
      for x in sampleXs {
        let lhsPixel = rgba(in: lhsImage, x: x, y: y)
        let rhsPixel = rgba(in: rhsImage, x: x, y: y)
        XCTAssertLessThanOrEqual(
          abs(Int(lhsPixel.red) - Int(rhsPixel.red)),
          tolerance,
          "red mismatch at \(x),\(y)",
          file: file,
          line: line
        )
        XCTAssertLessThanOrEqual(
          abs(Int(lhsPixel.green) - Int(rhsPixel.green)),
          tolerance,
          "green mismatch at \(x),\(y)",
          file: file,
          line: line
        )
        XCTAssertLessThanOrEqual(
          abs(Int(lhsPixel.blue) - Int(rhsPixel.blue)),
          tolerance,
          "blue mismatch at \(x),\(y)",
          file: file,
          line: line
        )
        XCTAssertLessThanOrEqual(
          abs(Int(lhsPixel.alpha) - Int(rhsPixel.alpha)),
          tolerance,
          "alpha mismatch at \(x),\(y)",
          file: file,
          line: line
        )
      }
    }
  }

  private static func vignetteEffectImage(value: Double, image: CIImage) -> CIImage {
    let extent = image.extent
    let radius = max(extent.width, extent.height) * 0.5
    return image.applyingFilter(
      "CIVignetteEffect",
      parameters: [
        kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
        kCIInputRadiusKey: radius,
        kCIInputIntensityKey: value,
        "inputFalloff": 0.5,
      ]
    )
    .cropped(to: extent)
  }

  private static func makeColorCubeData(dimension: Int) -> Data {
    var values: [Float] = []
    values.reserveCapacity(dimension * dimension * dimension * 4)

    for blueIndex in 0..<dimension {
      for greenIndex in 0..<dimension {
        for redIndex in 0..<dimension {
          let denominator = Float(max(dimension - 1, 1))
          let red = Float(redIndex) / denominator
          let green = Float(greenIndex) / denominator
          let blue = Float(blueIndex) / denominator

          values.append(1 - red)
          values.append(green)
          values.append(blue * 0.6)
          values.append(1)
        }
      }
    }

    return values.withUnsafeBufferPointer { buffer in
      Data(
        bytes: buffer.baseAddress!,
        count: buffer.count * MemoryLayout<Float>.size
      )
    }
  }

  private static func makeTestVideoAsset(size: CGSize) throws -> AVURLAsset {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("brightroom-parametric-\(UUID().uuidString)")
      .appendingPathExtension("mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(size.width),
        AVVideoHeightKey: Int(size.height),
      ]
    )
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(size.width),
        kCVPixelBufferHeightKey as String: Int(size.height),
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
      ]
    )

    guard writer.canAdd(input) else {
      throw TestVideoAssetError.cannotAddInput
    }

    writer.add(input)

    guard writer.startWriting() else {
      throw writer.error ?? TestVideoAssetError.cannotStartWriting
    }

    writer.startSession(atSourceTime: .zero)

    let pixelBuffer = try makeTestPixelBuffer(
      width: Int(size.width),
      height: Int(size.height)
    )
    while !input.isReadyForMoreMediaData {
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    guard adaptor.append(pixelBuffer, withPresentationTime: .zero) else {
      throw writer.error ?? TestVideoAssetError.cannotAppendFrame
    }

    input.markAsFinished()

    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting {
      semaphore.signal()
    }
    semaphore.wait()

    guard writer.status == .completed else {
      throw writer.error ?? TestVideoAssetError.cannotFinishWriting(writer.status)
    }

    return AVURLAsset(url: url)
  }

  private static func makeTestPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let result = CVPixelBufferCreate(
      kCFAllocatorDefault,
      width,
      height,
      kCVPixelFormatType_32BGRA,
      [
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
      ] as CFDictionary,
      &pixelBuffer
    )

    guard result == kCVReturnSuccess, let pixelBuffer else {
      throw TestVideoAssetError.cannotCreatePixelBuffer(result)
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer {
      CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    }

    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
      throw TestVideoAssetError.missingPixelBufferBaseAddress
    }

    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

    for y in 0..<height {
      let row = baseAddress
        .advanced(by: y * bytesPerRow)
        .assumingMemoryBound(to: UInt8.self)

      for x in 0..<width {
        let offset = x * 4
        row[offset] = UInt8(80 + (x % 24))
        row[offset + 1] = UInt8(100 + (y % 32))
        row[offset + 2] = UInt8(160)
        row[offset + 3] = UInt8(255)
      }
    }

    return pixelBuffer
  }

  private struct RGBA: Equatable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8
    var alpha: UInt8
  }

  private enum TestRedBoostFeature: ImageEffectFeatureDefinition {

    static let typeID: FeatureTypeID = "test.effect.redBoost"
    static let currentSchemaVersion = 1

    struct Payload: Codable, Equatable, Sendable {
      var amount: Double
    }

    static func apply(
      payload: Payload,
      node: FeatureNode,
      to image: CIImage,
      context: FeatureEvaluationContext
    ) throws -> CIImage {
      image.applyingFilter(
        "CIColorMatrix",
        parameters: [
          "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
          "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
          "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
          "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
          "inputBiasVector": CIVector(x: CGFloat(payload.amount), y: 0, z: 0, w: 0),
        ]
      )
      .cropped(to: image.extent)
    }
  }

  private enum TestExtentProbeFeature: ImageEffectFeatureDefinition {

    static let typeID: FeatureTypeID = "test.effect.extentProbe"
    static let currentSchemaVersion = 1

    struct Payload: Codable, Equatable, Sendable {
      init() {}
    }

    static func apply(
      payload: Payload,
      node: FeatureNode,
      to image: CIImage,
      context: FeatureEvaluationContext
    ) throws -> CIImage {
      CIImage(
        color: CIColor(
          red: min(image.extent.width / 100, 1),
          green: min(image.extent.height / 100, 1),
          blue: 0,
          alpha: 1
        )
      )
      .cropped(to: image.extent)
    }
  }

  private enum TestVideoAssetError: Error {
    case cannotAddInput
    case cannotStartWriting
    case cannotAppendFrame
    case cannotFinishWriting(AVAssetWriter.Status)
    case cannotCreatePixelBuffer(CVReturn)
    case missingPixelBufferBaseAddress
  }
}

private extension CIImage {

  static func parametricTestImage(white: CGFloat, extent: CGRect) -> CIImage {
    CIImage(color: CIColor(red: white, green: white, blue: white, alpha: 1))
      .cropped(to: extent)
  }

  static func parametricVerticalStripeImage(
    extent: CGRect,
    backgroundWhite: CGFloat,
    stripeWhite: CGFloat,
    stripeRect: CGRect
  ) -> CIImage {
    let background = CIImage.parametricTestImage(
      white: backgroundWhite,
      extent: extent
    )
    let stripe = CIImage.parametricTestImage(white: stripeWhite, extent: stripeRect)

    return stripe.applyingFilter(
      "CISourceOverCompositing",
      parameters: [kCIInputBackgroundImageKey: background]
    )
    .cropped(to: extent)
  }

  static func parametricColorPatchImage(extent: CGRect) -> CIImage {
    let background = CIImage(color: CIColor(red: 0.18, green: 0.32, blue: 0.52, alpha: 1))
      .cropped(to: extent)
    let warmPatch = CIImage(color: CIColor(red: 0.86, green: 0.26, blue: 0.18, alpha: 0.82))
      .cropped(
        to: CGRect(
          x: extent.minX + extent.width * 0.18,
          y: extent.minY,
          width: extent.width * 0.22,
          height: extent.height
        )
      )
    let coolPatch = CIImage(color: CIColor(red: 0.16, green: 0.45, blue: 0.92, alpha: 0.78))
      .cropped(
        to: CGRect(
          x: extent.minX + extent.width * 0.56,
          y: extent.minY,
          width: extent.width * 0.28,
          height: extent.height
        )
      )
    let brightPatch = CIImage(color: CIColor(red: 0.95, green: 0.92, blue: 0.76, alpha: 0.65))
      .cropped(
        to: CGRect(
          x: extent.minX,
          y: extent.minY + extent.height * 0.2,
          width: extent.width,
          height: extent.height * 0.3
        )
      )

    return [warmPatch, coolPatch, brightPatch].reduce(background) { image, patch in
      patch.applyingFilter(
        "CISourceOverCompositing",
        parameters: [kCIInputBackgroundImageKey: image]
      )
    }
    .cropped(to: extent)
  }
}
