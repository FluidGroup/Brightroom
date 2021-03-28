
import BrightroomUI
import SwiftUI

struct ContentView: View {
  @State private var image: SwiftUI.Image?

  @State private var sharedStack = Mocks.makeEditingStack(image: Mocks.imageHorizontal())
  @State private var fullScreenView: FullscreenIdentifiableView?

  @State private var stackForHorizontal: EditingStack = Mocks.makeEditingStack(image: Asset.horizontalRect.image)
  @State private var stackForVertical: EditingStack = Mocks.makeEditingStack(image: Asset.verticalRect.image)
  @State private var stackForSquare: EditingStack = Mocks.makeEditingStack(image: Asset.squareRect.image)
  @State private var stackForNasa: EditingStack = Mocks.makeEditingStack(
    fileURL:
    Bundle.main.path(
      forResource: "nasa",
      ofType: "jpg"
    ).map {
      URL(fileURLWithPath: $0)
    }!
  )
  @State private var stackForSmall: EditingStack = Mocks.makeEditingStack(image: Asset.superSmall.image)

  var body: some View {
    NavigationView {
      VStack {
        Group {
          if let image = image {
            image
              .resizable()
              .aspectRatio(contentMode: .fit)
          } else {
            Color.gray
          }
        }
        .frame(width: 120, height: 120, alignment: .center)
        Form {
          NavigationLink("Isolated", destination: IsolatedEditinView())

          Button("Component: Crop") {
            fullScreenView = .init { DemoCropView(editingStack: sharedStack) }
          }

          Section(content: {
            Button("Crop: Horizontal") {
              fullScreenView = .init {
                SwiftUIPhotosCropView(editingStack: stackForHorizontal, onCompleted: {
                  self.image = try! stackForHorizontal.makeRenderer().render().swiftUIImageDisplayP3
                  self.fullScreenView = nil
                })
              }
            }

            Button("Crop: Vertical") {
              fullScreenView = .init {
                SwiftUIPhotosCropView(editingStack: stackForVertical, onCompleted: {
                  self.image = try! stackForVertical.makeRenderer().render().swiftUIImageDisplayP3
                  self.fullScreenView = nil
                })
              }
            }

            Button("Crop: Square") {
              fullScreenView = .init {
                SwiftUIPhotosCropView(editingStack: stackForSquare, onCompleted: {
                  self.image = try! stackForSquare.makeRenderer().render().swiftUIImageDisplayP3
                  self.fullScreenView = nil
                })
              }
            }

            Button("Crop: Nasa") {
              fullScreenView = .init {
                SwiftUIPhotosCropView(editingStack: stackForNasa, onCompleted: {
                  self.image = try! stackForNasa.makeRenderer().render().swiftUIImageDisplayP3
                  self.fullScreenView = nil
                })
              }
            }

            Button("Crop: Super small") {
              fullScreenView = .init {
                SwiftUIPhotosCropView(editingStack: stackForSmall, onCompleted: {
                  self.image = try! stackForSmall.makeRenderer().render().swiftUIImageDisplayP3
                  self.fullScreenView = nil
                })
              }
            }

            Button("Crop: Remote") {
              let stack = EditingStack(
                imageProvider: .init(
                  editableRemoteURL: URL(string: "https://images.unsplash.com/photo-1604456930969-37f67bcd6e1e?ixid=MXwxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHw%3D&ixlib=rb-1.2.1")!
                )
              )

              fullScreenView = .init {
                SwiftUIPhotosCropView(editingStack: stack, onCompleted: {
                  self.image = try! stack.makeRenderer().render().swiftUIImageDisplayP3
                  self.fullScreenView = nil
                })
              }
            }

            Button("Crop: Remote - preview") {
              let stack = EditingStack(
                imageProvider: .init(
                  editableRemoteURL: URL(string: "https://images.unsplash.com/photo-1597522781074-9a05ab90638e?ixlib=rb-1.2.1&ixid=MXwxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHw%3D")!
                )
              )

              fullScreenView = .init {
                SwiftUIPhotosCropView(editingStack: stack, onCompleted: {
                  self.image = try! stack.makeRenderer().render().swiftUIImageDisplayP3
                  self.fullScreenView = nil
                })
              }
            }
          })

          Section(content: {
            Button("PixelEditor Square") {
              let stack = EditingStack.init(
                imageProvider: .init(image: Asset.l1000316.image),
                cropModifier: .init { _, crop, completion in
                  var new = crop
                  new.updateCropExtent(by: .square)
                  completion(new)
                }
              )
              fullScreenView = .init {
                PixelEditWrapper(editingStack: stack) {
                  self.image = try! stackForHorizontal.makeRenderer().render().swiftUIImageDisplayP3
                  self.fullScreenView = nil
                }
              }
            }

            Button("PixelEditor") {
              let stack = EditingStack.init(
                imageProvider: .init(image: Asset.l1000316.image)
              )
              fullScreenView = .init {
                PixelEditWrapper(editingStack: stack) {
                  self.image = try! stackForHorizontal.makeRenderer().render().swiftUIImageDisplayP3
                  self.fullScreenView = nil
                }
              }
            }
          })
        }
      }
      .navigationTitle("Pixel")
      .fullScreenCover(
        item: $fullScreenView,
        onDismiss: {}, content: {
          $0
        }
      )
    }
    .onAppear(perform: {
      ColorCubeStorage.loadToDefault()
    })
  }
}

import BrightroomUI
import BrightroomEngine

struct PixelEditWrapper: UIViewControllerRepresentable {
  typealias UIViewControllerType = UINavigationController

  private let editingStack: EditingStack
  private let onCompleted: () -> Void

  init(editingStack: EditingStack, onCompleted: @escaping () -> Void) {
    self.editingStack = editingStack
    self.onCompleted = onCompleted
    editingStack.start()
  }

  func makeUIViewController(context: Context) -> UINavigationController {
    let cropViewController = ClassicImageEditViewController(editingStack: editingStack)
    cropViewController.handlers.didEndEditing = { _, _ in
      onCompleted()
    }
    return UINavigationController(rootViewController: cropViewController)
  }

  func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
}

var _loaded = false
extension ColorCubeStorage {
  static func loadToDefault() {
    guard _loaded == false else {
      return
    }
    _loaded = true

    do {
      let loader = ColorCubeLoader(bundle: .main)
      self.default.filters = try loader.load()

    } catch {
      assertionFailure("\(error)")
    }
  }
}
