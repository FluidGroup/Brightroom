import BrightroomEngine
import BrightroomUI
import PhotosUI
import SwiftUI
import UIKit

struct ContentView: View {

  @State private var fullScreenView: FullscreenIdentifiableView?

  @State var horizontalStack = Mocks.makeEditingStack(image: Mocks.imageHorizontal())
  @State var verticalStack = Mocks.makeEditingStack(image: Mocks.imageVertical())
  @State private var photosCropHorizontalStack = Mocks.makeEditingStack(
    image: Asset.horizontalRect.image
  )
  @State private var photosCropVerticalStack = Mocks.makeEditingStack(
    image: Asset.verticalRect.image
  )
  @State private var photosCropSquareStack = Mocks.makeEditingStack(
    image: Asset.squareRect.image
  )
  @State private var photosCropNasaStack = Mocks.makeEditingStack(
    fileURL: Bundle.main.path(forResource: "nasa", ofType: "jpg").map {
      URL(fileURLWithPath: $0)
    }!
  )
  @State private var photosCropSuperSmallStack = Mocks.makeEditingStack(
    image: Asset.superSmall.image
  )
  @State private var photosCropRemoteStack = EditingStack(
    imageProvider: .init(
      editableRemoteURL: URL(
        string:
          "https://images.unsplash.com/photo-1604456930969-37f67bcd6e1e?ixid=MXwxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHw%3D&ixlib=rb-1.2.1"
      )!
    )
  )
  @State private var photosCropRemotePreviewStack = EditingStack(
    imageProvider: .init(
      editableRemoteURL: URL(
        string:
          "https://images.unsplash.com/photo-1597522781074-9a05ab90638e?ixlib=rb-1.2.1&ixid=MXwxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHw%3D"
      )!
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

          NavigationLink("Custom Filter") {
            DemoFilterView(editingStack: horizontalStack)
          }

          NavigationLink("Rendering") {
            RenderingDemoView()
          }

          Section("Restoration Horizontal") {
            Button("Masking") {
              fullScreenView = .init {
                DemoMaskingView {
                  horizontalStack
                }
              }
            }
          }

          Section("Restoration Vertical") {
            Button("Masking") {
              fullScreenView = .init {
                DemoMaskingView {
                  verticalStack
                }
              }
            }
          }

          Section(
            "PhotosCrop FaceDetection",
            content: {
              Button("Horizontal 1") {
                fullScreenView = .init(showsDismissButton: false) {
                  let stack = Mocks.makeEditingStack(
                    image: Asset.horizontalRect.image
                  )
                  stack.cropModifier = .faceDetection(aspectRatio: .square)
                  return DemoPhotosCropView(stack: stack)
                }
              }

              Button("Horizontal 2") {
                fullScreenView = .init(showsDismissButton: false) {
                  let stack = Mocks.makeEditingStack(
                    image: Asset.horizontalRect.image
                  )
                  stack.cropModifier = .faceDetection(aspectRatio: .square)
                  return DemoPhotosCropView(
                    stack: stack,
                    options: .fixedAspectRatio(.square)
                  )
                }
              }

            }
          )

          Section("Blur Masking") {
            Button("Local") {
              fullScreenView = .init {
                DemoMaskingView {
                  Mocks.makeEditingStack(
                    image: Asset.horizontalRect.image
                  )
                }
              }
            }

            Button("Remote") {
              fullScreenView = .init {
                DemoMaskingView {
                  EditingStack(
                    imageProvider: .init(
                      editableRemoteURL: URL(
                        string:
                          "https://images.unsplash.com/photo-1604456930969-37f67bcd6e1e?ixid=MXwxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHw%3D&ixlib=rb-1.2.1"
                      )!
                    )
                  )
                }
              }
            }
          }

          Section(
            "PhotosCrop",
            content: {
              Button("Horizontal") {
                fullScreenView = .init(showsDismissButton: false) {
                  DemoPhotosCropView(stack: photosCropHorizontalStack)
                }
              }

              Button("Vertical") {
                fullScreenView = .init(showsDismissButton: false) {
                  DemoPhotosCropView(stack: photosCropVerticalStack)
                }
              }

              Button("Square") {
                fullScreenView = .init(showsDismissButton: false) {
                  DemoPhotosCropView(stack: photosCropSquareStack)
                }
              }

              Button("Nasa") {
                fullScreenView = .init(showsDismissButton: false) {
                  DemoPhotosCropView(stack: photosCropNasaStack)
                }
              }

              Button("Super small") {
                fullScreenView = .init(showsDismissButton: false) {
                  DemoPhotosCropView(stack: photosCropSuperSmallStack)
                }
              }

              Button("Remote") {

                fullScreenView = .init(showsDismissButton: false) {
                  DemoPhotosCropView(stack: photosCropRemoteStack)
                }
              }

              Button("Remote - preview") {

                fullScreenView = .init(showsDismissButton: false) {
                  DemoPhotosCropView(stack: photosCropRemotePreviewStack)
                }
              }
            }
          )

          Section(content: {
            Button("PixelEditor Square") {
              fullScreenView = .init {
                DemoPixelEditor(editingStack: {
                  EditingStack.init(
                    imageProvider: .init(image: Asset.l1000316.image),
                    cropModifier: .init { _, crop, completion in
                      var new = crop
                      new.updateCropExtent(toFitAspectRatio: .square)
                      completion(new)
                    }
                  )
                })
              }
            }

            Button("PixelEditor") {
              fullScreenView = .init {
                DemoPixelEditor(
                  editingStack: {
                    EditingStack.init(
                      imageProvider: .init(image: Asset.l1000316.image)
                    )
                  },
                  options: .init(croppingAspectRatio: nil)
                )
              }
            }

            Button("PixelEditor 4:5") {
              fullScreenView = .init {
                DemoPixelEditor(
                  editingStack: {
                    EditingStack.init(
                      imageProvider: .init(image: Asset.l1000316.image)
                    )
                  },
                  options: .init(croppingAspectRatio: .init(width: 4, height: 5))
                )
              }
            }

            Button("PixelEditor 5:4") {
              fullScreenView = .init {
                DemoPixelEditor(
                  editingStack: {
                    EditingStack.init(
                      imageProvider: .init(image: Asset.l1000316.image)
                    )
                  },
                  options: .init(croppingAspectRatio: .init(width: 5, height: 4))
                )
              }
            }

            Button("PixelEditor left") {
              fullScreenView = .init {
                DemoPixelEditor(
                  editingStack: {
                    EditingStack.init(
                      imageProvider: .init(image: Mocks.imageOrientationLeft())
                    )
                  },
                  options: .init(croppingAspectRatio: nil)
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
  @State private var selectedPhotosCropStack: EditingStack?
  @State private var loadingMessage: String?
  @State private var fullScreenView: FullscreenIdentifiableView?

  var body: some View {

    Form {
      PhotosPicker("Select", selection: $item, matching: .images)

      if let selectedImage {
        Section("Selected Photo") {
          PickedImageSummary(image: selectedImage)
        }

        Section("Components") {
          Button("Masking") {
            fullScreenView = .init {
              DemoMaskingView {
                selectedImage.makeEditingStack()
              }
            }
          }
        }

        Section("BuiltIn") {
          Button("PhotosCrop") {
            let stack = photosCropStack(for: selectedImage)
            fullScreenView = .init(showsDismissButton: false) {
              DemoPhotosCropView(stack: stack)
            }
          }

          Button("PixelEditor") {
            fullScreenView = .init {
              DemoPixelEditor(editingStack: {
                selectedImage.makeEditingStack()
              }, options: .init(croppingAspectRatio: nil))
            }
          }

          Button("PixelEditor Square") {
            fullScreenView = .init {
              DemoPixelEditor(editingStack: {
                selectedImage.makeEditingStack()
              }, options: .init(croppingAspectRatio: .square))
            }
          }

          Button("PixelEditor 4:5") {
            fullScreenView = .init {
              DemoPixelEditor(editingStack: {
                selectedImage.makeEditingStack()
              }, options: .init(croppingAspectRatio: .init(width: 4, height: 5)))
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
      selectedPhotosCropStack = nil
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

  private func photosCropStack(for image: PickedDemoImage) -> EditingStack {
    if let selectedPhotosCropStack {
      return selectedPhotosCropStack
    }

    let stack = image.makeEditingStack()
    selectedPhotosCropStack = stack
    return stack
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

struct DemoPhotosCropView: View {

  @ObjectEdge var stack: EditingStack
  @Environment(\.dismiss) private var dismiss

  @State var resultImage: ResultImage?
  private let options: SwiftUIPhotosCropView.Options

  init(
    stack: EditingStack,
    options: SwiftUIPhotosCropView.Options = .init()
  ) {
    self._stack = .init(wrappedValue: stack)
    self.options = options
  }

  init(
    stack: @escaping () -> EditingStack,
    options: SwiftUIPhotosCropView.Options = .init()
  ) {
    self._stack = .init(wrappedValue: stack())
    self.options = options
  }

  var body: some View {

    SwiftUIPhotosCropView(
      editingStack: stack,
      options: options,
      onDone: {
        let image = try! stack.makeRenderer().render().cgImage
        self.resultImage = .init(cgImage: image)
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
  static func fixedAspectRatio(_ aspectRatio: PixelAspectRatio?) -> Self {
    var options = Self()
    options.aspectRatioOptions = .fixed(aspectRatio)
    return options
  }
}

struct DemoPixelEditor: View {

  @Environment(\.dismiss) private var dismiss

  @ObjectEdge var editingStack: EditingStack
  @State var resultImage: ResultImage?

  let options: PixelEditorOptions

  init(
    editingStack: @escaping () -> EditingStack,
    options: PixelEditorOptions = .init()
  ) {
    self._editingStack = .init(wrappedValue: editingStack())
    self.options = options
  }

  var body: some View {
    SwiftUIPixelEditorView(
      editingStack: editingStack,
      options: options,
      onEndEditing: { editingStack in
        let image = try! editingStack.makeRenderer().render().cgImage
        self.resultImage = .init(cgImage: image)
      },
      onCancelEditing: {
        dismiss()
      }
    )
    .sheet(item: $resultImage) {
      RenderedResultView(result: $0)
    }
  }
}

#Preview {
  ContentView()
}
