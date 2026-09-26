import BrightroomEngine
import BrightroomParametric
import BrightroomUI
import PhotosUI
import SwiftUI
import UIKit

struct ContentView: View {

  @State private var fullScreenView: FullscreenIdentifiableView?

  @State var verticalStack = Mocks.makeEditingStack(image: Mocks.imageVertical())

  // Each editor keeps its stack and its editing model together, so reopening
  // an editor shows the previous edit.
  @State private var photosCropHorizontal = DemoPhotosCropSession(
    stack: Mocks.makeEditingStack(image: Asset.horizontalRect.image)
  )
  @State private var photosCropVertical = DemoPhotosCropSession(
    stack: Mocks.makeEditingStack(image: Asset.verticalRect.image)
  )
  @State private var photosCropSquare = DemoPhotosCropSession(
    stack: Mocks.makeEditingStack(image: Asset.squareRect.image)
  )
  @State private var photosCropNasa = DemoPhotosCropSession(
    stack: Mocks.makeEditingStack(
      fileURL: Bundle.main.path(forResource: "nasa", ofType: "jpg").map {
        URL(fileURLWithPath: $0)
      }!
    )
  )
  @State private var photosCropSuperSmall = DemoPhotosCropSession(
    stack: Mocks.makeEditingStack(image: Asset.superSmall.image)
  )
  @State private var photosCropInstaLogo = DemoPhotosCropSession(
    stack: Mocks.makeEditingStack(image: Asset.instaLogo.image)
  )
  @State private var photosCropRemote = DemoPhotosCropSession(
    stack: EditingStack(
      imageProvider: .init(
        editableRemoteURL: URL(
          string:
            "https://images.unsplash.com/photo-1604456930969-37f67bcd6e1e?ixid=MXwxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHw%3D&ixlib=rb-1.2.1"
        )!
      )
    )
  )
  @State private var photosCropRemotePreview = DemoPhotosCropSession(
    stack: EditingStack(
      imageProvider: .init(
        editableRemoteURL: URL(
          string:
            "https://images.unsplash.com/photo-1597522781074-9a05ab90638e?ixlib=rb-1.2.1&ixid=MXwxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHw%3D"
        )!
      )
    )
  )

  var body: some View {
    NavigationSplitView {
      VStack {

        Form {

          NavigationLink("Isolated", destination: IsolatedEditinView())

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
            "PhotosCrop FaceDetection",
            content: {
              Button("Horizontal 1") {
                fullScreenView = .init(showsDismissButton: false) {
                  DemoPhotosCropView(
                    stack: {
                      Mocks.makeEditingStack(image: Asset.horizontalRect.image)
                    },
                    cropModifier: .faceDetection(aspectRatio: .square)
                  )
                }
              }

              Button("Horizontal 2") {
                fullScreenView = .init(showsDismissButton: false) {
                  DemoPhotosCropView(
                    stack: {
                      Mocks.makeEditingStack(image: Asset.horizontalRect.image)
                    },
                    cropModifier: .faceDetection(aspectRatio: .square),
                    options: .fixedAspectRatio(.square)
                  )
                }
              }

            }
          )

          Section(
            "PhotosCrop",
            content: {
              Button("Horizontal") {
                fullScreenView = .init(showsDismissButton: false) {
                  DemoPhotosCropView(session: photosCropHorizontal)
                }
              }

              Button("Vertical") {
                fullScreenView = .init(showsDismissButton: false) {
                  DemoPhotosCropView(session: photosCropVertical)
                }
              }

              Button("Square") {
                fullScreenView = .init(showsDismissButton: false) {
                  DemoPhotosCropView(session: photosCropSquare)
                }
              }

              Button("Nasa") {
                fullScreenView = .init(showsDismissButton: false) {
                  DemoPhotosCropView(session: photosCropNasa)
                }
              }

              Button("Super small") {
                fullScreenView = .init(showsDismissButton: false) {
                  DemoPhotosCropView(session: photosCropSuperSmall)
                }
              }

              Button("Insta Logo") {
                fullScreenView = .init(showsDismissButton: false) {
                  DemoPhotosCropView(session: photosCropInstaLogo)
                }
              }

              Button("Remote") {

                fullScreenView = .init(showsDismissButton: false) {
                  DemoPhotosCropView(session: photosCropRemote)
                }
              }

              Button("Remote - preview") {

                fullScreenView = .init(showsDismissButton: false) {
                  DemoPhotosCropView(session: photosCropRemotePreview)
                }
              }
            }
          )

          Section(content: {
            Button("PhotosCrop Square (modifier)") {
              fullScreenView = .init(showsDismissButton: false) {
                DemoPhotosCropView(
                  stack: {
                    EditingStack.init(
                      imageProvider: .init(image: Asset.l1000316.image)
                    )
                  },
                  cropModifier: CropModifier { _, crop in
                    var crop = crop
                    crop.updateCropExtent(toFitAspectRatio: .square)
                    return crop
                  },
                  options: .fixedAspectRatio(.square)
                )
              }
            }

            Button("PhotosCrop 4:5") {
              fullScreenView = .init(showsDismissButton: false) {
                DemoPhotosCropView(
                  stack: {
                    EditingStack.init(
                      imageProvider: .init(image: Asset.l1000316.image)
                    )
                  },
                  options: .fixedAspectRatio(.init(width: 4, height: 5))
                )
              }
            }

            Button("PhotosCrop 5:4") {
              fullScreenView = .init(showsDismissButton: false) {
                DemoPhotosCropView(
                  stack: {
                    EditingStack.init(
                      imageProvider: .init(image: Asset.l1000316.image)
                    )
                  },
                  options: .fixedAspectRatio(.init(width: 5, height: 4))
                )
              }
            }

            Button("PhotosCrop left") {
              fullScreenView = .init(showsDismissButton: false) {
                DemoPhotosCropView(
                  stack: {
                    EditingStack.init(
                      imageProvider: .init(image: Mocks.imageOrientationLeft())
                    )
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
    .onAppear(perform: {
      try? PresetStorage.default.loadLUTs()
    })
  }
}

@available(iOS 16, *)
struct WorkingOnPicked: View {

  @State private var item: PhotosPickerItem?
  @State private var selectedImage: PickedDemoImage?
  @State private var selectedPhotosCropSession: DemoPhotosCropSession?
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
          Button("PhotosCrop") {
            let session = photosCropSession(for: selectedImage)
            fullScreenView = .init(showsDismissButton: false) {
              DemoPhotosCropView(session: session)
            }
          }

          Button("PhotosCrop Square") {
            fullScreenView = .init(showsDismissButton: false) {
              DemoPhotosCropView(stack: {
                selectedImage.makeEditingStack()
              }, options: .fixedAspectRatio(.square))
            }
          }

          Button("PhotosCrop 4:5") {
            fullScreenView = .init(showsDismissButton: false) {
              DemoPhotosCropView(stack: {
                selectedImage.makeEditingStack()
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
      selectedPhotosCropSession = nil
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

  private func photosCropSession(for image: PickedDemoImage) -> DemoPhotosCropSession {
    if let selectedPhotosCropSession {
      return selectedPhotosCropSession
    }

    let session = DemoPhotosCropSession(stack: image.makeEditingStack())
    selectedPhotosCropSession = session
    return session
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

  func makeEditingStack() -> EditingStack {
    EditingStack(imageProvider: try! .init(data: data))
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

/// The model that owns an editing stack's document and history.
///
/// The model is stateful, so a demo that reopens an editor on the same image
/// keeps the session (not just the stack) to show the previous edit.
struct DemoPhotosCropSession {
  let editingModel: PhotosCropEditingModel

  @MainActor
  init(stack: EditingStack, cropModifier: CropModifier = .identity) {
    self.editingModel = PhotosCropEditingModel(
      editingStack: stack,
      cropModifier: cropModifier
    )
  }
}

struct DemoPhotosCropView: View {

  @ObjectEdge private var session: DemoPhotosCropSession
  @Environment(\.dismiss) private var dismiss

  @State var resultImage: ResultImage?
  private let options: SwiftUIPhotosCropView.Options

  /// Edits a long-lived session; reopening shows its previous edit.
  @MainActor
  init(
    session: DemoPhotosCropSession,
    options: SwiftUIPhotosCropView.Options = .demo()
  ) {
    self._session = .init(wrappedValue: session)
    self.options = options
  }

  /// Edits a new stack from scratch, created once for the view's identity.
  @MainActor
  init(
    stack: @escaping () -> EditingStack,
    cropModifier: CropModifier = .identity,
    options: SwiftUIPhotosCropView.Options = .demo()
  ) {
    self._session = .init(
      wrappedValue: DemoPhotosCropSession(stack: stack(), cropModifier: cropModifier)
    )
    self.options = options
  }

  var body: some View {

    SwiftUIPhotosCropView(
      editingModel: session.editingModel,
      options: options,
      onDone: { document in
        // Export straight to disk with bounded memory (strip render into an
        // mmap'd buffer + lazy-paged encode — see CIImageStreamingFileWriter),
        // then preview from a DOWNSAMPLED decode so the read-back doesn't
        // re-spike to the full resolution.
        let url = FileManager.default.temporaryDirectory
          .appendingPathComponent("brightroom-export-\(UUID().uuidString)")
          .appendingPathExtension("heic")
        let stack = session.editingModel.editingStack
        Task {
          do {
            let rendered = try await stack.makeRenderer(document: document).render(
              options: .init(output: .file(url: url, fileType: .heif(quality: 0.9)))
            )
            let cgImage = try rendered.thumbnail(maxPixelSize: 2048)
            await MainActor.run {
              // Keep the document that produced this render so the result
              // screen can show its features.
              self.resultImage = .init(cgImage: cgImage, document: document)
            }
          } catch {
            assertionFailure("\(error)")
          }
        }
      },
      onCancel: {
        dismiss()
      }
    )
    .sheet(item: $resultImage) {
      RenderedResultView(result: $0)
    }
  }
}

private extension SwiftUIPhotosCropView.Options {
  /// Creates demo options with the sample filter catalog explicitly supplied.
  static func demo() -> Self {
    var options = Self()
    options.filterPresets = PhotosCropDemoFilterPresets.make()
    return options
  }

  static func fixedAspectRatio(_ aspectRatio: PixelAspectRatio?) -> Self {
    var options = Self.demo()
    options.aspectRatioOptions = .fixed(aspectRatio)
    return options
  }
}

#Preview {
  ContentView()
}
