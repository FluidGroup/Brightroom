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


import StateGraph
import SwiftUI

import BrightroomEngine
import BrightroomParametric

/// The state and actions of one ImageEditor, kept apart from its views so both
/// platforms' editors can share them and tests can drive them without a window.
///
/// Actions take the binding and act on its latest document, writing it at most
/// once per completed operation. One operation is live at a time: any other
/// action first writes it as its own step, and Cancel, an outside change or the
/// editor disappearing drops it. Either ends the operation for its control
/// too: a control still in it, such as a slider whose arrow key is held,
/// previews and writes nothing more until it ends the operation itself. The
/// model never keeps a binding (only the gray point's solve holds one, until
/// its result is applied or dropped), never writes a document of another
/// image, and never registers anything with an `UndoManager`.
@MainActor
final class ImageEditorModel {

  /// The toolbar's tools; the inspector shows the selected tool's controls.
  enum Tool: CaseIterable, Identifiable, Sendable {
    case adjust

    var id: Self { self }
  }

  /// Where White Balance's gray point is. Every state but `off` samples: a
  /// click on the image solves the white balance there.
  enum GrayPointSampling: Equatable {
    case off
    /// Waiting for a click on the image.
    case waiting
    /// Solving the latest click.
    case solving
    /// Showing why the latest click gave no white balance, for
    /// `grayPointRejectionDuration`.
    case rejected(GrayPoint.Rejection)
  }

  /// The shortest time from the start of one output analysis to the start of
  /// the next.
  static let analysisInterval: Duration = .milliseconds(100)

  /// How long a rejected gray point shows before sampling waits for the next
  /// click again.
  static let grayPointRejectionDuration: Duration = .seconds(2)

  /// The image this model edits. ImageEditor gives each image a model of its
  /// own (`.id(document.source)`).
  let source: SourceImage

  // Observable state. A node notifies on every set, so only changed values
  // are assigned.

  /// Decides what is written and when, and holds the live value.
  @GraphStored private(set) var session: ImageEditorSession
  @GraphStored private(set) var switches: ImageEditor.AdjustmentSection.Switches = .init()
  @GraphStored private(set) var expandedSections: Set<ImageEditor.AdjustmentSection>
  /// The tool whose controls the inspector shows; nil while it is hidden.
  @GraphStored private(set) var selectedTool: Tool? = .adjust
  /// Show Original, as the toolbar toggles it.
  @GraphStored private(set) var isComparing: Bool = false
  /// Show Original while M is held.
  @GraphStored private(set) var isHoldingOriginal: Bool = false
  @GraphStored private(set) var isHistogramVisible: Bool = true
  @GraphStored private(set) var isFilterStripVisible: Bool = true
  /// White Balance's gray point, which the eyedropper starts and a solved
  /// white balance ends.
  @GraphStored private(set) var grayPointSampling: GrayPointSampling = .off
  /// The canvas's zoom as it last reported it; nil until it has.
  @GraphStored private(set) var zoom: ImageEditorCanvas.Zoom?
  /// The crop-output pixel under the pointer as the canvas last reported it;
  /// nil off the image.
  @GraphStored private(set) var pointerOutputPoint: CGPoint?
  /// The latest analysis of what the canvas shows; nil until one arrives.
  @GraphStored private(set) var analysis: OutputAnalysis?

  /// The canvas the editor shows registers here, through the environment, so
  /// commands reach it.
  let canvasRegistry = ImageEditorCanvasRegistry()

  /// The control whose operation has previewed and not ended; nil while none
  /// has. Its value is live unless it leaves the document's feature as it is,
  /// such as a held arrow key stepped back to the document's value.
  private var openOperation: ImageEditor.AdjustmentChange.Key?

  /// The control whose operation the model ended before the control did:
  /// another action wrote it as its own step, or Cancel or an outside change
  /// dropped it. Until the control ends it (`commit(_:to:)` or
  /// `endOperation(_:in:)`), its previews show nothing and its end writes
  /// nothing, so a key held across that action brings nothing back from
  /// before it.
  private var endedOperation: ImageEditor.AdjustmentChange.Key?

  /// The feature of the editor's latest write, kept until the next reported
  /// change of the feature (`documentDidChange(from:to:)`), which it tells
  /// apart from outside changes.
  private var lastWrittenFeature: ImageEditorFeature?

  /// Counts what makes a gray point solved meanwhile stale: every preview,
  /// every write, and every drop of the live value (Cancel, an outside change,
  /// the editor disappearing).
  private var generation = 0

  private let analyze: @Sendable (OutputAnalysis.Request) async -> OutputAnalysis?

  private let solveGrayPoint: @Sendable (GrayPoint.Request) async -> Result<WhiteBalanceFeature?, GrayPoint.Rejection>

  /// The solve of the latest gray-point click. It holds the binding until its
  /// result is applied or dropped. Internal so tests can await it.
  private(set) var grayPointTask: Task<Void, Never>?

  /// Ends the rejection a gray point shows.
  private var grayPointRejectionTask: Task<Void, Never>?

  /// The request whose result `analysis` holds.
  private var analyzedRequest: OutputAnalysis.Request?

  /// The request the running analysis loop takes next.
  private var pendingAnalysisRequest: OutputAnalysis.Request?

  /// The loop that runs analysis requests; nil while none runs. Internal so
  /// tests can await it.
  private(set) var analysisTask: Task<Void, Never>?

  /// Creates the model of an editor that opens `documentAtStart`. It only
  /// stores state, because a view's `State(initialValue:)` evaluates it on
  /// every initialization.
  ///
  /// - Parameters:
  ///   - analyze: Analyses a request off the main actor; tests pass their
  ///     own.
  ///   - solveGrayPoint: Solves a gray-point click off the main actor; tests
  ///     pass their own.
  init(
    documentAtStart: ImageEditorDocument,
    historyStep: ImageEditorSession.HistoryStep,
    analyze: @escaping @Sendable (OutputAnalysis.Request) async -> OutputAnalysis? = {
      await OutputAnalysis.make($0)
    },
    solveGrayPoint: @escaping @Sendable (GrayPoint.Request) async -> Result<WhiteBalanceFeature?, GrayPoint.Rejection> = {
      await GrayPoint.solve($0)
    }
  ) {
    self.source = documentAtStart.source
    self.session = ImageEditorSession(documentAtStart: documentAtStart, historyStep: historyStep)
    // The cards open by default, and those the opening document has values in.
    self.expandedSections = Set(
      ImageEditor.AdjustmentSection.allCases.filter {
        $0.isExpandedByDefault || $0.hasValues(in: documentAtStart.feature)
      }
    )
    self.analyze = analyze
    self.solveGrayPoint = solveGrayPoint
  }

  isolated deinit {
    analysisTask?.cancel()
    grayPointTask?.cancel()
    grayPointRejectionTask?.cancel()
  }

  // MARK: - Reading

  /// The feature the controls show: the document's, with the live value.
  func displayedFeature(of document: ImageEditorDocument) -> ImageEditorFeature {
    session.displayedFeature(of: document)
  }

  /// Whether the canvas shows the original, from the toggle or a held M.
  var showsOriginal: Bool {
    isComparing || isHoldingOriginal
  }

  /// What Show Original shows: no preset, adjustments, painted blur or
  /// vignette, the host's custom effects kept, in the document's crop.
  func originalFeature(of document: ImageEditorDocument) -> ImageEditorFeature {
    ImageEditorFeature(
      effects: .init(custom: document.feature.effects.custom),
      crop: document.feature.crop
    )
  }

  /// What the canvas shows: the original while it is shown, otherwise the
  /// displayed feature.
  func canvasFeature(of document: ImageEditorDocument) -> ImageEditorFeature {
    if showsOriginal {
      return originalFeature(of: document)
    }
    return displayedFeature(of: document)
  }

  /// What `section`'s rows show: the displayed feature, with the kept values
  /// while the section is switched off.
  func shownFeature(
    for section: ImageEditor.AdjustmentSection,
    in document: ImageEditorDocument
  ) -> ImageEditorFeature {
    switches.shownFeature(for: section, in: displayedFeature(of: document))
  }

  func switchState(
    of section: ImageEditor.AdjustmentSection,
    in document: ImageEditorDocument
  ) -> ImageEditor.AdjustmentSection.SwitchState? {
    switches.state(of: section, in: displayedFeature(of: document))
  }

  /// Whether `section` has values or kept values to reset.
  func canReset(
    _ section: ImageEditor.AdjustmentSection,
    in document: ImageEditorDocument
  ) -> Bool {
    switchState(of: section, in: document) != nil
  }

  /// Whether any section has values or kept values to reset.
  func canResetAdjustments(in document: ImageEditorDocument) -> Bool {
    let feature = displayedFeature(of: document)
    return switches.isEmpty == false
      || ImageEditor.AdjustmentSection.allCases.contains { $0.hasValues(in: feature) }
  }

  /// Whether the document's crop is one Revert to Original changes: it differs
  /// from the whole image and from the crop the aspect-ratio policy starts
  /// with. A crop that is either counts as unchanged and is kept, so a fresh
  /// document under a fixed ratio has nothing to revert, and reverting a
  /// document of the whole image never crops it.
  func hasCropChanges(_ document: ImageEditorDocument, options: ImageEditor.Options) -> Bool {
    let initialCrop = initialFeature(of: document, options: options).crop
    return document.hasCropChanges(initialCrop: initialCrop) && document.hasCropChanges()
  }

  /// What Revert to Original writes: the feature the aspect-ratio policy starts
  /// with, the host's custom effects kept, and the document's crop kept unless
  /// `hasCropChanges(_:options:)`.
  func revertFeature(
    of document: ImageEditorDocument,
    options: ImageEditor.Options
  ) -> ImageEditorFeature {
    var feature = initialFeature(of: document, options: options)
    if hasCropChanges(document, options: options) == false {
      feature.crop = document.feature.crop
    }
    return feature
  }

  /// Whether Revert to Original is enabled: the image has loaded, and an effect
  /// is shown or the crop has changed.
  func canRevert(
    _ document: ImageEditorDocument,
    options: ImageEditor.Options,
    isLoaded: Bool
  ) -> Bool {
    isLoaded
      && (displayedFeature(of: document).hasAnyEffect || hasCropChanges(document, options: options))
  }

  /// Whether Remove Filter is enabled: the image has loaded and a preset is
  /// selected.
  func canRemoveFilter(_ document: ImageEditorDocument, isLoaded: Bool) -> Bool {
    isLoaded && document.feature.effects.preset != nil
  }

  /// Whether Remove Painted Blur is enabled: the image has loaded and the
  /// document has a painted blur.
  func canRemoveLocalBlur(_ document: ImageEditorDocument, isLoaded: Bool) -> Bool {
    isLoaded && document.feature.localBlur != nil
  }

  /// The colour under the pointer in the latest analysis; nil off the image or
  /// without an analysis.
  var pointerColor: OutputAnalysis.Color? {
    guard let pointerOutputPoint else {
      return nil
    }
    return analysis?.color(atOutputPoint: pointerOutputPoint)
  }

  /// The binding the canvas writes through. A canvas change goes through the
  /// session like the controls' writes, and leaves the live value to its
  /// control. The macOS canvas writes nothing.
  func canvasBinding(for document: Binding<ImageEditorDocument>) -> Binding<ImageEditorDocument> {
    Binding {
      document.wrappedValue
    } set: { changed in
      self.writeCanvasChange(changed, to: document)
    }
  }

  // MARK: - Operations

  /// Shows `change` without writing it, as the live value of its control.
  ///
  /// The operation of another control is first written as its own step,
  /// which ends it. In a switched-off section the kept values are applied
  /// before the change, so editing the section switches it back on. An
  /// operation the model has ended shows nothing.
  func preview(_ change: ImageEditor.AdjustmentChange, in document: Binding<ImageEditorDocument>) {
    guard
      document.wrappedValue.source == source,
      change.key != endedOperation
    else {
      return
    }
    if let openOperation, openOperation != change.key {
      flush(document)
    }

    let switches = self.switches
    var session = self.session
    session.previewFeature(over: document.wrappedValue) { feature in
      feature = switches.shownFeature(for: change.section, in: feature)
      change.apply(to: &feature)
    }
    if session.liveFeature != self.session.liveFeature {
      self.session = session
    }
    openOperation = change.key
    generation += 1
    endComparing()
  }

  /// Writes `change` as one step, which ends its control's operation.
  ///
  /// Any edit of a section forgets the section's kept values, even one that
  /// leaves the section without values. The end of an operation the model
  /// ended first writes nothing: a key held across Revert, Cancel or the
  /// host's undo leaves what they wrote alone.
  func commit(_ change: ImageEditor.AdjustmentChange, to document: Binding<ImageEditorDocument>) {
    guard document.wrappedValue.source == source else {
      return
    }
    guard change.key != endedOperation else {
      endedOperation = nil
      return
    }
    preview(change, in: document)
    write(document)
    updateSwitches { $0.forget(change.section) }
  }

  /// Writes the live value only while the operation of `key` is in progress.
  /// A deferred end passes its operation's key, never a value, so it writes
  /// nothing once the operation has been written, dropped or replaced.
  func endOperation(
    _ key: ImageEditor.AdjustmentChange.Key,
    in document: Binding<ImageEditorDocument>
  ) {
    guard key != endedOperation else {
      endedOperation = nil
      return
    }
    guard openOperation == key else {
      return
    }
    write(document)
  }

  /// Writes the live value, if any, as its own step, as Done does before the
  /// editor closes. This ends the operation in progress: its control's later
  /// previews and its end write nothing.
  func flush(_ document: Binding<ImageEditorDocument>) {
    guard openOperation != nil else {
      return
    }
    endOpenOperation()
    write(document)
  }

  // MARK: - Actions

  /// Switches `section` off, keeping its values, or on, writing the kept values
  /// back and expanding its card: one write either way. Switching on with
  /// nothing kept writes nothing.
  func setSection(
    _ section: ImageEditor.AdjustmentSection,
    isOn: Bool,
    in document: Binding<ImageEditorDocument>
  ) {
    guard beginAction(on: document) else {
      return
    }
    if isOn {
      guard let kept = switches.keptFeature(for: section) else {
        return
      }
      updateSwitches { $0.forget(section) }
      write(document) { section.copyMembers(from: kept, to: &$0.feature) }
      if expandedSections.contains(section) == false {
        expandedSections.insert(section)
      }
    } else {
      let feature = document.wrappedValue.feature
      updateSwitches { $0.keep(section, from: feature) }
      write(document) { section.clear(in: &$0.feature) }
    }
  }

  /// Removes `section`'s values in one write and forgets its kept values. With
  /// only kept values, nothing is written and its switch goes.
  func resetSection(
    _ section: ImageEditor.AdjustmentSection,
    in document: Binding<ImageEditorDocument>
  ) {
    guard beginAction(on: document) else {
      return
    }
    updateSwitches { $0.forget(section) }
    write(document) { section.clear(in: &$0.feature) }
  }

  /// Removes every section's values in one write, a step of its own. The
  /// preset, the crop, the painted blur, `sharpen`, `unsharpMask`, `fade` and
  /// the host's custom effects stay.
  func resetAdjustments(in document: Binding<ImageEditorDocument>) {
    guard beginAction(on: document) else {
      return
    }
    updateSwitches { $0.forgetAll() }
    let cleared = ImageEditor.AdjustmentSection.clearingAll(in: document.wrappedValue.feature)
    reset(document, to: cleared)
  }

  /// Writes `revertFeature(of:options:)` as a step of its own, and ends the
  /// gray point.
  func revertToOriginal(in document: Binding<ImageEditorDocument>, options: ImageEditor.Options) {
    guard beginAction(on: document) else {
      return
    }
    updateSwitches { $0.forgetAll() }
    cancelGrayPointSampling()
    reset(document, to: revertFeature(of: document.wrappedValue, options: options))
  }

  /// Selects `preset`, or removes the filter with nil. Selecting the selected
  /// preset writes nothing.
  func selectPreset(_ preset: FilterFeature?, in document: Binding<ImageEditorDocument>) {
    guard beginAction(on: document) else {
      return
    }
    write(document) { $0.selectFilterPreset(preset) }
  }

  func removeLocalBlur(in document: Binding<ImageEditorDocument>) {
    guard beginAction(on: document) else {
      return
    }
    write(document) { $0.clearLocalBlur() }
  }

  /// Drops the live value, the gray point and the kept values, and writes back
  /// the document the editor opened with, history included. If the host keeps
  /// the editor on screen, it keeps working, and no gray point solved before
  /// the Cancel lands after it.
  func cancel(_ document: Binding<ImageEditorDocument>) {
    dropLiveValue()
    cancelGrayPointSampling()
    updateSwitches { $0.forgetAll() }
    let current = document.wrappedValue
    guard
      current.source == source,
      let restored = session.documentForCancel(replacing: current)
    else {
      return
    }
    lastWrittenFeature = restored.feature
    document.wrappedValue = restored
  }

  /// Follows a change of the binding's document, as `.onChange(of:)` reports
  /// it.
  ///
  /// A document of another image is ignored. A feature other than the one the
  /// editor last wrote is an outside change, such as the host's undo: the
  /// document wins, and the live value is dropped. A write is reported once,
  /// so a later change back to its feature, such as the host's redo, is an
  /// outside change too. Kept values of sections the document has values in
  /// again are forgotten.
  func documentDidChange(from old: ImageEditorDocument, to new: ImageEditorDocument) {
    guard new.source == source else {
      return
    }
    if new.feature != old.feature {
      if new.feature != lastWrittenFeature {
        dropLiveValue()
      }
      lastWrittenFeature = nil
    }
    updateSwitches { $0.follow(new.feature) }
  }

  /// Stops the analysis and the gray point, drops the live value and ends a
  /// held M, as the editor leaves the screen. The canvas area requests the
  /// analysis again when it appears.
  func editorDidDisappear() {
    stopAnalysis()
    cancelGrayPointSampling()
    dropLiveValue()
    // The controls leave with the editor, so none is still in an operation
    // when it appears again.
    endedOperation = nil
    setHoldingOriginal(false)
  }

  // MARK: - View state

  func setComparing(_ comparing: Bool) {
    if isComparing != comparing {
      isComparing = comparing
    }
  }

  func setHoldingOriginal(_ holding: Bool) {
    if isHoldingOriginal != holding {
      isHoldingOriginal = holding
    }
  }

  func toggleExpansion(of section: ImageEditor.AdjustmentSection) {
    expandedSections.formSymmetricDifference([section])
  }

  func select(_ tool: Tool?) {
    if selectedTool != tool {
      selectedTool = tool
    }
  }

  /// Follows the inspector's presentation: hiding it deselects the tool, and
  /// showing it selects Adjust unless a tool is selected.
  func setInspectorPresented(_ presented: Bool) {
    if presented {
      select(selectedTool ?? .adjust)
    } else {
      select(nil)
    }
  }

  func setHistogramVisible(_ visible: Bool) {
    if isHistogramVisible != visible {
      isHistogramVisible = visible
    }
  }

  func setFilterStripVisible(_ visible: Bool) {
    if isFilterStripVisible != visible {
      isFilterStripVisible = visible
    }
  }

  // MARK: - Canvas reports

  func canvasDidReportZoom(_ zoom: ImageEditorCanvas.Zoom) {
    if self.zoom != zoom {
      self.zoom = zoom
    }
  }

  func canvasDidReportPointer(_ point: CGPoint?) {
    if pointerOutputPoint != point {
      pointerOutputPoint = point
    }
  }

  // MARK: - Analysis

  /// Analyses what the canvas shows. The canvas area passes nil while the
  /// histogram is hidden or the image has not loaded, which stops the analysis.
  ///
  /// One analysis runs at a time, off the main actor, and one starts at most
  /// every `analysisInterval`. The latest request always runs, and a request
  /// the shown result answers runs nothing.
  func requestAnalysis(_ request: OutputAnalysis.Request?) {
    guard let request else {
      stopAnalysis()
      return
    }
    // A running loop's result replaces the shown one, so a request the shown
    // result answers waits for it too; the loop skips the request if the shown
    // result still answers it when its turn comes.
    if request == analyzedRequest, analysisTask == nil {
      return
    }
    pendingAnalysisRequest = request
    if analysisTask == nil {
      startAnalysis()
    }
  }

  /// Stops analysing. The shown result stays, so a request stopped while it
  /// ran runs again when it is requested again.
  func stopAnalysis() {
    analysisTask?.cancel()
    analysisTask = nil
    pendingAnalysisRequest = nil
  }

  /// Starts the loop that runs the pending requests one at a time, until none
  /// is left.
  private func startAnalysis() {
    let analyze = analyze
    let interval = Self.analysisInterval
    analysisTask = Task { [weak self] in
      while Task.isCancelled == false, let request = self?.takePendingAnalysisRequest() {
        let start = ContinuousClock.now
        let analysis = await analyze(request)
        // A stopped loop leaves the shown result as it is.
        guard Task.isCancelled == false else {
          return
        }
        self?.show(analysis, of: request)
        // Requests that arrive meanwhile wait, and only the latest runs.
        try? await Task.sleep(until: start + interval, clock: .continuous)
      }
    }
  }

  /// Takes the pending request; nil, which ends the loop, when none is pending
  /// or the shown result answers it.
  private func takePendingAnalysisRequest() -> OutputAnalysis.Request? {
    let request = pendingAnalysisRequest
    pendingAnalysisRequest = nil
    guard let request, request != analyzedRequest else {
      analysisTask = nil
      return nil
    }
    return request
  }

  private func show(_ analysis: OutputAnalysis?, of request: OutputAnalysis.Request) {
    self.analysis = analysis
    analyzedRequest = request
  }

  // MARK: - Gray point

  /// Starts White Balance's gray point: a click on the image then sets the
  /// white balance that makes that area neutral. Ends Show Original.
  func beginGrayPointSampling() {
    guard grayPointSampling == .off else {
      return
    }
    endComparing()
    setGrayPointSampling(.waiting)
  }

  /// Ends the gray point and drops a solve in progress.
  func cancelGrayPointSampling() {
    grayPointTask?.cancel()
    grayPointTask = nil
    grayPointRejectionTask?.cancel()
    grayPointRejectionTask = nil
    setGrayPointSampling(.off)
  }

  /// Samples the gray point at `point` of the crop output (full resolution,
  /// top-left origin), while the gray point is on.
  ///
  /// A live value is first written as its own step. The solve runs off the
  /// main actor in a task the model owns, which holds `document` until its
  /// result is applied or dropped. A white balance is written in one step and
  /// ends the gray point; a rejection shows for `grayPointRejectionDuration`
  /// and sampling goes on. The result is dropped, and sampling waits for
  /// another click, when anything was previewed or written since the click,
  /// an outside change dropped the live value, or the binding shows another
  /// image or another feature. Cancel, Revert, Done, leaving the screen and
  /// turning the gray point off end the gray point instead.
  func sampleGrayPoint(
    atOutputPoint point: CGPoint,
    previewSource: PreviewSource,
    rendering: AdjustmentRendering,
    in document: Binding<ImageEditorDocument>
  ) {
    guard
      grayPointSampling != .off,
      previewSource.source == source,
      beginAction(on: document)
    else {
      return
    }

    generation += 1
    let generation = self.generation
    let feature = document.wrappedValue.feature
    let request = GrayPoint.Request(
      previewSource: previewSource,
      feature: feature,
      outputPoint: point,
      adjustmentRendering: rendering
    )
    let solve = solveGrayPoint

    // A click while another solves or a rejection shows replaces it.
    grayPointTask?.cancel()
    grayPointRejectionTask?.cancel()
    grayPointRejectionTask = nil
    setGrayPointSampling(.solving)
    grayPointTask = Task { [weak self] in
      let result = await solve(request)
      guard Task.isCancelled == false else {
        return
      }
      self?.finishGrayPoint(result, generation: generation, over: feature, in: document)
    }
  }

  /// Applies the result of the click counted as `generation`, solved over
  /// `feature`, unless it is stale.
  private func finishGrayPoint(
    _ result: Result<WhiteBalanceFeature?, GrayPoint.Rejection>,
    generation: Int,
    over feature: ImageEditorFeature,
    in document: Binding<ImageEditorDocument>
  ) {
    // The feature catches an outside change that `.onChange(of:)` has not
    // reported yet, which it does on the editor's next update.
    guard
      generation == self.generation,
      document.wrappedValue.source == source,
      document.wrappedValue.feature == feature
    else {
      setGrayPointSampling(.waiting)
      return
    }

    switch result {
    case .success(let balance):
      setGrayPointSampling(.off)
      commit(.whiteBalance(balance), to: document)
    case .failure(let rejection):
      setGrayPointSampling(.rejected(rejection))
      let duration = Self.grayPointRejectionDuration
      grayPointRejectionTask = Task { [weak self] in
        try? await Task.sleep(for: duration)
        guard Task.isCancelled == false else {
          return
        }
        self?.endGrayPointRejection()
      }
    }
  }

  private func endGrayPointRejection() {
    if case .rejected = grayPointSampling {
      setGrayPointSampling(.waiting)
    }
  }

  private func setGrayPointSampling(_ sampling: GrayPointSampling) {
    if grayPointSampling != sampling {
      grayPointSampling = sampling
    }
  }

  // MARK: - Writing

  /// Begins an action other than a control's operation: writes the live value
  /// as its own step and ends Show Original. Returns false, doing nothing,
  /// when the binding shows another image.
  private func beginAction(on document: Binding<ImageEditorDocument>) -> Bool {
    guard document.wrappedValue.source == source else {
      return false
    }
    flush(document)
    endComparing()
    return true
  }

  /// Writes the live value, then `change`, to the binding as one write, which
  /// ends the operation in progress. Nothing is written when the binding shows
  /// another image or the feature stays the same.
  private func write(
    _ document: Binding<ImageEditorDocument>,
    _ change: (inout ImageEditorDocument) -> Void = { _ in }
  ) {
    let current = document.wrappedValue
    guard current.source == source else {
      return
    }
    openOperation = nil
    var session = self.session
    let hadLiveValue = session.liveFeature != nil
    let next = session.document(after: current, change: change)
    // The session changes only when it gives up its live value or records a
    // write.
    if hadLiveValue || next != nil {
      self.session = session
    }
    if let next {
      assign(next, to: document)
    }
  }

  /// Writes `feature` as a step of its own, dropping the live value. Nothing is
  /// written when the binding shows another image or already has the feature.
  private func reset(_ document: Binding<ImageEditorDocument>, to feature: ImageEditorFeature) {
    let current = document.wrappedValue
    guard current.source == source else {
      return
    }
    openOperation = nil
    // Assigned back even without a write: a reset also ends the tool visit.
    var session = self.session
    let next = session.document(afterResetTo: feature, of: current)
    self.session = session
    if let next {
      assign(next, to: document)
    }
  }

  private func writeCanvasChange(
    _ changed: ImageEditorDocument,
    to document: Binding<ImageEditorDocument>
  ) {
    let current = document.wrappedValue
    guard current.source == source, changed.source == source else {
      return
    }
    var session = self.session
    guard let next = session.document(afterCanvasChange: changed, over: current) else {
      return
    }
    self.session = session
    assign(next, to: document)
  }

  /// Assigns a document the editor wrote. Its feature is remembered first, so
  /// the change it causes is not taken for an outside change.
  private func assign(_ next: ImageEditorDocument, to document: Binding<ImageEditorDocument>) {
    lastWrittenFeature = next.feature
    generation += 1
    document.wrappedValue = next
    updateSwitches { $0.follow(next.feature) }
  }

  /// Drops the live value without writing it, which ends the operation in
  /// progress. A gray point solved meanwhile is stale even when nothing was
  /// live: the document or the editor changed under it.
  private func dropLiveValue() {
    endOpenOperation()
    generation += 1
    if session.liveFeature != nil {
      session.discardLiveFeature()
    }
  }

  /// Ends the operation in progress before its control ends it.
  private func endOpenOperation() {
    if let openOperation {
      endedOperation = openOperation
      self.openOperation = nil
    }
  }

  /// Ends Show Original, from the toggle or a held M: an edit shows the edit.
  private func endComparing() {
    setComparing(false)
    setHoldingOriginal(false)
  }

  private func updateSwitches(_ change: (inout ImageEditor.AdjustmentSection.Switches) -> Void) {
    var switches = self.switches
    change(&switches)
    if switches != self.switches {
      self.switches = switches
    }
  }

  /// The feature the aspect-ratio policy starts `document` with, its custom
  /// effects kept.
  private func initialFeature(
    of document: ImageEditorDocument,
    options: ImageEditor.Options
  ) -> ImageEditorFeature {
    options.aspectRatioPolicy.initialFeature(
      imageSize: document.source.pixelSize,
      custom: document.feature.effects.custom
    )
  }
}
