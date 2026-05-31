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
  @State private var suppressedFeatureIDs: Set<FeatureID> = []

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
        .frame(minHeight: 300)
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
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Text("Feature Tree")
          .font(.headline)

        Spacer()

        Button {
          suppressedFeatureIDs.removeAll()
        } label: {
          Label("Enable All", systemImage: "checkmark.circle")
        }
        .buttonStyle(.borderless)
        .disabled(suppressedFeatureIDs.isEmpty)
      }

      ScrollView {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(lines) { line in
            treeLineView(line)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 280)
    }
    .frame(maxWidth: 520, alignment: .leading)
  }

  private func treeLineView(_ line: ParametricMacTreeLine) -> some View {
    let isSuppressed = line.featureID.map { suppressedFeatureIDs.contains($0) } ?? false

    return HStack(spacing: 10) {
      if let featureID = line.featureID {
        Toggle("", isOn: featureEnabledBinding(for: featureID))
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.small)
          .help(isSuppressed ? "Restore this feature" : "Suppress this feature")
      } else {
        Image(systemName: line.kind.systemImage)
          .font(.caption.weight(.semibold))
          .foregroundStyle(line.kind.color)
          .frame(width: 28)
      }

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(line.kind.title)
            .font(.caption2.monospaced().weight(.semibold))
            .foregroundStyle(line.kind.color)

          if isSuppressed {
            Text("Suppressed")
              .font(.caption2.weight(.semibold))
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .foregroundStyle(.secondary)
              .background(.quaternary, in: Capsule())
          }
        }

        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(line.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(isSuppressed ? .secondary : .primary)

          Text(line.detail)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }

      Spacer(minLength: 0)
    }
    .padding(.leading, CGFloat(line.level) * 18)
    .padding(.vertical, 8)
    .padding(.horizontal, 10)
    .background(isSuppressed ? Color.secondary.opacity(0.08) : Color(nsColor: .controlBackgroundColor).opacity(0.78))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .opacity(isSuppressed ? 0.58 : 1)
  }

  private func featureEnabledBinding(for featureID: FeatureID) -> Binding<Bool> {
    Binding(
      get: {
        suppressedFeatureIDs.contains(featureID) == false
      },
      set: { isEnabled in
        if isEnabled {
          suppressedFeatureIDs.remove(featureID)
        } else {
          suppressedFeatureIDs.insert(featureID)
        }
      }
    )
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
      globalVignette: globalVignette,
      suppressedFeatureIDs: suppressedFeatureIDs
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
  var suppressedFeatureIDs: Set<FeatureID>

  func isFeatureEnabled(_ featureID: FeatureID) -> Bool {
    suppressedFeatureIDs.contains(featureID) == false
  }
}

/// A rendered source/output pair plus textual tree rows for inspection.
struct ParametricMacPreviewOutput {

  var sourceImage: NSImage
  var outputImage: NSImage
  var sourceExtent: CGRect
  var outputExtent: CGRect
  var treeLines: [ParametricMacTreeLine]
}

/// A single visible row in the interactive feature tree inspector.
struct ParametricMacTreeLine: Identifiable {

  var id: String
  var level: Int
  var kind: ParametricMacTreeKind
  var title: String
  var detail: String
  var featureID: FeatureID?
}

/// Display categories used by the macOS feature tree editor.
enum ParametricMacTreeKind: String {

  case source
  case main
  case domain
  case local
  case mask
  case effect

  var title: String {
    rawValue.uppercased()
  }

  var color: Color {
    switch self {
    case .source:
      .secondary
    case .main:
      .primary
    case .domain:
      .cyan
    case .local:
      .orange
    case .mask:
      .pink
    case .effect:
      .green
    }
  }

  var systemImage: String {
    switch self {
    case .source:
      "photo"
    case .main:
      "arrow.right"
    case .domain:
      "crop"
    case .local:
      "scope"
    case .mask:
      "paintbrush"
    case .effect:
      "slider.horizontal.3"
    }
  }
}

/// Stable feature IDs used by the macOS demo document and tree editor.
enum ParametricMacPreviewFeatureID {

  static let crop1 = FeatureID(rawValue: "mac-demo-crop-1")
  static let localAdjustment = FeatureID(rawValue: "mac-demo-local-adjustment")
  static let brushMask = FeatureID(rawValue: "mac-demo-brush-mask")
  static let featherMask = FeatureID(rawValue: "mac-demo-feather-mask")
  static let localExposure = FeatureID(rawValue: "mac-demo-local-exposure")
  static let localBlur = FeatureID(rawValue: "mac-demo-local-blur")
  static let globalBrightness = FeatureID(rawValue: "mac-demo-global-brightness")
  static let globalSaturation = FeatureID(rawValue: "mac-demo-global-saturation")
  static let crop2 = FeatureID(rawValue: "mac-demo-crop-2")
  static let globalVignette = FeatureID(rawValue: "mac-demo-global-vignette")
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
      .init(
        id: "source",
        level: 0,
        kind: .source,
        title: "Source",
        detail: sizeDescription(Self.sourceSize),
        featureID: nil
      ),
      .init(
        id: "main",
        level: 0,
        kind: .main,
        title: "Main",
        detail: "source -> output",
        featureID: nil
      ),
    ]
    var currentSize = Self.sourceSize

    if settings.isFirstCropEnabled {
      let featureID = ParametricMacPreviewFeatureID.crop1
      let isEnabled = settings.isFeatureEnabled(featureID)
      let cropRect = insetRect(size: currentSize, inset: settings.firstCropInset)
      features.append(
        .domain(
          try FeatureNode(
            BrightroomFeatureDefinitions.Crop.self,
            id: featureID,
            isEnabled: isEnabled,
            payload: .init(cropRect: cropRect)
          )
        )
      )
      if isEnabled {
        currentSize = cropRect.size
      }
      treeLines.append(
        .init(
          id: featureID.rawValue,
          level: 1,
          kind: .domain,
          title: "Crop 1",
          detail: "inset \(Int(settings.firstCropInset)) -> \(sizeDescription(cropRect.size))",
          featureID: featureID
        )
      )
    }

    if settings.isLocalAdjustmentEnabled {
      let localAdjustmentID = ParametricMacPreviewFeatureID.localAdjustment
      let brushID = ParametricMacPreviewFeatureID.brushMask
      let featherID = ParametricMacPreviewFeatureID.featherMask
      let exposureID = ParametricMacPreviewFeatureID.localExposure
      let blurID = ParametricMacPreviewFeatureID.localBlur
      let brush = try makeBrushMask(
        size: currentSize,
        settings: settings,
        id: brushID,
        isEnabled: settings.isFeatureEnabled(brushID)
      )
      let featheredMask = try FeatureNode(
        BrightroomFeatureDefinitions.FeatherMask.self,
        id: featherID,
        isEnabled: settings.isFeatureEnabled(featherID),
        payload: .init(input: brush, radius: settings.maskFeatherRadius)
      )
      var effects: [FeatureNode] = [
        try FeatureNode(
          BrightroomFeatureDefinitions.Exposure.self,
          id: exposureID,
          isEnabled: settings.isFeatureEnabled(exposureID),
          payload: .init(value: settings.localExposure)
        ),
      ]
      if settings.localBlurRadius > 0.1 {
        effects.append(
          try FeatureNode(
            BrightroomFeatureDefinitions.GaussianBlur.self,
            id: blurID,
            isEnabled: settings.isFeatureEnabled(blurID),
            payload: .init(radius: .absolute(settings.localBlurRadius))
          )
        )
      }

      if effects.contains(where: \.isEnabled) {
        features.append(
          .localAdjustment(
            FeatureLocalAdjustment(
              id: localAdjustmentID,
              isEnabled: settings.isFeatureEnabled(localAdjustmentID),
              mask: featheredMask,
              effectPipeline: FeatureEffectPipeline(effects: effects)
            )
          )
        )
      }
      treeLines.append(
        .init(
          id: localAdjustmentID.rawValue,
          level: 1,
          kind: .local,
          title: "Local Adjustment",
          detail: "alpha blend branch",
          featureID: localAdjustmentID
        )
      )
      treeLines.append(
        .init(
          id: brushID.rawValue,
          level: 2,
          kind: .mask,
          title: "Brush Mask",
          detail: "diameter \(Int(settings.brushDiameter))",
          featureID: brushID
        )
      )
      treeLines.append(
        .init(
          id: featherID.rawValue,
          level: 2,
          kind: .mask,
          title: "Feather Mask",
          detail: "radius \(Int(settings.maskFeatherRadius))",
          featureID: featherID
        )
      )
      treeLines.append(
        .init(
          id: exposureID.rawValue,
          level: 2,
          kind: .effect,
          title: "Exposure",
          detail: settings.localExposure.formatted(.number.precision(.fractionLength(2))),
          featureID: exposureID
        )
      )
      if settings.localBlurRadius > 0.1 {
        treeLines.append(
          .init(
            id: blurID.rawValue,
            level: 2,
            kind: .effect,
            title: "Blur",
            detail: "\(Int(settings.localBlurRadius)) px",
            featureID: blurID
          )
        )
      }
    }

    let preCropEffects = try makeGlobalColorEffects(settings: settings)
    features.append(contentsOf: preCropEffects.features.map(FeatureTreeNode.effect))
    treeLines.append(contentsOf: preCropEffects.treeLines)

    if settings.isSecondCropEnabled {
      let featureID = ParametricMacPreviewFeatureID.crop2
      let isEnabled = settings.isFeatureEnabled(featureID)
      let cropRect = insetRect(size: currentSize, inset: settings.secondCropInset)
      features.append(
        .domain(
          try FeatureNode(
            BrightroomFeatureDefinitions.Crop.self,
            id: featureID,
            isEnabled: isEnabled,
            payload: .init(cropRect: cropRect)
          )
        )
      )
      if isEnabled {
        currentSize = cropRect.size
      }
      treeLines.append(
        .init(
          id: featureID.rawValue,
          level: 1,
          kind: .domain,
          title: "Crop 2",
          detail: "inset \(Int(settings.secondCropInset)) -> \(sizeDescription(cropRect.size))",
          featureID: featureID
        )
      )
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
      let featureID = ParametricMacPreviewFeatureID.globalBrightness
      features.append(
        try FeatureNode(
          BrightroomFeatureDefinitions.Brightness.self,
          id: featureID,
          isEnabled: settings.isFeatureEnabled(featureID),
          payload: .init(value: settings.globalBrightness)
        )
      )
      treeLines.append(
        .init(
          id: featureID.rawValue,
          level: 1,
          kind: .effect,
          title: "Brightness",
          detail: settings.globalBrightness.formatted(.number.precision(.fractionLength(2))),
          featureID: featureID
        )
      )
    }

    if abs(settings.globalSaturation) > 0.001 {
      let featureID = ParametricMacPreviewFeatureID.globalSaturation
      features.append(
        try FeatureNode(
          BrightroomFeatureDefinitions.Saturation.self,
          id: featureID,
          isEnabled: settings.isFeatureEnabled(featureID),
          payload: .init(value: settings.globalSaturation)
        )
      )
      treeLines.append(
        .init(
          id: featureID.rawValue,
          level: 1,
          kind: .effect,
          title: "Saturation",
          detail: settings.globalSaturation.formatted(.number.precision(.fractionLength(2))),
          featureID: featureID
        )
      )
    }

    return (features, treeLines)
  }

  private func makeVignetteEffect(
    settings: ParametricMacPreviewSettings
  ) throws -> (feature: FeatureNode, treeLine: ParametricMacTreeLine)? {
    guard settings.globalVignette > 0.001 else {
      return nil
    }
    let featureID = ParametricMacPreviewFeatureID.globalVignette

    return (
      try FeatureNode(
        BrightroomFeatureDefinitions.Vignette.self,
        id: featureID,
        isEnabled: settings.isFeatureEnabled(featureID),
        payload: .init(value: settings.globalVignette)
      ),
      .init(
        id: featureID.rawValue,
        level: 1,
        kind: .effect,
        title: "Vignette",
        detail: settings.globalVignette.formatted(.number.precision(.fractionLength(2))),
        featureID: featureID
      )
    )
  }

  private func makeBrushMask(
    size: CGSize,
    settings: ParametricMacPreviewSettings,
    id: FeatureID,
    isEnabled: Bool
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
      id: id,
      isEnabled: isEnabled,
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
