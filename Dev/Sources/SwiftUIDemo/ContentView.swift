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

  private var nasaImageURL: URL {
    Bundle.main.url(forResource: "nasa", withExtension: "jpg")!
  }

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

          NavigationLink("Metal Brush Sandbox") {
            MetalBrushSandboxView()
          }

          NavigationLink("Parametric Features") {
            ParametricFeaturePreviewView()
          }

          NavigationLink("Parametric Video") {
            ParametricVideoRenderPlaygroundView()
          }
          NavigationLink("Metal Brush Sandbox NASA") {
            MetalBrushSandboxView(fileURL: nasaImageURL)
          }

          NavigationLink("Editing Canvas Crop Probe") {
            EditingCanvasCropProbeView()
          }

          NavigationLink("PencilKit Reference") {
            PencilKitReferenceSandboxView()
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
            Button("PhotosCrop Square (modifier)") {
              fullScreenView = .init(showsDismissButton: false) {
                DemoPhotosCropView(
                  stack: {
                    EditingStack.init(
                      imageProvider: .init(image: Asset.l1000316.image),
                      cropModifier: .init { _, crop, completion in
                        var new = crop
                        new.updateCropExtent(toFitAspectRatio: .square)
                        completion(new)
                      }
                    )
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

        Section("BuiltIn") {
          Button("PhotosCrop") {
            let stack = photosCropStack(for: selectedImage)
            fullScreenView = .init(showsDismissButton: false) {
              DemoPhotosCropView(stack: stack)
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
        // Rendering synchronously here would hang the main thread for the
        // full-resolution export; the async overload renders on the
        // renderer's serial queue and calls back on main.
        try! stack.makeRenderer().render { result in
          switch result {
          case .success(let rendered):
            self.resultImage = .init(cgImage: rendered.cgImage)
          case .failure(let error):
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
  static func fixedAspectRatio(_ aspectRatio: PixelAspectRatio?) -> Self {
    var options = Self()
    options.aspectRatioOptions = .fixed(aspectRatio)
    return options
  }
}

#Preview {
  ContentView()
}
