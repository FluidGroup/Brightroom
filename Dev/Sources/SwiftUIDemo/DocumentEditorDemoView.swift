import BrightroomEngine
import BrightroomParametric
import BrightroomUI
import PhotosUI
import SwiftUI

/// A host that owns an `EditingDocument` as plain view state.
///
/// - The document exists only once there is an image: bundled data or a
///   picked photo becomes a `SourceImage`, then a document.
/// - Undo and Redo buttons drive the document's own history. Every write to
///   the document is also registered with the window's `UndoManager`, as a
///   document-based app would, so "System Undo" (or shake) walks the writes.
///   The reverse step is registered inside the undo, so it becomes the redo.
/// - Editing a copy: Done writes the copy to the document (one system undo
///   step for the session) and Cancel drops it, so a cancelled session leaves
///   nothing to undo. Editing the document itself, as in a document window,
///   makes each of the editor's writes one system undo step.
/// - A host bar over the editor undoes and redoes the document the editor is
///   bound to while it is open, as a document window's Edit menu would.
/// - The history limit is configurable and the history can be dropped, as an
///   app that does not save history would do before saving.
struct DocumentEditorDemoView: View {

  @State private var document: ImageEditorDocument?
  /// The copy the editor edits while `editsCopy` is on.
  @State private var draft: ImageEditorDocument?
  @State private var isEditing = false
  @State private var showsCancel = true
  @State private var editsCopy = true
  @State private var pickerItem: PhotosPickerItem?
  @State private var loadingMessage: String?
  @State private var rendered: ResultImage?
  @State private var renderTask: Task<Void, Never>?
  /// The target the `UndoManager` registrations are grouped under.
  @State private var undoTarget = UndoTarget()

  @Environment(\.undoManager) private var undoManager

  var body: some View {
    Form {
      Section("Image") {
        Button("Bundled photo (data)") {
          Task { await open(Self.loadBundledImage, initialCrop: .fullImage) }
        }
        Button("Bundled photo, square face crop") {
          Task { await open(Self.loadBundledImage, initialCrop: .faceDetection(aspectRatio: .square)) }
        }
        PhotosPicker("Pick a photo", selection: $pickerItem, matching: .images)
        if let loadingMessage {
          Text(loadingMessage)
            .foregroundStyle(.secondary)
        }
      }

      if let document {
        documentSections(document)
      }
    }
    .navigationTitle("Document Editor")
    .fullScreenCover(isPresented: $isEditing) {
      editor
    }
    .sheet(item: $rendered) {
      RenderedResultView(result: $0)
    }
    .onChange(of: pickerItem) { _, item in
      guard let item else { return }
      Task {
        await open({
          guard let data = try await item.loadTransferable(type: Data.self) else {
            throw CocoaError(.fileReadCorruptFile)
          }
          return try SourceImage(data: data)
        }, initialCrop: .fullImage)
      }
    }
  }

  /// The cover is shown only while a document exists, and neither the
  /// document nor the draft is set back to nil while it is shown.
  @ViewBuilder
  private var editor: some View {
    if editsCopy {
      if let binding = Binding($draft) {
        // The editor's own navigation bar sits at the top of its frame, so
        // the host bar stacks above it rather than insetting it.
        VStack(spacing: 0) {
          hostHistoryBar(binding)
          ImageEditor(
            document: binding,
            options: .documentEditorDemo(),
            onDone: {
              write(binding.wrappedValue)
              isEditing = false
            },
            onCancel: showsCancel ? { isEditing = false } : nil
          )
        }
      }
    } else if let document {
      // Reads the latest value: the editor can write twice in one event.
      let binding = Binding(get: { self.document ?? document }, set: { write($0) })
      VStack(spacing: 0) {
        hostHistoryBar(binding)
        ImageEditor(
          document: binding,
          options: .documentEditorDemo(),
          onDone: { isEditing = false },
          onCancel: showsCancel ? { isEditing = false } : nil
        )
      }
    }
  }

  /// Undo and redo over the open editor: the host walks the history of the
  /// document the editor is bound to, and the editor sees each step as a
  /// write from outside.
  private func hostHistoryBar(_ document: Binding<ImageEditorDocument>) -> some View {
    HStack(spacing: 16) {
      Text("Host")
        .font(.caption)
        .foregroundStyle(.secondary)
      Button("Undo") { document.wrappedValue.undo() }
        .disabled(!document.wrappedValue.canUndo)
        .accessibilityIdentifier("document-editor.host-undo")
      Button("Redo") { document.wrappedValue.redo() }
        .disabled(!document.wrappedValue.canRedo)
        .accessibilityIdentifier("document-editor.host-redo")
      Spacer()
      Text("\(document.wrappedValue.history.undoStack.count) undo · \(document.wrappedValue.history.redoStack.count) redo")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background(.bar)
  }

  @ViewBuilder
  private func documentSections(_ document: ImageEditorDocument) -> some View {
    Section("Document") {
      LabeledContent("Image", value: "\(Int(document.source.pixelSize.width)) x \(Int(document.source.pixelSize.height)) px")
      LabeledContent("Crop", value: Self.describe(document.feature.crop))
      LabeledContent("Undo steps", value: "\(document.history.undoStack.count)")
      LabeledContent("Redo steps", value: "\(document.history.redoStack.count)")
      LabeledContent("Uncommitted changes", value: document.hasUncommittedChanges ? "Yes" : "No")

      Toggle("Show Cancel in the editor", isOn: $showsCancel)
      Toggle("Edit a copy; Done writes it back", isOn: $editsCopy)
        .accessibilityIdentifier("document-editor.edits-copy")

      Button(document.canUndo || document.canRedo ? "Reopen editor" : "Open editor") {
        startEditing()
      }
      .accessibilityIdentifier("document-editor.open")

      HStack {
        Button("Undo") { update { $0.undo() } }
          .disabled(!document.canUndo)
          .accessibilityIdentifier("document-editor.undo")
        Spacer()
        Button("Redo") { update { $0.redo() } }
          .disabled(!document.canRedo)
          .accessibilityIdentifier("document-editor.redo")
      }
      .buttonStyle(.borderless)

      HStack {
        Button("Render") { render(document) }
          .disabled(renderTask != nil)
        if renderTask != nil {
          Spacer()
          ProgressView()
        }
      }
    }

    Section {
      Stepper(
        "History limit: \(document.history.limit.map(String.init) ?? "none")",
        onIncrement: { update { $0.history.limit = (document.history.limit ?? 0) + 1 } },
        onDecrement: { update { $0.history.limit = max(0, (document.history.limit ?? 1) - 1) } }
      )
      Button("Unlimited history") { update { $0.history.limit = nil } }
      Button("Drop history", role: .destructive) { update { $0.history.removeAll() } }
        .disabled(document.history.undoStack.isEmpty && document.history.redoStack.isEmpty)
    } header: {
      Text("History")
    } footer: {
      Text("The history is part of the document value. Saving it is the app's choice; dropping it keeps the feature.")
    }

    Section {
      Button("System Undo") { undoManager?.undo() }
        .disabled(!(undoManager?.canUndo ?? false))
      Button("System Redo") { undoManager?.redo() }
        .disabled(!(undoManager?.canRedo ?? false))
    } header: {
      Text("UndoManager")
    } footer: {
      Text("Every write to the document is registered as one system undo step: one editor session when editing a copy, one editor operation when editing the document itself. The library registers nothing itself.")
    }
  }

  // MARK: - Actions

  /// Loads an image, then creates the document over it.
  private func open(
    _ loadImage: @escaping () async throws -> SourceImage,
    initialCrop: InitialCrop
  ) async {
    loadingMessage = "Loading..."
    do {
      let image = try await loadImage()
      let newDocument = await EditingDocument(source: image, initialCrop: initialCrop)
      // Replacing the image starts a new edit; it is not an undoable change.
      undoManager?.removeAllActions(withTarget: undoTarget)
      document = newDocument
      loadingMessage = nil
      startEditing()
    } catch {
      loadingMessage = "Failed to load the image: \(error)"
    }
  }

  private func startEditing() {
    // A result arriving over the editor would collide with it.
    cancelRendering()
    draft = document
    isEditing = true
  }

  /// Writes `new` to the document and registers the write with the
  /// `UndoManager`.
  ///
  /// The reverse step is registered right here: inside an undo, the
  /// `UndoManager` records it as the redo. Registering from
  /// `onChange(of:)` would run after the undo returned and record a new
  /// undo step instead.
  private func write(_ new: ImageEditorDocument) {
    Self.write(new, to: $document, undoManager: undoManager, target: undoTarget)
  }

  private static func write(
    _ new: ImageEditorDocument,
    to document: Binding<ImageEditorDocument?>,
    undoManager: UndoManager?,
    target: UndoTarget
  ) {
    guard let old = document.wrappedValue, old != new else {
      return
    }
    document.wrappedValue = new
    // Replacing the photo is not an edit.
    guard old.source == new.source else {
      return
    }
    undoManager?.registerUndo(withTarget: target) { _ in
      write(old, to: document, undoManager: undoManager, target: target)
    }
  }

  /// Changes the document through `write(_:)`, so the change is undoable.
  private func update(_ change: (inout ImageEditorDocument) -> Void) {
    guard var next = document else {
      return
    }
    change(&next)
    write(next)
  }

  private func render(_ document: ImageEditorDocument) {
    renderTask = Task {
      defer {
        // A cancelled task's slot may already hold a newer task.
        if !Task.isCancelled { renderTask = nil }
      }
      do {
        let rendered = try await document.render()
        guard !Task.isCancelled else { return }
        self.rendered = ResultImage(
          cgImage: try rendered.cgImage,
          metadata: [
            "undo steps: \(document.history.undoStack.count)",
            "redo steps: \(document.history.redoStack.count)",
          ],
          feature: document.feature
        )
      } catch {
        guard !Task.isCancelled else { return }
        loadingMessage = "Failed to render: \(error)"
      }
    }
  }

  private func cancelRendering() {
    renderTask?.cancel()
    renderTask = nil
  }

  // MARK: - Helpers

  private final class UndoTarget {}

  private static func loadBundledImage() async throws -> SourceImage {
    guard let url = Bundle.main.url(forResource: "nasa", withExtension: "jpg") else {
      throw CocoaError(.fileNoSuchFile)
    }
    return try SourceImage(data: Data(contentsOf: url))
  }

  private static func describe(_ crop: CropFeature) -> String {
    let rect = crop.rect
    var text = "\(Int(rect.minX)), \(Int(rect.minY)), \(Int(rect.width)) x \(Int(rect.height))"
    if crop.quarterTurn != .zero {
      text += " · \(crop.quarterTurn)"
    }
    if crop.straightenRadians != 0 {
      text += " · \(String(format: "%.2f", crop.straightenRadians)) rad"
    }
    return text
  }
}

private extension ImageEditor.Options {
  static func documentEditorDemo() -> Self {
    var options = Self()
    options.filters = DemoFilters.make() + DemoLUTs.bundled
    return options
  }
}

/// Remote images are the app's job: it owns networking, authentication,
/// status codes, and caching, then hands the bytes to `SourceImage(data:)`.
enum DemoRemoteImage {

  static func load(_ url: URL, session: URLSession = .shared) async throws -> SourceImage {
    let (data, response) = try await session.data(from: url)
    if let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) == false {
      throw URLError(.badServerResponse)
    }
    return try SourceImage(data: data)
  }
}
