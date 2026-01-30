import BrightroomEngine
import BrightroomUI
import SwiftUI
import Verge

struct IsolatedEditinView: View {
  @ReadingObject<EditingStack> var editingStackState: EditingStack.State
  @State private var fullScreenView: FullscreenIdentifiableView?

  init() {
    self._editingStackState = .init { Mocks.makeEditingStack(image: Mocks.imageHorizontal()) }
  }

  var body: some View {
    Form.init {
      Button("Crop") {
        fullScreenView = .init {
          SwiftUIPhotosCropView(
            editingStack: $editingStackState.driver,
            onDone: {},
            onCancel: {}
          )

        }
      }

      Button("Custom Crop") {
        fullScreenView = .init { DemoCropView(editingStack: { $editingStackState.driver }) }
      }

      Button("Blur Mask") {
        fullScreenView = .init { MaskingViewWrapper(editingStack: $editingStackState.driver) }
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
