import QuartzCore

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The canvas a `ViewportDisplayLink` drives.
@MainActor
protocol ViewportDisplayLinkOwner: AnyObject {
  /// Draws one frame of the canvas; called on every tick of the link.
  func drawViewportFrame()
}

/// Calls its owner's `drawViewportFrame()` on every display refresh.
///
/// The run loop retains this proxy, not the owner: the link retains its
/// target (this object), and this object holds its owner weakly. A tick that
/// finds no owner invalidates the link.
///
/// A link that does not tick cannot invalidate itself that way: a paused
/// link, and on macOS a link whose view has left its window, gets no ticks,
/// so it stays scheduled, with this proxy, after its owner is gone. An owner
/// that pauses the link, or that can outlive its window, calls `invalidate()`
/// when it is dismantled and in its isolated deinit.
///
/// The UIKit canvas runs its link for the lifetime of the visible editor and
/// never pauses it: gesture boundaries never start or stop it, every
/// displayed frame samples the viewport, and the canvas submits Metal work
/// only when its input changes. The AppKit canvas pauses its link while
/// nothing moves and invalidates it as described above.
@MainActor
final class ViewportDisplayLink: NSObject {
  weak var owner: (any ViewportDisplayLinkOwner)?
  private var displayLink: CADisplayLink?

  /// Whether the link skips its ticks. The link stays scheduled while paused,
  /// and a paused link never notices that its owner is gone.
  ///
  /// The UIKit canvas never sets it. A host that pauses resumes the link when
  /// anything may need a new frame, and invalidates it itself.
  var isPaused = false {
    didSet {
      displayLink?.isPaused = isPaused
    }
  }

  #if os(iOS)
  func start(maximumFramesPerSecond: Int) {
    if displayLink == nil {
      let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
      link.add(to: .main, forMode: .common)
      displayLink = link
    }
    let maximum = Float(maximumFramesPerSecond)
    displayLink?.preferredFrameRateRange = .init(
      minimum: min(60, maximum), maximum: maximum, preferred: maximum
    )
  }
  #elseif os(macOS)
  /// Starts the link on the display `view` is on, or updates its frame rate.
  ///
  /// The link is created from the first view passed and follows that view
  /// between screens; it does not fire while the view is hidden.
  func start(in view: NSView, maximumFramesPerSecond: Int) {
    if displayLink == nil {
      let link = view.displayLink(target: self, selector: #selector(tick(_:)))
      link.isPaused = isPaused
      link.add(to: .main, forMode: .common)
      displayLink = link
    }
    let maximum = Float(maximumFramesPerSecond)
    displayLink?.preferredFrameRateRange = .init(
      minimum: min(60, maximum), maximum: maximum, preferred: maximum
    )
  }
  #endif

  /// Whether a link is scheduled: started and not invalidated since.
  var isScheduled: Bool { displayLink != nil }

  func invalidate() {
    displayLink?.invalidate()
    displayLink = nil
  }

  isolated deinit {
    invalidate()
  }

  @objc private func tick(_ link: CADisplayLink) {
    guard let owner else {
      invalidate()
      return
    }
    owner.drawViewportFrame()
  }
}
