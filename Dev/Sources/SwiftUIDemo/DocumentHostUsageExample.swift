// Host usage example for the document design. It only has to type-check; it
// is not wired into the demo UI. `DocumentEditorDemoView` is the runnable
// counterpart.

import BrightroomEngine
import BrightroomParametric
import BrightroomUI
import Photos
import SwiftUI

// MARK: - Loading: every source becomes a SourceImage before a document exists

enum ExampleImageLoading {

  static func load(asset: PHAsset) async throws -> ImageEditorDocument {
    let image = try await SourceImage(asset: asset)
    return await EditingDocument(image: image, cropModifier: .faceDetection(aspectRatio: .square))
  }

  static func load(remote url: URL) async throws -> ImageEditorDocument {
    // The app owns networking; the library reads the bytes.
    EditingDocument(image: try await DemoRemoteImage.load(url))
  }

  static func load(file url: URL) throws -> ImageEditorDocument {
    EditingDocument(image: try SourceImage(contentsOf: url))
  }

  /// RAW is developed when the image is created, which takes hundreds of
  /// milliseconds, so it runs off the main actor.
  @concurrent
  static func load(raw url: URL) async throws -> ImageEditorDocument {
    EditingDocument(image: try SourceImage(rawContentsOf: url))
  }

  static func load(contentEditingInput input: PHContentEditingInput) throws -> ImageEditorDocument {
    guard let url = input.fullSizeImageURL else {
      throw CocoaError(.fileNoSuchFile)
    }
    return EditingDocument(image: try SourceImage(contentsOf: url))
  }

  static func load(uiImage: UIImage) -> ImageEditorDocument {
    EditingDocument(image: SourceImage(image: uiImage), history: .init(limit: 20))
  }
}

// MARK: - A host that owns undo, presents the built-in editor, and exports

struct ExampleEditorScreen: View {

  // The document is a value in the host's state; the editor edits it through
  // a binding and the host's toolbar drives its history.
  @State var document: ImageEditorDocument
  @State private var isEditing = false
  @State private var exported: CGImage?

  var body: some View {
    VStack {
      Button("Edit") { isEditing = true }
      HStack {
        Button("Undo") { document.undo() }
          .disabled(!document.canUndo)
        Button("Redo") { document.redo() }
          .disabled(!document.canRedo)
      }
      Button("Export") {
        let document = document
        Task {
          do {
            exported = try await document.render().cgImage
          } catch {
            exported = nil
          }
        }
      }
    }
    .fullScreenCover(isPresented: $isEditing) {
      ExamplePresentedEditor(document: $document, isPresented: $isEditing)
    }
  }
}

/// The editor restores the document it opened with on Cancel, so the host
/// only dismisses.
private struct ExamplePresentedEditor: View {

  @Binding var document: ImageEditorDocument
  @Binding var isPresented: Bool

  var body: some View {
    ImageEditor(
      document: $document,
      onDone: { isPresented = false },
      onCancel: { isPresented = false }
    )
  }
}

// MARK: - A custom editor over the reusable canvas

struct ExampleCustomCropEditor: View {

  @Binding var document: ImageEditorDocument
  @State private var target: ImageEditorCanvas.Target? = .crop
  @State private var applyAction = ImageEditorCanvas.ApplyAction()

  var body: some View {
    VStack {
      ImageEditorCanvas(document: $document) { _ in
        Color.clear
      } cropOutsideOverlay: { _ in
        Color.black.opacity(0.4)
      }
      .editingTarget(target)
      .registerApplyAction(applyAction)

      HStack {
        Button("Crop") { select(.crop) }
        Button("Blur") { select(.localBlur) }
      }

      Slider(
        value: Binding(
          get: { document.feature.effects.exposure?.ev ?? 0 },
          set: { document.feature.effects.exposure = ExposureFeature(ev: $0) }
        ),
        in: -1...1,
        onEditingChanged: { isEditing in
          if !isEditing { document.commit() }
        }
      )
    }
  }

  /// ImageEditorCanvas never commits; this editor makes each tool visit one
  /// undo step. The order matters: `applyAction()` writes the crop guide's
  /// pending crop synchronously, so the commit includes it. Committing in
  /// `onChange(of: target)` would run before the crop the canvas writes,
  /// later, when it leaves `.crop`.
  private func select(_ newTarget: ImageEditorCanvas.Target) {
    guard newTarget != target else { return }
    if target == .crop {
      applyAction()
    }
    target = newTarget
    document.commit()
  }
}

// MARK: - App-owned persistence: the library defines no storage format

/// The app's own saved form. It stores how to find the image again and the
/// feature's parameters; history is optional and saved here as plain steps.
struct ExampleSavedEdit: Codable {

  struct Step: Codable {
    var exposure: Double?
    var cropRect: CGRect
    var rotation: Int
    var straightenRadians: Double
  }

  var imageFileName: String
  var current: Step
  var undo: [Step]

  init(document: ImageEditorDocument, imageFileName: String, keepsHistory: Bool) {
    self.imageFileName = imageFileName
    self.current = Step(document.feature)
    self.undo = keepsHistory ? document.history.undoStack.map(Step.init) : []
  }

  func makeDocument(imageDirectory: URL) throws -> ImageEditorDocument {
    let image = try SourceImage(contentsOf: imageDirectory.appendingPathComponent(imageFileName))
    return EditingDocument(
      image: image,
      feature: current.makeFeature(),
      history: .init(undoStack: undo.map { $0.makeFeature() }, redoStack: [])
    )
  }
}

extension ExampleSavedEdit.Step {

  init(_ feature: ImageEditorFeature) {
    self.exposure = feature.effects.exposure?.ev
    self.cropRect = feature.crop.rect
    self.rotation = feature.crop.quarterTurn.rawValue
    self.straightenRadians = feature.crop.straightenRadians
  }

  func makeFeature() -> ImageEditorFeature {
    ImageEditorFeature(
      effects: .init(exposure: exposure.map { ExposureFeature(ev: $0) }),
      crop: CropFeature(
        rect: cropRect,
        quarterTurn: QuarterTurn(rawValue: rotation) ?? .zero,
        straightenRadians: straightenRadians
      )
    )
  }
}

// MARK: - Parametric renderers take a feature, not a document

enum ExampleFeatureRendering {

  static func preview(of document: ImageEditorDocument) throws -> CIImage {
    try FeatureRenderer().makeImage(
      from: document.image.makeCIImage(maxPixelSize: 1024),
      feature: document.feature
    )
  }
}
