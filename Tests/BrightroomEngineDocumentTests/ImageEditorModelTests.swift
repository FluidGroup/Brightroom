import CoreGraphics
import CoreImage
import SwiftUI
import Testing

@testable import BrightroomEngine
import BrightroomParametric
@testable import BrightroomUI

/// The editor model without a window: what it writes to the host's binding
/// and when, its section switches, Reset, Revert's crop rule, Show Original,
/// how it schedules the output analysis, and when it applies a gray point.
@MainActor
struct ImageEditorModelTests {

  typealias Fixtures = DocumentTestFixtures
  private typealias Section = ImageEditor.AdjustmentSection
  private typealias Change = ImageEditor.AdjustmentChange

  /// A host-side document that counts writes, as a FileDocument host would
  /// count undo registrations.
  @MainActor
  final class Host {
    var document: ImageEditorDocument
    private(set) var writes = 0
    /// The document as the editor's `.onChange(of:)` last saw it.
    private var reported: ImageEditorDocument

    init(_ document: ImageEditorDocument) {
      self.document = document
      self.reported = document
    }

    var binding: Binding<ImageEditorDocument> {
      Binding(get: { self.document }, set: { self.document = $0; self.writes += 1 })
    }

    /// Reports the document's change since the last report, as the editor's
    /// `.onChange(of:)` does on its next update.
    func update(_ model: ImageEditorModel) {
      guard document != reported else {
        return
      }
      model.documentDidChange(from: reported, to: document)
      reported = document
    }
  }

  /// An analysis that records each request and holds it until the test
  /// answers it.
  @MainActor
  final class Analyzer {
    private(set) var requests: [OutputAnalysis.Request] = []
    private var waiting: [CheckedContinuation<OutputAnalysis?, Never>] = []

    /// The analyses started and not answered yet.
    var inFlight: Int {
      waiting.count
    }

    func analyze(_ request: OutputAnalysis.Request) async -> OutputAnalysis? {
      requests.append(request)
      return await withCheckedContinuation { waiting.append($0) }
    }

    /// Answers the oldest analysis in flight.
    func answer(_ analysis: OutputAnalysis?) {
      waiting.removeFirst().resume(returning: analysis)
    }
  }

  /// A gray-point solve that records each request and holds it until the
  /// test answers it.
  @MainActor
  final class GrayPointSolver {
    private(set) var requests: [GrayPoint.Request] = []
    private var waiting: [CheckedContinuation<Result<WhiteBalanceFeature?, GrayPoint.Rejection>, Never>] = []

    func solve(_ request: GrayPoint.Request) async -> Result<WhiteBalanceFeature?, GrayPoint.Rejection> {
      requests.append(request)
      return await withCheckedContinuation { waiting.append($0) }
    }

    /// Answers the oldest solve in flight.
    func answer(_ result: Result<WhiteBalanceFeature?, GrayPoint.Rejection>) {
      waiting.removeFirst().resume(returning: result)
    }
  }

  /// Actions that first write the live value of another control.
  enum Action: CaseIterable, Sendable {
    case otherControl
    case sectionSwitch
    case reset
    case revert
    case preset
    case grayPoint
    case done
  }

  /// Events that drop the live value without writing it.
  enum Drop: CaseIterable, Sendable {
    case cancel
    case outsideChange
    case disappearance
  }

  /// Events that end a control's operation before the control ends it, such
  /// as while its arrow key is still held.
  enum Interruption: CaseIterable, Sendable {
    case otherControl
    case sectionSwitch
    case revert
    case preset
    case done
    case cancel
    case hostUndo
  }

  /// Events during a gray point's solve that make its result stale.
  enum GrayPointInterruption: CaseIterable, Sendable {
    case preview
    case commit
    case outsideChange
    /// An outside change the editor's `.onChange(of:)` has not reported yet.
    case unreportedOutsideChange
    case anotherImage
    case cancel
    case disappearance
  }

  private static let imageSize = Fixtures.rotatedJPEGSize

  /// A feature without values, over the whole image.
  private static var plain: ImageEditorFeature {
    ImageEditorFeature(imageSize: imageSize)
  }

  /// `plain` with `changes` applied in order.
  private static func feature(_ changes: Change...) -> ImageEditorFeature {
    var feature = plain
    for change in changes {
      change.apply(to: &feature)
    }
    return feature
  }

  private static let preset = FilterFeature(
    name: "Warm",
    id: "warm",
    effects: [AnyImageEffect(BrightnessFeature(value: 0.1))]
  )

  private static var localBlur: LocalAdjustmentFeature<GaussianBlurFeature> {
    let stroke = BrushMask.Stroke(
      stampCenters: [CGPoint(x: 10, y: 20)],
      brush: .init(diameter: 8, hardness: 1, opacity: 1)
    )
    return LocalAdjustmentFeature(mask: .brush(BrushMask(strokes: [stroke]))) {
      GaussianBlurFeature(radius: .absolute(4))
    }
  }

  /// A feature that sets every member, over part of the image.
  private static var full: ImageEditorFeature {
    ImageEditorFeature(
      effects: .init(
        preset: preset,
        exposure: ExposureFeature(ev: 0.5),
        brightness: BrightnessFeature(value: 0.1),
        whiteBalance: WhiteBalanceFeature(temperature: 600, tint: -20),
        highlights: HighlightsFeature(value: 0.3),
        shadows: ShadowsFeature(value: -0.2),
        saturation: SaturationFeature(value: 0.5),
        contrast: ContrastFeature(value: 0.1),
        blacks: BlacksFeature(amount: -30),
        colorGrading: ColorGradingFeature(midtones: .init(hue: 200, saturation: 40)),
        clarity: ClarityFeature(amount: 25),
        texture: TextureFeature(amount: -15),
        sharpen: SharpenFeature(intensity: 0.4, radius: .absolute(2)),
        unsharpMask: UnsharpMaskFeature(intensity: 0.5, radius: .absolute(3)),
        gaussianBlur: GaussianBlurFeature(radius: .proportional(10)),
        fade: FadeFeature(intensity: 0.2),
        grain: GrainFeature.CameraRaw(amount: 20, size: 40, roughness: 60, seed: 7),
        custom: [AnyImageEffect(ExposureFeature(ev: 1))]
      ),
      localBlur: localBlur,
      crop: CropFeature(rect: CGRect(x: 2, y: 4, width: 16, height: 30)),
      vignette: VignetteFeature(value: 0.5)
    )
  }

  /// A host of a document of `feature`, and the model of an editor that opens
  /// it, writing a step per operation as the macOS editor does.
  private func makeEditor(
    _ feature: ImageEditorFeature = Self.plain,
    analyze: @escaping @Sendable (OutputAnalysis.Request) async -> OutputAnalysis? = { _ in nil },
    solveGrayPoint: @escaping @Sendable (GrayPoint.Request) async -> Result<WhiteBalanceFeature?, GrayPoint.Rejection> = {
      _ in .success(nil)
    }
  ) throws -> (host: Host, model: ImageEditorModel) {
    let host = Host(try Fixtures.makeDocument(feature: feature))
    let model = ImageEditorModel(
      documentAtStart: host.document,
      historyStep: .operation,
      analyze: analyze,
      solveGrayPoint: solveGrayPoint
    )
    return (host, model)
  }

  /// Waits until `condition` holds, for at most five seconds.
  private func wait(
    until condition: () -> Bool,
    _ comment: Comment,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while condition() == false {
      try #require(ContinuousClock.now < deadline, comment, sourceLocation: sourceLocation)
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  // MARK: - Operations

  @Test func `A drag shows its values live and is written once at its end`() throws {
    let (host, model) = try makeEditor()
    for value in stride(from: 10.0, through: 50, by: 10) {
      model.preview(.slider(.exposure, value), in: host.binding)
    }
    #expect(host.writes == 0)
    #expect(host.document.feature == Self.plain)
    #expect(model.displayedFeature(of: host.document) == Self.feature(.slider(.exposure, 50)))

    model.commit(.slider(.exposure, 60), to: host.binding)
    #expect(host.writes == 1)
    #expect(host.document.feature == Self.feature(.slider(.exposure, 60)))
    #expect(model.displayedFeature(of: host.document) == host.document.feature)
  }

  @Test func `Each completed operation is a step of its own`() throws {
    let (host, model) = try makeEditor()
    model.commit(.slider(.exposure, 40), to: host.binding)
    model.commit(.slider(.contrast, 30), to: host.binding)
    #expect(host.writes == 2)

    var undone = host.document
    undone.undo()
    #expect(undone.feature == Self.feature(.slider(.exposure, 40)))
    undone.undo()
    #expect(undone.feature == Self.plain)
  }

  @Test func `An operation that leaves the feature as it is writes nothing`() throws {
    let (host, model) = try makeEditor(Self.feature(.slider(.saturation, 50)))
    model.commit(.slider(.saturation, 50), to: host.binding)
    // A drag that returns to where it started.
    model.preview(.slider(.saturation, 80), in: host.binding)
    model.commit(.slider(.saturation, 50), to: host.binding)
    #expect(host.writes == 0)
  }

  @Test(arguments: Action.allCases)
  func `A live value is written as its own step before any other action`(_ action: Action) async throws {
    // Saturation gives the switch, Reset and Revert something to remove.
    let opened = Self.feature(.slider(.saturation, 50))
    let (host, model) = try makeEditor(
      opened,
      solveGrayPoint: { _ in .success(WhiteBalanceFeature(temperature: 500)) }
    )
    model.preview(.slider(.exposure, 40), in: host.binding)
    let live = model.displayedFeature(of: host.document)

    switch action {
    case .otherControl:
      model.preview(.slider(.contrast, 30), in: host.binding)
      #expect(host.writes == 1, "The other control's first value writes the live value.")
      model.commit(.slider(.contrast, 30), to: host.binding)
    case .sectionSwitch:
      model.setSection(.color, isOn: false, in: host.binding)
    case .reset:
      model.resetAdjustments(in: host.binding)
    case .revert:
      model.revertToOriginal(in: host.binding, options: .init())
    case .preset:
      model.selectPreset(Self.preset, in: host.binding)
    case .grayPoint:
      model.beginGrayPointSampling()
      model.sampleGrayPoint(
        atOutputPoint: CGPoint(x: 10, y: 20),
        previewSource: Self.previewSource(of: host.document.source),
        rendering: .standard,
        in: host.binding
      )
      #expect(host.writes == 1, "The click writes the live value.")
      await model.grayPointTask?.value
    case .done:
      model.flush(host.binding)
    }

    var undone = host.document
    if action == .done {
      #expect(host.writes == 1)
      #expect(host.document.feature == live)
    } else {
      #expect(host.writes == 2)
      #expect(host.document.feature != live)
      undone.undo()
      #expect(undone.feature == live, "Undo returns to the live value, written as a step of its own.")
    }
    undone.undo()
    #expect(undone.feature == opened)
  }

  @Test func `Ending an operation writes only while that operation is live`() throws {
    let (host, model) = try makeEditor()
    model.preview(.slider(.exposure, 40), in: host.binding)
    model.endOperation(.slider(.contrast), in: host.binding)
    #expect(host.writes == 0, "Another control's end writes nothing.")

    model.endOperation(.slider(.exposure), in: host.binding)
    #expect(host.writes == 1)
    #expect(host.document.feature == Self.feature(.slider(.exposure, 40)))

    model.endOperation(.slider(.exposure), in: host.binding)
    #expect(host.writes == 1, "The operation is over.")
  }

  @Test(arguments: Drop.allCases)
  func `The late end of a dropped operation writes nothing`(_ drop: Drop) throws {
    let (host, model) = try makeEditor()
    model.preview(.slider(.exposure, 40), in: host.binding)

    switch drop {
    case .cancel:
      model.cancel(host.binding)
    case .outsideChange:
      host.document.feature.effects.saturation = SaturationFeature(value: 0.5)
      host.update(model)
    case .disappearance:
      model.editorDidDisappear()
    }
    let document = host.document
    #expect(model.displayedFeature(of: document) == document.feature, "The live value is dropped.")

    model.endOperation(.slider(.exposure), in: host.binding)
    #expect(host.writes == 0)
    #expect(host.document == document)
  }

  @Test(arguments: Interruption.allCases)
  func `A control whose operation another action ended writes nothing more until it ends it`(
    _ interruption: Interruption
  ) throws {
    let (host, model) = try makeEditor()
    model.commit(.slider(.exposure, 20), to: host.binding)
    host.update(model)
    // An arrow key held on Exposure.
    model.preview(.slider(.exposure, 30), in: host.binding)

    switch interruption {
    case .otherControl:
      model.commit(.slider(.contrast, 30), to: host.binding)
    case .sectionSwitch:
      model.setSection(.basic, isOn: false, in: host.binding)
    case .revert:
      model.revertToOriginal(in: host.binding, options: .init())
    case .preset:
      model.selectPreset(Self.preset, in: host.binding)
    case .done:
      model.flush(host.binding)
    case .cancel:
      model.cancel(host.binding)
    case .hostUndo:
      host.document.undo()
    }
    host.update(model)
    let document = host.document
    let writes = host.writes

    // The held key's later repeats, then its key-up.
    model.preview(.slider(.exposure, 31), in: host.binding)
    #expect(model.displayedFeature(of: host.document) == document.feature, "A later value shows nothing.")
    model.commit(.slider(.exposure, 32), to: host.binding)
    #expect(host.writes == writes)
    #expect(host.document == document)

    // The next press is an operation of its own.
    model.preview(.slider(.exposure, 10), in: host.binding)
    model.commit(.slider(.exposure, 10), to: host.binding)
    #expect(host.writes == writes + 1)
    #expect(host.document.feature.effects.exposure == Self.feature(.slider(.exposure, 10)).effects.exposure)
  }

  @Test func `The late end of an operation the model ended clears it for the control's next operation`() throws {
    let (host, model) = try makeEditor()
    model.preview(.slider(.exposure, 40), in: host.binding)
    // Stepped back to the document's value: nothing is live, yet the
    // operation goes on.
    model.preview(.slider(.exposure, 0), in: host.binding)
    model.revertToOriginal(in: host.binding, options: .init())
    model.preview(.slider(.exposure, 10), in: host.binding)
    #expect(model.displayedFeature(of: host.document) == host.document.feature)

    // Focus left during the key step.
    model.endOperation(.slider(.exposure), in: host.binding)
    #expect(host.writes == 0)

    model.commit(.slider(.exposure, 10), to: host.binding)
    #expect(host.writes == 1)
  }

  @Test func `After the editor leaves the screen and comes back, a control's operation writes`() throws {
    let (host, model) = try makeEditor()
    model.preview(.slider(.exposure, 40), in: host.binding)
    model.editorDidDisappear()

    model.preview(.slider(.exposure, 10), in: host.binding)
    #expect(model.displayedFeature(of: host.document) == Self.feature(.slider(.exposure, 10)))
    model.commit(.slider(.exposure, 10), to: host.binding)
    #expect(host.writes == 1)
  }

  @Test func `The write a preview makes first does not drop the live value it then sets`() throws {
    let (host, model) = try makeEditor()
    model.preview(.slider(.exposure, 40), in: host.binding)
    model.preview(.slider(.contrast, 30), in: host.binding)
    #expect(host.writes == 1)

    // The editor's `.onChange(of:)` sees its own write on the next update.
    host.update(model)
    let expected = Self.feature(.slider(.exposure, 40), .slider(.contrast, 30))
    #expect(model.displayedFeature(of: host.document) == expected)

    model.endOperation(.slider(.contrast), in: host.binding)
    #expect(host.writes == 2)
    #expect(host.document.feature == expected)
  }

  @Test func `An outside change of the feature drops the live value`() throws {
    let (host, model) = try makeEditor()
    model.commit(.slider(.exposure, 40), to: host.binding)
    host.update(model)
    model.preview(.slider(.contrast, 30), in: host.binding)

    // The host undoes the exposure.
    host.document.undo()
    host.update(model)
    #expect(host.document.feature == Self.plain)
    #expect(model.displayedFeature(of: host.document) == Self.plain, "The document wins.")

    model.flush(host.binding)
    #expect(host.writes == 1)
  }

  @Test func `A redo by the host back to the editor's last write drops the live value`() throws {
    let (host, model) = try makeEditor()
    model.commit(.slider(.exposure, 40), to: host.binding)
    host.update(model)
    let written = host.document.feature

    // A wheel drag goes on while the host undoes and redoes.
    let grading = Change.colorGrading(ColorGradingFeature(midtones: .init(hue: 200, saturation: 40)))
    model.preview(grading, in: host.binding)
    host.document.undo()
    host.update(model)
    model.preview(grading, in: host.binding)
    host.document.redo()
    host.update(model)
    #expect(host.document.feature == written)
    #expect(model.displayedFeature(of: host.document) == written, "The document wins.")

    model.endOperation(.colorGrading, in: host.binding)
    #expect(host.writes == 1)
  }

  @Test func `A document of another image is never written and never followed`() throws {
    let opened = Self.feature(.slider(.exposure, 40))
    let (host, model) = try makeEditor(opened)
    // The host binds a document of another image, without a new identity.
    let other = Host(try Fixtures.makeDocument(feature: opened))
    #expect(other.document.source != model.source)

    model.preview(.slider(.contrast, 30), in: other.binding)
    #expect(model.displayedFeature(of: host.document) == opened, "Nothing of the other image is shown.")
    model.commit(.slider(.contrast, 30), to: other.binding)
    model.setSection(.basic, isOn: false, in: other.binding)
    model.resetSection(.basic, in: other.binding)
    model.resetAdjustments(in: other.binding)
    model.revertToOriginal(in: other.binding, options: .init())
    model.selectPreset(Self.preset, in: other.binding)
    model.removeLocalBlur(in: other.binding)
    model.cancel(other.binding)
    #expect(other.writes == 0)
    #expect(other.document.feature == opened)

    // A change to such a document follows nothing: the kept values and the
    // live value stay.
    model.setSection(.basic, isOn: false, in: host.binding)
    model.preview(.slider(.saturation, 50), in: host.binding)
    model.documentDidChange(from: host.document, to: other.document)
    #expect(model.switchState(of: .basic, in: host.document) == .off)
    #expect(model.displayedFeature(of: host.document) == Self.feature(.slider(.saturation, 50)))
  }

  // MARK: - Section switches

  @Test func `Switching a section off and on writes once each and restores its values`() throws {
    let opened = Self.feature(.slider(.exposure, 40), .slider(.contrast, 30), .slider(.saturation, 50))
    let (host, model) = try makeEditor(opened)
    #expect(model.switchState(of: .basic, in: host.document) == .on)

    model.setSection(.basic, isOn: false, in: host.binding)
    host.update(model)
    #expect(host.writes == 1)
    #expect(host.document.feature == Self.feature(.slider(.saturation, 50)))
    #expect(model.switchState(of: .basic, in: host.document) == .off)
    #expect(
      Section.basic.members(of: model.shownFeature(for: .basic, in: host.document)) == Section.basic.members(of: opened),
      "The rows show the kept values."
    )

    // Collapsed, so that switching on expands it.
    model.toggleExpansion(of: .basic)
    #expect(model.expandedSections.contains(.basic) == false)
    model.setSection(.basic, isOn: true, in: host.binding)
    host.update(model)
    #expect(host.writes == 2)
    #expect(host.document.feature == opened)
    #expect(model.switchState(of: .basic, in: host.document) == .on)
    #expect(model.switches.isEmpty)
    #expect(model.expandedSections.contains(.basic))

    model.setSection(.basic, isOn: true, in: host.binding)
    #expect(host.writes == 2, "Nothing kept: nothing to write.")
  }

  @Test func `Editing a switched-off section restores it in the same write`() throws {
    let (host, model) = try makeEditor(Self.feature(.slider(.exposure, 40), .slider(.contrast, 30)))
    model.setSection(.basic, isOn: false, in: host.binding)

    model.preview(.slider(.exposure, 60), in: host.binding)
    let expected = Self.feature(.slider(.exposure, 60), .slider(.contrast, 30))
    #expect(model.displayedFeature(of: host.document) == expected)
    #expect(model.switchState(of: .basic, in: host.document) == .on, "The edit switches the card on.")

    model.commit(.slider(.exposure, 60), to: host.binding)
    #expect(host.writes == 2)
    #expect(host.document.feature == expected)
    #expect(model.switches.keptFeature(for: .basic) == nil)
  }

  @Test func `Dragging a switched-off one-member section to neutral forgets its kept values`() throws {
    let (host, model) = try makeEditor(Self.feature(.slider(.saturation, 50)))
    model.setSection(.color, isOn: false, in: host.binding)
    #expect(model.switchState(of: .color, in: host.document) == .off)

    model.commit(.slider(.saturation, 0), to: host.binding)
    #expect(host.writes == 1, "The section stays without values, so nothing is written.")
    #expect(model.switchState(of: .color, in: host.document) == nil, "The switch goes with the kept values.")
  }

  @Test func `An undo of a switch-off by the host forgets the kept values`() throws {
    let opened = Self.feature(.slider(.exposure, 40))
    let (host, model) = try makeEditor(opened)
    model.setSection(.basic, isOn: false, in: host.binding)
    host.update(model)
    #expect(model.switchState(of: .basic, in: host.document) == .off)

    host.document.undo()
    host.update(model)
    #expect(host.document.feature == opened)
    #expect(model.switches.isEmpty)
    #expect(model.switchState(of: .basic, in: host.document) == .on)
  }

  // MARK: - Reset

  @Test func `Reset removes every section's values in one step and keeps what no section owns`() throws {
    let opened = Self.full
    let (host, model) = try makeEditor(opened)
    #expect(model.canResetAdjustments(in: host.document))

    model.resetAdjustments(in: host.binding)
    #expect(host.writes == 1)
    let reset = host.document.feature
    #expect(reset == Section.clearingAll(in: opened))
    #expect(reset.effects.preset == opened.effects.preset)
    #expect(reset.crop == opened.crop)
    #expect(reset.localBlur == opened.localBlur)
    #expect(reset.effects.custom == opened.effects.custom)
    #expect(reset.effects.sharpen == opened.effects.sharpen)
    #expect(reset.effects.unsharpMask == opened.effects.unsharpMask)
    #expect(reset.effects.fade == opened.effects.fade)
    #expect(Section.allCases.allSatisfy { $0.hasValues(in: reset) == false })
    #expect(model.canResetAdjustments(in: host.document) == false)

    var undone = host.document
    undone.undo()
    #expect(undone.feature == opened)
  }

  @Test func `Reset is enabled only with values or kept values`() throws {
    let (plainHost, plainModel) = try makeEditor()
    #expect(plainModel.canResetAdjustments(in: plainHost.document) == false)
    plainModel.preview(.slider(.exposure, 40), in: plainHost.binding)
    #expect(plainModel.canResetAdjustments(in: plainHost.document), "A live value counts.")

    let (host, model) = try makeEditor(Self.feature(.slider(.saturation, 50)))
    model.setSection(.color, isOn: false, in: host.binding)
    #expect(host.document.feature == Self.plain)
    #expect(model.canResetAdjustments(in: host.document), "Kept values count.")

    model.resetAdjustments(in: host.binding)
    #expect(host.writes == 1, "Only kept values: nothing to write.")
    #expect(model.switches.isEmpty)
    #expect(model.canResetAdjustments(in: host.document) == false)
  }

  @Test func `Resetting a section removes its values in one write, or only forgets kept ones`() throws {
    let (host, model) = try makeEditor(Self.feature(.slider(.exposure, 40), .slider(.saturation, 50)))
    #expect(model.canReset(.basic, in: host.document))

    model.resetSection(.basic, in: host.binding)
    #expect(host.writes == 1)
    #expect(host.document.feature == Self.feature(.slider(.saturation, 50)))
    #expect(model.canReset(.basic, in: host.document) == false)

    model.setSection(.color, isOn: false, in: host.binding)
    #expect(host.writes == 2)
    #expect(model.canReset(.color, in: host.document))
    model.resetSection(.color, in: host.binding)
    #expect(host.writes == 2, "Only kept values: nothing to write.")
    #expect(model.switchState(of: .color, in: host.document) == nil)
  }

  // MARK: - Revert

  @Test func `Revert writes the initial feature with the host's custom effects and forgets kept values`() throws {
    let opened = Self.full
    let (host, model) = try makeEditor(opened)
    model.setSection(.color, isOn: false, in: host.binding)
    let switchedOff = host.document.feature
    #expect(model.canRevert(host.document, options: .init(), isLoaded: true))

    model.revertToOriginal(in: host.binding, options: .init())
    #expect(host.writes == 2)
    #expect(host.document.feature == ImageEditorFeature(effects: .init(custom: opened.effects.custom), crop: Self.plain.crop))
    #expect(model.switches.isEmpty)
    #expect(model.canRevert(host.document, options: .init(), isLoaded: true) == false)

    var undone = host.document
    undone.undo()
    #expect(undone.feature == switchedOff, "Revert is a step of its own.")
  }

  @Test func `Under a fixed ratio Revert keeps a crop of the whole image or of the ratio, and returns any other crop to the ratio's`() throws {
    var options = ImageEditor.Options()
    options.aspectRatioPolicy = .fixed(.square)
    let ratioCrop = InitialCrop.crop(fitting: .square, imageSize: Self.imageSize)

    // A fresh document of the whole image has nothing to revert.
    let (fresh, freshModel) = try makeEditor()
    #expect(freshModel.hasCropChanges(fresh.document, options: options) == false)
    #expect(freshModel.canRevert(fresh.document, options: options, isLoaded: true) == false)

    // An effect over the whole image: the whole image stays.
    let (whole, wholeModel) = try makeEditor(Self.feature(.slider(.exposure, 40)))
    #expect(wholeModel.canRevert(whole.document, options: options, isLoaded: true))
    wholeModel.revertToOriginal(in: whole.binding, options: options)
    #expect(whole.document.feature == Self.plain)

    // The ratio's own crop counts as unchanged too.
    var ratioFeature = Self.plain
    ratioFeature.crop = ratioCrop
    let (ratio, ratioModel) = try makeEditor(ratioFeature)
    #expect(ratioModel.canRevert(ratio.document, options: options, isLoaded: true) == false)

    // Any other crop returns to the ratio's.
    var croppedFeature = Self.plain
    croppedFeature.crop = CropFeature(rect: CGRect(x: 0, y: 0, width: 20, height: 30))
    let (cropped, croppedModel) = try makeEditor(croppedFeature)
    #expect(croppedModel.hasCropChanges(cropped.document, options: options))
    #expect(croppedModel.canRevert(cropped.document, options: options, isLoaded: true))
    croppedModel.revertToOriginal(in: cropped.binding, options: options)
    #expect(cropped.writes == 1)
    #expect(cropped.document.feature == ratioFeature)
  }

  @Test func `Revert is enabled once the image has loaded and something differs`() throws {
    let (host, model) = try makeEditor(Self.feature(.slider(.exposure, 40)))
    #expect(model.canRevert(host.document, options: .init(), isLoaded: false) == false)
    #expect(model.canRevert(host.document, options: .init(), isLoaded: true))

    let (plainHost, plainModel) = try makeEditor()
    #expect(plainModel.canRevert(plainHost.document, options: .init(), isLoaded: true) == false)
    plainModel.preview(.slider(.exposure, 40), in: plainHost.binding)
    #expect(plainModel.canRevert(plainHost.document, options: .init(), isLoaded: true), "A live value counts.")
  }

  // MARK: - Show Original

  @Test func `Show Original shows the original in the current crop, writes nothing, and editing ends it`() throws {
    let crop = CropFeature(rect: CGRect(x: 0, y: 10, width: 20, height: 20))
    let custom = [AnyImageEffect(ExposureFeature(ev: 1))]
    var opened = Self.feature(.slider(.exposure, 40))
    opened.crop = crop
    opened.effects.custom = custom
    opened.effects.preset = Self.preset
    opened.localBlur = Self.localBlur
    opened.vignette = VignetteFeature(value: 0.5)
    let (host, model) = try makeEditor(opened)
    #expect(model.canvasFeature(of: host.document) == opened)

    model.setComparing(true)
    #expect(model.showsOriginal)
    #expect(model.canvasFeature(of: host.document) == ImageEditorFeature(effects: .init(custom: custom), crop: crop))
    #expect(model.displayedFeature(of: host.document) == opened, "The controls keep showing the edit.")
    model.setComparing(false)
    model.setHoldingOriginal(true)
    #expect(model.canvasFeature(of: host.document) == ImageEditorFeature(effects: .init(custom: custom), crop: crop))
    model.setHoldingOriginal(false)
    #expect(model.canvasFeature(of: host.document) == opened)
    #expect(host.writes == 0)

    model.setComparing(true)
    model.preview(.slider(.contrast, 30), in: host.binding)
    #expect(model.isComparing == false)
    #expect(model.showsOriginal == false)

    model.setHoldingOriginal(true)
    #expect(model.showsOriginal)
    model.commit(.slider(.contrast, 30), to: host.binding)
    #expect(model.isHoldingOriginal == false)
    #expect(host.writes == 1, "Only the edit writes.")

    model.setComparing(true)
    model.selectPreset(nil, in: host.binding)
    #expect(model.isComparing == false)
  }

  // MARK: - View state

  @Test func `The cards open by default and where the document has values, and the inspector follows its tool`() throws {
    let (_, model) = try makeEditor(Self.feature(.slider(.saturation, 50)))
    #expect(model.expandedSections == [.whiteBalance, .basic, .color])
    model.toggleExpansion(of: .grain)
    #expect(model.expandedSections == [.whiteBalance, .basic, .color, .grain])

    #expect(model.selectedTool == .adjust)
    model.setInspectorPresented(false)
    #expect(model.selectedTool == nil)
    model.setInspectorPresented(true)
    #expect(model.selectedTool == .adjust)
  }

  // MARK: - Done, Cancel, presets and removals

  @Test func `Done writes a live value once`() throws {
    let (host, model) = try makeEditor()
    model.flush(host.binding)
    #expect(host.writes == 0, "Nothing live: nothing to write.")

    model.preview(.slider(.exposure, 40), in: host.binding)
    model.flush(host.binding)
    model.flush(host.binding)
    #expect(host.writes == 1)
    #expect(host.document.feature == Self.feature(.slider(.exposure, 40)))
  }

  @Test func `Cancel restores the opening document, drops the live value and forgets kept values`() throws {
    let opened = Self.feature(.slider(.exposure, 40), .slider(.saturation, 50))
    let (host, model) = try makeEditor(opened)
    let openingDocument = host.document
    model.commit(.slider(.contrast, 30), to: host.binding)
    model.setSection(.color, isOn: false, in: host.binding)
    model.preview(.slider(.exposure, 80), in: host.binding)
    #expect(host.writes == 2)

    model.cancel(host.binding)
    host.update(model)
    #expect(host.writes == 3)
    #expect(host.document == openingDocument, "History included.")
    #expect(model.displayedFeature(of: host.document) == opened)
    #expect(model.switches.isEmpty)

    model.endOperation(.slider(.exposure), in: host.binding)
    #expect(host.writes == 3, "The dropped drag's late end writes nothing.")
  }

  @Test func `Selecting the selected preset writes nothing`() throws {
    let (host, model) = try makeEditor()
    model.selectPreset(Self.preset, in: host.binding)
    model.selectPreset(Self.preset, in: host.binding)
    #expect(host.writes == 1)
    #expect(host.document.feature.effects.preset == Self.preset)
  }

  @Test func `Removing the filter and the painted blur writes once each`() throws {
    var opened = Self.plain
    opened.effects.preset = Self.preset
    opened.localBlur = Self.localBlur
    let (host, model) = try makeEditor(opened)

    model.selectPreset(nil, in: host.binding)
    #expect(host.writes == 1)
    #expect(host.document.feature.effects.preset == nil)
    #expect(host.document.feature.localBlur == opened.localBlur)

    model.removeLocalBlur(in: host.binding)
    #expect(host.writes == 2)
    #expect(host.document.feature.localBlur == nil)

    model.selectPreset(nil, in: host.binding)
    model.removeLocalBlur(in: host.binding)
    #expect(host.writes == 2, "Nothing left to remove.")
  }

  @Test func `Removing the filter and the painted blur is enabled once the image has loaded`() throws {
    var opened = Self.plain
    opened.effects.preset = Self.preset
    opened.localBlur = Self.localBlur
    let (host, model) = try makeEditor(opened)
    #expect(model.canRemoveFilter(host.document, isLoaded: false) == false)
    #expect(model.canRemoveLocalBlur(host.document, isLoaded: false) == false)
    #expect(model.canRemoveFilter(host.document, isLoaded: true))
    #expect(model.canRemoveLocalBlur(host.document, isLoaded: true))

    let (plainHost, plainModel) = try makeEditor()
    #expect(plainModel.canRemoveFilter(plainHost.document, isLoaded: true) == false)
    #expect(plainModel.canRemoveLocalBlur(plainHost.document, isLoaded: true) == false)
  }

  // MARK: - Analysis

  /// A preview of `source` for requests; the tests' analyses never read its
  /// pixels.
  private static func previewSource(of source: SourceImage) -> PreviewSource {
    PreviewSource(source: source, thumbnail: CIImage.empty(), image: CIImage.empty())
  }

  private static func request(
    exposure value: Double,
    over previewSource: PreviewSource
  ) -> OutputAnalysis.Request {
    .init(
      previewSource: previewSource,
      feature: feature(.slider(.exposure, value)),
      adjustmentRendering: .standard
    )
  }

  /// A one-pixel analysis that its red value tells apart.
  private static func analysis(_ marker: UInt8) -> OutputAnalysis {
    OutputAnalysis(
      histogram: .init(red: [], green: [], blue: [], pixelCount: 1, shadowClipping: 0, highlightClipping: 0),
      outputSize: CGSize(width: 1, height: 1),
      pixelWidth: 1,
      pixelHeight: 1,
      pixels: [marker, 0, 0, 255]
    )
  }

  @Test func `The colour under the pointer comes from the latest analysis`() async throws {
    // A 2 × 2 bitmap over a 20 × 40 output: red and green over blue and a
    // transparent pixel.
    let analysis = OutputAnalysis(
      histogram: .init(red: [], green: [], blue: [], pixelCount: 3, shadowClipping: 0, highlightClipping: 0),
      outputSize: CGSize(width: 20, height: 40),
      pixelWidth: 2,
      pixelHeight: 2,
      pixels: [
        255, 0, 0, 255, 0, 255, 0, 255,
        0, 0, 255, 255, 0, 0, 0, 0,
      ]
    )
    let (host, model) = try makeEditor(analyze: { _ in analysis })
    model.canvasDidReportPointer(CGPoint(x: 2, y: 3))
    #expect(model.pointerColor == nil, "No analysis yet.")

    model.requestAnalysis(Self.request(exposure: 0, over: Self.previewSource(of: host.document.source)))
    try await wait(until: { model.analysis != nil }, "The analysis never arrived.")
    #expect(model.pointerColor == .init(red: 255, green: 0, blue: 0))
    model.canvasDidReportPointer(CGPoint(x: 15, y: 3))
    #expect(model.pointerColor == .init(red: 0, green: 255, blue: 0))
    model.canvasDidReportPointer(CGPoint(x: 2, y: 30))
    #expect(model.pointerColor == .init(red: 0, green: 0, blue: 255))
    model.canvasDidReportPointer(CGPoint(x: 15, y: 30))
    #expect(model.pointerColor == nil, "Transparent.")
    model.canvasDidReportPointer(nil)
    #expect(model.pointerColor == nil)
  }

  @Test func `One analysis runs at a time, and the latest request waiting runs next`() async throws {
    let analyzer = Analyzer()
    let (host, model) = try makeEditor(analyze: { await analyzer.analyze($0) })
    let previewSource = Self.previewSource(of: host.document.source)
    let first = Self.request(exposure: 10, over: previewSource)
    let replaced = Self.request(exposure: 20, over: previewSource)
    let latest = Self.request(exposure: 30, over: previewSource)

    model.requestAnalysis(first)
    try await wait(until: { analyzer.requests == [first] }, "The first request never ran.")
    let loop = try #require(model.analysisTask)
    model.requestAnalysis(replaced)
    model.requestAnalysis(latest)
    #expect(model.analysisTask == loop, "No second loop starts.")
    #expect(analyzer.inFlight == 1)

    analyzer.answer(Self.analysis(1))
    try await wait(until: { model.analysis?.pixels.first == 1 }, "The first result never appeared.")
    try await wait(until: { analyzer.requests.count == 2 }, "The latest request never ran.")
    #expect(analyzer.requests == [first, latest], "The request the latest replaced never runs.")

    analyzer.answer(Self.analysis(3))
    try await wait(until: { model.analysis?.pixels.first == 3 }, "The latest result never appeared.")
    await loop.value
    #expect(analyzer.requests.count == 2)

    // The shown result answers its own request.
    model.requestAnalysis(latest)
    #expect(model.analysisTask == nil)
    #expect(analyzer.requests.count == 2)
  }

  @Test func `A request for the shown result while another runs runs after it`() async throws {
    let analyzer = Analyzer()
    let (host, model) = try makeEditor(analyze: { await analyzer.analyze($0) })
    let previewSource = Self.previewSource(of: host.document.source)
    let shown = Self.request(exposure: 10, over: previewSource)
    let other = Self.request(exposure: 20, over: previewSource)

    model.requestAnalysis(shown)
    try await wait(until: { analyzer.inFlight == 1 }, "The request never ran.")
    analyzer.answer(Self.analysis(1))
    await model.analysisTask?.value
    #expect(model.analysis?.pixels.first == 1)

    // A drag away and back while the analysis of the value away runs.
    model.requestAnalysis(other)
    try await wait(until: { analyzer.inFlight == 1 }, "The second request never ran.")
    model.requestAnalysis(shown)
    analyzer.answer(Self.analysis(2))
    try await wait(until: { analyzer.requests.count == 3 }, "The request the shown result does not answer never ran.")
    #expect(analyzer.requests == [shown, other, shown])
    analyzer.answer(Self.analysis(1))
    try await wait(until: { model.analysis?.pixels.first == 1 }, "The result of the latest request never appeared.")
  }

  @Test func `Nothing is analysed while the histogram is hidden`() async throws {
    let analyzer = Analyzer()
    let (host, model) = try makeEditor(analyze: { await analyzer.analyze($0) })
    let request = Self.request(exposure: 10, over: Self.previewSource(of: host.document.source))

    model.requestAnalysis(nil)
    #expect(model.analysisTask == nil)

    // Hiding the histogram stops a running analysis, whose result is dropped.
    model.requestAnalysis(request)
    try await wait(until: { analyzer.inFlight == 1 }, "The request never ran.")
    let loop = try #require(model.analysisTask)
    model.requestAnalysis(nil)
    #expect(model.analysisTask == nil)
    analyzer.answer(Self.analysis(1))
    await loop.value
    #expect(model.analysis == nil)
    #expect(analyzer.requests == [request])
  }

  @Test func `A request stopped while it runs runs again when the editor reappears`() async throws {
    let analyzer = Analyzer()
    let (host, model) = try makeEditor(analyze: { await analyzer.analyze($0) })
    let request = Self.request(exposure: 10, over: Self.previewSource(of: host.document.source))

    model.requestAnalysis(request)
    try await wait(until: { analyzer.inFlight == 1 }, "The request never ran.")
    let loop = try #require(model.analysisTask)
    model.editorDidDisappear()
    analyzer.answer(Self.analysis(1))
    await loop.value
    #expect(model.analysis == nil, "The stopped result is dropped.")

    // The canvas area requests the analysis again when it appears.
    model.requestAnalysis(request)
    try await wait(until: { analyzer.requests.count == 2 }, "The request did not run again.")
    analyzer.answer(Self.analysis(1))
    try await wait(until: { model.analysis?.pixels.first == 1 }, "The result never appeared.")
  }

  // MARK: - Gray point

  private static let balance = WhiteBalanceFeature(temperature: -800, tint: 12)

  /// Turns the gray point on, if it is off, and clicks the image. Returns the
  /// solve's task once `solver` holds the solve.
  private func clickGrayPoint(
    in host: Host,
    of model: ImageEditorModel,
    solvedBy solver: GrayPointSolver
  ) async throws -> Task<Void, Never> {
    let solved = solver.requests.count
    model.beginGrayPointSampling()
    model.sampleGrayPoint(
      atOutputPoint: CGPoint(x: 10, y: 20),
      previewSource: Self.previewSource(of: host.document.source),
      rendering: .standard,
      in: host.binding
    )
    let task = try #require(model.grayPointTask)
    try await wait(until: { solver.requests.count == solved + 1 }, "The solve never started.")
    return task
  }

  @Test func `A gray point is written in one step and ends sampling`() async throws {
    let solver = GrayPointSolver()
    let (host, model) = try makeEditor(solveGrayPoint: { await solver.solve($0) })
    #expect(model.grayPointSampling == .off)
    model.beginGrayPointSampling()
    #expect(model.grayPointSampling == .waiting)

    let task = try await clickGrayPoint(in: host, of: model, solvedBy: solver)
    #expect(model.grayPointSampling == .solving)
    let request = try #require(solver.requests.first)
    #expect(request.outputPoint == CGPoint(x: 10, y: 20))
    #expect(request.feature == host.document.feature)

    solver.answer(.success(Self.balance))
    await task.value
    #expect(host.writes == 1)
    #expect(host.document.feature.effects.whiteBalance == Self.balance)
    #expect(model.grayPointSampling == .off)

    var undone = host.document
    undone.undo()
    #expect(undone.feature == Self.plain)
  }

  @Test(arguments: GrayPointInterruption.allCases)
  func `A gray point solved while anything happens is dropped`(_ interruption: GrayPointInterruption) async throws {
    let solver = GrayPointSolver()
    let (host, model) = try makeEditor(solveGrayPoint: { await solver.solve($0) })
    let task = try await clickGrayPoint(in: host, of: model, solvedBy: solver)

    switch interruption {
    case .preview:
      model.preview(.slider(.exposure, 40), in: host.binding)
    case .commit:
      model.commit(.slider(.exposure, 40), to: host.binding)
    case .outsideChange:
      host.document.feature.effects.saturation = SaturationFeature(value: 0.5)
      host.update(model)
    case .unreportedOutsideChange:
      host.document.feature.effects.saturation = SaturationFeature(value: 0.5)
    case .anotherImage:
      // The host binds a document of another image, without a new identity.
      host.document = try Fixtures.makeDocument(feature: Self.plain)
    case .cancel:
      model.cancel(host.binding)
    case .disappearance:
      model.editorDidDisappear()
    }
    let document = host.document
    let writes = host.writes

    solver.answer(.success(Self.balance))
    await task.value
    #expect(host.writes == writes)
    #expect(host.document == document)
    switch interruption {
    case .cancel, .disappearance:
      #expect(model.grayPointSampling == .off, "Cancel and leaving the screen end the gray point.")
    case .preview, .commit, .outsideChange, .unreportedOutsideChange, .anotherImage:
      #expect(model.grayPointSampling == .waiting, "Sampling waits for another click.")
    }
  }

  @Test func `A rejected gray point shows, and a click while it shows solves again`() async throws {
    let solver = GrayPointSolver()
    let (host, model) = try makeEditor(solveGrayPoint: { await solver.solve($0) })
    let rejected = try await clickGrayPoint(in: host, of: model, solvedBy: solver)
    solver.answer(.failure(.tooDark))
    await rejected.value
    #expect(model.grayPointSampling == .rejected(.tooDark))
    #expect(host.writes == 0)

    let solved = try await clickGrayPoint(in: host, of: model, solvedBy: solver)
    #expect(model.grayPointSampling == .solving)
    solver.answer(.success(Self.balance))
    await solved.value
    #expect(host.writes == 1)
    #expect(model.grayPointSampling == .off)
  }

  @Test func `A rejection shows for a moment, then sampling waits for another click`() async throws {
    let solver = GrayPointSolver()
    let (host, model) = try makeEditor(solveGrayPoint: { await solver.solve($0) })
    let task = try await clickGrayPoint(in: host, of: model, solvedBy: solver)
    solver.answer(.failure(.tooBright))
    await task.value
    #expect(model.grayPointSampling == .rejected(.tooBright))

    try await wait(until: { model.grayPointSampling == .waiting }, "The rejection never ended.")
    #expect(host.writes == 0)
  }

  @Test func `Starting the gray point ends Show Original, and Revert ends the gray point`() throws {
    let (host, model) = try makeEditor(Self.feature(.slider(.exposure, 40)))
    model.setComparing(true)
    model.beginGrayPointSampling()
    #expect(model.isComparing == false)
    #expect(model.grayPointSampling == .waiting)

    model.cancelGrayPointSampling()
    #expect(model.grayPointSampling == .off)

    model.beginGrayPointSampling()
    model.revertToOriginal(in: host.binding, options: .init())
    #expect(model.grayPointSampling == .off)
    #expect(host.writes == 1)
  }
}
