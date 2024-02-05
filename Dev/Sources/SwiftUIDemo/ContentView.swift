import BrightroomEngine
import BrightroomUI
import SwiftUI

struct ContentView: View {

  @State private var fullScreenView: FullscreenIdentifiableView?

  var body: some View {
    NavigationView {
      VStack {

        Form {
          NavigationLink("Isolated", destination: IsolatedEditinView())

          Section {

            Button("Component: Crop") {
              fullScreenView = .init {
                DemoCropView(
                  editingStack: Mocks.makeEditingStack(image: Mocks.imageHorizontal())
                )
              }
            }
          }

          Section(content: {
            Button("Crop: Horizontal") {
              fullScreenView = .init {
                DemoPhotosCropView(stack: {
                  Mocks.makeEditingStack(
                    image: Asset.horizontalRect.image
                  )
                })
              }
            }

            Button("Crop: Vertical") {
              fullScreenView = .init {
                DemoPhotosCropView(stack: {
                  Mocks.makeEditingStack(
                    image: Asset.verticalRect.image
                  )
                })
              }
            }

            Button("Crop: Square") {
              fullScreenView = .init {
                DemoPhotosCropView(stack: {
                  Mocks.makeEditingStack(
                    image: Asset.squareRect.image
                  )
                })
              }
            }

            Button("Crop: Nasa") {
              fullScreenView = .init {
                DemoPhotosCropView(stack: {
                  Mocks.makeEditingStack(
                    fileURL:
                      Bundle.main.path(
                        forResource: "nasa",
                        ofType: "jpg"
                      ).map {
                        URL(fileURLWithPath: $0)
                      }!
                  )
                })
              }
            }

            Button("Crop: Super small") {
              fullScreenView = .init {
                DemoPhotosCropView(stack: {
                  Mocks.makeEditingStack(
                    image: Asset.superSmall.image
                  )
                })
              }
            }

            Button("Crop: Remote") {

              fullScreenView = .init {

                DemoPhotosCropView(stack: {
                  EditingStack(
                    imageProvider: .init(
                      editableRemoteURL: URL(
                        string:
                          "https://images.unsplash.com/photo-1604456930969-37f67bcd6e1e?ixid=MXwxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHw%3D&ixlib=rb-1.2.1"
                      )!
                    )
                  )
                })

              }
            }

            Button("Crop: Remote - preview") {

              fullScreenView = .init {

                DemoPhotosCropView(stack: {
                  EditingStack(
                    imageProvider: .init(
                      editableRemoteURL: URL(
                        string:
                          "https://images.unsplash.com/photo-1597522781074-9a05ab90638e?ixlib=rb-1.2.1&ixid=MXwxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHw%3D"
                      )!
                    )
                  )
                })

              }
            }
          })

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
                DemoPixelEditor(editingStack: {
                  EditingStack.init(
                    imageProvider: .init(image: Asset.l1000316.image)
                  )
                })
              }
            }

          })

          Section("Lab") {
            NavigationLink("Rotating", destination: BookRotateScrollView())
          }
        }

      }
      .navigationTitle("Pixel")
      .fullScreenCover(
        item: $fullScreenView,
        onDismiss: {},
        content: {
          $0
        }
      )
    }
    .onAppear(perform: {
      try? PresetStorage.default.loadLUTs()
    })
  }
}

struct DemoPhotosCropView: View {

  @ObjectEdge var stack: EditingStack

  @State var resultImage: ResultImage?

  init(stack: @escaping () -> EditingStack) {
    self._stack = .init(wrappedValue: stack())
  }

  var body: some View {

    SwiftUIPhotosCropView(
      editingStack: stack,
      onDone: {
        let image = try! stack.makeRenderer().render().cgImage
        self.resultImage = .init(cgImage: image)
      },
      onCancel: {}
    )
    .sheet(item: $resultImage) {
      RenderedResultView(result: $0)
    }

  }

}

struct DemoPixelEditor: View {

  @ObjectEdge var editingStack: EditingStack
  @State var resultImage: ResultImage?

  init(editingStack: @escaping () -> EditingStack) {
    self._editingStack = .init(wrappedValue: editingStack())
  }

  var body: some View {
    DemoPixelEditWrapper(
      editingStack: editingStack,
      onCompleted: {
        let image = try! editingStack.makeRenderer().render().cgImage
        self.resultImage = .init(cgImage: image)
      }
    )
  }
}

struct DemoPixelEditWrapper: UIViewControllerRepresentable {

  typealias UIViewControllerType = UINavigationController

  private let onCompleted: () -> Void

  let editingStack: EditingStack

  @State var resultImage: ResultImage?

  init(editingStack: EditingStack, onCompleted: @escaping () -> Void) {
    self.editingStack = editingStack
    self.onCompleted = onCompleted
  }

  func makeUIViewController(context: Context) -> UINavigationController {
    editingStack.start()
    let cropViewController = ClassicImageEditViewController(editingStack: editingStack)
    cropViewController.handlers.didEndEditing = { _, _ in
      onCompleted()
    }
    return UINavigationController(rootViewController: cropViewController)
  }

  func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
}

#Preview {
  ContentView()
}
