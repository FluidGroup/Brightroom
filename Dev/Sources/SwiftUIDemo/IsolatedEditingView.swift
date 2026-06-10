import BrightroomEngine
import BrightroomUI
import SwiftUI
import StateGraph

struct IsolatedEditinView: View {
  let editingStack = Mocks.makeEditingStack(image: Mocks.imageHorizontal())
  @State private var fullScreenView: FullscreenIdentifiableView?

  var body: some View {
    Form.init {
      Button("Crop") {
        fullScreenView = .init(showsDismissButton: false) {
          DemoPhotosCropView(stack: editingStack)
        }
      }

      Button("Blur Mask") {
        fullScreenView = .init { SwiftUIBlurryMaskingView(editingStack: editingStack) }
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
