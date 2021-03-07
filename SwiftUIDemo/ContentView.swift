
import SwiftUI

struct ContentView: View {
  @State private var image: SwiftUI.Image?

  @State private var sharedStack = Mocks.makeEditingStack(image: Mocks.imageHorizontal())
  @State private var fullScreenView: FullscreenIdentifiableView?
  
  @State private var stackForHorizontal: EditingStack = Mocks.makeEditingStack(image: Asset.horizontalRect.image)
  @State private var stackForVertical: EditingStack = Mocks.makeEditingStack(image: Asset.verticalRect.image)
  @State private var stackForSquare: EditingStack = Mocks.makeEditingStack(image: Asset.squareRect.image)
  @State private var stackForSmall: EditingStack = Mocks.makeEditingStack(image: Asset.superSmall.image)

  var body: some View {
    NavigationView {
      VStack {
        if let image = image {
          image
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 300, height: 300, alignment: .center)
        } else {
          Color.gray.frame(width: 300, height: 300, alignment: .center)
        }
        Form {
          Button("Component: Crop") {
            fullScreenView = .init { DemoCropView(editingStack: sharedStack) }
          }

          Section(content: {
            Button("Horizontal") {
              fullScreenView = .init {
                CropViewWrapper(editingStack: stackForHorizontal, onCompleted: {
                  self.image = SwiftUI.Image.init(uiImage: stackForHorizontal.makeRenderer().render())
                  self.fullScreenView = nil
                })
              }
            }

            Button("Vertical") {
              fullScreenView = .init {
                CropViewWrapper(editingStack: stackForVertical, onCompleted: {
                  self.image = SwiftUI.Image.init(uiImage: stackForVertical.makeRenderer().render())
                  self.fullScreenView = nil
                })
              }
            }

            Button("Square") {
              fullScreenView = .init {
                CropViewWrapper(editingStack: stackForSquare, onCompleted: {
                  self.image = SwiftUI.Image.init(uiImage: stackForSquare.makeRenderer().render())
                  self.fullScreenView = nil
                })
              }
            }

            Button("Super small") {
              fullScreenView = .init {
                CropViewWrapper(editingStack: stackForSmall, onCompleted: {
                  self.image = SwiftUI.Image.init(uiImage: stackForSmall.makeRenderer().render())
                  self.fullScreenView = nil
                })
              }
            }

            Button("Remote") {
              let stack = EditingStack(
                source: .init(
                  url: URL(string: "https://images.unsplash.com/photo-1604456930969-37f67bcd6e1e?ixid=MXwxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHw%3D&ixlib=rb-1.2.1")!,
                  imageSize: .init(width: 4025, height: 6037)
                ),
                previewSize: .init(width: 1000, height: 1000)
              )

              fullScreenView = .init {
                CropViewWrapper(editingStack: stack, onCompleted: {
                  self.image = SwiftUI.Image.init(uiImage: stack.makeRenderer().render())
                  self.fullScreenView = nil
                })
              }
            }
          })
          
          Section(content: {
            
            Button("PixelEditor") {
              let stack = EditingStack.init(
                source: .init(image: Asset.l1000316.image),
                previewSize: CGSize(width: 600, height: 600),
                modifyCrop: { _, crop in
                  crop.updateCropExtent(by: .square)
                }
              )
              fullScreenView = .init {
                return PixelEditWrapper(editingStack: stack) {
                  self.image = SwiftUI.Image.init(uiImage: stack.makeRenderer().render())
                  self.fullScreenView = nil
                }
              }
            }
          })
        }
      }
      .fullScreenCover(
        item: $fullScreenView,
        onDismiss: {}, content: {
          $0
        }
      )
    }
  }
}

struct FullscreenIdentifiableView: View, Identifiable {
  @Environment(\.presentationMode) var presentationMode

  let id = UUID()
  private let content: AnyView

  init<Content: View>(content: () -> Content) {
    self.content = .init(content())
  }

  var body: some View {
    VStack {
      content
      Button("Dismiss") {
        presentationMode.wrappedValue.dismiss()
      }
      .padding(16)
    }
    .clipped()
  }
}

import PixelEditor
import PixelEngine

struct CropViewWrapper: UIViewControllerRepresentable {

  typealias UIViewControllerType = CropViewController

  private let editingStack: EditingStack
  private let onCompleted: () -> Void

  init(editingStack: EditingStack, onCompleted: @escaping () -> Void) {
    self.editingStack = editingStack
    self.onCompleted = onCompleted
    editingStack.start()
  }

  func makeUIViewController(context: Context) -> CropViewController {
    let cropViewController = CropViewController(editingStack: editingStack)
    cropViewController.handlers.didFinish = onCompleted
    return cropViewController
  }

  func updateUIViewController(_ uiViewController: CropViewController, context: Context) {}
}

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
