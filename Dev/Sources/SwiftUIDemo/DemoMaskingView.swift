import BrightroomEngine
import BrightroomUI
import SwiftUI

struct DemoMaskingView: View {

  @ObjectEdge var editingStack: EditingStack

  init(editingStack: @escaping () -> EditingStack) {
    self._editingStack = .init(wrappedValue: editingStack())
  }

  var body: some View {
    SwiftUIBlurryMaskingView(editingStack: editingStack)
  }

}

#Preview {
  DemoMaskingView(
    editingStack: {
      Mocks.makeEditingStack(
        image: Asset.verticalRect.image
      )
    }
  )
}
