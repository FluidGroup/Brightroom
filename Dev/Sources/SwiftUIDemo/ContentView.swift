import BrightroomEngine
import BrightroomParametric
import BrightroomUI
import PhotosUI
import SwiftUI
import UIKit

struct ContentView: View {

  @State private var fullScreenView: FullscreenIdentifiableView?

  // Each editor keeps its document in a store, so reopening an editor shows
  // the previous edit and keeps its undo history.
  @State private var horizontalStore = DemoDocumentStore(
    image: Mocks.makeSourceImage(image: Asset.horizontalRect.image)
  )
  @State private var verticalStore = DemoDocumentStore(
    image: Mocks.makeSourceImage(image: Asset.verticalRect.image)
  )
  @State private var squareStore = DemoDocumentStore(
    image: Mocks.makeSourceImage(image: Asset.squareRect.image)
  )
  @State private var nasaStore = DemoDocumentStore(
    image: Mocks.makeSourceImage(
      contentsOf: Bundle.main.path(forResource: "nasa", ofType: "jpg").map {
        URL(fileURLWithPath: $0)
      }!
    )
  )
  @State private var superSmallStore = DemoDocumentStore(
    image: Mocks.makeSourceImage(image: Asset.superSmall.image)
  )
  @State private var instaLogoStore = DemoDocumentStore(
    image: Mocks.makeSourceImage(image: Asset.instaLogo.image)
  )
  @State private var remoteStore = DemoDocumentStore(
    loading: {
      try await DemoRemoteImage.load(
        URL(
          string:
            "https://images.unsplash.com/photo-1604456930969-37f67bcd6e1e?ixid=MXwxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHw%3D&ixlib=rb-1.2.1"
        )!
      )
    }
  )
  @State private var remotePreviewStore = DemoDocumentStore(
    loading: {
      try await DemoRemoteImage.load(
        URL(
          string:
            "https://images.unsplash.com/photo-1597522781074-9a05ab90638e?ixlib=rb-1.2.1&ixid=MXwxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHw%3D"
        )!
      )
    }
  )

  var body: some View {
    NavigationSplitView {
      VStack {

        Form {

          NavigationLink("Isolated", destination: IsolatedEditingView())

          NavigationLink("Document Editor") {
            DocumentEditorDemoView()
          }

          if #available(iOS 16, *) {
            NavigationLink("Pick image") {
              WorkingOnPicked()
            }
          }

          NavigationLink("Rendering") {
            RenderingDemoView()
          }

          NavigationLink("Parametric Features") {
            ParametricFeaturePreviewView()
          }

          NavigationLink("Parametric Video") {
            ParametricVideoRenderPlaygroundView()
          }
          NavigationLink("PencilKit Reference") {
            PencilKitReferenceSandboxView()
          }

          Section(
            "ImageEditor FaceDetection",
            content: {
              Button("Horizontal 1") {
                fullScreenView = .init(showsDismissButton: false) {
                  DemoImageEditor(
                    image: {
                      Mocks.makeSourceImage(image: Asset.horizontalRect.image)
                    },
                    initialCrop: .faceDetection(aspectRatio: .square)
                  )
                }
              }

              Button("Horizontal 2") {
                fullScreenView = .init(showsDismissButton: false) {
                  DemoImageEditor(
                    image: {
                      Mocks.makeSourceImage(image: Asset.horizontalRect.image)
                    },
                    initialCrop: .faceDetection(aspectRatio: .square),
                    options: .fixedAspectRatio(.square)
                  )
                }
              }

            }
          )

          Section(
            "ImageEditor",
            content: {
              Button("Horizontal") {
                fullScreenView = .init(showsDismissButton: false) {
                  DemoImageEditor(store: horizontalStore)
                }
              }

              Button("Vertical") {
                fullScreenView = .init(showsDismissButton: false) {
                  DemoImageEditor(store: verticalStore)
                }
              }

              Button("Square") {
                fullScreenView = .init(showsDismissButton: false) {
                  DemoImageEditor(store: squareStore)
                }
              }

              Button("Nasa") {
                fullScreenView = .init(showsDismissButton: false) {
                  DemoImageEditor(store: nasaStore)
                }
              }

              Button("Super small") {
                fullScreenView = .init(showsDismissButton: false) {
                  DemoImageEditor(store: superSmallStore)
                }
              }

              Button("Insta Logo") {
                fullScreenView = .init(showsDismissButton: false) {
                  DemoImageEditor(store: instaLogoStore)
                }
              }

              Button("Remote") {

                fullScreenView = .init(showsDismissButton: false) {
                  DemoImageEditor(store: remoteStore)
                }
              }

              Button("Remote - preview") {

                fullScreenView = .init(showsDismissButton: false) {
                  DemoImageEditor(store: remotePreviewStore)
                }
              }
            }
          )

          Section(content: {
            Button("ImageEditor Square (initial crop)") {
              fullScreenView = .init(showsDismissButton: false) {
                DemoImageEditor(
                  image: {
                    SourceImage(image: Asset.l1000316.image)
                  },
                  initialCrop: .aspectRatio(.square),
                  options: .fixedAspectRatio(.square)
                )
              }
            }

            Button("ImageEditor 4:5") {
              fullScreenView = .init(showsDismissButton: false) {
                DemoImageEditor(
                  image: {
                    SourceImage(image: Asset.l1000316.image)
                  },
                  options: .fixedAspectRatio(.init(width: 4, height: 5))
                )
              }
            }

            Button("ImageEditor 5:4") {
              fullScreenView = .init(showsDismissButton: false) {
                DemoImageEditor(
                  image: {
                    SourceImage(image: Asset.l1000316.image)
                  },
                  options: .fixedAspectRatio(.init(width: 5, height: 4))
                )
              }
            }

            Button("ImageEditor left") {
              fullScreenView = .init(showsDismissButton: false) {
                DemoImageEditor(
                  image: {
                    SourceImage(image: Mocks.imageOrientationLeft())
                  }
                )
              }
            }

          })

        }

      }
      .navigationTitle("Brightroom")
      .fullScreenCover(
        item: $fullScreenView,
        onDismiss: {},
        content: {
          $0
        }
      )
    } detail: {
      Text("Brightroom")
        .font(.largeTitle.bold())
        .foregroundStyle(.secondary)
    }
  }
}

@available(iOS 16, *)
struct WorkingOnPicked: View {

  @State private var item: PhotosPickerItem?
  @State private var selectedImage: PickedDemoImage?
  @State private var selectedDocumentStore: DemoDocumentStore?
  @State private var loadingMessage: String?
  @State private var fullScreenView: FullscreenIdentifiableView?

  var body: some View {

    Form {
      PhotosPicker("Select", selection: $item, matching: .images)

      if let selectedImage {
        Section("Selected Photo") {
          PickedImageSummary(image: selectedImage)
        }

        Section("BuiltIn") {
          Button("ImageEditor") {
            let store = documentStore(for: selectedImage)
            fullScreenView = .init(showsDismissButton: false) {
              DemoImageEditor(store: store)
            }
          }

          Button("ImageEditor Square") {
            fullScreenView = .init(showsDismissButton: false) {
              DemoImageEditor(image: {
                selectedImage.makeSourceImage()
              }, options: .fixedAspectRatio(.square))
            }
          }

          Button("ImageEditor 4:5") {
            fullScreenView = .init(showsDismissButton: false) {
              DemoImageEditor(image: {
                selectedImage.makeSourceImage()
              }, options: .fixedAspectRatio(.init(width: 4, height: 5)))
            }
          }
        }

      }

      if let loadingMessage {
        Section {
          Text(loadingMessage)
            .foregroundStyle(.secondary)
        }
      }

    }
    .fullScreenCover(
      item: $fullScreenView,
      onDismiss: {},
      content: {
        $0
      }
    )
    .onChange(of: item, perform: { value in
      selectedImage = nil
      selectedDocumentStore = nil
      loadingMessage = "Loading selected image..."

      guard let value else {
        loadingMessage = nil
        return
      }

      Task {

        do {
          guard let transferable = try await value.loadTransferable(type: Data.self) else {
            await MainActor.run {
              loadingMessage = "No image data was found."
            }
            return
          }

          guard let previewImage = UIImage(data: transferable) else {
            await MainActor.run {
              loadingMessage = "The selected image could not be previewed."
            }
            return
          }

          let selectedImage = PickedDemoImage(
            data: transferable,
            previewImage: previewImage
          )
          await MainActor.run {
            self.selectedImage = selectedImage
            loadingMessage = nil
          }
        } catch {
          await MainActor.run {
            loadingMessage = "Failed to load selected image."
          }
        }

      }
    })

  }

  private func documentStore(for image: PickedDemoImage) -> DemoDocumentStore {
    if let selectedDocumentStore {
      return selectedDocumentStore
    }

    let store = DemoDocumentStore(image: image.makeSourceImage())
    selectedDocumentStore = store
    return store
  }

}

@available(iOS 16, *)
private struct PickedDemoImage: Identifiable {
  let id = UUID()
  let data: Data
  let previewImage: UIImage

  var pixelSize: CGSize {
    previewImage.size.applying(.init(scaleX: previewImage.scale, y: previewImage.scale))
  }

  func makeSourceImage() -> SourceImage {
    try! SourceImage(data: data)
  }
}

@available(iOS 16, *)
private struct PickedImageSummary: View {
  let image: PickedDemoImage

  var body: some View {
    HStack(spacing: 12) {
      Image(uiImage: image.previewImage)
        .resizable()
        .scaledToFill()
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 6))

      VStack(alignment: .leading, spacing: 4) {
        Text("Selected image")
          .font(.headline)
        Text("\(Int(image.pixelSize.width)) x \(Int(image.pixelSize.height)) px")
        Text(ByteCountFormatter.string(fromByteCount: Int64(image.data.count), countStyle: .file))
      }
      .font(.footnote)
      .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }
}

/// A long-lived edit of one image.
///
/// The store keeps the document, so reopening the editor shows the previous
/// edit and keeps its undo history. The document exists only once the image
/// is loaded: an edit never exists without its image.
@MainActor
@Observable
final class DemoDocumentStore {

  /// The edited document; nil until the image is loaded.
  var document: ImageEditorDocument?

  private(set) var loadingError: String?

  @ObservationIgnored
  private let loadImage: @Sendable () async throws -> SourceImage

  @ObservationIgnored
  private let initialCrop: InitialCrop

  /// A store over an image that loads asynchronously, such as a download.
  init(
    loading loadImage: @escaping @Sendable () async throws -> SourceImage,
    initialCrop: InitialCrop = .fullImage
  ) {
    self.loadImage = loadImage
    self.initialCrop = initialCrop
  }

  /// A store over an image that is already available.
  convenience init(image: SourceImage, initialCrop: InitialCrop = .fullImage) {
    self.init(loading: { image }, initialCrop: initialCrop)
  }

  /// Loads the image and creates the document, once.
  func prepareDocument() async {
    guard document == nil else {
      return
    }
    do {
      let image = try await loadImage()
      let document = await EditingDocument(source: image, initialCrop: initialCrop)
      // Another call may have finished first while this one was suspended.
      if self.document == nil {
        self.document = document
      }
    } catch {
      loadingError = "\(error)"
    }
  }
}

struct DemoImageEditor: View {

  @ObjectEdge private var store: DemoDocumentStore
  @Environment(\.dismiss) private var dismiss

  @State var resultImage: ResultImage?

  private let options: ImageEditor.Options

  /// Edits a long-lived store; reopening shows its previous edit.
  @MainActor
  init(
    store: DemoDocumentStore,
    options: ImageEditor.Options = .demo()
  ) {
    self._store = .init(wrappedValue: store)
    self.options = options
  }

  /// Edits a new document from scratch, created once for the view's identity.
  @MainActor
  init(
    image: @escaping () -> SourceImage,
    initialCrop: InitialCrop = .fullImage,
    options: ImageEditor.Options = .demo()
  ) {
    self._store = .init(
      wrappedValue: DemoDocumentStore(image: image(), initialCrop: initialCrop)
    )
    self.options = options
  }

  var body: some View {
    @Bindable var store = store

    Group {
      // The editor takes a non-optional binding: show it once the document
      // exists. The store never sets it back to nil.
      if let document = Binding($store.document) {
        ImageEditor(
          document: document,
          options: options,
          onDone: {
            export(document.wrappedValue)
          },
          onCancel: {
            // The editor already restored the document it opened with.
            dismiss()
          }
        )
      } else if let loadingError = store.loadingError {
        Text(loadingError)
      } else {
        ProgressView()
      }
    }
    .task {
      await store.prepareDocument()
    }
    .sheet(item: $resultImage) {
      RenderedResultView(result: $0)
    }
  }

  private func export(_ document: ImageEditorDocument) {
    // Export straight to disk with bounded memory (strip render into an
    // mmap'd buffer + lazy-paged encode — see CIImageStreamingFileWriter),
    // then preview from a DOWNSAMPLED decode so the read-back doesn't
    // re-spike to the full resolution.
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("brightroom-export-\(UUID().uuidString)")
      .appendingPathExtension("heic")
    Task {
      do {
        let rendered = try await document.render(
          options: .init(output: .file(url: url, fileType: .heif(quality: 0.9)))
        )
        let cgImage = try rendered.thumbnail(maxPixelSize: 2048)
        // Keep the feature that produced this render so the result screen
        // can show its tree.
        self.resultImage = .init(cgImage: cgImage, feature: document.feature)
      } catch {
        assertionFailure("\(error)")
      }
    }
  }
}

private extension ImageEditor.Options {
  /// Creates demo options with the sample filters and the bundled LUTs.
  static func demo() -> Self {
    var options = Self()
    options.filters = DemoFilters.make() + DemoLUTs.bundled
    return options
  }

  static func fixedAspectRatio(_ aspectRatio: AspectRatio) -> Self {
    var options = Self.demo()
    options.aspectRatioPolicy = .fixed(aspectRatio)
    return options
  }
}

#Preview {
  ContentView()
}
