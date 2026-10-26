import Foundation

/// Runs only the last handler it receives, `interval` seconds after it
/// arrives; a newer handler replaces a pending one.
///
/// A handler may schedule the next run: the debouncer lets go of the timer
/// that fired before it runs the handler.
final class Debouncer {
  private var timerReference: DispatchSourceTimer?

  let interval: TimeInterval
  let queue: DispatchQueue

  /// Whether a handler is waiting for its timer.
  var isPending: Bool {
    timerReference != nil
  }

  init(interval: TimeInterval, queue: DispatchQueue = .main) {
    self.interval = interval
    self.queue = queue
  }

  func on(handler: @escaping () -> Void) {
    let deadline = DispatchTime.now() + DispatchTimeInterval.milliseconds(Int(interval * 1000.0))

    timerReference?.cancel()

    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: deadline)

    timer.setEventHandler(handler: { [weak timer, weak self] in
      timer?.cancel()
      self?.timerReference = nil
      handler()
    })
    timer.resume()

    timerReference = timer
  }

  func cancel() {
    timerReference?.cancel()
    timerReference = nil
  }
}
