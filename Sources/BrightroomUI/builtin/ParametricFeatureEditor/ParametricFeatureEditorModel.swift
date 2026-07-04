//
// Copyright (c) 2026 Muukii <muukii.app@gmail.com>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#if os(iOS)

import CoreGraphics
import Foundation
import Observation

import BrightroomEngine
import BrightroomParametric

/// The active feature-list selection used by the parametric editor.
///
/// The selected feature identity and mode are kept together so the canvas can
/// derive both the FeatureTree point being previewed and the feature node being
/// edited. A row can therefore be active as a pure preview, as a parameter
/// editor, or as a direct CropView tool.
public struct ParametricFeatureEditorSelection: Equatable, Sendable {

  /// The active editing mode for the selected feature row.
  public enum Mode: String, CaseIterable, Equatable, Sendable {

    /// Show the evaluated image without direct canvas editing.
    case preview

    /// Edit crop geometry through CropView's crop guide.
    case crop

    /// Edit a local-adjustment mask through CropView's brush surface.
    case mask

    /// Edit feature parameters through the selected list cell.
    case parameters
  }

  /// The selected feature or virtual row identity.
  public var activeFeatureID: FeatureID

  /// The way the selected feature is currently edited.
  public var mode: Mode

  /// Creates an active feature selection.
  public init(
    activeFeatureID: FeatureID = EditingFeatureTree.finalCropNodeID,
    mode: Mode = .crop
  ) {
    self.activeFeatureID = activeFeatureID
    self.mode = mode
  }
}

/// A user-facing feature row in the parametric editor.
///
/// Rows are a display projection over `EditingStack.Edit.features` plus two
/// virtual anchors, Source and Output. Global adjustment features live inside
/// the global `EffectPipelineFeature`, so they are projected as child rows with
/// their own stable `FeatureID`s while still mutating the parent pipeline.
public struct ParametricFeatureEditorRow: Equatable, Identifiable, Sendable {

  /// The kind of feature represented by the row.
  public enum Kind: Equatable, Sendable {

    /// The original source image before the feature tree is evaluated.
    case source

    /// The global effect-pipeline container node.
    case globalEffects

    /// A supported adjustment feature inside the global effect pipeline.
    case globalAdjustment(ParametricFeatureEditorAdjustmentParameter)

    /// A local adjustment branch with an editable mask.
    case localAdjustment

    /// An additional, repeated crop feature upstream of the final crop.
    case crop

    /// The document's final crop feature.
    case finalCrop

    /// The evaluated document output.
    case output

    /// A feature that is preserved in the list but has no tailored controls.
    case unsupported
  }

  /// The row identity used for SwiftUI diffing and active selection.
  public var id: FeatureID

  /// The feature kind represented by the row.
  public var kind: Kind

  /// Primary display title.
  public var title: String

  /// Secondary status text.
  public var subtitle: String

  /// SF Symbol name used by the feature list.
  public var systemImageName: String

  /// Whether the represented feature participates in rendering.
  public var isEnabled: Bool

  /// The visual nesting level in the feature list.
  public var indentationLevel: Int

  /// The mode the editor should enter when this row becomes active.
  public var preferredMode: ParametricFeatureEditorSelection.Mode

  /// Creates a feature-list row.
  public init(
    id: FeatureID,
    kind: Kind,
    title: String,
    subtitle: String,
    systemImageName: String,
    isEnabled: Bool = true,
    indentationLevel: Int = 0,
    preferredMode: ParametricFeatureEditorSelection.Mode
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.subtitle = subtitle
    self.systemImageName = systemImageName
    self.isEnabled = isEnabled
    self.indentationLevel = indentationLevel
    self.preferredMode = preferredMode
  }
}

/// A supported global-adjustment feature shown as a parameter row.
public enum ParametricFeatureEditorAdjustmentParameter: String, CaseIterable, Identifiable, Sendable {

  case exposure
  case brightness
  case contrast
  case saturation
  case blur

  public var id: Self { self }

  /// The row identity used when this adjustment is stored in the global
  /// effect pipeline.
  public var featureID: FeatureID {
    FeatureID(rawValue: "brightroom.parametric-editor.global-adjustment.\(rawValue)")
  }

  /// Display title for the adjustment row.
  public var title: String {
    switch self {
    case .exposure: return "Exposure"
    case .brightness: return "Brightness"
    case .contrast: return "Contrast"
    case .saturation: return "Saturation"
    case .blur: return "Blur"
    }
  }

  /// SF Symbol name used by controls that add or edit this adjustment.
  public var systemImageName: String {
    switch self {
    case .exposure: return "plusminus.circle"
    case .brightness: return "sun.max"
    case .contrast: return "circle.lefthalf.filled"
    case .saturation: return "drop"
    case .blur: return "drop.fill"
    }
  }

  /// Slider range used by the row-level parameter editor.
  public var sliderRange: ClosedRange<Double> {
    switch self {
    case .blur:
      return 0...100
    case .exposure, .brightness, .contrast, .saturation:
      return -100...100
    }
  }

  /// The initial non-neutral slider value used when the user adds the feature.
  public var initialSliderValue: Double {
    switch self {
    case .exposure: return 20
    case .brightness: return 20
    case .contrast: return 15
    case .saturation: return 20
    case .blur: return 35
    }
  }

  /// Whether this parameter is represented by `effect`.
  public func matches(_ effect: any ImageEffectFeatureType) -> Bool {
    switch self {
    case .exposure: return effect is ExposureFeature
    case .brightness: return effect is BrightnessFeature
    case .contrast: return effect is ContrastFeature
    case .saturation: return effect is SaturationFeature
    case .blur: return effect is GaussianBlurFeature
    }
  }

  /// The adjustment parameter represented by a supported effect.
  public static func parameter(
    for effect: any ImageEffectFeatureType
  ) -> Self? {
    allCases.first { $0.matches(effect) }
  }

  /// The current row slider value for this parameter.
  public func sliderValue(in effects: EffectPipeline) -> Double {
    let filterValue: Double
    switch self {
    case .exposure:
      filterValue = effects.first(of: ExposureFeature.self)?.value ?? 0
    case .brightness:
      filterValue = effects.first(of: BrightnessFeature.self)?.value ?? 0
    case .contrast:
      filterValue = effects.first(of: ContrastFeature.self)?.value ?? 0
    case .saturation:
      filterValue = effects.first(of: SaturationFeature.self)?.value ?? 0
    case .blur:
      filterValue = effects.first(of: GaussianBlurFeature.self)?.parametricEditorSliderValue ?? 0
    }

    guard maximumFilterValue != 0 else {
      return 0
    }

    return (filterValue / maximumFilterValue * 100).rounded()
  }

  /// Writes a row slider value into an effect pipeline.
  public func apply(sliderValue: Double, to effects: inout EffectPipeline) {
    let clamped = min(max(sliderValue, sliderRange.lowerBound), sliderRange.upperBound)
    let filterValue = clamped / 100 * maximumFilterValue
    let value: Double? = abs(clamped) < 0.5 ? nil : filterValue

    switch self {
    case .exposure:
      upsert(
        value,
        into: &effects,
        make: { ExposureFeature(id: featureID, value: $0) },
        update: { $0.value = $1 }
      )
    case .brightness:
      upsert(
        value,
        into: &effects,
        make: { BrightnessFeature(id: featureID, value: $0) },
        update: { $0.value = $1 }
      )
    case .contrast:
      upsert(
        value,
        into: &effects,
        make: { ContrastFeature(id: featureID, value: $0) },
        update: { $0.value = $1 }
      )
    case .saturation:
      upsert(
        value,
        into: &effects,
        make: { SaturationFeature(id: featureID, value: $0) },
        update: { $0.value = $1 }
      )
    case .blur:
      upsert(
        value,
        into: &effects,
        make: { GaussianBlurFeature(id: featureID, value: $0) },
        update: { $0.radius = .editingStackFilterValue($1) }
      )
    }
  }

  private var maximumFilterValue: Double {
    switch self {
    case .exposure: return 1.8
    case .brightness: return 0.2
    case .contrast: return 0.18
    case .saturation: return 1
    case .blur: return 100
    }
  }

  private func upsert<T: ImageEffectFeatureType>(
    _ value: Double?,
    into effects: inout EffectPipeline,
    make: (Double) -> T,
    update: (inout T, Double) -> Void
  ) {
    guard let value else {
      effects.set(nil as T?)
      return
    }

    if var existing = effects.first(of: T.self) {
      update(&existing, value)
      effects.set(existing)
    } else {
      effects.set(make(value), insertionIndex: ParametricFeatureEditorEffectOrder.insertionIndex(for: T.self))
    }
  }
}

/// The policy layer for the generic SwiftUI parametric feature editor.
///
/// The model keeps UI selection, feature-list projection, and document
/// mutations in one place. `EditingStack` remains the document/history owner;
/// this type only decides how a feature-list editor interprets and edits that
/// document.
@MainActor
@Observable
public final class ParametricFeatureEditorModel {

  /// The stack whose current edit is shown by the feature-list editor.
  @ObservationIgnored public let editingStack: EditingStack

  @ObservationIgnored private let cropViewDocumentStore: CropViewDocument

  /// The active feature row and editing mode.
  public var selection: ParametricFeatureEditorSelection

  /// Mask brush diameter in viewport points.
  public var maskBrushPointDiameter: Double = 36

  /// Creates a parametric feature editor over an editing stack.
  public init(
    editingStack: EditingStack,
    initialSelection: ParametricFeatureEditorSelection = .init()
  ) {
    self.editingStack = editingStack
    self.cropViewDocumentStore = CropViewDocument(editingStack: editingStack)
    self.selection = initialSelection
  }

  /// The reusable CropView document used by the editor canvas.
  var cropViewDocument: CropViewDocument {
    cropViewDocumentStore
  }

  /// The current loaded stack state.
  public var loadedState: EditingStack.Loaded? {
    editingStack.loadedState
  }

  /// Whether the source image has loaded into an editable document.
  public var isLoaded: Bool {
    loadedState != nil
  }

  /// The current FeatureTree projection.
  public var featureTree: EditingFeatureTree? {
    loadedState.map { EditingFeatureTree(edit: $0.currentEdit) }
  }

  /// The rows shown in source-to-output feature order.
  public var rows: [ParametricFeatureEditorRow] {
    guard let loadedState, let featureTree else {
      return [
        .source,
        .output,
      ]
    }

    var rows: [ParametricFeatureEditorRow] = [.source]
    for node in featureTree.nodes {
      rows.append(contentsOf: makeRows(for: node, edit: loadedState.currentEdit))
    }
    rows.append(.output)
    return rows
  }

  /// The row for the active selection, if it still exists.
  public var activeRow: ParametricFeatureEditorRow? {
    rows.first { $0.id == selection.activeFeatureID }
  }

  /// The canvas focus derived from the active feature row.
  public var currentFeatureFocus: CropViewFeatureFocus {
    featureFocus(for: selection)
  }

  /// The masking brush currently applied to CropView.
  public var maskingBrush: CropViewMaskingBrush {
    CropViewMaskingBrush(
      diameter: .viewportPoints(CGFloat(maskBrushPointDiameter)),
      hardness: 0.72,
      opacity: 1,
      spacing: 0.05
    )
  }

  /// Starts image preparation.
  public func start() {
    editingStack.start()
  }

  /// Commits the current document as an undo checkpoint when it changed.
  public func commitCurrentEditIfNeeded() {
    editingStack.commitCurrentEditIfNeeded()
  }

  /// Selects a feature row and enters that row's preferred editing mode.
  public func select(row: ParametricFeatureEditorRow) {
    selection = ParametricFeatureEditorSelection(
      activeFeatureID: row.id,
      mode: row.preferredMode
    )
  }

  /// Switches the active row to another mode.
  public func setMode(_ mode: ParametricFeatureEditorSelection.Mode) {
    selection.mode = mode
  }

  /// Adds or activates a supported global adjustment feature.
  public func addGlobalAdjustment(
    _ parameter: ParametricFeatureEditorAdjustmentParameter
  ) {
    setGlobalAdjustmentValue(parameter.initialSliderValue, parameter: parameter)
    selection = ParametricFeatureEditorSelection(
      activeFeatureID: parameter.featureID,
      mode: .parameters
    )
  }

  /// Adds an additional crop feature immediately before the final crop and
  /// selects it for editing.
  ///
  /// The new crop starts as an identity crop over its input domain — the final
  /// crop's current input domain, since it is inserted just upstream of it — so
  /// it is a no-op until the user reframes it. Repeated crops compose: this crop
  /// clips the already-cropped result of any upstream crop, and the final crop
  /// clips this crop's result.
  public func addCrop() {
    guard var edit = loadedState?.currentEdit, let tree = featureTree else {
      return
    }

    let domainSize = tree.inputDomainSize(
      ofFeature: EditingFeatureTree.finalCropNodeID,
      sourceSize: edit.imageSize
    ) ?? edit.imageSize

    let cropID = FeatureID()
    let crop = CropFeature(
      id: cropID,
      cropRect: CGRect(origin: .zero, size: domainSize)
    )

    let finalCropIndex = edit.features.firstIndex {
      $0.id == EditingFeatureTree.finalCropNodeID
    } ?? edit.features.count
    edit.insertFeature(.domain(crop), at: finalCropIndex)
    applyEditIfChanged(edit)

    selection = ParametricFeatureEditorSelection(
      activeFeatureID: cropID,
      mode: .crop
    )
  }

  /// Adds a blur local-adjustment feature before the final crop.
  public func addBlurMaskAdjustment() {
    let layerID = FeatureID()
    let effect = GaussianBlurFeature(
      id: FeatureID(rawValue: "\(layerID.rawValue).blur"),
      value: ParametricFeatureEditorAdjustmentParameter.blur.initialSliderValue
    )
    let adjustment = LocalAdjustmentFeature(
      id: layerID,
      maskTree: MaskTree(
        root: .brush(
          BrushMask(id: FeatureID(rawValue: "\(layerID.rawValue).mask"))
        )
      ),
      effectPipeline: EffectPipeline(effects: [effect])
    )

    guard var edit = loadedState?.currentEdit else {
      return
    }

    var localAdjustments = edit.localAdjustments
    localAdjustments.append(adjustment)
    EditingFeatureTree.replaceLocalAdjustments(
      localAdjustments,
      in: &edit,
      insertingBefore: EditingFeatureTree.finalCropNodeID
    )
    applyEditIfChanged(edit)

    selection = ParametricFeatureEditorSelection(
      activeFeatureID: layerID,
      mode: .mask
    )
  }

  /// Removes a supported global adjustment feature.
  public func removeGlobalAdjustment(
    _ parameter: ParametricFeatureEditorAdjustmentParameter
  ) {
    setGlobalAdjustmentValue(0, parameter: parameter)
    selection = ParametricFeatureEditorSelection(
      activeFeatureID: EditingFeatureTree.globalEffectsNodeID,
      mode: .parameters
    )
  }

  /// Removes a removable main-tree feature.
  public func removeFeature(id: FeatureID) {
    guard var edit = loadedState?.currentEdit else {
      return
    }

    guard id != EditingFeatureTree.finalCropNodeID else {
      return
    }

    guard edit.removeFeature(id: id) else {
      return
    }

    applyEditIfChanged(edit)
    selection = ParametricFeatureEditorSelection(
      activeFeatureID: EditingFeatureTree.finalCropNodeID,
      mode: .crop
    )
  }

  /// Sets whether a known main-tree feature participates in rendering.
  public func setFeatureEnabled(
    _ isEnabled: Bool,
    id: FeatureID
  ) {
    editingStack.updateFeature(id: id) { feature in
      switch feature {
      case let .domain(domain):
        guard var crop = domain as? CropFeature else {
          return
        }
        crop.isEnabled = isEnabled
        feature = .domain(crop)

      case let .effect(effect):
        guard var bundle = effect as? EffectPipelineFeature else {
          return
        }
        bundle.isEnabled = isEnabled
        feature = .effect(bundle)

      case var .localAdjustment(adjustment):
        adjustment.isEnabled = isEnabled
        feature = .localAdjustment(adjustment)
      }
    }
  }

  /// Reads and writes global adjustment sliders through SwiftUI bindings.
  public subscript(
    globalAdjustment parameter: ParametricFeatureEditorAdjustmentParameter
  ) -> Double {
    get {
      parameter.sliderValue(in: currentGlobalEffects)
    }
    set {
      setGlobalAdjustmentValue(newValue, parameter: parameter)
    }
  }

  /// Reads and writes a local adjustment's blur amount through SwiftUI bindings.
  public subscript(localAdjustmentBlur id: FeatureID) -> Double {
    get {
      guard let adjustment = featureTree?.localAdjustment(id: id) else {
        return 0
      }
      return ParametricFeatureEditorAdjustmentParameter.blur.sliderValue(
        in: adjustment.effectPipeline
      )
    }
    set {
      setLocalAdjustmentBlurValue(newValue, id: id)
    }
  }

  /// The canvas focus for a specific selection.
  public func featureFocus(
    for selection: ParametricFeatureEditorSelection
  ) -> CropViewFeatureFocus {
    guard let row = rows.first(where: { $0.id == selection.activeFeatureID }) else {
      return .output
    }

    switch row.kind {
    case .source:
      return CropViewFeatureFocus(viewingPoint: .source)

    case .output, .globalEffects, .globalAdjustment, .unsupported:
      return .output

    case .finalCrop:
      guard selection.mode == .crop else {
        return .output
      }
      return CropViewFeatureFocus(
        viewingPoint: .output,
        editingTarget: .crop(id: EditingFeatureTree.finalCropNodeID)
      )

    case .crop:
      guard selection.mode == .crop else {
        return .output
      }
      // A repeated crop is authored against its input domain — the evaluated
      // result of every upstream feature — so the canvas previews that point
      // while the crop guide edits this node. The final output (which this crop
      // and any downstream crop clip) is not what the user frames here.
      let viewingPoint = featureTree?.inputPoint(ofFeature: row.id) ?? .output
      return CropViewFeatureFocus(
        viewingPoint: viewingPoint,
        editingTarget: .crop(id: row.id)
      )

    case .localAdjustment:
      guard selection.mode == .mask else {
        return .output
      }
      let seedEffect = featureTree?.localAdjustment(id: row.id)?.effectPipeline
      return CropViewFeatureFocus(
        viewingPoint: .output,
        editingTarget: .localAdjustmentMask(
          id: row.id,
          seedEffect: seedEffect
        )
      )
    }
  }

  private var currentGlobalEffects: EffectPipeline {
    featureTree?.globalEffects ?? loadedState?.currentEdit.effects ?? EffectPipeline()
  }

  private func setGlobalAdjustmentValue(
    _ sliderValue: Double,
    parameter: ParametricFeatureEditorAdjustmentParameter
  ) {
    guard var edit = loadedState?.currentEdit else {
      return
    }

    if edit.updateFeature(id: EditingFeatureTree.globalEffectsNodeID, mutate: { feature in
      guard
        case let .effect(effect) = feature,
        var bundle = effect as? EffectPipelineFeature
      else {
        return
      }

      parameter.apply(sliderValue: sliderValue, to: &bundle.pipeline)
      feature = .effect(bundle)
    }) {
      applyEditIfChanged(edit)
      return
    }

    var pipeline = EffectPipeline()
    parameter.apply(sliderValue: sliderValue, to: &pipeline)
    guard pipeline.isEmpty == false else {
      return
    }

    edit.insertFeature(
      .effect(
        EffectPipelineFeature(
          id: EditingFeatureTree.globalEffectsNodeID,
          pipeline: pipeline
        )
      ),
      at: globalEffectsInsertionIndex(in: edit)
    )
    applyEditIfChanged(edit)
  }

  private func setLocalAdjustmentBlurValue(
    _ sliderValue: Double,
    id: FeatureID
  ) {
    editingStack.updateFeature(id: id) { feature in
      guard case var .localAdjustment(adjustment) = feature else {
        return
      }

      ParametricFeatureEditorAdjustmentParameter.blur.apply(
        sliderValue: sliderValue,
        to: &adjustment.effectPipeline
      )
      feature = .localAdjustment(adjustment)
    }
  }

  private func makeRows(
    for node: EditingFeatureTree.Node,
    edit: EditingStack.Edit
  ) -> [ParametricFeatureEditorRow] {
    switch node {
    case let .effect(effect):
      guard
        let bundle = effect as? EffectPipelineFeature,
        node.id == EditingFeatureTree.globalEffectsNodeID
      else {
        return [
          ParametricFeatureEditorRow(
            id: node.id,
            kind: .unsupported,
            title: "Effect",
            subtitle: node.id.rawValue,
            systemImageName: "wand.and.stars",
            isEnabled: node.isEnabled,
            preferredMode: .preview
          ),
        ]
      }

      let supportedEffects = bundle.pipeline.effects.compactMap { effect -> ParametricFeatureEditorRow? in
        guard let parameter = ParametricFeatureEditorAdjustmentParameter.parameter(for: effect) else {
          return nil
        }

        return ParametricFeatureEditorRow(
          id: effect.id,
          kind: .globalAdjustment(parameter),
          title: parameter.title,
          subtitle: "\(Int(parameter.sliderValue(in: bundle.pipeline)))",
          systemImageName: parameter.systemImageName,
          isEnabled: effect.isEnabled,
          indentationLevel: 1,
          preferredMode: .parameters
        )
      }

      return [
        ParametricFeatureEditorRow(
          id: bundle.id,
          kind: .globalEffects,
          title: "Global Effects",
          subtitle: bundle.pipeline.isEmpty ? "Neutral" : "\(bundle.pipeline.effects.count) effects",
          systemImageName: "slider.horizontal.3",
          isEnabled: bundle.isEnabled,
          preferredMode: .parameters
        ),
      ] + supportedEffects

    case let .localAdjustment(adjustment):
      return [
        ParametricFeatureEditorRow(
          id: adjustment.id,
          kind: .localAdjustment,
          title: title(for: adjustment),
          subtitle: subtitle(for: adjustment),
          systemImageName: "paintbrush.pointed",
          isEnabled: adjustment.isEnabled,
          preferredMode: .mask
        ),
      ]

    case let .domain(domain):
      guard let crop = domain as? CropFeature else {
        return [
          ParametricFeatureEditorRow(
            id: node.id,
            kind: .unsupported,
            title: "Domain",
            subtitle: node.id.rawValue,
            systemImageName: "square.stack.3d.down.right",
            isEnabled: node.isEnabled,
            preferredMode: .preview
          ),
        ]
      }

      let isFinal = crop.id == EditingFeatureTree.finalCropNodeID
      let displayRect = crop.displayCropRect(imageSize: edit.imageSize)
      return [
        ParametricFeatureEditorRow(
          id: crop.id,
          kind: isFinal ? .finalCrop : .crop,
          title: "Crop",
          subtitle: "\(Int(displayRect.width)) x \(Int(displayRect.height))",
          systemImageName: "crop",
          isEnabled: crop.isEnabled,
          preferredMode: .crop
        ),
      ]
    }
  }

  private func globalEffectsInsertionIndex(in edit: EditingStack.Edit) -> Int {
    let features = edit.features
    let finalCropIndex = features.firstIndex {
      $0.id == EditingFeatureTree.finalCropNodeID
    } ?? features.count

    for index in features.indices where index < finalCropIndex {
      if case .localAdjustment = features[index] {
        return index
      }
    }

    return finalCropIndex
  }

  private func applyEditIfChanged(_ edit: EditingStack.Edit) {
    guard editingStack.loadedState?.currentEdit != edit else {
      return
    }
    editingStack.loadedState?.currentEdit = edit
  }

  private func title(for adjustment: LocalAdjustmentFeature) -> String {
    if adjustment.effectPipeline.effects.contains(where: { $0 is GaussianBlurFeature }) {
      return "Blur Mask"
    }
    return "Local Adjustment"
  }

  private func subtitle(for adjustment: LocalAdjustmentFeature) -> String {
    let strokeCount = adjustment.maskTree.brushStrokeCount
    let effectCount = adjustment.effectPipeline.effects.count
    return "\(strokeCount) strokes, \(effectCount) effects"
  }
}

private enum ParametricFeatureEditorEffectOrder {

  private static let order: [ObjectIdentifier] = [
    ObjectIdentifier(ExposureFeature.self),
    ObjectIdentifier(BrightnessFeature.self),
    ObjectIdentifier(SaturationFeature.self),
    ObjectIdentifier(ContrastFeature.self),
    ObjectIdentifier(GaussianBlurFeature.self),
  ]

  static func insertionIndex<T: ImageEffectFeatureType>(
    for type: T.Type
  ) -> (EffectPipeline) -> Int {
    let newRank = rank(of: ObjectIdentifier(type))
    return { pipeline in
      pipeline.effects.firstIndex { existing in
        rank(of: ObjectIdentifier(Swift.type(of: existing))) > newRank
      } ?? pipeline.effects.count
    }
  }

  private static func rank(of typeIdentity: ObjectIdentifier) -> Int {
    order.firstIndex(of: typeIdentity) ?? order.count
  }
}

private extension ParametricFeatureEditorRow {

  static let source = Self(
    id: FeatureID(rawValue: "brightroom.parametric-editor.source"),
    kind: .source,
    title: "Source",
    subtitle: "Original",
    systemImageName: "photo",
    preferredMode: .preview
  )

  static let output = Self(
    id: FeatureID(rawValue: "brightroom.parametric-editor.output"),
    kind: .output,
    title: "Output",
    subtitle: "Result",
    systemImageName: "rectangle.and.arrow.up.right.and.arrow.down.left",
    preferredMode: .preview
  )
}

private extension GaussianBlurFeature {

  var parametricEditorSliderValue: Double? {
    switch radius {
    case let .editingStackFilterValue(value):
      return value
    case .absolute:
      return nil
    }
  }
}

private extension MaskTree {

  var brushStrokeCount: Int {
    root.brushStrokeCount
  }
}

private extension MaskNode {

  var brushStrokeCount: Int {
    switch self {
    case let .brush(mask):
      return mask.strokes.count
    case let .invert(input):
      return input.brushStrokeCount
    case let .feather(feather):
      return feather.input.brushStrokeCount
    case let .union(nodes), let .intersect(nodes):
      return nodes.reduce(0) { $0 + $1.brushStrokeCount }
    case let .subtract(subtract):
      return subtract.base.brushStrokeCount + subtract.removing.brushStrokeCount
    }
  }
}

#endif
