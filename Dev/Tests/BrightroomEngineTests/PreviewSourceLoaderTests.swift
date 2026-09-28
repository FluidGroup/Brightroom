import CoreGraphics
import CoreImage
import Testing
import UIKit
import os

@testable import BrightroomEngine
@testable import BrightroomParametric

/// `PreviewSourceLoader` prepares one image's preview pixels for the editors;
/// it holds no edit and no history. Rendering belongs to the document.
@MainActor
struct PreviewSourceLoaderTests {

  private func makeImage(size: CGSize) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
      UIColor.orange.setFill()
      UIRectFill(CGRect(origin: .zero, size: size))
    }
  }

  private func makeSourceImage() throws -> SourceImage {
    let cgImage = try #require(makeImage(size: CGSize(width: 8, height: 4)).cgImage)
    return SourceImage(cgImage: cgImage, orientation: .up)
  }

  @Test func `Loading publishes a preview without an edit`() async throws {
    let size = CGSize(width: 40, height: 20)
    let image = SourceImage(image: makeImage(size: size))
    let loader = PreviewSourceLoader(source: image)
    #expect(loader.phase == .idle)

    await loader.load()

    let previewSource = try #require(loader.previewSource)
    #expect(previewSource.source == image)
    #expect(previewSource.source.pixelSize == size)
    #expect(previewSource.thumbnail.extent.isEmpty == false)
    #expect(previewSource.image.extent.size == size)
  }

  @Test func `Phase moves from idle through loading to loaded`() async throws {
    let source = try makeSourceImage()
    let expected = PreviewSource(source: source, thumbnail: CIImage.empty(), image: CIImage.empty())
    let gate = Gate()
    let loader = PreviewSourceLoader(source: source) { _ in
      await gate.wait()
      return expected
    }
    #expect(loader.phase == .idle)

    let caller = Task { await loader.load() }
    while loader.phase == .idle {
      await Task.yield()
    }
    #expect(loader.phase == .loading)
    #expect(loader.previewSource == nil)

    await gate.open()
    await caller.value
    #expect(loader.phase == .loaded(expected))
    #expect(loader.previewSource == expected)
  }

  @Test func `The preparation starts while the main actor is busy`() async throws {
    let source = try makeSourceImage()
    let expected = PreviewSource(source: source, thumbnail: CIImage.empty(), image: CIImage.empty())
    let started = OSAllocatedUnfairLock(initialState: false)
    let loader = PreviewSourceLoader(source: source) { _ in
      started.withLock { $0 = true }
      return expected
    }

    // The editor's `.task` calls `load()`, and then the main actor is busy,
    // as it is during the editor's presentation animation. The decode must
    // not wait for it.
    let caller = Task { await loader.load() }
    let busyMainActor = Task { blockUntil(started, timeout: 2) }
    #expect(await busyMainActor.value)

    await caller.value
    #expect(loader.phase == .loaded(expected))
  }

  @Test func `Concurrent and later loads share one preparation`() async throws {
    let source = try makeSourceImage()
    let counter = Counter()
    let gate = Gate()
    let loader = PreviewSourceLoader(source: source) { source in
      await counter.increment()
      await gate.wait()
      return await PreviewSource.make(from: source)
    }

    let first = Task { await loader.load() }
    let second = Task { await loader.load() }
    while loader.phase == .idle {
      await Task.yield()
    }
    await gate.open()
    await first.value
    await second.value
    let loaded = try #require(loader.previewSource)

    // A call after the preparation ended returns the same preview at once.
    await loader.load()
    #expect(loader.previewSource == loaded)
    #expect(await counter.value == 1)
  }

  @Test func `A failed preparation publishes failed and is not retried`() async throws {
    let counter = Counter()
    let loader = PreviewSourceLoader(source: try makeSourceImage()) { _ in
      await counter.increment()
      return nil
    }

    await loader.load()
    #expect(loader.phase == .failed)
    #expect(loader.previewSource == nil)

    await loader.load()
    #expect(loader.phase == .failed)
    #expect(await counter.value == 1)
  }

  @Test func `Cancelling a caller neither cancels the preparation nor leaves it loading`() async throws {
    let source = try makeSourceImage()
    let expected = PreviewSource(source: source, thumbnail: CIImage.empty(), image: CIImage.empty())
    let gate = Gate()
    let loader = PreviewSourceLoader(source: source) { _ in
      await gate.wait()
      // The preparation runs in its own task: a caller's cancellation does
      // not reach it.
      return Task.isCancelled ? nil : expected
    }

    // A SwiftUI `.task` whose view disappeared while loading.
    let cancelled = Task { await loader.load() }
    while loader.phase == .idle {
      await Task.yield()
    }
    cancelled.cancel()

    // The view reappears and loads again.
    let reappeared = Task { await loader.load() }
    await gate.open()
    await cancelled.value
    #expect(loader.phase == .loaded(expected))
    await reappeared.value
    #expect(loader.phase == .loaded(expected))
  }

  @Test func `A document renders over its preview's source image`() async throws {
    let size = CGSize(width: 40, height: 20)
    let cgImage = try #require(makeImage(size: size).cgImage)
    let previewSource = PreviewSource.test(cgImage: cgImage)

    let crop = CropFeature.test(imageSize: size, topLeftRect: CGRect(x: 4, y: 2, width: 16, height: 12))
    let rendered = try await EditingDocument(source: previewSource.source, feature: crop).render()

    let image = try rendered.cgImage
    #expect(image.width == 16)
    #expect(image.height == 12)
  }
}

/// Blocks the calling thread until `flag` is set or `timeout` passes, and
/// returns whether it was set.
private func blockUntil(_ flag: OSAllocatedUnfairLock<Bool>, timeout: TimeInterval) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if flag.withLock({ $0 }) {
      return true
    }
    usleep(1_000)
  }
  return flag.withLock { $0 }
}

/// Holds a preparation until the test opens it.
private actor Gate {

  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard isOpen == false else {
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    isOpen = true
    for waiter in waiters {
      waiter.resume()
    }
    waiters.removeAll()
  }
}

/// Counts preparations.
private actor Counter {

  private(set) var value = 0

  func increment() {
    value += 1
  }
}
