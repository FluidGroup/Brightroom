#if os(iOS)
import UIKit

/// The platform's view class, for code shared by the UIKit and AppKit canvases.
typealias PlatformView = UIView
#elseif os(macOS)
import AppKit

/// The platform's view class, for code shared by the UIKit and AppKit canvases.
typealias PlatformView = NSView
#endif
