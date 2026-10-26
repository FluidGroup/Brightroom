import AppKit
import BrightroomParametric
import CoreImage
import SwiftUI
import UniformTypeIdentifiers

struct ParametricMacDemoView: View {

  @State private var settings = ParametricMacPreviewSettings.initial
  @State private var draggedFeature: ParametricMacEditableFeature?

  private let renderer = ParametricMacPreviewRenderer()

  var body: some View {
    let previewSettings = settings
    let rendered = Result {
      try renderer.render(settings: previewSettings)
    }
    let output = try? rendered.get()

    return HStack(spacing: 0) {
      featureEditorPanel(output: output)
        .frame(width: 380)
        .background(.regularMaterial)

      Divider()

      previewPanel(rendered: rendered)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func previewPanel(rendered: Result<ParametricMacPreviewOutput, Error>) -> some View {
    VStack(alignment: .leading, spacing: 18) {
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

  private func featureEditorPanel(output: ParametricMacPreviewOutput?) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Feature Editor")
            .font(.title3.bold())
          Text("Drag rows to change evaluation order.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer()

        Button {
          settings.suppressedNodes.removeAll()
        } label: {
          Label("Enable All", systemImage: "checkmark.circle")
        }
        .buttonStyle(.borderless)
        .disabled(settings.suppressedNodes.isEmpty)
      }

      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          if let output {
            summaryRow(
              icon: "photo",
              title: "Source",
              detail: "\(Int(output.sourceExtent.width)) x \(Int(output.sourceExtent.height))"
            )
          }

          summaryRow(
            icon: "arrow.right",
            title: "Main",
            detail: "source -> output"
          )

          ForEach(settings.featureOrder) { feature in
            featureEditorRow(
              feature,
              summary: output?.treeLine(for: feature.node)
            )
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(20)
  }

  private func summaryRow(
    icon: String,
    title: String,
    detail: String
  ) -> some View {
    HStack(spacing: 10) {
      Image(systemName: icon)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 28)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.caption.weight(.semibold))
        Text(detail)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 0)
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 10)
  }

  private func featureEditorRow(
    _ feature: ParametricMacEditableFeature,
    summary: ParametricMacTreeLine?
  ) -> some View {
    let node = feature.node
    let isSuppressed = settings.suppressedNodes.contains(node)
    let detail = summary?.detail ?? feature.defaultDetail

    return HStack(spacing: 10) {
      Image(systemName: "line.3.horizontal")
        .font(.caption.weight(.bold))
        .foregroundStyle(.tertiary)
        .frame(width: 16)
        .help("Drag to reorder")
        .onDrag {
          draggedFeature = feature
          return NSItemProvider(object: feature.rawValue as NSString)
        }

      Toggle("", isOn: featureEnabledBinding(for: node))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
        .help(isSuppressed ? "Restore this feature" : "Suppress this feature")

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(feature.kind.title)
            .font(.caption2.monospaced().weight(.semibold))
            .foregroundStyle(feature.kind.color)

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
          Text(feature.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(isSuppressed ? .secondary : .primary)

          Text(detail)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }

        featureParameterControls(for: feature)
          .padding(.top, 8)
      }

      Spacer(minLength: 0)

      featureMoveControls(for: feature)
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 10)
    .background(isSuppressed ? Color.secondary.opacity(0.08) : Color(nsColor: .controlBackgroundColor).opacity(0.78))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .opacity(isSuppressed ? 0.58 : 1)
    .onDrop(
      of: [UTType.text],
      delegate: ParametricMacFeatureDropDelegate(
        targetFeature: feature,
        featureOrder: $settings.featureOrder,
        draggedFeature: $draggedFeature
      )
    )
  }

  @ViewBuilder
  private func featureParameterControls(for feature: ParametricMacEditableFeature) -> some View {
    switch feature {
    case .crop1:
      parameterSlider(
        title: "Inset",
        value: $settings.firstCropInset,
        range: 0...140,
        step: 1,
        valueText: "\(Int(settings.firstCropInset))"
      )

    case .localAdjustment:
      VStack(alignment: .leading, spacing: 10) {
        nestedFeatureToggle(
          title: "Brush Mask",
          detail: "diameter \(Int(settings.brushDiameter))",
          node: .brushMask
        )
        parameterSlider(
          title: "Brush",
          value: $settings.brushDiameter,
          range: 40...360,
          step: 1,
          valueText: "\(Int(settings.brushDiameter))"
        )

        nestedFeatureToggle(
          title: "Feather Mask",
          detail: "radius \(Int(settings.maskFeatherRadius))",
          node: .featherMask
        )
        parameterSlider(
          title: "Feather",
          value: $settings.maskFeatherRadius,
          range: 0...48,
          step: 1,
          valueText: "\(Int(settings.maskFeatherRadius))"
        )

        Divider()

        nestedFeatureToggle(
          title: "Exposure",
          detail: settings.localExposure.formatted(.number.precision(.fractionLength(2))),
          node: .localExposure
        )
        parameterSlider(
          title: "Exposure",
          value: $settings.localExposure,
          range: -1...1,
          step: 0.01,
          valueText: settings.localExposure.formatted(.number.precision(.fractionLength(2)))
        )

        nestedFeatureToggle(
          title: "Blur",
          detail: "\(Int(settings.localBlurRadius)) px",
          node: .localBlur
        )
        parameterSlider(
          title: "Blur",
          value: $settings.localBlurRadius,
          range: 0...24,
          step: 1,
          valueText: "\(Int(settings.localBlurRadius)) px"
        )
      }

    case .globalBrightness:
      parameterSlider(
        title: "Brightness",
        value: $settings.globalBrightness,
        range: -0.25...0.25,
        step: 0.01,
        valueText: settings.globalBrightness.formatted(.number.precision(.fractionLength(2)))
      )

    case .globalSaturation:
      parameterSlider(
        title: "Saturation",
        value: $settings.globalSaturation,
        range: -0.75...0.75,
        step: 0.01,
        valueText: settings.globalSaturation.formatted(.number.precision(.fractionLength(2)))
      )

    case .crop2:
      parameterSlider(
        title: "Inset",
        value: $settings.secondCropInset,
        range: 0...96,
        step: 1,
        valueText: "\(Int(settings.secondCropInset))"
      )

    case .globalVignette:
      parameterSlider(
        title: "Vignette",
        value: $settings.globalVignette,
        range: 0...1.2,
        step: 0.01,
        valueText: settings.globalVignette.formatted(.number.precision(.fractionLength(2)))
      )
    }
  }

  private func parameterSlider(
    title: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    step: Double,
    valueText: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Text(valueText)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Slider(value: value, in: range, step: step)
    }
  }

  private func nestedFeatureToggle(
    title: String,
    detail: String,
    node: ParametricMacNode
  ) -> some View {
    HStack(spacing: 8) {
      Toggle("", isOn: featureEnabledBinding(for: node))
        .labelsHidden()
        .toggleStyle(.checkbox)
      Text(title)
        .font(.caption.weight(.semibold))
      Text(detail)
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
  }

  private func featureMoveControls(for feature: ParametricMacEditableFeature) -> some View {
    VStack(spacing: 2) {
      Button {
        moveFeature(feature, by: -1)
      } label: {
        Image(systemName: "chevron.up")
      }
      .buttonStyle(.borderless)
      .controlSize(.mini)
      .disabled(settings.featureOrder.first == feature)
      .help("Move earlier")

      Button {
        moveFeature(feature, by: 1)
      } label: {
        Image(systemName: "chevron.down")
      }
      .buttonStyle(.borderless)
      .controlSize(.mini)
      .disabled(settings.featureOrder.last == feature)
      .help("Move later")
    }
    .frame(width: 22)
  }

  private func moveFeature(
    _ feature: ParametricMacEditableFeature,
    by offset: Int
  ) {
    guard let sourceIndex = settings.featureOrder.firstIndex(of: feature) else {
      return
    }
    let destinationIndex = min(
      max(sourceIndex + offset, 0),
      settings.featureOrder.count - 1
    )
    guard sourceIndex != destinationIndex else {
      return
    }

    withAnimation(.snappy) {
      let movedFeature = settings.featureOrder.remove(at: sourceIndex)
      settings.featureOrder.insert(movedFeature, at: destinationIndex)
    }
  }

  private func featureEnabledBinding(for node: ParametricMacNode) -> Binding<Bool> {
    Binding(
      get: {
        settings.suppressedNodes.contains(node) == false
      },
      set: { isEnabled in
        if isEnabled {
          settings.suppressedNodes.remove(node)
        } else {
          settings.suppressedNodes.insert(node)
        }
      }
    )
  }
}

/// User-editable values that define the macOS parametric preview's root feature.
struct ParametricMacPreviewSettings {

  static let initial = ParametricMacPreviewSettings(
    featureOrder: ParametricMacEditableFeature.defaultOrder,
    firstCropInset: 48,
    localExposure: 0.55,
    localBlurRadius: 4,
    brushDiameter: 220,
    maskFeatherRadius: 18,
    secondCropInset: 34,
    globalBrightness: 0.03,
    globalSaturation: 0.22,
    globalVignette: 0.45,
    suppressedNodes: []
  )

  var featureOrder: [ParametricMacEditableFeature]
  var firstCropInset: Double
  var localExposure: Double
  var localBlurRadius: Double
  var brushDiameter: Double
  var maskFeatherRadius: Double
  var secondCropInset: Double
  var globalBrightness: Double
  var globalSaturation: Double
  var globalVignette: Double
  /// Nodes the user switched off. A suppressed node is left out of the
  /// root feature; features have no per-node enabled flags.
  var suppressedNodes: Set<ParametricMacNode>

  /// Whether the root feature includes `node`, that is, it is not suppressed.
  func includes(_ node: ParametricMacNode) -> Bool {
    suppressedNodes.contains(node) == false
  }
}

/// A rendered source/output pair plus textual tree rows for inspection.
struct ParametricMacPreviewOutput {

  var sourceImage: NSImage
  var outputImage: NSImage
  var sourceExtent: CGRect
  var outputExtent: CGRect
  var treeLines: [ParametricMacTreeLine]

  func treeLine(for node: ParametricMacNode) -> ParametricMacTreeLine? {
    treeLines.first { $0.node == node }
  }
}

/// A single visible row in the interactive feature tree inspector.
struct ParametricMacTreeLine: Identifiable {

  var id: String
  var kind: ParametricMacTreeKind
  var title: String
  var detail: String
  var node: ParametricMacNode?
}

/// Display categories used by the macOS feature tree editor.
enum ParametricMacTreeKind: String {

  case domain
  case local
  case mask
  case effect

  var title: String {
    rawValue.uppercased()
  }

  var color: Color {
    switch self {
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
}

/// Top-level editable actions in the macOS parametric demo.
///
/// The order of this list is the order of the generated
/// `MacDemoFeature` steps, so dragging rows in the editor changes the real
/// evaluation sequence instead of only rearranging display rows.
enum ParametricMacEditableFeature: String, CaseIterable, Identifiable {

  case crop1
  case localAdjustment
  case globalBrightness
  case globalSaturation
  case crop2
  case globalVignette

  static let defaultOrder: [ParametricMacEditableFeature] = [
    .crop1,
    .localAdjustment,
    .globalBrightness,
    .globalSaturation,
    .crop2,
    .globalVignette,
  ]

  var id: String {
    rawValue
  }

  var node: ParametricMacNode {
    switch self {
    case .crop1:
      .crop1
    case .localAdjustment:
      .localAdjustment
    case .globalBrightness:
      .globalBrightness
    case .globalSaturation:
      .globalSaturation
    case .crop2:
      .crop2
    case .globalVignette:
      .globalVignette
    }
  }

  var kind: ParametricMacTreeKind {
    switch self {
    case .crop1, .crop2:
      .domain
    case .localAdjustment:
      .local
    case .globalBrightness, .globalSaturation, .globalVignette:
      .effect
    }
  }

  var title: String {
    switch self {
    case .crop1:
      "Crop 1"
    case .localAdjustment:
      "Local Adjustment"
    case .globalBrightness:
      "Brightness"
    case .globalSaturation:
      "Saturation"
    case .crop2:
      "Crop 2"
    case .globalVignette:
      "Vignette"
    }
  }

  var defaultDetail: String {
    switch self {
    case .crop1, .crop2:
      "current domain crop"
    case .localAdjustment:
      "mask + effect branch"
    case .globalBrightness, .globalSaturation, .globalVignette:
      "global effect"
    }
  }
}

/// Reorders top-level feature rows during a macOS drag operation.
struct ParametricMacFeatureDropDelegate: DropDelegate {

  let targetFeature: ParametricMacEditableFeature
  @Binding var featureOrder: [ParametricMacEditableFeature]
  @Binding var draggedFeature: ParametricMacEditableFeature?

  func dropEntered(info: DropInfo) {
    guard let draggedFeature,
          draggedFeature != targetFeature,
          let sourceIndex = featureOrder.firstIndex(of: draggedFeature),
          let targetIndex = featureOrder.firstIndex(of: targetFeature)
    else {
      return
    }

    withAnimation(.snappy) {
      featureOrder.move(
        fromOffsets: IndexSet(integer: sourceIndex),
        toOffset: targetIndex > sourceIndex ? targetIndex + 1 : targetIndex
      )
    }
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: .move)
  }

  func performDrop(info: DropInfo) -> Bool {
    draggedFeature = nil
    return true
  }
}

/// Nodes of the macOS demo's root feature that the tree editor can suppress.
enum ParametricMacNode: String, Hashable {

  case crop1
  case localAdjustment
  case brushMask
  case featherMask
  case localExposure
  case localBlur
  case globalBrightness
  case globalSaturation
  case crop2
  case globalVignette
}

/// The macOS demo's root feature: its steps evaluate in the order the editor lists them.
struct MacDemoFeature: Feature {

  var steps: [ParametricMacStep]

  var body: [ParametricMacStep] {
    steps
  }
}

/// One reorderable step of the macOS demo's root feature.
///
/// The steps are decided at runtime (their order is user data), so a host enum
/// gives them one type while each case keeps its concrete feature.
enum ParametricMacStep: Feature {

  case crop(CropFeature)
  case localAdjustment(LocalAdjustmentFeature<[AnyImageEffect]>)
  case effect(AnyImageEffect)

  var body: some Feature {
    switch self {
    case let .crop(crop):
      crop
    case let .localAdjustment(localAdjustment):
      localAdjustment
    case let .effect(effect):
      effect
    }
  }
}

/// Builds and renders a value-tree root feature for the macOS demo.
struct ParametricMacPreviewRenderer {

  private static let sourceSize = CGSize(width: 960, height: 640)
  private static let context = CIContext()

  /// Renders the current settings into AppKit images for display.
  func render(settings: ParametricMacPreviewSettings) throws -> ParametricMacPreviewOutput {
    let sourceImage = makeSourceImage()
    let feature = makeFeature(settings: settings)
    let outputImage = try FeatureRenderer().makeImage(
      from: sourceImage,
      feature: feature.feature
    )

    return ParametricMacPreviewOutput(
      sourceImage: try makeNSImage(from: sourceImage),
      outputImage: try makeNSImage(from: outputImage),
      sourceExtent: sourceImage.extent,
      outputExtent: outputImage.extent,
      treeLines: feature.treeLines
    )
  }

  private func makeFeature(
    settings: ParametricMacPreviewSettings
  ) -> (feature: MacDemoFeature, treeLines: [ParametricMacTreeLine]) {
    var steps: [ParametricMacStep] = []
    var treeLines: [ParametricMacTreeLine] = []
    var currentSize = Self.sourceSize

    for editableFeature in settings.featureOrder {
      switch editableFeature {
      case .crop1, .crop2:
        let isFirst = editableFeature == .crop1
        let output = makeCropFeature(
          node: editableFeature.node,
          title: isFirst ? "Crop 1" : "Crop 2",
          inset: isFirst ? settings.firstCropInset : settings.secondCropInset,
          currentSize: currentSize,
          settings: settings
        )
        if let feature = output.feature {
          steps.append(.crop(feature))
          currentSize = feature.rect.size
        }
        treeLines.append(output.treeLine)

      case .localAdjustment:
        let output = makeLocalAdjustment(
          currentSize: currentSize,
          settings: settings
        )
        if let feature = output.feature {
          steps.append(.localAdjustment(feature))
        }
        treeLines.append(contentsOf: output.treeLines)

      case .globalBrightness:
        let node = ParametricMacNode.globalBrightness
        if settings.includes(node) {
          steps.append(.effect(AnyImageEffect(BrightnessFeature(value: settings.globalBrightness))))
        }
        treeLines.append(
          .init(
            id: node.rawValue,
            kind: .effect,
            title: "Brightness",
            detail: settings.globalBrightness.formatted(.number.precision(.fractionLength(2))),
            node: node
          )
        )

      case .globalSaturation:
        let node = ParametricMacNode.globalSaturation
        if settings.includes(node) {
          steps.append(.effect(AnyImageEffect(SaturationFeature(value: settings.globalSaturation))))
        }
        treeLines.append(
          .init(
            id: node.rawValue,
            kind: .effect,
            title: "Saturation",
            detail: settings.globalSaturation.formatted(.number.precision(.fractionLength(2))),
            node: node
          )
        )

      case .globalVignette:
        let node = ParametricMacNode.globalVignette
        if settings.includes(node) {
          steps.append(.effect(AnyImageEffect(VignetteFeature(value: settings.globalVignette))))
        }
        treeLines.append(
          .init(
            id: node.rawValue,
            kind: .effect,
            title: "Vignette",
            detail: settings.globalVignette.formatted(.number.precision(.fractionLength(2))),
            node: node
          )
        )
      }
    }

    return (
      MacDemoFeature(steps: steps),
      treeLines
    )
  }

  private func makeCropFeature(
    node: ParametricMacNode,
    title: String,
    inset: Double,
    currentSize: CGSize,
    settings: ParametricMacPreviewSettings
  ) -> (feature: CropFeature?, treeLine: ParametricMacTreeLine) {
    let cropRect = insetRect(size: currentSize, inset: inset)
    return (
      settings.includes(node) ? CropFeature(rect: cropRect) : nil,
      .init(
        id: node.rawValue,
        kind: .domain,
        title: title,
        detail: "inset \(Int(inset)) -> \(sizeDescription(cropRect.size))",
        node: node
      )
    )
  }

  private func makeLocalAdjustment(
    currentSize: CGSize,
    settings: ParametricMacPreviewSettings
  ) -> (feature: LocalAdjustmentFeature<[AnyImageEffect]>?, treeLines: [ParametricMacTreeLine]) {
    // Suppression is structural: a suppressed brush has no strokes, a
    // suppressed feather leaves the brush as the mask root, and a suppressed
    // effect is left out of the content.
    let brush = BrushMask(
      strokes: settings.includes(.brushMask)
        ? [makeBrushStroke(size: currentSize, settings: settings)]
        : []
    )
    let maskRoot: Mask = settings.includes(.featherMask)
      ? .feathered(.brush(brush), radius: settings.maskFeatherRadius)
      : .brush(brush)

    var effects: [AnyImageEffect] = []
    if settings.includes(.localExposure) {
      effects.append(AnyImageEffect(ExposureFeature(ev: settings.localExposure)))
    }
    if settings.includes(.localBlur) {
      effects.append(AnyImageEffect(GaussianBlurFeature(radius: .absolute(settings.localBlurRadius))))
    }

    let localAdjustment: LocalAdjustmentFeature<[AnyImageEffect]>?
    if settings.includes(.localAdjustment), effects.isEmpty == false {
      localAdjustment = LocalAdjustmentFeature(mask: maskRoot) {
        effects
      }
    } else {
      localAdjustment = nil
    }

    return (
      localAdjustment,
      [
        .init(
          id: ParametricMacNode.localAdjustment.rawValue,
          kind: .local,
          title: "Local Adjustment",
          detail: "alpha blend branch",
          node: .localAdjustment
        ),
        .init(
          id: ParametricMacNode.brushMask.rawValue,
          kind: .mask,
          title: "Brush Mask",
          detail: "diameter \(Int(settings.brushDiameter))",
          node: .brushMask
        ),
        .init(
          id: ParametricMacNode.featherMask.rawValue,
          kind: .mask,
          title: "Feather Mask",
          detail: "radius \(Int(settings.maskFeatherRadius))",
          node: .featherMask
        ),
        .init(
          id: ParametricMacNode.localExposure.rawValue,
          kind: .effect,
          title: "Exposure",
          detail: settings.localExposure.formatted(.number.precision(.fractionLength(2))),
          node: .localExposure
        ),
        .init(
          id: ParametricMacNode.localBlur.rawValue,
          kind: .effect,
          title: "Blur",
          detail: "\(Int(settings.localBlurRadius)) px",
          node: .localBlur
        ),
      ]
    )
  }

  private func makeBrushStroke(
    size: CGSize,
    settings: ParametricMacPreviewSettings
  ) -> BrushMask.Stroke {
    let centerY = size.height * 0.56
    let stamps = stride(from: 0.18, through: 0.82, by: 0.08).map { progress in
      CGPoint(
        x: size.width * progress,
        y: centerY + sin(progress * .pi * 3) * size.height * 0.08
      )
    }
    return BrushMask.Stroke(
      stampCenters: stamps,
      brush: BrushMask.Brush(
        diameter: settings.brushDiameter,
        hardness: 0.35,
        opacity: 1
      )
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
