
import SwiftUI

struct ContentView: View {
  @State private var target: FullscreenIdentifiableView?
  @State private var image: SwiftUI.Image?

  @State private var sharedStack = Mocks.makeEditingStack(image: Mocks.imageHorizontal())
  @State private var fullScreenView: FullscreenIdentifiableView?

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

          Button("Horizontal") {
            let stack = Mocks.makeEditingStack(image: Mocks.imageHorizontal())
            target = .init {
              CropViewWrapper(editingStack: stack, onCompleted: {
                self.image = SwiftUI.Image.init(uiImage: stack.makeRenderer().render())
                self.target = nil
              })
            }
          }

          Button("Vertical") {
            let stack = Mocks.makeEditingStack(image: Mocks.imageVertical())
            target = .init {
              CropViewWrapper(editingStack: stack, onCompleted: {
                self.image = SwiftUI.Image.init(uiImage: stack.makeRenderer().render())
                self.target = nil
              })
            }
          }

          Button("Square") {
            let stack = Mocks.makeEditingStack(image: Mocks.imageSquare())
            target = .init {
              CropViewWrapper(editingStack: stack, onCompleted: {
                self.image = SwiftUI.Image.init(uiImage: stack.makeRenderer().render())
                self.target = nil
              })
            }
          }

          Button("Super small") {
            let stack = Mocks.makeEditingStack(image: Mocks.imageSuperSmall())
            target = .init {
              CropViewWrapper(editingStack: stack, onCompleted: {
                self.image = SwiftUI.Image.init(uiImage: stack.makeRenderer().render())
                self.target = nil
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

            target = .init {
              CropViewWrapper(editingStack: stack, onCompleted: {
                self.image = SwiftUI.Image.init(uiImage: stack.makeRenderer().render())
                self.target = nil
              })
            }
          }
        }
      }
      .sheet(item: $target, content: { $0 })
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
  }
}

import PixelEditor
import PixelEngine

struct CropViewWrapper: UIViewControllerRepresentable, Identifiable {
  let id: UUID = .init()

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
