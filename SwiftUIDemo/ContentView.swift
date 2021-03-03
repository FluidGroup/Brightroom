
import SwiftUI

struct ContentView: View {
  
  @State private var target: CropViewWrapper?
  
  var body: some View {
    Form {
      Button("Horizontal") {
        target = CropViewWrapper(editingStack: Mocks.makeEditingStack(image: Mocks.imageHorizontal()))
      }
      
      Button("Vertical") {
        target = CropViewWrapper(editingStack: Mocks.makeEditingStack(image: Mocks.imageVertical()))
      }
      
      Button("Square") {
        target = CropViewWrapper(editingStack: Mocks.makeEditingStack(image: Mocks.imageSquare()))
      }
      
      Button("Super small") {
        target = CropViewWrapper(editingStack: Mocks.makeEditingStack(image: Mocks.imageSuperSmall()))
      }
      
      Button("Remote") {
        target = CropViewWrapper(
          editingStack: EditingStack(
            source: .init(
              url: URL(string: "https://images.unsplash.com/photo-1604456930969-37f67bcd6e1e?ixid=MXwxMjA3fDB8MHxwaG90by1wYWdlfHx8fGVufDB8fHw%3D&ixlib=rb-1.2.1")!,
              imageSize: .init(width: 4025, height: 6037)
            ),
            previewSize: .init(width: 1000, height: 1000)
          )
        )
      }
    }
    .sheet(item: $target, content: { $0 })
  }
}

import PixelEditor
import PixelEngine

struct CropViewWrapper: UIViewControllerRepresentable, Identifiable {
  
  let id: UUID = .init()
    
  typealias UIViewControllerType = CropViewController
  
  private let editingStack: EditingStack
  
  init(editingStack: EditingStack) {
    self.editingStack = editingStack
    editingStack.start()
  }

  func makeUIViewController(context: Context) -> CropViewController {
    let cropViewController = CropViewController(editingStack: editingStack)
    return cropViewController
  }
  
  func updateUIViewController(_ uiViewController: CropViewController, context: Context) {
    
  }
          
}
