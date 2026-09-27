// Host usage sketch for the engine-centric document design. It only has to
// type-check against the prototype; it is not wired into the demo UI.

import BrightroomEngine
import BrightroomParametric
import BrightroomUI
import Photos
import SwiftUI

// MARK: - Loading: every source becomes a SourceImage before a document exists

enum SketchImageLoading {

  static func load(asset: PHAsset) async throws -> EditingDocument<PhotosCropFeature> {
    let image = try await SourceImage(asset: asset)
    return await EditingDocument(image: image, cropModifier: .faceDetection(aspectRatio: .square))
  }

  static func load(remote url: URL) async throws -> EditingDocument<PhotosCropFeature> {
    EditingDocument(image: try await SourceImage(remoteURL: url))
  }

  static func load(file url: URL) throws -> EditingDocument<PhotosCropFeature> {
    EditingDocument(image: try SourceImage(fileURL: url))
  }

  static func load(raw url: URL) throws -> EditingDocument<PhotosCropFeature> {
    EditingDocument(image: try SourceImage(rawFileURL: url))
  }

  static func load(uiImage: UIImage) -> EditingDocument<PhotosCropFeature> {
    EditingDocument(image: SourceImage(image: uiImage), history: .init(limit: 20))
  }
}

// MARK: - A host that owns undo, presents the built-in editor, and exports

struct SketchEditorScreen: View {

  // The document is a value in the host's state; the editor edits it through
  // a binding and the host's toolbar drives its history.
  @State var document: EditingDocument<PhotosCropFeature>
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
          let rendered = try await document.render()
          exported = try rendered.cgImage
        }
      }
    }
    .fullScreenCover(isPresented: $isEditing) {
      SketchPresentedEditor(document: $document, isPresented: $isEditing)
    }
  }
}

/// Restores the document on Cancel: the editor writes changes live.
private struct SketchPresentedEditor: View {

  @Binding var document: EditingDocument<PhotosCropFeature>
  @Binding var isPresented: Bool
  @State private var original: EditingDocument<PhotosCropFeature>?

  var body: some View {
    SwiftUIPhotosCropView(
      document: $document,
      onDone: { isPresented = false },
      onCancel: {
        if let original { document = original }
        isPresented = false
      }
    )
    .onAppear { original = document }
  }
}

// MARK: - A custom editor over the reusable canvas

struct SketchCustomCropEditor: View {

  @Binding var document: EditingDocument<PhotosCropFeature>
  @State private var target: CropViewEditingTarget? = .crop
  @State private var applyAction = SwiftUICropView.ApplyAction()

  var body: some View {
    VStack {
      SwiftUICropView(document: $document) { _ in
        Color.clear
      } cropOutsideOverlay: { _ in
        Color.black.opacity(0.4)
      }
      .editingTarget(target)
      .registerApplyAction(applyAction)

      Picker("Tool", selection: $target) {
        Text("Crop").tag(CropViewEditingTarget?.some(.crop))
        Text("Blur").tag(CropViewEditingTarget?.some(.blurMask))
      }
      .onChange(of: target) {
        // SwiftUICropView never commits; this editor makes each tool visit
        // one undo step.
        document.commit()
      }

      Slider(
        value: Binding(
          get: { document.feature.effects.exposure?.value ?? 0 },
          set: { document.feature.effects.exposure = ExposureFeature(value: $0) }
        ),
        in: -1...1,
        onEditingChanged: { isEditing in
          if !isEditing { document.commit() }
        }
      )
    }
  }
}

// MARK: - App-owned persistence: the library defines no storage format

/// The app's own saved form. It stores how to find the image again and the
/// feature's parameters; history is optional and saved here as plain steps.
struct SketchSavedEdit: Codable {

  struct Step: Codable {
    var exposure: Double?
    var cropRect: CGRect
    var rotation: Int
    var straightenRadians: Double
  }

  var imageFileName: String
  var current: Step
  var undo: [Step]

  init(document: EditingDocument<PhotosCropFeature>, imageFileName: String, keepsHistory: Bool) {
    self.imageFileName = imageFileName
    self.current = Step(document.feature)
    self.undo = keepsHistory ? document.history.undoStack.map(Step.init) : []
  }

  func makeDocument(imageDirectory: URL) throws -> EditingDocument<PhotosCropFeature> {
    let image = try SourceImage(fileURL: imageDirectory.appendingPathComponent(imageFileName))
    return EditingDocument(
      image: image,
      feature: current.makeFeature(),
      history: .init(undoStack: undo.map { $0.makeFeature() }, redoStack: [])
    )
  }
}

extension SketchSavedEdit.Step {

  init(_ feature: PhotosCropFeature) {
    self.exposure = feature.effects.exposure?.value
    self.cropRect = feature.crop.cropRect
    self.rotation = feature.crop.rotation.rawValue
    self.straightenRadians = feature.crop.straightenRadians
  }

  func makeFeature() -> PhotosCropFeature {
    PhotosCropFeature(
      effects: .init(exposure: exposure.map { ExposureFeature(value: $0) }),
      crop: CropFeature(
        cropRect: cropRect,
        rotation: QuarterTurn(rawValue: rotation) ?? .zero,
        straightenRadians: straightenRadians
      )
    )
  }
}

// MARK: - Parametric renderers take a feature, not a document

enum SketchFeatureRendering {

  static func preview(of document: EditingDocument<PhotosCropFeature>) throws -> CIImage {
    try ParametricImageRenderer().makeImage(
      from: document.image.makeCIImage(maxPixelSize: 1024),
      feature: document.feature
    )
  }
}
