import AVFoundation
import CoreImage
import Foundation
import Testing

@testable import BrightroomEngine
@testable import BrightroomParametric

struct ParametricFeatureTreeTests {

  @Test func documentCodableRoundTrip() throws {
    let document = EditingDocument(
      mainTree: MainTree(
        features: [
          .domain(
            CropFeature(
              id: FeatureID(rawValue: "crop-a"),
              cropRect: CGRect(x: 4, y: 5, width: 30, height: 20)
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
                  BrightnessFeature(id: FeatureID(rawValue: "brightness-a"), value: 0.1),
                  GaussianBlurFeature(id: FeatureID(rawValue: "blur-a"), radius: 3),
                ]
              )
            )
          ),
          .effect(
            ExposureFeature(id: FeatureID(rawValue: "exposure-a"), value: 0.25)
          ),
          .effect(ContrastFeature(id: FeatureID(rawValue: "contrast-a"), value: 0.08)),
          .effect(SaturationFeature(id: FeatureID(rawValue: "saturation-a"), value: 0.12)),
          .effect(HighlightsFeature(id: FeatureID(rawValue: "highlights-a"), value: 0.2)),
          .effect(ShadowsFeature(id: FeatureID(rawValue: "shadows-a"), value: 0.15)),
          .effect(
            HighlightShadowTintFeature(
              id: FeatureID(rawValue: "highlight-shadow-tint-a"),
              highlightColor: ParametricRGBAColor(red: 1, green: 0.2, blue: 0.1, alpha: 0.05),
              shadowColor: ParametricRGBAColor(red: 0.1, green: 0.2, blue: 1, alpha: 0.04)
            )
          ),
          .effect(TemperatureFeature(id: FeatureID(rawValue: "temperature-a"), value: 450)),
          .effect(SharpenFeature(id: FeatureID(rawValue: "sharpen-a"), sharpness: 0.2, radius: 4)),
          .effect(UnsharpMaskFeature(id: FeatureID(rawValue: "unsharp-a"), intensity: 0.1, radius: 0.25)),
          .effect(VignetteFeature(id: FeatureID(rawValue: "vignette-a"), value: 0.35)),
          .effect(FadeFeature(id: FeatureID(rawValue: "fade-a"), intensity: 0.05)),
        ]
      )
    )

    let codec = ParametricDocumentCodec()
    let data = try codec.encode(document)
    let decoded = try codec.decode(data)

    #expect(decoded == document)
  }

  @Test func codecRoundTripMatchesOriginalDocumentRendering() throws {
    let document = EditingDocument(
      mainTree: MainTree(
        features: [
          .domain(
            CropFeature(
              id: FeatureID(rawValue: "node-crop"),
              cropRect: CGRect(x: 4, y: 3, width: 36, height: 24)
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
                  ExposureFeature(id: FeatureID(rawValue: "node-local-exposure"), value: 0.5),
                ]
              )
            )
          ),
          .effect(BrightnessFeature(id: FeatureID(rawValue: "node-brightness"), value: 0.05)),
        ]
      )
    )
    let codec = ParametricDocumentCodec()
    let data = try codec.encode(document)
    let decoded = try codec.decode(data)
    let input = CIImage.parametricColorPatchImage(
      extent: CGRect(x: 0, y: 0, width: 48, height: 36)
    )

    let originalOutput = try Self.compiler.makeOutput(from: input, document: document)
    let decodedOutput = try Self.compiler.makeOutput(from: input, document: decoded)

    #expect(decoded == document)
    try Self.assertImagesMatch(
      originalOutput.image,
      decodedOutput.image,
      tolerance: 2
    )
  }

  @Test func customRegisteredFeatureRendersLikeDefaultFeatures() throws {
    var codec = ParametricDocumentCodec()
    codec.register(TestRedBoostFeature.self)
    let document = EditingDocument(
      mainTree: MainTree(
        features: [
          .effect(
            TestRedBoostFeature(
              id: FeatureID(rawValue: "custom-red-boost"),
              amount: 0.25
            )
          ),
          .effect(
            BrightnessFeature(
              id: FeatureID(rawValue: "registry-brightness"),
              value: 0.02
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

    let data = try codec.encode(document)
    let decoded = try codec.decode(data)
    let output = try FeatureGraphCompiler().makeOutput(from: input, document: decoded)

    try Self.assertImagesMatch(
      expected,
      output.image,
      tolerance: 2
    )
  }

  @Test func codecRoundTripPreservesDocumentWithCustomRegisteredFeature() throws {
    var codec = ParametricDocumentCodec()
    codec.register(TestRedBoostFeature.self)
    let document = EditingDocument(
      mainTree: MainTree(
        features: [
          .effect(
            TestRedBoostFeature(
              id: FeatureID(rawValue: "round-trip-red-boost"),
              amount: 0.4
            )
          ),
          .effect(
            BrightnessFeature(
              id: FeatureID(rawValue: "round-trip-brightness"),
              value: 0.03
            )
          ),
        ]
      )
    )

    let data = try codec.encode(document)
    let decoded = try codec.decode(data)

    #expect(decoded == document)
  }

  @Test func decodingUnregisteredFeatureTypeThrows() throws {
    var registeringCodec = ParametricDocumentCodec()
    registeringCodec.register(TestRedBoostFeature.self)
    let document = EditingDocument(
      mainTree: MainTree(
        features: [
          .effect(
            TestRedBoostFeature(
              id: FeatureID(rawValue: "unregistered-red-boost"),
              amount: 0.1
            )
          ),
        ]
      )
    )
    let data = try registeringCodec.encode(document)

    let plainCodec = ParametricDocumentCodec()
    #expect(
      throws: ParametricDocumentCodecError.unregisteredFeatureType(TestRedBoostFeature.featureTypeKey)
    ) {
      try plainCodec.decode(data)
    }
  }

  @Test func encodingUnregisteredFeatureTypeThrowsAtSaveTime() throws {
    // A codec must refuse to write a document it cannot read back.
    let document = EditingDocument(
      mainTree: MainTree(
        features: [
          .effect(
            TestRedBoostFeature(
              id: FeatureID(rawValue: "save-time-red-boost"),
              amount: 0.1
            )
          ),
        ]
      )
    )

    let plainCodec = ParametricDocumentCodec()
    #expect(
      throws: ParametricDocumentCodecError.unregisteredFeatureType(TestRedBoostFeature.featureTypeKey)
    ) {
      try plainCodec.encode(document)
    }
  }

  @Test func plainJSONCodingWithoutCodecThrowsMissingRegistry() throws {
    let document = EditingDocument(
      mainTree: MainTree(
        features: [
          .effect(BrightnessFeature(id: FeatureID(rawValue: "plain-brightness"), value: 0.1)),
        ]
      )
    )

    #expect(throws: ParametricDocumentCodecError.missingRegistry) {
      try JSONEncoder().encode(document)
    }

    let codec = ParametricDocumentCodec()
    let data = try codec.encode(document)
    #expect(throws: ParametricDocumentCodecError.missingRegistry) {
      try JSONDecoder().decode(EditingDocument.self, from: data)
    }
  }

  @Test func schemaVersionMigrationDecodesOldPayload() throws {
    // Write with the v1 shape under the shared key, then decode with the v2
    // type whose decodeParameters converts the old payload.
    var writingCodec = ParametricDocumentCodec()
    writingCodec.register(TestMigratingFeatureV1.self)
    let document = EditingDocument(
      mainTree: MainTree(
        features: [
          .effect(
            TestMigratingFeatureV1(
              id: FeatureID(rawValue: "migrating-feature"),
              amount: 0.5
            )
          ),
        ]
      )
    )
    let data = try writingCodec.encode(document)

    var readingCodec = ParametricDocumentCodec()
    readingCodec.register(TestMigratingFeatureV2.self)
    let decoded = try readingCodec.decode(data)

    let firstFeature = try #require(decoded.mainTree.features.first)
    guard case let .effect(effect) = firstFeature else {
      Issue.record("expected the migrated v2 feature")
      return
    }
    let migrated = try #require(effect as? TestMigratingFeatureV2, "expected the migrated v2 feature")
    #expect(migrated.id == FeatureID(rawValue: "migrating-feature"))
    #expect(migrated.strength == 0.5)
  }

  @Test func unsupportedDocumentFormatVersionThrows() throws {
    let codec = ParametricDocumentCodec()
    let document = EditingDocument(
      mainTree: MainTree(
        features: [
          .effect(BrightnessFeature(id: FeatureID(rawValue: "format-brightness"), value: 0.1)),
        ]
      )
    )
    let data = try codec.encode(document)
    let mutated = String(decoding: data, as: UTF8.self)
      .replacingOccurrences(of: "\"formatVersion\":1", with: "\"formatVersion\":99")
      .data(using: .utf8)!

    #expect(throws: ParametricDocumentCodecError.unsupportedDocumentFormatVersion(99)) {
      try codec.decode(mutated)
    }
  }

  @Test func parametricImageRendererMatchesFeatureGraphCompiler() throws {
    let document = EditingDocument(
      mainTree: MainTree(
        features: [
          .effect(
            BrightnessFeature(
              id: FeatureID(rawValue: "image-renderer-brightness"),
              value: 0.05
            )
          ),
          .effect(
            SaturationFeature(
              id: FeatureID(rawValue: "image-renderer-saturation"),
              value: 0.12
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

  /// An `EffectPipelineFeature` (the document's bundled global-effects node)
  /// must render identically to the same effects scattered as individual
  /// `.effect` main-tree features. This is the contract that lets the editing
  /// stack store one identity-stable effects node while the compiler flattens
  /// it through `childFeatures`.
  @Test func effectPipelineFeatureMatchesScatteredEffects() throws {
    let brightness = BrightnessFeature(id: FeatureID(rawValue: "pipeline-brightness"), value: 0.05)
    let saturation = SaturationFeature(id: FeatureID(rawValue: "pipeline-saturation"), value: 0.12)

    let scattered = EditingDocument(
      mainTree: MainTree(features: [.effect(brightness), .effect(saturation)])
    )
    let bundled = EditingDocument(
      mainTree: MainTree(features: [
        .effect(
          EffectPipelineFeature(
            id: FeatureID(rawValue: "pipeline-node"),
            pipeline: EffectPipeline(effects: [brightness, saturation])
          )
        )
      ])
    )

    let input = CIImage.parametricColorPatchImage(
      extent: CGRect(x: 0, y: 0, width: 36, height: 24)
    )
    let scatteredOutput = try Self.compiler.makeOutput(from: input, document: scattered).image
    let bundledOutput = try Self.compiler.makeOutput(from: input, document: bundled).image

    try Self.assertImagesMatch(scatteredOutput, bundledOutput, tolerance: 2)
  }

  @Test func videoFrameRendererMatchesDocumentRendering() throws {
    let document = EditingDocument(
      mainTree: MainTree(
        features: [
          .effect(
            ExposureFeature(
              id: FeatureID(rawValue: "video-exposure"),
              value: 0.4
            )
          ),
          .effect(
            BrightnessFeature(
              id: FeatureID(rawValue: "video-brightness"),
              value: 0.04
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

  @Test func videoRendererResolvesCropOutputRenderSize() throws {
    let document = EditingDocument(
      mainTree: MainTree(
        features: [
          .domain(
            CropFeature(
              id: FeatureID(rawValue: "video-crop"),
              cropRect: CGRect(x: 8, y: 6, width: 24, height: 18)
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

    #expect(renderSize == CGSize(width: 24, height: 18))
  }

  @Test func videoRendererCreatesVideoComposition() throws {
    let assetSize = CGSize(width: 48, height: 36)
    let asset = try Self.makeTestVideoAsset(size: assetSize)
    defer {
      try? FileManager.default.removeItem(at: asset.url)
    }
    let document = EditingDocument(
      mainTree: MainTree(
        features: [
          .effect(
            BrightnessFeature(
              id: FeatureID(rawValue: "video-composition-brightness"),
              value: 0.03
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

    #expect(composition.renderSize == assetSize)
  }

  @Test func videoFrameRendererPlacesOutputInsideRenderExtent() throws {
    let document = EditingDocument(
      mainTree: MainTree(
        features: [
          .domain(
            CropFeature(
              id: FeatureID(rawValue: "video-crop-place"),
              cropRect: CGRect(x: 8, y: 6, width: 24, height: 18)
            )
          ),
          .effect(
            BrightnessFeature(
              id: FeatureID(rawValue: "video-crop-brightness"),
              value: 0.05
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

    #expect(output.extent == renderExtent)
    try Self.assertImagesMatch(
      expected,
      output,
      tolerance: 2
    )
  }

  @Test func multipleCropsEvaluateInCurrentDomain() throws {
    let document = EditingDocument(
      mainTree: MainTree(
        features: [
          .domain(
            CropFeature(
              id: FeatureID(rawValue: "crop-a"),
              cropRect: CGRect(x: 10, y: 10, width: 80, height: 80)
            )
          ),
          .domain(
            CropFeature(
              id: FeatureID(rawValue: "crop-b"),
              cropRect: CGRect(x: 20, y: 20, width: 25, height: 30)
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

    #expect(output.image.extent == CGRect(x: 0, y: 0, width: 25, height: 30))
  }

  @Test func imageEffectReceivesCurrentExtentAfterCrop() throws {
    let document = EditingDocument(
      mainTree: MainTree(
        features: [
          .domain(
            CropFeature(
              id: FeatureID(rawValue: "extent-probe-crop"),
              cropRect: CGRect(x: 10, y: 8, width: 40, height: 20)
            )
          ),
          .effect(
            TestExtentProbeFeature(
              id: FeatureID(rawValue: "extent-probe-effect")
            )
          ),
        ]
      )
    )
    let input = CIImage.parametricColorPatchImage(
      extent: CGRect(x: 0, y: 0, width: 80, height: 60)
    )

    let output = try FeatureGraphCompiler().makeOutput(from: input, document: document)

    #expect(output.image.extent == CGRect(x: 0, y: 0, width: 40, height: 20))
    let rendered = try Self.render(output.image)
    let pixel = Self.rgba(in: rendered, x: 20, y: 10)
    #expect(abs(Int(pixel.red) - 102) <= 2)
    #expect(abs(Int(pixel.green) - 51) <= 2)
  }

  @Test func vignetteUsesCurrentExtentAfterCrop() throws {
    let document = EditingDocument(
      mainTree: MainTree(
        features: [
          .domain(
            CropFeature(
              id: FeatureID(rawValue: "vignette-crop"),
              cropRect: CGRect(x: 10, y: 8, width: 40, height: 20)
            )
          ),
          .effect(
            VignetteFeature(
              id: FeatureID(rawValue: "vignette-after-crop"),
              value: 0.5
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

  @Test func localAdjustmentsAndGlobalEffectEvaluateInOrder() throws {
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
          ExposureFeature(id: FeatureID(rawValue: "local-exposure-effect"), value: 1),
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
          GaussianBlurFeature(id: FeatureID(rawValue: "blur-effect"), radius: 5),
        ]
      )
    )
    let document = EditingDocument(
      mainTree: MainTree(
        features: [
          .localAdjustment(localExposure),
          .localAdjustment(localBlur),
          .effect(BrightnessFeature(id: FeatureID(rawValue: "global-brightness"), value: 0.05)),
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

    #expect(localPixel.red > outsidePixel.red)
    #expect(blurredNeighborPixel.red > outsidePixel.red)
    #expect(blurredNeighborPixel.red < stripePixel.red)
  }

  @Test func invertedMaskAppliesOutsideBrush() throws {
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
                  ExposureFeature(id: FeatureID(rawValue: "invert-exposure"), value: 1),
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

    #expect(corner.red > center.red)
  }

  @Test func duplicateIDsThrowValidationError() throws {
    let id = FeatureID(rawValue: "duplicate")
    let document = EditingDocument(
      mainTree: MainTree(
        features: [
          .effect(BrightnessFeature(id: id, value: 0.1)),
          .effect(ExposureFeature(id: id, value: 0.1)),
        ]
      )
    )

    #expect(throws: FeatureGraphCompilerError.duplicateID(id)) {
      try Self.compiler.makeOutput(from: Self.smallInput, document: document)
    }
  }

  @Test func emptyLocalAdjustmentPipelineThrowsValidationError() throws {
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

    #expect(throws: FeatureGraphCompilerError.emptyLocalAdjustmentEffectPipeline(id)) {
      try Self.compiler.makeOutput(from: Self.smallInput, document: document)
    }
  }

  @Test func disabledLocalAdjustmentWithEmptyPipelinePassesValidation() throws {
    // Evaluation skips disabled features, so validation has to accept them too.
    // Otherwise toggling a layer off makes the whole document unexportable
    // while the preview still renders it fine.
    let brightness = BrightnessFeature(
      id: FeatureID(rawValue: "kept-brightness"),
      value: 0.1
    )
    let withDisabled = EditingDocument(
      mainTree: MainTree(
        features: [
          .localAdjustment(
            LocalAdjustmentFeature(
              id: FeatureID(rawValue: "disabled-local"),
              isEnabled: false,
              maskTree: MaskTree(
                root: .brush(BrushMask(id: FeatureID(rawValue: "disabled-mask")))
              ),
              effectPipeline: EffectPipeline()
            )
          ),
          .effect(brightness),
        ]
      )
    )
    let withoutDisabled = EditingDocument(
      mainTree: MainTree(features: [.effect(brightness)])
    )
    let input = CIImage.parametricColorPatchImage(
      extent: CGRect(x: 0, y: 0, width: 36, height: 24)
    )

    let output = try Self.compiler.makeOutput(from: input, document: withDisabled).image
    let expected = try Self.compiler.makeOutput(from: input, document: withoutDisabled).image

    try Self.assertImagesMatch(output, expected, tolerance: 2)
  }

  @Test func metalKernelRegistryCanCreateBrushStampRecipe() throws {
    let registry = ParametricKernelRegistry()

    let image = try registry.makeBrushStamp(
      extent: CGRect(x: 0, y: 0, width: 12, height: 12),
      center: CGPoint(x: 6, y: 6),
      radius: 4,
      hardness: 0.5,
      opacity: 1
    )

    #expect(image.extent == CGRect(x: 0, y: 0, width: 12, height: 12))
  }

  private static let compiler = FeatureGraphCompiler()

  private static let smallInput = CIImage.parametricTestImage(
    white: 0.5,
    extent: CGRect(x: 0, y: 0, width: 8, height: 8)
  )

  private static let context = CIContext()

  private static func render(_ image: CIImage) throws -> CGImage {
    try #require(Self.context.createCGImage(image, from: image.extent))
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
    sourceLocation: SourceLocation = SourceLocation(
      fileID: #fileID,
      filePath: #filePath,
      line: #line,
      column: #column
    )
  ) throws {
    #expect(lhs.extent == rhs.extent, sourceLocation: sourceLocation)

    let lhsImage = try render(lhs)
    let rhsImage = try render(rhs)
    #expect(lhsImage.width == rhsImage.width, sourceLocation: sourceLocation)
    #expect(lhsImage.height == rhsImage.height, sourceLocation: sourceLocation)

    let sampleXs = [4, lhsImage.width / 3, lhsImage.width / 2, max(lhsImage.width - 5, 0)]
    let sampleYs = [4, lhsImage.height / 3, lhsImage.height / 2, max(lhsImage.height - 5, 0)]

    for y in sampleYs {
      for x in sampleXs {
        let lhsPixel = rgba(in: lhsImage, x: x, y: y)
        let rhsPixel = rgba(in: rhsImage, x: x, y: y)
        #expect(
          abs(Int(lhsPixel.red) - Int(rhsPixel.red)) <= tolerance,
          "red mismatch at \(x),\(y)",
          sourceLocation: sourceLocation
        )
        #expect(
          abs(Int(lhsPixel.green) - Int(rhsPixel.green)) <= tolerance,
          "green mismatch at \(x),\(y)",
          sourceLocation: sourceLocation
        )
        #expect(
          abs(Int(lhsPixel.blue) - Int(rhsPixel.blue)) <= tolerance,
          "blue mismatch at \(x),\(y)",
          sourceLocation: sourceLocation
        )
        #expect(
          abs(Int(lhsPixel.alpha) - Int(rhsPixel.alpha)) <= tolerance,
          "alpha mismatch at \(x),\(y)",
          sourceLocation: sourceLocation
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

  private struct TestRedBoostFeature: ImageEffectFeatureType, PersistableFeature {

    static let featureTypeKey: FeatureTypeKey = "test.red-boost"

    var id: FeatureID = .init()
    var isEnabled: Bool = true
    var amount: Double

    func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
      image.applyingFilter(
        "CIColorMatrix",
        parameters: [
          "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
          "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
          "inputBVector": CIVector(x: 0, y: 0, z: 1, w: 0),
          "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
          "inputBiasVector": CIVector(x: CGFloat(amount), y: 0, z: 0, w: 0),
        ]
      )
      .cropped(to: image.extent)
    }
  }

  private struct TestExtentProbeFeature: ImageEffectFeatureType {

    var id: FeatureID = .init()
    var isEnabled: Bool = true

    func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
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

  /// The v1 shape of the migrating test feature: field named `amount`.
  private struct TestMigratingFeatureV1: ImageEffectFeatureType, PersistableFeature {

    static let featureTypeKey: FeatureTypeKey = "test.migrating"

    var id: FeatureID = .init()
    var isEnabled: Bool = true
    var amount: Double

    func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
      image
    }
  }

  /// The v2 shape under the same key: field renamed to `strength`, with a
  /// typed migration from the v1 payload.
  private struct TestMigratingFeatureV2: ImageEffectFeatureType, PersistableFeature {

    static let featureTypeKey: FeatureTypeKey = "test.migrating"
    static let schemaVersion = 2

    var id: FeatureID = .init()
    var isEnabled: Bool = true
    var strength: Double

    func apply(to image: CIImage, context: FeatureEvaluationContext) throws -> CIImage {
      image
    }

    static func decodeParameters(from decoder: Decoder, version: Int) throws -> Self {
      switch version {
      case 2:
        return try Self(from: decoder)
      case 1:
        struct V1: Decodable {
          var id: FeatureID
          var isEnabled: Bool
          var amount: Double
        }
        let old = try V1(from: decoder)
        return Self(id: old.id, isEnabled: old.isEnabled, strength: old.amount)
      default:
        throw ParametricDocumentCodecError.unsupportedSchemaVersion(
          featureTypeKey,
          version: version
        )
      }
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
