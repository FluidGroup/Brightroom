
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
            Button("Horizontal") {
              fullScreenView = .init {
                CropViewControllerWrapper(editingStack: stackForHorizontal, onCompleted: {
                  self.image = SwiftUI.Image.init(uiImage: stackForHorizontal.makeRenderer().render())
                  self.fullScreenView = nil
                })
              }
            }

            Button("Vertical") {
              fullScreenView = .init {
                CropViewControllerWrapper(editingStack: stackForVertical, onCompleted: {
                  self.image = SwiftUI.Image.init(uiImage: stackForVertical.makeRenderer().render())
                  self.fullScreenView = nil
                })
              }
            }

            Button("Square") {
              fullScreenView = .init {
                CropViewControllerWrapper(editingStack: stackForSquare, onCompleted: {
                  self.image = SwiftUI.Image.init(uiImage: stackForSquare.makeRenderer().render())
                  self.fullScreenView = nil
                })
              }
            }

            Button("Nasa") {
              fullScreenView = .init {
                CropViewControllerWrapper(editingStack: stackForNasa, onCompleted: {
                  self.image = SwiftUI.Image.init(uiImage: stackForNasa.makeRenderer().render())
                  self.fullScreenView = nil
                })
              }
            }

            Button("Super small") {
              fullScreenView = .init {
                CropViewControllerWrapper(editingStack: stackForSmall, onCompleted: {
                  self.image = SwiftUI.Image.init(uiImage: stackForSmall.makeRenderer().render())
                  self.fullScreenView = nil
                })
              }
            }

            Button("Remote") {
              let stack = EditingStack(
                imageProvider: .init(
                  editableRemoteURL: URL(string: "https://images.unsplash.com/photo-1604456930969-37f67bcd6e1e?ixid=MXwxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHw%3D&ixlib=rb-1.2.1")!,
                  imageSize: .init(width: 4025, height: 6037)
                ),
                previewMaxPixelSize: 1000
              )

              fullScreenView = .init {
                CropViewControllerWrapper(editingStack: stack, onCompleted: {
                  self.image = SwiftUI.Image.init(uiImage: stack.makeRenderer().render())
                  self.fullScreenView = nil
                })
              }
            }

            Button("Remote - preview") {
              let stack = EditingStack(
                imageProvider: .init(
                  previewRemoteURL: URL(string: "https://images.unsplash.com/photo-1597522781074-9a05ab90638e?ixlib=rb-1.2.1&ixid=MXwxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHw%3D&auto=format&fit=crop&w=125&q=80")!,
                  editableRemoteURL: URL(string: "https://images.unsplash.com/photo-1597522781074-9a05ab90638e?ixlib=rb-1.2.1&ixid=MXwxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHw%3D")!,
                  imageSize: .init(width: 4980, height: 3984)
                ),
                previewMaxPixelSize: 1000
              )

              fullScreenView = .init {
                CropViewControllerWrapper(editingStack: stack, onCompleted: {
                  self.image = SwiftUI.Image.init(uiImage: stack.makeRenderer().render())
                  self.fullScreenView = nil
                })
              }
            }
          })

          Section(content: {
            Button("PixelEditor Square") {
              let stack = EditingStack.init(
                imageProvider: .init(image: Asset.l1000316.image),
                previewMaxPixelSize: 400 * 2,
                modifyCrop: { _, crop in
                  crop.updateCropExtent(by: .square)
                }
              )
              fullScreenView = .init {
                PixelEditWrapper(editingStack: stack) {
                  self.image = SwiftUI.Image.init(uiImage: stack.makeRenderer().render())
                  self.fullScreenView = nil
                }
              }
            }

            Button("PixelEditor") {
              let stack = EditingStack.init(
                imageProvider: .init(image: Asset.l1000316.image),
                previewMaxPixelSize: 400 * 2
              )
              fullScreenView = .init {
                PixelEditWrapper(editingStack: stack) {
                  self.image = SwiftUI.Image.init(uiImage: stack.makeRenderer().render())
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

import PixelEditor
import PixelEngine


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
    let cropViewController = PixelEditViewController(viewModel: .init(editingStack: editingStack))
    cropViewController.callbacks.didEndEditing = { _, _ in
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
      try autoreleasepool {
        let bundle = Bundle.main
        let rootPath = bundle.bundlePath as NSString
        let fileList = try FileManager.default.contentsOfDirectory(atPath: rootPath as String)

        let filters = fileList
          .filter { $0.hasSuffix(".png") || $0.hasSuffix(".PNG") }
          .sorted()
          .map { path -> FilterColorCube in
            let url = URL(fileURLWithPath: rootPath.appendingPathComponent(path))
            let data = try! Data(contentsOf: url)
            let image = UIImage(data: data)!
            let name = path
              .replacingOccurrences(of: "LUT_", with: "")
              .replacingOccurrences(of: ".png", with: "")
              .replacingOccurrences(of: ".PNG", with: "")
            return FilterColorCube.init(
              name: name,
              identifier: path,
              lutImage: image,
              dimension: 64
            )
          }

        self.default.filters = filters
      }

    } catch {
      assertionFailure("\(error)")
    }
  }
}
