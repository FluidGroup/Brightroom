import AppKit
import BrightroomParametric
import CoreImage
import SwiftUI

struct ParametricMacDemoView: View {

  @State private var isFirstCropEnabled = true
  @State private var firstCropInset = 48.0
  @State private var isLocalAdjustmentEnabled = true
  @State private var localExposure = 0.55
  @State private var localBlurRadius = 4.0
  @State private var brushDiameter = 220.0
  @State private var maskFeatherRadius = 18.0
  @State private var isSecondCropEnabled = true
  @State private var secondCropInset = 34.0
  @State private var globalBrightness = 0.03
  @State private var globalSaturation = 0.22
  @State private var globalVignette = 0.45

  private let renderer = ParametricMacPreviewRenderer()

  var body: some View {
    HStack(spacing: 0) {
      controlPanel
        .frame(width: 320)
        .background(.regularMaterial)

      Divider()

      previewPanel
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var controlPanel: some View {
    Form {
      Section("Domain") {
        Toggle("Crop 1", isOn: $isFirstCropEnabled)
        Slider(value: $firstCropInset, in: 0...140, step: 1) {
          Text("Inset")
        }

        Toggle("Crop 2", isOn: $isSecondCropEnabled)
        Slider(value: $secondCropInset, in: 0...96, step: 1) {
          Text("Inset")
        }
      }

      Section("Local") {
        Toggle("Local Adjustment", isOn: $isLocalAdjustmentEnabled)
        Slider(value: $localExposure, in: -1...1, step: 0.01) {
          Text("Exposure")
        }
        Slider(value: $localBlurRadius, in: 0...24, step: 1) {
          Text("Blur")
        }
        Slider(value: $brushDiameter, in: 40...360, step: 1) {
          Text("Brush")
        }
        Slider(value: $maskFeatherRadius, in: 0...48, step: 1) {
          Text("Feather")
        }
      }

      Section("Global") {
        Slider(value: $globalBrightness, in: -0.25...0.25, step: 0.01) {
          Text("Brightness")
        }
        Slider(value: $globalSaturation, in: -0.75...0.75, step: 0.01) {
          Text("Saturation")
        }
        Slider(value: $globalVignette, in: 0...1.2, step: 0.01) {
          Text("Vignette")
        }
      }
    }
    .formStyle(.grouped)
  }

  private var previewPanel: some View {
    let settings = makeSettings()
    let rendered = Result {
      try renderer.render(settings: settings)
    }

    return VStack(alignment: .leading, spacing: 18) {
      Text("Parametric Mac Demo")
        .font(.title.bold())

      switch rendered {
      case let .success(output):
        HStack(alignment: .top, spacing: 18) {
          imagePreview(title: "Source", image: output.sourceImage, extent: output.sourceExtent)
          imagePreview(title: "Output", image: output.outputImage, extent: output.outputExtent)
        }
        .frame(maxHeight: .infinity)

        treeView(lines: output.treeLines)

      case let .failure(error):
        ContentUnavailableView(
          "Render failed",
          systemImage: "exclamationmark.triangle",
          description: Text(String(describing: error))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .padding(24)
  }

  private func imagePreview(
    title: String,
    image: NSImage,
    extent: CGRect
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(title)
          .font(.headline)
        Spacer()
        Text("\(Int(extent.width)) x \(Int(extent.height))")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      Image(nsImage: image)
        .resizable()
        .interpolation(.medium)
        .aspectRatio(contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
  }

  private func treeView(lines: [ParametricMacTreeLine]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Feature Tree")
        .font(.headline)

      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
        ForEach(lines) { line in
          GridRow {
            Text(String(repeating: "  ", count: line.level) + line.kind)
              .font(.caption.monospaced())
              .foregroundStyle(line.color)
            Text(line.value)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .padding(14)
    .background(.thinMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }

  private func makeSettings() -> ParametricMacPreviewSettings {
    ParametricMacPreviewSettings(
      isFirstCropEnabled: isFirstCropEnabled,
      firstCropInset: firstCropInset,
      isLocalAdjustmentEnabled: isLocalAdjustmentEnabled,
      localExposure: localExposure,
      localBlurRadius: localBlurRadius,
      brushDiameter: brushDiameter,
      maskFeatherRadius: maskFeatherRadius,
      isSecondCropEnabled: isSecondCropEnabled,
      secondCropInset: secondCropInset,
      globalBrightness: globalBrightness,
      globalSaturation: globalSaturation,
      globalVignette: globalVignette
    )
  }
}

/// User-editable values that define the macOS parametric preview document.
struct ParametricMacPreviewSettings {

  var isFirstCropEnabled: Bool
  var firstCropInset: Double
  var isLocalAdjustmentEnabled: Bool
  var localExposure: Double
  var localBlurRadius: Double
  var brushDiameter: Double
  var maskFeatherRadius: Double
  var isSecondCropEnabled: Bool
  var secondCropInset: Double
  var globalBrightness: Double
  var globalSaturation: Double
  var globalVignette: Double
}

/// A rendered source/output pair plus textual tree rows for inspection.
struct ParametricMacPreviewOutput {

  var sourceImage: NSImage
  var outputImage: NSImage
  var sourceExtent: CGRect
  var outputExtent: CGRect
  var treeLines: [ParametricMacTreeLine]
}

/// A single visible row in the feature tree inspector.
struct ParametricMacTreeLine: Identifiable {

  var id = UUID()
  var level: Int
  var kind: String
  var value: String

  var color: Color {
    switch kind {
    case "domain":
      .cyan
    case "local":
      .orange
    case "mask":
      .pink
    case "effect":
      .green
    default:
      .primary
    }
  }
}

/// Builds and renders a registry-backed parametric document for the macOS demo.
struct ParametricMacPreviewRenderer {

  private static let sourceSize = CGSize(width: 960, height: 640)
  private static let context = CIContext()

  /// Renders the current settings into AppKit images for display.
  func render(settings: ParametricMacPreviewSettings) throws -> ParametricMacPreviewOutput {
    let sourceImage = makeSourceImage()
    let document = try makeDocument(settings: settings)
    let outputImage = try ParametricImageRenderer().makeImage(
      from: sourceImage,
      document: document.document
    )

    return ParametricMacPreviewOutput(
      sourceImage: try makeNSImage(from: sourceImage),
      outputImage: try makeNSImage(from: outputImage),
      sourceExtent: sourceImage.extent,
      outputExtent: outputImage.extent,
      treeLines: document.treeLines
    )
  }

  private func makeDocument(
    settings: ParametricMacPreviewSettings
  ) throws -> (document: FeatureDocument, treeLines: [ParametricMacTreeLine]) {
    var features: [FeatureTreeNode] = []
    var treeLines: [ParametricMacTreeLine] = [
      .init(level: 0, kind: "source", value: sizeDescription(Self.sourceSize)),
      .init(level: 0, kind: "main", value: "source -> output"),
    ]
    var currentSize = Self.sourceSize

    if settings.isFirstCropEnabled {
      let cropRect = insetRect(size: currentSize, inset: settings.firstCropInset)
      features.append(
        .domain(
          try FeatureNode(
            BrightroomFeatureDefinitions.Crop.self,
            id: FeatureID(rawValue: "mac-demo-crop-1"),
            payload: .init(cropRect: cropRect)
          )
        )
      )
      currentSize = cropRect.size
      treeLines.append(.init(level: 1, kind: "domain", value: "Crop 1 -> \(sizeDescription(currentSize))"))
    }

    if settings.isLocalAdjustmentEnabled {
      let brush = try makeBrushMask(size: currentSize, settings: settings)
      let featheredMask = try FeatureNode(
        BrightroomFeatureDefinitions.FeatherMask.self,
        id: FeatureID(rawValue: "mac-demo-feather-mask"),
        payload: .init(input: brush, radius: settings.maskFeatherRadius)
      )
      var effects: [FeatureNode] = [
        try FeatureNode(
          BrightroomFeatureDefinitions.Exposure.self,
          id: FeatureID(rawValue: "mac-demo-local-exposure"),
          payload: .init(value: settings.localExposure)
        ),
      ]
      if settings.localBlurRadius > 0.1 {
        effects.append(
          try FeatureNode(
            BrightroomFeatureDefinitions.GaussianBlur.self,
            id: FeatureID(rawValue: "mac-demo-local-blur"),
            payload: .init(radius: .absolute(settings.localBlurRadius))
          )
        )
      }

      features.append(
        .localAdjustment(
          FeatureLocalAdjustment(
            id: FeatureID(rawValue: "mac-demo-local-adjustment"),
            mask: featheredMask,
            effectPipeline: FeatureEffectPipeline(effects: effects)
          )
        )
      )
      treeLines.append(.init(level: 1, kind: "local", value: "Local Adjustment"))
      treeLines.append(.init(level: 2, kind: "mask", value: "Brush -> Feather \(Int(settings.maskFeatherRadius))"))
      treeLines.append(.init(level: 2, kind: "effect", value: "Exposure \(settings.localExposure.formatted(.number.precision(.fractionLength(2))))"))
      if settings.localBlurRadius > 0.1 {
        treeLines.append(.init(level: 2, kind: "effect", value: "Blur \(Int(settings.localBlurRadius))"))
      }
    }

    let preCropEffects = try makeGlobalColorEffects(settings: settings)
    features.append(contentsOf: preCropEffects.features.map(FeatureTreeNode.effect))
    treeLines.append(contentsOf: preCropEffects.treeLines)

    if settings.isSecondCropEnabled {
      let cropRect = insetRect(size: currentSize, inset: settings.secondCropInset)
      features.append(
        .domain(
          try FeatureNode(
            BrightroomFeatureDefinitions.Crop.self,
            id: FeatureID(rawValue: "mac-demo-crop-2"),
            payload: .init(cropRect: cropRect)
          )
        )
      )
      currentSize = cropRect.size
      treeLines.append(.init(level: 1, kind: "domain", value: "Crop 2 -> \(sizeDescription(currentSize))"))
    }

    if let vignette = try makeVignetteEffect(settings: settings) {
      features.append(.effect(vignette.feature))
      treeLines.append(vignette.treeLine)
    }

    return (
      FeatureDocument(mainTree: FeatureMainTree(features: features)),
      treeLines
    )
  }

  private func makeGlobalColorEffects(
    settings: ParametricMacPreviewSettings
  ) throws -> (features: [FeatureNode], treeLines: [ParametricMacTreeLine]) {
    var features: [FeatureNode] = []
    var treeLines: [ParametricMacTreeLine] = []

    if abs(settings.globalBrightness) > 0.001 {
      features.append(
        try FeatureNode(
          BrightroomFeatureDefinitions.Brightness.self,
          id: FeatureID(rawValue: "mac-demo-global-brightness"),
          payload: .init(value: settings.globalBrightness)
        )
      )
      treeLines.append(.init(level: 1, kind: "effect", value: "Brightness \(settings.globalBrightness.formatted(.number.precision(.fractionLength(2))))"))
    }

    if abs(settings.globalSaturation) > 0.001 {
      features.append(
        try FeatureNode(
          BrightroomFeatureDefinitions.Saturation.self,
          id: FeatureID(rawValue: "mac-demo-global-saturation"),
          payload: .init(value: settings.globalSaturation)
        )
      )
      treeLines.append(.init(level: 1, kind: "effect", value: "Saturation \(settings.globalSaturation.formatted(.number.precision(.fractionLength(2))))"))
    }

    return (features, treeLines)
  }

  private func makeVignetteEffect(
    settings: ParametricMacPreviewSettings
  ) throws -> (feature: FeatureNode, treeLine: ParametricMacTreeLine)? {
    guard settings.globalVignette > 0.001 else {
      return nil
    }

    return (
      try FeatureNode(
        BrightroomFeatureDefinitions.Vignette.self,
        id: FeatureID(rawValue: "mac-demo-global-vignette"),
        payload: .init(value: settings.globalVignette)
      ),
      .init(level: 1, kind: "effect", value: "Vignette \(settings.globalVignette.formatted(.number.precision(.fractionLength(2))))")
    )
  }

  private func makeBrushMask(
    size: CGSize,
    settings: ParametricMacPreviewSettings
  ) throws -> FeatureNode {
    let centerY = size.height * 0.56
    let stamps = stride(from: 0.18, through: 0.82, by: 0.08).map { progress in
      CGPoint(
        x: size.width * progress,
        y: centerY + sin(progress * .pi * 3) * size.height * 0.08
      )
    }
    let stroke = BrushMaskStroke(
      stamps: stamps,
      brush: BrushMaskBrush(
        diameter: settings.brushDiameter,
        hardness: 0.35,
        opacity: 1
      )
    )
    return try FeatureNode(
      BrightroomFeatureDefinitions.BrushMask.self,
      id: FeatureID(rawValue: "mac-demo-brush-mask"),
      payload: .init(strokes: [stroke])
    )
  }

  private func insetRect(size: CGSize, inset: Double) -> CGRect {
    let boundedInset = min(
      max(inset, 0),
      max(min(size.width, size.height) / 2 - 1, 0)
    )
    return CGRect(
      x: boundedInset,
      y: boundedInset,
      width: max(size.width - boundedInset * 2, 1),
      height: max(size.height - boundedInset * 2, 1)
    )
  }

  private func makeSourceImage() -> CIImage {
    let extent = CGRect(origin: .zero, size: Self.sourceSize)
    let background = CIFilter(
      name: "CILinearGradient",
      parameters: [
        "inputPoint0": CIVector(x: 0, y: 0),
        "inputPoint1": CIVector(x: Self.sourceSize.width, y: Self.sourceSize.height),
        "inputColor0": CIColor(red: 0.06, green: 0.09, blue: 0.13, alpha: 1),
        "inputColor1": CIColor(red: 0.82, green: 0.54, blue: 0.28, alpha: 1),
      ]
    )!
    .outputImage!
    .cropped(to: extent)
    let grid = CIFilter(
      name: "CICheckerboardGenerator",
      parameters: [
        "inputCenter": CIVector(x: 0, y: 0),
        "inputColor0": CIColor(red: 0.08, green: 0.14, blue: 0.2, alpha: 0.38),
        "inputColor1": CIColor(red: 0.94, green: 0.88, blue: 0.72, alpha: 0.18),
        "inputWidth": 52,
        "inputSharpness": 0.82,
      ]
    )!
    .outputImage!
    .cropped(to: extent)
    .composited(over: background)
    let warmBand = CIImage(color: CIColor(red: 0.96, green: 0.24, blue: 0.18, alpha: 0.68))
      .cropped(to: CGRect(x: 130, y: 0, width: 120, height: Self.sourceSize.height))
      .composited(over: grid)
    let coolBand = CIImage(color: CIColor(red: 0.02, green: 0.46, blue: 0.95, alpha: 0.7))
      .cropped(to: CGRect(x: 600, y: 0, width: 150, height: Self.sourceSize.height))
      .composited(over: warmBand)
    let glow = CIFilter(
      name: "CIRadialGradient",
      parameters: [
        "inputCenter": CIVector(x: 470, y: 340),
        "inputRadius0": 16,
        "inputRadius1": 260,
        "inputColor0": CIColor(red: 1, green: 0.96, blue: 0.7, alpha: 0.92),
        "inputColor1": CIColor(red: 1, green: 0.96, blue: 0.7, alpha: 0),
      ]
    )!
    .outputImage!
    .cropped(to: extent)

    return glow
      .composited(over: coolBand)
      .cropped(to: extent)
  }

  private func makeNSImage(from image: CIImage) throws -> NSImage {
    let outputExtent = image.extent.integral
    let normalizedImage = image.transformed(
      by: CGAffineTransform(
        translationX: -outputExtent.minX,
        y: -outputExtent.minY
      )
    )
    let normalizedExtent = CGRect(origin: .zero, size: outputExtent.size)
    guard let cgImage = Self.context.createCGImage(normalizedImage, from: normalizedExtent) else {
      throw ParametricMacPreviewError.failedToCreateCGImage(outputExtent)
    }
    return NSImage(cgImage: cgImage, size: normalizedExtent.size)
  }

  private func sizeDescription(_ size: CGSize) -> String {
    "\(Int(size.width)) x \(Int(size.height))"
  }
}

/// Errors raised while materializing the macOS preview surface.
enum ParametricMacPreviewError: Error {

  /// Core Image could not create a displayable image for the requested extent.
  case failedToCreateCGImage(CGRect)
}
