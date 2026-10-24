import Darwin
import SwiftUI
import Testing
import UIKit

/// A view hosted in a window by `mountEditor(_:)`, read and driven through
/// its accessibility tree, as VoiceOver (or a UI test) would.
@MainActor
struct MountedEditor {
  let window: UIWindow
  let host: UIViewController

  /// Every element in the window's accessibility tree.
  var elements: [NSObject] {
    var elements: [NSObject] = []
    collect(host.view, into: &elements)
    return elements
  }

  /// The element labelled `label`, if one is on screen.
  func element(_ label: String) -> NSObject? {
    elements.first { $0.accessibilityLabel == label }
  }

  /// Lays the window out until `condition` holds.
  func wait(
    until condition: () -> Bool,
    _ comment: Comment,
    sourceLocation: SourceLocation = #_sourceLocation
  ) async throws {
    for _ in 0..<200 {
      host.view.layoutIfNeeded()
      if condition() {
        return
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record(comment, sourceLocation: sourceLocation)
    throw CancellationError()
  }

  private func collect(_ object: NSObject, into elements: inout [NSObject]) {
    elements.append(object)
    if let children = object.accessibilityElements as? [NSObject] {
      for child in children {
        collect(child, into: &elements)
      }
    } else {
      let count = object.accessibilityElementCount()
      if count != NSNotFound {
        for index in 0..<count {
          if let child = object.accessibilityElement(at: index) as? NSObject {
            collect(child, into: &elements)
          }
        }
      }
    }
    if let view = object as? UIView {
      for subview in view.subviews {
        collect(subview, into: &elements)
      }
    }
  }
}

/// Shows `rootView` in a window whose accessibility tree the test reads.
@MainActor
func mountEditor(_ rootView: some View) -> MountedEditor {
  AccessibilityAutomation.enable()
  let host = UIHostingController(rootView: rootView)
  let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
  window.rootViewController = host
  window.makeKeyAndVisible()
  return MountedEditor(window: window, host: host)
}

/// Turns on the accessibility runtime's automation mode for the test process,
/// as a UI test runner does, so SwiftUI vends the accessibility elements these
/// tests read. The iOS 27 simulator vends them without it; the iOS 26
/// simulator CI runs on vends none of SwiftUI's elements until something
/// enables it. `_AXSSetAutomationEnabled` is private, so this lives only in
/// tests, and the setting is put back when the process exits.
@MainActor
private enum AccessibilityAutomation {

  private typealias Getter = @convention(c) () -> Int32
  private typealias Setter = @convention(c) (Int32) -> Void

  private static var isEnabled = false

  static func enable() {
    guard isEnabled == false else {
      return
    }
    isEnabled = true
    let root = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] ?? ""
    guard
      let library = dlopen(root + "/usr/lib/libAccessibility.dylib", RTLD_NOW),
      let getter = dlsym(library, "_AXSAutomationEnabled"),
      let setter = dlsym(library, "_AXSSetAutomationEnabled")
    else {
      Issue.record("The accessibility runtime is unavailable, so SwiftUI may vend no elements.")
      return
    }
    accessibilityAutomationInitialValue = unsafeBitCast(getter, to: Getter.self)()
    setAccessibilityAutomation = unsafeBitCast(setter, to: Setter.self)
    setAccessibilityAutomation?(1)
    atexit {
      setAccessibilityAutomation?(accessibilityAutomationInitialValue)
    }
  }
}

// Globals, because the `atexit` handler is a C function that captures nothing.
nonisolated(unsafe) private var accessibilityAutomationInitialValue: Int32 = 0
nonisolated(unsafe) private var setAccessibilityAutomation: (@convention(c) (Int32) -> Void)?
