
import SwiftUI
import PixelEngine

struct IsolatedEditinView: View {
  
  @StateObject var editingStack = Mocks.makeEditingStack(image: Mocks.imageHorizontal())
  @State private var fullScreenView: FullscreenIdentifiableView?
  
  var body: some View {
    
    Form {
      Button("Crop") {
        fullScreenView = .init { CropViewControllerWrapper(editingStack: editingStack, onCompleted: {}) }
      }
      
      Button("Custom Crop") {
        fullScreenView = .init { DemoCropView(editingStack: editingStack) }
      }
            
      Button("Blur Mask") {
        fullScreenView = .init { MaskingViewWrapper(editingStack: editingStack) }
      }
    }
    .navigationTitle("Isolated-Editing")
    .fullScreenCover(
      item: $fullScreenView,
      onDismiss: {}, content: {
        $0
      }
    )
    
  }
}
