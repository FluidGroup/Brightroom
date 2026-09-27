import CoreGraphics
import SwiftUI
import Testing

@testable import BrightroomEngine
import BrightroomParametric
@testable import BrightroomUI

/// What PhotosCrop writes to the host's binding, and when.
@MainActor
struct PhotosCropEditorSessionTests {

  typealias Fixtures = DocumentTestFixtures

  /// A host-side document that counts writes, as a FileDocument host would
  /// count undo registrations.
  @MainActor
  final class Host {
    var document: EditingDocument<PhotosCropFeature>
    private(set) var writes = 0

    init(_ document: EditingDocument<PhotosCropFeature>) {
      self.document = document
    }

    var binding: Binding<EditingDocument<PhotosCropFeature>> {
      Binding(get: { self.document }, set: { self.document = $0; self.writes += 1 })
    }
  }

  // MARK: - Session

  @Test func `A change and its commit are one value`() throws {
    let document = try Fixtures.makeDocument()
    var session = PhotosCropEditorSession(documentAtStart: document)

    let written = session.document(after: document, committing: true) {
      $0.feature.effects.exposure = ExposureFeature(value: 2)
    }
    let next = try #require(written)
    #expect(next.feature == Fixtures.exposure(2))
    #expect(!next.hasUncommittedChanges)
    #expect(next.history.undoStack == [Fixtures.exposure(0)])
  }

  @Test func `An operation that changes nothing produces no write`() throws {
    let document = try Fixtures.makeDocument()
    var session = PhotosCropEditorSession(documentAtStart: document)

    let unchanged = session.document(after: document)
    let committedUnchanged = session.document(after: document, committing: true)
    #expect(unchanged == nil)
    #expect(committedUnchanged == nil)
    let presetCleared = session.document(after: document) { $0.selectFilterPreset(nil) }
    #expect(presetCleared == nil)
  }

  @Test func `A slider value is shown while dragging and written once at the end`() throws {
    let host = Host(try Fixtures.makeDocument())
    var session = PhotosCropEditorSession(documentAtStart: host.document)

    for value in stride(from: 1.0, through: 50.0, by: 1.0) {
      session.previewAdjustmentValue(value, parameter: .exposure, over: host.document)
    }
    #expect(host.writes == 0)
    let shown = session.displayedFeature(of: host.document)
    #expect(shown.effects.exposure != nil)
    #expect(host.document.feature.effects.exposure == ExposureFeature(value: 0))

    if let next = session.document(after: host.document) {
      host.binding.wrappedValue = next
    }
    #expect(host.writes == 1)
    #expect(host.document.feature == shown)
    #expect(host.document.hasUncommittedChanges, "Writing a slider value does not commit.")
    #expect(session.liveFeature == nil)
  }

  @Test func `Dragging back to the written value leaves nothing to write`() throws {
    var document = try Fixtures.makeDocument()
    document.feature.effects.exposure = nil
    var session = PhotosCropEditorSession(documentAtStart: document)

    session.previewAdjustmentValue(40, parameter: .exposure, over: document)
    #expect(session.liveFeature != nil)
    session.previewAdjustmentValue(0, parameter: .exposure, over: document)
    #expect(session.liveFeature == nil)
    let written = session.document(after: document)
    #expect(written == nil)
  }

  @Test func `Leaving a tool writes the live value with the commit`() throws {
    let document = try Fixtures.makeDocument()
    var session = PhotosCropEditorSession(documentAtStart: document)
    session.previewAdjustmentValue(30, parameter: .saturation, over: document)

    let written = session.document(after: document, committing: true)
    let next = try #require(written)
    #expect(next.feature.effects.saturation != nil)
    #expect(!next.hasUncommittedChanges)
    #expect(next.canUndo)
  }

  @Test func `An outside change drops the live value`() throws {
    var document = try Fixtures.makeDocument()
    var session = PhotosCropEditorSession(documentAtStart: document)
    session.previewAdjustmentValue(30, parameter: .saturation, over: document)

    // The host undoes something while the slider is held.
    document.feature = Fixtures.exposure(7)
    session.discardLiveFeature()
    #expect(session.displayedFeature(of: document) == Fixtures.exposure(7))
    let written = session.document(after: document)
    #expect(written == nil)
  }

  @Test func `Cancel restores the document the editor opened with, history included`() throws {
    var document = try Fixtures.makeDocument()
    document.feature = Fixtures.exposure(1)
    document.commit()
    let opened = document
    var session = PhotosCropEditorSession(documentAtStart: opened)

    let written = session.document(after: document, committing: true) {
      $0.feature.effects.exposure = ExposureFeature(value: 5)
    }
    document = try #require(written)
    document.feature = Fixtures.exposure(6)

    #expect(session.documentForCancel(replacing: document) == opened)
    #expect(session.documentForCancel(replacing: opened) == nil, "Nothing changed: no write.")
  }

  @Test func `Cancel never replaces a document of another image`() throws {
    let data = try Fixtures.makeRotatedJPEG()
    let opened = EditingDocument(image: try SourceImage(data: data))
    let session = PhotosCropEditorSession(documentAtStart: opened)
    let other = EditingDocument(image: try SourceImage(data: data))
    #expect(session.documentForCancel(replacing: other) == nil)
  }

  // MARK: - Canvas writes

  @Test func `A canvas change of another image is dropped`() throws {
    let data = try Fixtures.makeRotatedJPEG()
    let shown = try SourceImage(data: data)
    let host = Host(EditingDocument(image: try SourceImage(data: data)))

    // A change queued by the canvas that showed `shown`.
    SwiftUICropView.apply({ $0.effects.exposure = .init(value: 1) }, preparedFor: shown, to: host.binding)
    #expect(host.writes == 0)
    #expect(host.document.feature.effects.exposure == nil)

    SwiftUICropView.apply({ $0.effects.exposure = .init(value: 1) }, preparedFor: host.document.image, to: host.binding)
    #expect(host.writes == 1)
    #expect(host.document.feature.effects.exposure == ExposureFeature(value: 1))
  }

  @Test func `A canvas change that changes nothing is not written`() throws {
    let host = Host(try Fixtures.makeDocument())
    SwiftUICropView.apply({ _ in }, preparedFor: host.document.image, to: host.binding)
    SwiftUICropView.apply({ $0.blurMask = nil }, preparedFor: host.document.image, to: host.binding)
    #expect(host.writes == 0)
  }

  @Test func `A canvas change applies to the latest document`() throws {
    let host = Host(try Fixtures.makeDocument())
    // The host changed the document after the canvas queued its change.
    host.document.feature.effects.saturation = SaturationFeature(value: 0.5)
    SwiftUICropView.apply({ $0.effects.exposure = .init(value: 1) }, preparedFor: host.document.image, to: host.binding)
    #expect(host.document.feature.effects.saturation == SaturationFeature(value: 0.5))
    #expect(host.document.feature.effects.exposure == ExposureFeature(value: 1))
  }
}
