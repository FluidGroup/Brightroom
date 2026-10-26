import Foundation
import Testing

@testable import BrightroomUI

/// The crop canvas waits with `Debouncer`: its scroll settle checks again
/// from inside a handler until the scroll view rests.
@MainActor
struct DebouncerTests {

  final class Runs {
    var labels: [String] = []
  }

  private func wait(milliseconds: Int) async throws {
    try await Task.sleep(for: .milliseconds(milliseconds))
  }

  @Test
  func `a handler that schedules the next run gets it`() async throws {
    let debouncer = Debouncer(interval: 0.05)
    let runs = Runs()

    debouncer.on {
      runs.labels.append("first")
      debouncer.on {
        runs.labels.append("second")
      }
    }

    try await wait(milliseconds: 400)
    #expect(runs.labels == ["first", "second"])
  }

  @Test
  func `a handler that keeps scheduling runs until it is done`() async throws {
    let debouncer = Debouncer(interval: 0.03)
    let runs = Runs()

    func check() {
      debouncer.on {
        runs.labels.append("check")
        if runs.labels.count < 3 {
          check()
        }
      }
    }
    check()

    try await wait(milliseconds: 500)
    #expect(runs.labels == ["check", "check", "check"])
  }

  @Test
  func `a newer handler replaces a pending one`() async throws {
    let debouncer = Debouncer(interval: 0.05)
    let runs = Runs()

    debouncer.on { runs.labels.append("replaced") }
    debouncer.on { runs.labels.append("latest") }

    try await wait(milliseconds: 300)
    #expect(runs.labels == ["latest"])
  }

  @Test
  func `cancel drops the pending handler`() async throws {
    let debouncer = Debouncer(interval: 0.05)
    let runs = Runs()

    debouncer.on { runs.labels.append("cancelled") }
    debouncer.cancel()

    try await wait(milliseconds: 300)
    #expect(runs.labels.isEmpty)
  }

  /// Tests of the crop canvas wait for its debouncers this way.
  @Test
  func `it is pending from scheduling until the handler runs or is cancelled`() async throws {
    let debouncer = Debouncer(interval: 0.05)
    let runs = Runs()
    #expect(debouncer.isPending == false)

    debouncer.on {
      runs.labels.append("first")
      #expect(debouncer.isPending == false)
    }
    #expect(debouncer.isPending)
    try await wait(milliseconds: 300)
    #expect(runs.labels == ["first"])
    #expect(debouncer.isPending == false)

    debouncer.on { runs.labels.append("cancelled") }
    #expect(debouncer.isPending)
    debouncer.cancel()
    #expect(debouncer.isPending == false)
  }
}
