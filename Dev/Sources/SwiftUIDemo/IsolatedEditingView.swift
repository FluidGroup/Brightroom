import BrightroomEngine
import BrightroomUI
import SwiftUI

struct IsolatedEditinView: View {
  @StateObject var editingStack = Mocks.makeEditingStack(image: Mocks.imageHorizontal())
  @State private var fullScreenView: FullscreenIdentifiableView?

  var body: some View {
    Form.init {
      Button("Crop") {
        fullScreenView = .init {
          SwiftUIPhotosCropView(
            editingStack: editingStack,
            onDone: {},
            onCancel: {}
          )

        }
      }

      Button("Custom Crop") {
        fullScreenView = .init { DemoCropView(editingStack: {editingStack}) }
      }

      Button("Blur Mask") {
        fullScreenView = .init { MaskingViewWrapper(editingStack: editingStack) }
      }
    }
    .navigationTitle("Isolated-Editing")
    .fullScreenCover(
      item: $fullScreenView,
      onDismiss: {},
      content: {
        $0
      }
    )
  }
}
