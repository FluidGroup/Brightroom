import Testing

@testable import BrightroomUI

extension EditingCanvasView {

  /// Waits `minimum`, then until no scroll settle or crop layout is still
  /// scheduled, and lays out.
  ///
  /// The settle (0.2 s, again when the scroll view rests outside its range)
  /// and the layout after a guide change (0.8 s) run on main-queue timers.
  /// A busy main thread, such as CI's simulator drawing the canvas, can run
  /// them later than a fixed wait allows, so a test that waited only a fixed
  /// time could check the canvas before they ran.
  func waitForPendingCropUpdates(
    after minimum: Duration,
    timeout: Duration = .seconds(10),
    sourceLocation: SourceLocation = #_sourceLocation
  ) async throws {
    try await Task.sleep(for: minimum)
    let deadline = ContinuousClock.now + timeout
    while hasPendingCropUpdate {
      try #require(
        ContinuousClock.now < deadline,
        "a scroll settle or crop layout was still scheduled after \(timeout)",
        sourceLocation: sourceLocation
      )
      try await Task.sleep(for: .milliseconds(20))
    }
    layoutIfNeeded()
  }
}
