import BrightroomUI
import SwiftUI

@main
struct ParametricMacDemoApp: App {

  var body: some Scene {
    WindowGroup {
      DemoRootView()
    }
    .defaultSize(width: 1400, height: 900)
    // The editor's commands in the View and Image menus, and Show Inspector
    // for its adjustments.
    .commands {
      InspectorCommands()
      ImageEditorCommands()
    }
  }
}
