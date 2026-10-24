import CoreGraphics
import SwiftUI
import Testing

@testable import BrightroomEngine
import BrightroomParametric
@testable import BrightroomUI

/// What ImageEditor writes to the host's binding, and when.
@MainActor
struct ImageEditorSessionTests {

  typealias Fixtures = DocumentTestFixtures

  /// A host-side document that counts writes, as a FileDocument host would
  /// count undo registrations.
  @MainActor
  final class Host {
    var document: ImageEditorDocument
    private(set) var writes = 0

    init(_ document: ImageEditorDocument) {
      self.document = document
    }

    var binding: Binding<ImageEditorDocument> {
      Binding(get: { self.document }, set: { self.document = $0; self.writes += 1 })
    }
  }

  // MARK: - Session

  @Test func `A tool visit's first write commits the previous visit in the same value`() throws {
    var document = try Fixtures.makeDocument()
    var session = ImageEditorSession(documentAtStart: document)

    document = try #require(session.document(after: document) {
      $0.feature.effects.exposure = ExposureFeature(ev: 2)
    })
    #expect(document.hasUncommittedChanges)
    #expect(document.history.undoStack.isEmpty)

    let left = session.endToolVisit(of: document)
    #expect(left == nil, "Leaving a tool writes nothing by itself.")

    let next = try #require(session.document(after: document) {
      $0.feature.effects.saturation = SaturationFeature(value: 0.5)
    })
    #expect(next.history.undoStack == [Fixtures.exposure(0)], "The previous visit is one step.")
    #expect(next.hasUncommittedChanges)
    #expect(next.feature.effects.saturation == SaturationFeature(value: 0.5))
  }

  @Test func `Writes of one tool visit are one step`() throws {
    var document = try Fixtures.makeDocument()
    var session = ImageEditorSession(documentAtStart: document)
    for value in 1...3 {
      document = try #require(session.document(after: document) {
        $0.feature.effects.exposure = ExposureFeature(ev: Double(value))
      })
    }
    #expect(document.history.undoStack.isEmpty)

    document.undo()
    #expect(document.feature == Fixtures.exposure(0))
  }

  @Test func `Uncommitted changes the editor opens with are committed by its first write`() throws {
    var document = try Fixtures.makeDocument()
    // The last visit of a previous session.
    document.feature = Fixtures.exposure(1)
    var session = ImageEditorSession(documentAtStart: document)

    let next = try #require(session.document(after: document) {
      $0.feature.effects.saturation = SaturationFeature(value: 0.5)
    })
    #expect(next.history.undoStack == [Fixtures.exposure(0)])
    #expect(next.hasUncommittedChanges)
  }

  @Test func `An operation that changes nothing produces no write, not even a commit`() throws {
    var document = try Fixtures.makeDocument()
    document.feature = Fixtures.exposure(1)
    var session = ImageEditorSession(documentAtStart: document)

    let unchanged = session.document(after: document)
    #expect(unchanged == nil)
    let left = session.endToolVisit(of: document)
    #expect(left == nil)
    let presetCleared = session.document(after: document) { $0.selectFilterPreset(nil) }
    #expect(presetCleared == nil)
    #expect(document.hasUncommittedChanges, "A commit alone is never written.")
  }

  @Test func `An undo by the host back into the visit continues the visit`() throws {
    var document = try Fixtures.makeDocument()
    var session = ImageEditorSession(documentAtStart: document)
    let first = try #require(session.document(after: document) {
      $0.feature.effects.exposure = ExposureFeature(ev: 1)
    })
    let second = try #require(session.document(after: first) {
      $0.feature.effects.exposure = ExposureFeature(ev: 2)
    })
    _ = second

    // The host's UndoManager restores the value before the second write.
    session.noteDocument(first)
    document = try #require(session.document(after: first) {
      $0.feature.effects.exposure = ExposureFeature(ev: 3)
    })
    #expect(document.history.undoStack.isEmpty, "Still one visit: no commit.")
  }

  @Test func `An undo by the host out of the visit starts a new step on the next write`() throws {
    var document = try Fixtures.makeDocument()
    document.feature = Fixtures.exposure(1)
    let opened = document
    var session = ImageEditorSession(documentAtStart: opened)
    _ = try #require(session.document(after: opened) {
      $0.feature.effects.saturation = SaturationFeature(value: 0.5)
    })

    // The host's UndoManager restores the document the editor opened with.
    session.noteDocument(opened)
    document = try #require(session.document(after: opened) {
      $0.feature.effects.contrast = ContrastFeature(value: 0.2)
    })
    #expect(document.history.undoStack == [Fixtures.exposure(0)])
  }

  @Test func `Every write is recorded by a host that counts writes as undo steps`() throws {
    let host = Host(try Fixtures.makeDocument())
    var session = ImageEditorSession(documentAtStart: host.document)

    // Filters: one tap. Leave. Adjust: one drag. Leave. Done.
    if let next = session.document(after: host.document, change: { $0.feature.effects.exposure = ExposureFeature(ev: 1) }) {
      host.binding.wrappedValue = next
    }
    if let next = session.endToolVisit(of: host.document) {
      host.binding.wrappedValue = next
    }
    session.previewAdjustmentValue(30, parameter: .saturation, over: host.document)
    if let next = session.endToolVisit(of: host.document) {
      host.binding.wrappedValue = next
    }
    if let next = session.document(after: host.document) {
      host.binding.wrappedValue = next
    }

    #expect(host.writes == 2, "Two visible changes, two writes: no commit-only write.")
    #expect(host.document.history.undoStack.count == 1)
    #expect(host.document.hasUncommittedChanges)
    var undone = host.document
    undone.undo()
    undone.undo()
    #expect(undone.feature == Fixtures.exposure(0))
  }

  @Test func `A slider value is shown while dragging and written once at the end`() throws {
    let host = Host(try Fixtures.makeDocument())
    var session = ImageEditorSession(documentAtStart: host.document)

    for value in stride(from: 1.0, through: 50.0, by: 1.0) {
      session.previewAdjustmentValue(value, parameter: .exposure, over: host.document)
    }
    #expect(host.writes == 0)
    let shown = session.displayedFeature(of: host.document)
    #expect(shown.effects.exposure != nil)
    #expect(host.document.feature.effects.exposure == ExposureFeature(ev: 0))

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
    var session = ImageEditorSession(documentAtStart: document)

    session.previewAdjustmentValue(40, parameter: .exposure, over: document)
    #expect(session.liveFeature != nil)
    session.previewAdjustmentValue(0, parameter: .exposure, over: document)
    #expect(session.liveFeature == nil)
    let written = session.document(after: document)
    #expect(written == nil)
  }

  @Test func `Leaving a tool writes a live value as part of the visit`() throws {
    let document = try Fixtures.makeDocument()
    var session = ImageEditorSession(documentAtStart: document)
    session.previewAdjustmentValue(30, parameter: .saturation, over: document)

    let written = session.endToolVisit(of: document)
    let next = try #require(written)
    #expect(next.feature.effects.saturation != nil)
    #expect(next.hasUncommittedChanges)
    #expect(next.canUndo)
    #expect(session.liveFeature == nil)
  }

  @Test func `An outside change drops the live value`() throws {
    var document = try Fixtures.makeDocument()
    var session = ImageEditorSession(documentAtStart: document)
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
    var session = ImageEditorSession(documentAtStart: opened)

    let written = session.document(after: document) {
      $0.feature.effects.exposure = ExposureFeature(ev: 5)
    }
    document = try #require(written)
    _ = session.endToolVisit(of: document)
    document = try #require(session.document(after: document) {
      $0.feature.effects.exposure = ExposureFeature(ev: 6)
    })

    #expect(session.documentForCancel(replacing: document) == opened)
    #expect(session.documentForCancel(replacing: opened) == nil, "Nothing changed: no write.")
  }

  @Test func `Another document of the same image restarts the session`() throws {
    var opened = try Fixtures.makeDocument()
    opened.feature = Fixtures.exposure(1)
    opened.commit()
    var session = ImageEditorSession(documentAtStart: opened)
    _ = try #require(session.document(after: opened) {
      $0.feature.effects.saturation = SaturationFeature(value: 0.5)
    })

    // The host rebinds the editor to a duplicate with its own edit.
    var duplicate = EditingDocument(source: opened.source, feature: Fixtures.exposure(-1))
    session.noteDocument(duplicate)
    #expect(session.documentForCancel(replacing: duplicate) == nil, "Cancel must not write the first document over the duplicate.")

    duplicate = try #require(session.document(after: duplicate) {
      $0.feature.effects.saturation = SaturationFeature(value: 0.2)
    })
    #expect(session.documentForCancel(replacing: duplicate)?.feature == Fixtures.exposure(-1))
  }

  @Test func `A write over an unknown document restarts the session first`() throws {
    let opened = try Fixtures.makeDocument()
    var session = ImageEditorSession(documentAtStart: opened)
    _ = try #require(session.document(after: opened) {
      $0.feature.effects.saturation = SaturationFeature(value: 0.5)
    })

    // The rebinding and the next write arrive before any onChange.
    let duplicate = EditingDocument(source: opened.source, feature: Fixtures.exposure(-1))
    let written = try #require(session.document(after: duplicate) {
      $0.feature.effects.contrast = ContrastFeature(value: 0.2)
    })
    #expect(session.documentAtStart == duplicate)
    #expect(session.documentForCancel(replacing: written) == duplicate)
  }

  @Test func `A value the session wrote keeps the session`() throws {
    let opened = try Fixtures.makeDocument()
    var session = ImageEditorSession(documentAtStart: opened)
    let first = try #require(session.document(after: opened) {
      $0.feature.effects.exposure = ExposureFeature(ev: 1)
    })
    let second = try #require(session.document(after: first) {
      $0.feature.effects.exposure = ExposureFeature(ev: 2)
    })

    // Undo and redo by the host's UndoManager.
    session.noteDocument(first)
    session.noteDocument(opened)
    session.noteDocument(second)
    #expect(session.documentAtStart == opened)
    #expect(session.documentForCancel(replacing: second) == opened)
  }

  @Test func `Cancel never replaces a document of another image`() throws {
    let data = try Fixtures.makeRotatedJPEG()
    let opened = EditingDocument(source: try SourceImage(data: data))
    let session = ImageEditorSession(documentAtStart: opened)
    let other = EditingDocument(source: try SourceImage(data: data))
    #expect(session.documentForCancel(replacing: other) == nil)
  }

  // MARK: - Reset

  @Test func `Reset writes the initial feature as a step of its own`() throws {
    let initial = ImageEditorFeature(imageSize: Fixtures.rotatedJPEGSize)
    // D0: opened, committed.
    var document = try Fixtures.makeDocument(feature: Fixtures.exposure(1))
    var session = ImageEditorSession(documentAtStart: document)
    // D1: the visit's work.
    document = try #require(session.document(after: document) {
      $0.feature.effects.saturation = SaturationFeature(value: 0.5)
    })
    let edited = document.feature

    // R: one write, committing the visit first.
    let reset = session.document(afterResetTo: initial, of: document)
    document = try #require(reset)
    #expect(document.feature == initial)
    #expect(document.history.undoStack == [Fixtures.exposure(1)])
    #expect(document.hasUncommittedChanges)

    // E: the next edit starts a new step, so the reset is one.
    document = try #require(session.document(after: document) {
      $0.feature.effects.contrast = ContrastFeature(value: 0.2)
    })
    #expect(document.history.undoStack == [Fixtures.exposure(1), edited])
    document.undo()
    #expect(document.feature == initial)
    document.undo()
    #expect(document.feature == edited)
    document.undo()
    #expect(document.feature == Fixtures.exposure(1))
  }

  @Test func `Reset of a document that has the initial feature writes nothing`() throws {
    let initial = ImageEditorFeature(imageSize: Fixtures.rotatedJPEGSize)
    var document = try Fixtures.makeDocument(feature: Fixtures.exposure(1))
    // The last visit left the document initial, uncommitted.
    document.feature = initial
    var session = ImageEditorSession(documentAtStart: document)

    let reset = session.document(afterResetTo: initial, of: document)
    #expect(reset == nil)
    #expect(document.hasUncommittedChanges, "Not even a commit is written.")
  }

  @Test func `Reset drops a live slider value instead of writing it`() throws {
    let initial = ImageEditorFeature(imageSize: Fixtures.rotatedJPEGSize)
    let document = try Fixtures.makeDocument(feature: Fixtures.exposure(1))
    var session = ImageEditorSession(documentAtStart: document)
    session.previewAdjustmentValue(30, parameter: .saturation, over: document)
    #expect(session.liveFeature != nil)

    let reset = session.document(afterResetTo: initial, of: document)
    let written = try #require(reset)
    #expect(written.feature == initial, "The live value is not written.")
    #expect(written.history.undoStack.isEmpty, "The opened document was committed already.")
    #expect(session.liveFeature == nil)
    #expect(session.displayedFeature(of: written) == initial)
  }

  @Test func `Reset under a fixed ratio writes the fitted crop`() throws {
    let size = Fixtures.rotatedJPEGSize
    let initial = ImageEditor.Options.AspectRatioPolicy.fixed(.square).initialFeature(imageSize: size)
    // The 20 x 40 image fits a centered 20 x 20 square.
    #expect(initial.crop.rect == CGRect(x: 0, y: 10, width: 20, height: 20))
    #expect(initial.crop == InitialCrop.crop(fitting: .square, imageSize: size))
    #expect(initial.hasAnyEffect == false)
    #expect(ImageEditor.Options.AspectRatioPolicy.selectable.initialFeature(imageSize: size) == ImageEditorFeature(imageSize: size))
    #expect(ImageEditor.Options.AspectRatioPolicy.freeform.initialFeature(imageSize: size) == ImageEditorFeature(imageSize: size))

    let document = try Fixtures.makeDocument(feature: Fixtures.exposure(1))
    var session = ImageEditorSession(documentAtStart: document)
    let reset = session.document(afterResetTo: initial, of: document)
    let written = try #require(reset)
    #expect(written.feature == initial)
    #expect(written.feature.crop.quarterTurn == .zero)
    #expect(written.hasCropChanges(initialCrop: initial.crop) == false)
    #expect(written.hasCropChanges(), "The fitted square is not the whole image.")
  }

  // MARK: - Canvas writes

  @Test func `A canvas change commits the previous visit and keeps a live value`() throws {
    var document = try Fixtures.makeDocument()
    var session = ImageEditorSession(documentAtStart: document)
    document = try #require(session.document(after: document) {
      $0.feature.effects.exposure = ExposureFeature(ev: 1)
    })
    _ = session.endToolVisit(of: document)

    var changed = document
    changed.feature.effects.saturation = SaturationFeature(value: 0.5)
    let written = session.document(afterCanvasChange: changed, over: document)
    let next = try #require(written)
    #expect(next.history.undoStack == [Fixtures.exposure(0)])
    #expect(next.feature.effects.saturation == SaturationFeature(value: 0.5))
    let unchanged = session.document(afterCanvasChange: next, over: next)
    #expect(unchanged == nil)
  }

  @Test func `A canvas change of another image is dropped`() throws {
    let data = try Fixtures.makeRotatedJPEG()
    let shown = try SourceImage(data: data)
    let host = Host(EditingDocument(source: try SourceImage(data: data)))

    // A change queued by the canvas that showed `shown`.
    ImageEditorCanvas.apply({ $0.effects.exposure = .init(ev: 1) }, preparedFor: shown, to: host.binding)
    #expect(host.writes == 0)
    #expect(host.document.feature.effects.exposure == nil)

    ImageEditorCanvas.apply({ $0.effects.exposure = .init(ev: 1) }, preparedFor: host.document.source, to: host.binding)
    #expect(host.writes == 1)
    #expect(host.document.feature.effects.exposure == ExposureFeature(ev: 1))
  }

  @Test func `A canvas change that changes nothing is not written`() throws {
    let host = Host(try Fixtures.makeDocument())
    ImageEditorCanvas.apply({ _ in }, preparedFor: host.document.source, to: host.binding)
    ImageEditorCanvas.apply({ $0.localBlur = nil }, preparedFor: host.document.source, to: host.binding)
    #expect(host.writes == 0)
  }

  @Test func `A canvas change applies to the latest document`() throws {
    let host = Host(try Fixtures.makeDocument())
    // The host changed the document after the canvas queued its change.
    host.document.feature.effects.saturation = SaturationFeature(value: 0.5)
    ImageEditorCanvas.apply({ $0.effects.exposure = .init(ev: 1) }, preparedFor: host.document.source, to: host.binding)
    #expect(host.document.feature.effects.saturation == SaturationFeature(value: 0.5))
    #expect(host.document.feature.effects.exposure == ExposureFeature(ev: 1))
  }
}
