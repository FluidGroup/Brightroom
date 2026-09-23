import CoreGraphics
import CoreImage
import Foundation
import Testing

@testable import BrightroomParametric

/// Numeric and compiled-kernel regression coverage for the scene-linear YRGB effect.
@Suite("Tone Curve rendering", .serialized)
struct ToneCurveRendererTests {

  @Test
  func sceneLinearShaperMatchesAnchorsAndRoundTripsExtendedValues() {
    expectToneCurveClose(
      ToneCurveSceneLinearShaper.normalizedCurveCoordinate(for: 0),
      0
    )
    expectToneCurveClose(
      ToneCurveSceneLinearShaper.normalizedCurveCoordinate(for: 0.18),
      0.5
    )
    expectToneCurveClose(
      ToneCurveSceneLinearShaper.linearValue(
        forNormalizedCurveCoordinate: 1
      ),
      23.019_953_068_838_497
    )

    let values = [
      -0.02,
      0,
      0.004_131_837_473_948_394_6,
      0.18,
      1,
      10,
      23.019_953_068_838_497,
      64,
    ]
    for value in values {
      let normalized =
        ToneCurveSceneLinearShaper.normalizedCurveCoordinate(for: value)
      let roundTrip = ToneCurveSceneLinearShaper.linearValue(
        forNormalizedCurveCoordinate: normalized
      )
      expectToneCurveClose(
        roundTrip,
        value,
        tolerance: max(1, abs(value)) * 0.000_000_000_01
      )
    }
  }

  @Test
  func neutralAndDiagonalAuthoredCurvesUseTheExactBypass() throws {
    #expect(ToneCurveRenderPlan(value: .neutral) == nil)

    var diagonal = ToneCurve()
    let diagonalPointID = diagonal.insertPoint(input: 0.4, output: 0.4)
    _ = try #require(diagonalPointID)
    let diagonalValue = ToneCurveEditorValue(red: diagonal)
    #expect(diagonalValue.isNeutral == false)
    #expect(ToneCurveRenderPlan(value: diagonalValue) == nil)

    var inwardDiagonalEndpoint = ToneCurve()
    inwardDiagonalEndpoint.movePoint(
      id: .blackEndpoint,
      input: 0.2,
      output: 0.2
    )
    #expect(inwardDiagonalEndpoint.isIdentityMapping == false)
    #expect(
      ToneCurveRenderPlan(
        value: ToneCurveEditorValue(red: inwardDiagonalEndpoint)
      ) != nil
    )

    let source = Self.makeImage([
      SIMD4(0.2, 0.1, 0.05, 1)
    ])
    let output = try ToneCurveRenderer.apply(to: source, value: diagonalValue)
    #expect(output === source)

    let feature = ToneCurveFeature(value: diagonalValue)
    #expect(feature.isEnabled == false)
    let featureOutput = try feature.apply(
      to: source,
      context: FeatureEvaluationContext()
    )
    #expect(featureOutput === source)
  }

  @Test
  func renderPlanUsesOneUUIDIndependentSixtyFourKiBTable() throws {
    let firstCurve = try Self.makeCurve(
      interiors: [(0.25, 0.45), (0.8, 0.7)]
    )
    let secondCurve = try Self.makeCurve(
      interiors: [(0.25, 0.45), (0.8, 0.7)]
    )
    #expect(firstCurve != secondCurve)

    let firstValue = ToneCurveEditorValue(red: firstCurve)
    let secondValue = ToneCurveEditorValue(red: secondCurve)
    let firstPlan = try #require(ToneCurveRenderPlan(value: firstValue))
    let secondPlan = try #require(ToneCurveRenderPlan(value: secondValue))

    #expect(firstPlan.identity == secondPlan.identity)
    #expect(firstPlan.sampleTable.yRed.count == 4_096)
    #expect(firstPlan.sampleTable.greenBlue.count == 4_096)
    #expect(firstPlan.sampleTable.combinedData().count == 65_536)
    #expect(firstPlan.activeChannels == SIMD4(0, 1, 0, 0))
    #expect(
      ToneCurveFeature(value: firstValue)
        == ToneCurveFeature(value: secondValue)
    )
  }

  @Test
  func sampledTableTracksTheCanonicalSplineIncludingEndpointExtrapolation()
    throws
  {
    let value = try Self.representativeValue()
    let plan = try #require(ToneCurveRenderPlan(value: value))
    let normalizedInputs = [
      -0.2, 0, 0.000_1, 0.137, 0.25, 0.499_9, 0.7, 0.913, 1, 1.2,
    ]

    for channel in ToneCurveChannel.allCases {
      let evaluator = ToneCurveEvaluator(curve: value[channel])
      for input in normalizedInputs {
        expectToneCurveClose(
          plan.normalizedOutput(for: channel, input: input),
          evaluator.output(at: input),
          tolerance: 0.000_002
        )
      }
    }
  }

  @Test
  func sampledPlanFlattensMovedEndpointsInsideAndBeyondTheNormalizedDomain()
    throws
  {
    var curve = ToneCurve()
    curve.movePoint(id: .blackEndpoint, input: 0.15, output: 0.04)
    curve.movePoint(id: .whiteEndpoint, input: 0.86, output: 0.97)
    let value = ToneCurveEditorValue(red: curve)
    let plan = try #require(ToneCurveRenderPlan(value: value))
    let evaluator = ToneCurveEvaluator(curve: curve)

    #expect(plan.lowerTangents.y == 0)
    #expect(plan.upperTangents.y == 0)
    for input in [-0.2, 0, 0.1] {
      expectToneCurveClose(
        plan.normalizedOutput(for: .red, input: input),
        0.04,
        tolerance: 0.000_002
      )
    }
    for input in [0.9, 1, 1.2] {
      expectToneCurveClose(
        plan.normalizedOutput(for: .red, input: input),
        0.97,
        tolerance: 0.000_002
      )
    }
    // A uniform LUT can straddle the derivative discontinuity at an arbitrary
    // authored endpoint. Its one-cell interpolation error stays below 1e-4.
    expectToneCurveClose(
      plan.normalizedOutput(for: .red, input: 0.15),
      0.04,
      tolerance: 0.000_1
    )
    expectToneCurveClose(
      plan.normalizedOutput(for: .red, input: 0.86),
      0.97,
      tolerance: 0.000_1
    )
    for input in [-0.2, 0, 0.1, 0.15, 0.5, 0.86, 1, 1.2] {
      expectToneCurveClose(
        plan.normalizedOutput(for: .red, input: input),
        evaluator.output(at: input),
        tolerance: 0.000_1
      )
    }
  }

  @Test
  func compiledMetalKernelMatchesFlatMovedEndpointExtensions() throws {
    var curve = ToneCurve()
    curve.movePoint(id: .blackEndpoint, input: 0.15, output: 0.04)
    curve.movePoint(id: .whiteEndpoint, input: 0.86, output: 0.97)
    let value = ToneCurveEditorValue(red: curve)
    let plan = try #require(ToneCurveRenderPlan(value: value))
    let normalizedInputs = [-0.2, 0, 0.1, 0.15, 0.5, 0.86, 1, 1.2]
    let sourcePixels = normalizedInputs.map { normalizedInput in
      SIMD4<Float>(
        Float(
          ToneCurveSceneLinearShaper.linearValue(
            forNormalizedCurveCoordinate: normalizedInput
          )
        ),
        0.18,
        0.18,
        1
      )
    }
    let source = Self.makeImage(sourcePixels)

    let output = try ToneCurveRenderer.apply(to: source, plan: plan)
    let actual = Self.sample(
      output,
      pixelCount: sourcePixels.count,
      context: Self.floatCIContext
    )

    for index in sourcePixels.indices {
      let sourcePixel = SIMD4<Double>(
        Double(sourcePixels[index].x),
        Double(sourcePixels[index].y),
        Double(sourcePixels[index].z),
        Double(sourcePixels[index].w)
      )
      let expected = ToneCurveReferenceProcessor.processPremultiplied(
        sourcePixel,
        plan: plan
      )
      expectToneCurveClose(actual[index], expected, tolerance: 0.001)
    }
  }

  @Test
  func cpuTableProcessorTracksTheIndependentAnalyticReference() throws {
    let value = try Self.representativeValue()
    let plan = try #require(ToneCurveRenderPlan(value: value))
    let pixels = [
      SIMD4(-0.02, 0.01, 0.04, 1.0),
      SIMD4(0.0, 0.18, 0.35, 1.0),
      SIMD4(0.18, 0.18, 0.18, 1.0),
      SIMD4(1.0, 0.5, 0.2, 1.0),
      SIMD4(4.0, 2.0, 0.5, 1.0),
      SIMD4(0.1, 0.05, 0.025, 0.25),
    ]

    for pixel in pixels {
      let analytic = ToneCurveReferenceProcessor.processPremultiplied(
        pixel,
        value: value
      )
      let sampled = ToneCurveReferenceProcessor.processPremultiplied(
        pixel,
        plan: plan
      )
      expectToneCurveClose(sampled, analytic, tolerance: 0.000_5)
    }
  }

  @Test
  func rgbCurvesPreserveInputLuminanceBeforeYDefinesTheFinalLuminance() throws {
    let rgbValue = ToneCurveEditorValue(
      red: try Self.makeCurve(interiors: [(0.32, 0.52)]),
      green: try Self.makeCurve(interiors: [(0.55, 0.38)]),
      blue: try Self.makeCurve(interiors: [(0.7, 0.84)])
    )
    let yCurve = try Self.makeCurve(
      black: 0.03,
      white: 0.94,
      interiors: [(0.4, 0.28), (0.72, 0.82)]
    )
    let yValue = ToneCurveEditorValue(y: yCurve)
    let combinedValue = ToneCurveEditorValue(
      y: yCurve,
      red: rgbValue.red,
      green: rgbValue.green,
      blue: rgbValue.blue
    )
    let source = SIMD4(0.16, 0.072, 0.024, 0.4)

    let rgbResult = ToneCurveReferenceProcessor.processPremultiplied(
      source,
      value: rgbValue
    )
    let actual = ToneCurveReferenceProcessor.processPremultiplied(
      source,
      value: combinedValue
    )
    let yResult = ToneCurveReferenceProcessor.processPremultiplied(
      source,
      value: yValue
    )
    expectToneCurveClose(actual, rgbResult + yResult - source)

    let straightInput = SIMD3(source.x, source.y, source.z) / source.w
    let straightRGB = SIMD3(rgbResult.x, rgbResult.y, rgbResult.z) / rgbResult.w
    let inputY = Self.displayP3Luminance(straightInput)
    expectToneCurveClose(Self.displayP3Luminance(straightRGB), inputY)

    let normalizedInput =
      ToneCurveSceneLinearShaper.normalizedCurveCoordinate(for: inputY)
    let normalizedOutput = ToneCurveEvaluator(curve: yCurve).output(
      at: normalizedInput
    )
    let expectedY = ToneCurveSceneLinearShaper.linearValue(
      forNormalizedCurveCoordinate: normalizedOutput
    )
    let straightOutput = SIMD3(actual.x, actual.y, actual.z) / actual.w
    expectToneCurveClose(Self.displayP3Luminance(straightOutput), expectedY)
  }

  @Test
  func identicalGangedYRGBCurvesApplyOnceToANeutralInput() throws {
    let curve = try Self.makeCurve(
      interiors: [(0.28, 0.2), (0.72, 0.84)]
    )
    let source = SIMD4(0.18, 0.18, 0.18, 1.0)
    let yOnly = ToneCurveReferenceProcessor.processPremultiplied(
      source,
      value: ToneCurveEditorValue(y: curve)
    )
    let rgbOnly = ToneCurveReferenceProcessor.processPremultiplied(
      source,
      value: ToneCurveEditorValue(red: curve, green: curve, blue: curve)
    )
    let ganged = ToneCurveReferenceProcessor.processPremultiplied(
      source,
      value: ToneCurveEditorValue(
        y: curve,
        red: curve,
        green: curve,
        blue: curve
      )
    )
    let serialDoubleApplication =
      ToneCurveReferenceProcessor.processPremultiplied(
        yOnly,
        value: ToneCurveEditorValue(y: curve)
      )

    expectToneCurveClose(rgbOnly, source)
    expectToneCurveClose(ganged, yOnly)
    #expect(Self.maximumChannelDelta(ganged, serialDoubleApplication) > 0.001)
  }

  @Test
  func referenceProcessorPreservesPremultiplicationAndExtendedRange() throws {
    let value = ToneCurveEditorValue(
      green: try Self.makeCurve(interiors: [(0.5, 0.7)])
    )
    let transparent = SIMD4(0.3, -0.2, 4.0, 0.0)
    #expect(
      ToneCurveReferenceProcessor.processPremultiplied(
        transparent,
        value: value
      ) == transparent
    )

    let straight = SIMD4(-0.02, 0.2, 4.0, 1.0)
    let translucent = SIMD4(-0.005, 0.05, 1.0, 0.25)
    let straightOutput = ToneCurveReferenceProcessor.processPremultiplied(
      straight,
      value: value
    )
    let translucentOutput = ToneCurveReferenceProcessor.processPremultiplied(
      translucent,
      value: value
    )

    #expect(straightOutput.w == 1)
    #expect(translucentOutput.w == 0.25)
    #expect(straightOutput.x < 0)
    #expect(straightOutput.z > 1)
    #expect(Self.allFinite(straightOutput))
    expectToneCurveClose(
      SIMD3(
        translucentOutput.x,
        translucentOutput.y,
        translucentOutput.z
      ),
      SIMD3(
        straightOutput.x,
        straightOutput.y,
        straightOutput.z
      ) * 0.25
    )
  }

  @Test
  func compiledMetalKernelMatchesTheSampledCPUPlanAndPreservesExtent() throws {
    let value = try Self.representativeValue()
    let plan = try #require(ToneCurveRenderPlan(value: value))
    let sourcePixels: [SIMD4<Float>] = [
      SIMD4(-0.02, 0.01, 0.04, 1),
      SIMD4(0, 0.18, 0.35, 1),
      SIMD4(0.18, 0.18, 0.18, 1),
      SIMD4(1, 0.5, 0.2, 1),
      SIMD4(4, 2, 0.5, 1),
      SIMD4(0.1, 0.05, 0.025, 0.25),
    ]
    let source = Self.makeImage(
      sourcePixels,
      translatedBy: CGPoint(x: 7, y: 11)
    )

    let output = try ToneCurveRenderer.apply(to: source, plan: plan)
    #expect(output.extent == source.extent)
    let floatActual = Self.sample(
      output,
      pixelCount: sourcePixels.count,
      context: Self.floatCIContext
    )
    let productionActual = Self.sample(
      output,
      pixelCount: sourcePixels.count,
      context: Self.halfCIContext
    )

    for index in sourcePixels.indices {
      let sourcePixel = SIMD4<Double>(
        Double(sourcePixels[index].x),
        Double(sourcePixels[index].y),
        Double(sourcePixels[index].z),
        Double(sourcePixels[index].w)
      )
      let expected = ToneCurveReferenceProcessor.processPremultiplied(
        sourcePixel,
        plan: plan
      )
      expectToneCurveClose(floatActual[index], expected, tolerance: 0.001)
      expectToneCurveHalfClose(productionActual[index], expected)
    }
  }

  @Test
  func maximumPointCurveProducesFiniteExtendedOutputs() throws {
    var curve = ToneCurve()
    for index in 1...10 {
      let pointID = curve.insertPoint(
        input: Double(index) / 11,
        output: index.isMultiple(of: 2) ? 0.95 : 0.05
      )
      _ = try #require(pointID)
    }
    #expect(curve.points.count == ToneCurve.maximumPointCount)

    let value = ToneCurveEditorValue(red: curve)
    let plan = try #require(ToneCurveRenderPlan(value: value))
    for linear in [-0.1, 0, 0.18, 1, 4, 24] {
      let output = ToneCurveReferenceProcessor.processPremultiplied(
        SIMD4(linear, 0.18, 0.18, 1),
        plan: plan
      )
      #expect(Self.allFinite(output))
    }
  }

  private static let luminanceCoefficients = SIMD3(
    0.228_974_564_1,
    0.691_738_521_8,
    0.079_286_914_1
  )

  /// Float32 context that separates table-coordinate/kernel accuracy from the
  /// deliberate half-float quantization used by the production working format.
  private static let halfCIContext = CIContext(options: [
    .workingFormat: CIFormat.RGBAh,
    .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
    .cacheIntermediates: false,
  ])

  private static let floatCIContext = CIContext(options: [
    .workingFormat: CIFormat.RGBAf,
    .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
    .cacheIntermediates: false,
  ])

  private static func representativeValue() throws -> ToneCurveEditorValue {
    ToneCurveEditorValue(
      y: try makeCurve(
        black: 0.02,
        white: 0.96,
        interiors: [(0.28, 0.2), (0.72, 0.84)]
      ),
      red: try makeCurve(interiors: [(0.25, 0.4), (0.78, 0.7)]),
      green: try makeCurve(
        black: 0.01,
        white: 0.97,
        interiors: [(0.5, 0.42)]
      ),
      blue: try makeCurve(interiors: [(0.35, 0.22), (0.68, 0.8)])
    )
  }

  private static func makeCurve(
    black: Double = 0,
    white: Double = 1,
    interiors: [(Double, Double)]
  ) throws -> ToneCurve {
    var curve = ToneCurve()
    curve.movePoint(id: .blackEndpoint, input: 0, output: black)
    curve.movePoint(id: .whiteEndpoint, input: 1, output: white)
    for (input, output) in interiors {
      let pointID = curve.insertPoint(input: input, output: output)
      _ = try #require(
        pointID,
        "Expected a legal Tone Curve test point at \(input)"
      )
    }
    return curve
  }

  private static func makeImage(
    _ pixels: [SIMD4<Float>],
    translatedBy origin: CGPoint = .zero
  ) -> CIImage {
    let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
    let image = CIImage(
      bitmapData: data,
      bytesPerRow: pixels.count * MemoryLayout<SIMD4<Float>>.stride,
      size: CGSize(width: pixels.count, height: 1),
      format: .RGBAf,
      colorSpace: nil
    )
    guard origin != .zero else { return image }
    return image.transformed(
      by: CGAffineTransform(translationX: origin.x, y: origin.y)
    )
  }

  private static func sample(
    _ image: CIImage,
    pixelCount: Int,
    context: CIContext
  ) -> [SIMD4<Double>] {
    var components = [Float](repeating: 0, count: pixelCount * 4)
    components.withUnsafeMutableBytes { bytes in
      context.render(
        image,
        toBitmap: bytes.baseAddress!,
        rowBytes: pixelCount * MemoryLayout<SIMD4<Float>>.stride,
        bounds: image.extent,
        format: .RGBAf,
        colorSpace: nil
      )
    }
    return (0..<pixelCount).map { index in
      let offset = index * 4
      return SIMD4(
        Double(components[offset]),
        Double(components[offset + 1]),
        Double(components[offset + 2]),
        Double(components[offset + 3])
      )
    }
  }

  private static func displayP3Luminance(_ rgb: SIMD3<Double>) -> Double {
    rgb.x * luminanceCoefficients.x
      + rgb.y * luminanceCoefficients.y
      + rgb.z * luminanceCoefficients.z
  }

  private static func maximumChannelDelta(
    _ lhs: SIMD4<Double>,
    _ rhs: SIMD4<Double>
  ) -> Double {
    max(
      abs(lhs.x - rhs.x),
      abs(lhs.y - rhs.y),
      abs(lhs.z - rhs.z),
      abs(lhs.w - rhs.w)
    )
  }

  private static func allFinite(_ value: SIMD4<Double>) -> Bool {
    value.x.isFinite && value.y.isFinite && value.z.isFinite && value.w.isFinite
  }
}

private func expectToneCurveHalfClose(
  _ actual: SIMD4<Double>,
  _ expected: SIMD4<Double>,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  for (actualComponent, expectedComponent) in zip(
    [actual.x, actual.y, actual.z, actual.w],
    [expected.x, expected.y, expected.z, expected.w]
  ) {
    // The export renderer deliberately renders in RGBAh. Four shaper/table evaluations can
    // accumulate slightly over 1% half-float quantization error; the separate
    // RGBAf assertion remains the strict coordinate and kernel-math gate.
    let tolerance = max(0.003, abs(expectedComponent) * 0.012)
    expectToneCurveClose(
      actualComponent,
      expectedComponent,
      tolerance: tolerance,
      sourceLocation: sourceLocation
    )
  }
}

private func expectToneCurveClose(
  _ actual: Double,
  _ expected: Double,
  tolerance: Double = 0.000_000_001,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  #expect(
    abs(actual - expected) <= tolerance,
    "Expected \(expected), got \(actual)",
    sourceLocation: sourceLocation
  )
}

private func expectToneCurveClose(
  _ actual: SIMD3<Double>,
  _ expected: SIMD3<Double>,
  tolerance: Double = 0.000_000_001,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  expectToneCurveClose(
    actual.x,
    expected.x,
    tolerance: tolerance,
    sourceLocation: sourceLocation
  )
  expectToneCurveClose(
    actual.y,
    expected.y,
    tolerance: tolerance,
    sourceLocation: sourceLocation
  )
  expectToneCurveClose(
    actual.z,
    expected.z,
    tolerance: tolerance,
    sourceLocation: sourceLocation
  )
}

private func expectToneCurveClose(
  _ actual: SIMD4<Double>,
  _ expected: SIMD4<Double>,
  tolerance: Double = 0.000_000_001,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  expectToneCurveClose(
    SIMD3(actual.x, actual.y, actual.z),
    SIMD3(expected.x, expected.y, expected.z),
    tolerance: tolerance,
    sourceLocation: sourceLocation
  )
  expectToneCurveClose(
    actual.w,
    expected.w,
    tolerance: tolerance,
    sourceLocation: sourceLocation
  )
}
