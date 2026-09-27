import BrightroomEngine
import BrightroomParametric
import BrightroomUI
import PhotosUI
import SwiftUI

/// A host that owns an `EditingDocument` as plain view state.
///
/// - The document exists only once there is an image: bundled data or a
///   picked photo becomes a `SourceImage`, then a document.
/// - The editor edits the document through a non-optional binding; closing
///   and reopening it continues the same edit.
/// - Undo and Redo buttons drive the document's own history. Each write is
///   also registered with the window's `UndoManager`, as a document-based app
///   would, so "System Undo" (or shake) walks the writes.
/// - The history limit is configurable and the history can be dropped, as an
///   app that does not save history would do before saving.
struct DocumentEditorDemoView: View {

  @State private var document: EditingDocument<PhotosCropFeature>?
  @State private var isEditing = false
  @State private var showsCancel = true
  @State private var pickerItem: PhotosPickerItem?
  @State private var loadingMessage: String?
  @State private var rendered: ResultImage?
  /// The target the `UndoManager` registrations are grouped under.
  @State private var undoTarget = UndoTarget()

  @Environment(\.undoManager) private var undoManager

  var body: some View {
    Form {
      Section("Image") {
        Button("Bundled photo (data)") {
          Task { await open(Self.loadBundledImage, cropModifier: .identity) }
        }
        Button("Bundled photo, square face crop") {
          Task { await open(Self.loadBundledImage, cropModifier: .faceDetection(aspectRatio: .square)) }
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
      // The cover is shown only while a document exists, and the document is
      // never set back to nil while it is shown.
      if let binding = Binding($document) {
        SwiftUIPhotosCropView(
          document: binding,
          options: .documentEditorDemo(),
          onDone: {
            isEditing = false
            render(binding.wrappedValue)
          },
          onCancel: showsCancel ? { isEditing = false } : nil
        )
      }
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
        }, cropModifier: .identity)
      }
    }
    .onChange(of: document) { old, new in
      registerSystemUndo(from: old, to: new)
    }
  }

  @ViewBuilder
  private func documentSections(_ document: EditingDocument<PhotosCropFeature>) -> some View {
    Section("Document") {
      LabeledContent("Image", value: "\(Int(document.image.pixelSize.width)) x \(Int(document.image.pixelSize.height)) px")
      LabeledContent("Crop", value: Self.describe(document.feature.crop.cropRect))
      LabeledContent("Undo steps", value: "\(document.history.undoStack.count)")
      LabeledContent("Redo steps", value: "\(document.history.redoStack.count)")
      LabeledContent("Uncommitted changes", value: document.hasUncommittedChanges ? "Yes" : "No")

      Toggle("Show Cancel in the editor", isOn: $showsCancel)

      Button(document.canUndo || document.canRedo ? "Reopen editor" : "Open editor") {
        isEditing = true
      }
      .accessibilityIdentifier("document-editor.open")

      HStack {
        Button("Undo") { self.document?.undo() }
          .disabled(!document.canUndo)
          .accessibilityIdentifier("document-editor.undo")
        Spacer()
        Button("Redo") { self.document?.redo() }
          .disabled(!document.canRedo)
          .accessibilityIdentifier("document-editor.redo")
      }
      .buttonStyle(.borderless)

      Button("Render") { render(document) }
    }

    Section {
      Stepper(
        "History limit: \(document.history.limit.map(String.init) ?? "none")",
        onIncrement: { self.document?.history.limit = (document.history.limit ?? 0) + 1 },
        onDecrement: { self.document?.history.limit = max(0, (document.history.limit ?? 1) - 1) }
      )
      Button("Unlimited history") { self.document?.history.limit = nil }
      Button("Drop history", role: .destructive) { self.document?.history.removeAll() }
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
      Text("Every write to the document is registered as one system undo step. The library registers nothing itself.")
    }
  }

  // MARK: - Actions

  /// Loads an image, then creates the document over it.
  private func open(
    _ loadImage: @escaping () async throws -> SourceImage,
    cropModifier: CropModifier
  ) async {
    loadingMessage = "Loading..."
    do {
      let image = try await loadImage()
      let newDocument = await EditingDocument(image: image, cropModifier: cropModifier)
      // Replacing the image starts a new edit; it is not an undoable change.
      undoManager?.removeAllActions(withTarget: undoTarget)
      document = newDocument
      loadingMessage = nil
      isEditing = true
    } catch {
      loadingMessage = "Failed to load the image: \(error)"
    }
  }

  private func registerSystemUndo(
    from old: EditingDocument<PhotosCropFeature>?,
    to new: EditingDocument<PhotosCropFeature>?
  ) {
    // Replacing the photo is not an edit.
    guard let old, let new, old.image == new.image, let undoManager else {
      return
    }
    let binding = $document
    undoManager.registerUndo(withTarget: undoTarget) { _ in
      // Writing the old value fires onChange again, which registers the redo.
      binding.wrappedValue = old
    }
  }

  private func render(_ document: EditingDocument<PhotosCropFeature>) {
    Task {
      do {
        let rendered = try await document.render()
        self.rendered = ResultImage(
          cgImage: try rendered.cgImage,
          metadata: [
            "undo steps: \(document.history.undoStack.count)",
            "redo steps: \(document.history.redoStack.count)",
          ],
          feature: document.feature
        )
      } catch {
        loadingMessage = "Failed to render: \(error)"
      }
    }
  }

  // MARK: - Helpers

  private final class UndoTarget {}

  private static func loadBundledImage() async throws -> SourceImage {
    guard let url = Bundle.main.url(forResource: "nasa", withExtension: "jpg") else {
      throw CocoaError(.fileNoSuchFile)
    }
    return try SourceImage(data: Data(contentsOf: url))
  }

  private static func describe(_ rect: CGRect) -> String {
    "\(Int(rect.minX)), \(Int(rect.minY)), \(Int(rect.width)) x \(Int(rect.height))"
  }
}

private extension SwiftUIPhotosCropView.Options {
  static func documentEditorDemo() -> Self {
    var options = Self()
    options.filterPresets = PhotosCropDemoFilterPresets.make()
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
