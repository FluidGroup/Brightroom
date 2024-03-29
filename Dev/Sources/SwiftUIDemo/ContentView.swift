import BrightroomEngine
import BrightroomUI
import PhotosUI
import SwiftUI

struct ContentView: View {

  @State private var fullScreenView: FullscreenIdentifiableView?

  @State var horizontalStack = Mocks.makeEditingStack(image: Mocks.imageHorizontal())
  @State var verticalStack = Mocks.makeEditingStack(image: Mocks.imageVertical())

  var body: some View {
    NavigationView {
      VStack {

        Form {

          NavigationLink("ImagePreviewView") {
            DemoCropView2(editingStack: {
              horizontalStack
            })
          }

          NavigationLink("Isolated", destination: IsolatedEditinView())

          if #available(iOS 16, *) {
            NavigationLink("Pick image") {
              WorkingOnPicked()
            }
          }

          Section("Restoration Horizontal") {
            Button("Crop") {
              fullScreenView = .init {
                DemoCropView(editingStack: { horizontalStack })
              }
            }

            Button("Masking") {
              fullScreenView = .init {
                DemoMaskingView {
                  horizontalStack
                }
              }
            }
          }

          Section("Restoration Vertical") {
            Button("Crop") {
              fullScreenView = .init {
                DemoCropView(editingStack: { verticalStack })
              }
            }

            Button("Masking") {
              fullScreenView = .init {
                DemoMaskingView {
                  verticalStack
                }
              }
            }
          }

          Section("Crop") {

            Button("Local") {
              fullScreenView = .init {
                DemoCropView(
                  editingStack: { Mocks.makeEditingStack(image: Mocks.imageHorizontal()) }
                )
              }
            }
          }

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
                fullScreenView = .init {
                  DemoPhotosCropView(stack: {
                    Mocks.makeEditingStack(
                      image: Asset.horizontalRect.image
                    )
                  })
                }
              }

              Button("Vertical") {
                fullScreenView = .init {
                  DemoPhotosCropView(stack: {
                    Mocks.makeEditingStack(
                      image: Asset.verticalRect.image
                    )
                  })
                }
              }

              Button("Square") {
                fullScreenView = .init {
                  DemoPhotosCropView(stack: {
                    Mocks.makeEditingStack(
                      image: Asset.squareRect.image
                    )
                  })
                }
              }

              Button("Nasa") {
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

              Button("Super small") {
                fullScreenView = .init {
                  DemoPhotosCropView(stack: {
                    Mocks.makeEditingStack(
                      image: Asset.superSmall.image
                    )
                  })
                }
              }

              Button("Remote") {

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

              Button("Remote - preview") {

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

          Section("Lab") {
            NavigationLink("Rotating", destination: BookRotateScrollView())
          }
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
    }
    .onAppear(perform: {
      try? PresetStorage.default.loadLUTs()
    })
  }
}

@available(iOS 16, *)
struct WorkingOnPicked: View {

  @State private var item: PhotosPickerItem?
  @State private var editingStack: EditingStack?
  @State private var fullScreenView: FullscreenIdentifiableView?

  var body: some View {

    Form {
      PhotosPicker("Select", selection: $item)

      if let stack = editingStack {
        Section("Components") {

          Button("Crop") {
            fullScreenView = .init {
              DemoCropView(editingStack: { stack })
            }
          }

          Button("Masking") {
            fullScreenView = .init {
              DemoMaskingView {
                stack
              }
            }
          }
        }

        Section("BuiltIn") {
          Button("PhotosCrop") {
            fullScreenView = .init {
              DemoPhotosCropView(stack: {
                Mocks.makeEditingStack(
                  image: Asset.horizontalRect.image
                )
              })
            }
          }

          Button("ClassicEditor") {
            fullScreenView = .init {
              DemoPixelEditor(editingStack: {
                stack
              })
            }
          }
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
      guard let value else { return }

      Task {

        do {
          guard let transferable = try await value.loadTransferable(type: Data.self) else {
            print("Error: no transferable found.")
            return
          }

          let stack = EditingStack(imageProvider: try .init(data: transferable))

          self.editingStack = stack

        } catch {
          print("Error: \(error)")
        }

      }
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

  let options: ClassicImageEditOptions

  init(
    editingStack: @escaping () -> EditingStack,
    options: ClassicImageEditOptions = .init()
  ) {
    self._editingStack = .init(wrappedValue: editingStack())
    self.options = options
  }

  var body: some View {
    DemoPixelEditWrapper(
      editingStack: editingStack,
      options: options,

      onCompleted: {
        let image = try! editingStack.makeRenderer().render().cgImage
        self.resultImage = .init(cgImage: image)
      }
    )
    .sheet(item: $resultImage) {
      RenderedResultView(result: $0)
    }
  }
}

struct DemoPixelEditWrapper: UIViewControllerRepresentable {

  typealias UIViewControllerType = UINavigationController

  private let onCompleted: () -> Void

  let editingStack: EditingStack
  let options: ClassicImageEditOptions

  init(
    editingStack: EditingStack,
    options: ClassicImageEditOptions,
    onCompleted: @escaping () -> Void
  ) {
    self.editingStack = editingStack
    self.onCompleted = onCompleted
    self.options = options
  }

  func makeUIViewController(context: Context) -> UINavigationController {
    editingStack.start()
    let cropViewController = ClassicImageEditViewController(
      editingStack: editingStack,
      options: options
    )
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
