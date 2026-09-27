import CoreGraphics
import Testing

@testable import BrightroomEngine
import BrightroomParametric
@testable import BrightroomUI

/// The commit-style history of `EditingDocument`.
struct EditingDocumentHistoryTests {

  typealias Fixtures = DocumentTestFixtures

  @Test func `A new document has nothing to undo or redo`() throws {
    let document = try Fixtures.makeDocument()
    #expect(!document.hasUncommittedChanges)
    #expect(!document.canUndo)
    #expect(!document.canRedo)
    #expect(document.history.undoStack.isEmpty)
    #expect(document.history.redoStack.isEmpty)
    #expect(document.history.limit == 100)
  }

  @Test func `Changes record nothing until committed`() throws {
    var document = try Fixtures.makeDocument()

    document.feature = Fixtures.exposure(1)
    #expect(document.hasUncommittedChanges)
    #expect(document.canUndo)
    #expect(document.history.undoStack.isEmpty)

    document.commit()
    #expect(!document.hasUncommittedChanges)
    #expect(document.history.undoStack == [Fixtures.exposure(0)])
    #expect(document.feature == Fixtures.exposure(1))
  }

  @Test func `Committing without a change does nothing`() throws {
    var document = try Fixtures.makeDocument()
    let before = document
    document.commit()
    #expect(document == before)

    // Changing and changing back is no change either.
    document.feature = Fixtures.exposure(1)
    document.feature = Fixtures.exposure(0)
    document.commit()
    #expect(document == before)
  }

  @Test func `Undo and redo walk commits`() throws {
    var document = try Fixtures.makeDocument()
    document.feature = Fixtures.exposure(1)
    document.commit()
    document.feature = Fixtures.exposure(2)
    document.commit()

    document.undo()
    #expect(document.feature == Fixtures.exposure(1))
    document.undo()
    #expect(document.feature == Fixtures.exposure(0))
    #expect(!document.canUndo)
    #expect(!document.hasUncommittedChanges)

    // Undo at the start changes nothing.
    let atStart = document
    document.undo()
    #expect(document == atStart)

    document.redo()
    document.redo()
    #expect(document.feature == Fixtures.exposure(2))
    #expect(!document.canRedo)

    // Redo at the end changes nothing.
    let atEnd = document
    document.redo()
    #expect(document == atEnd)
  }

  @Test func `Undo returns uncommitted changes and redo brings them back`() throws {
    var document = try Fixtures.makeDocument()
    document.feature = Fixtures.exposure(1)

    document.undo()
    #expect(document.feature == Fixtures.exposure(0))
    #expect(!document.hasUncommittedChanges)
    #expect(document.canRedo)

    document.redo()
    #expect(document.feature == Fixtures.exposure(1))
    #expect(!document.hasUncommittedChanges)
  }

  @Test func `Undoing uncommitted changes at the limit keeps every undo step`() throws {
    var document = try Fixtures.makeDocument(history: .init(limit: 2))
    for value in 1...3 {
      document.feature = Fixtures.exposure(Double(value))
      document.commit()
    }
    document.feature = Fixtures.exposure(4)
    #expect(document.history.undoStack == [Fixtures.exposure(1), Fixtures.exposure(2)])

    document.undo()
    #expect(document.feature == Fixtures.exposure(3))
    #expect(document.history.undoStack == [Fixtures.exposure(1), Fixtures.exposure(2)])
    #expect(document.history.redoStack == [Fixtures.exposure(4)])

    document.undo()
    document.undo()
    #expect(document.feature == Fixtures.exposure(1), "The oldest step must survive undoing the uncommitted changes.")
  }

  @Test func `With a limit of 0, uncommitted changes can still be undone`() throws {
    var document = try Fixtures.makeDocument(history: .init(limit: 0))
    document.feature = Fixtures.exposure(1)
    #expect(document.canUndo)

    document.undo()
    #expect(document.feature == Fixtures.exposure(0))
    #expect(!document.canUndo)
    #expect(document.canRedo)

    document.redo()
    #expect(document.feature == Fixtures.exposure(1))
    #expect(!document.canUndo, "A limit of 0 keeps no undo step.")
  }

  @Test func `Undoing uncommitted changes replaces the earlier redo steps`() throws {
    var document = try Fixtures.makeDocument()
    document.feature = Fixtures.exposure(1)
    document.commit()
    document.undo()
    #expect(document.history.redoStack == [Fixtures.exposure(1)])

    document.feature = Fixtures.exposure(5)
    document.undo()
    #expect(document.feature == Fixtures.exposure(0))
    #expect(document.history.redoStack == [Fixtures.exposure(5)])
    #expect(document.history.undoStack.isEmpty)
  }

  @Test func `Uncommitted changes hide redo and discarding them shows it again`() throws {
    var document = try Fixtures.makeDocument()
    document.feature = Fixtures.exposure(1)
    document.commit()
    document.undo()
    #expect(document.canRedo)

    document.feature = Fixtures.exposure(5)
    #expect(!document.canRedo)
    document.redo()
    #expect(document.feature == Fixtures.exposure(5), "Redo must not overwrite uncommitted changes.")

    document.discardUncommittedChanges()
    #expect(document.feature == Fixtures.exposure(0))
    #expect(document.canRedo)
    document.redo()
    #expect(document.feature == Fixtures.exposure(1))
  }

  @Test func `A commit clears redo`() throws {
    var document = try Fixtures.makeDocument()
    document.feature = Fixtures.exposure(1)
    document.commit()
    document.undo()

    document.feature = Fixtures.exposure(3)
    document.commit()
    #expect(!document.canRedo)
    #expect(document.history.redoStack.isEmpty)
    #expect(document.history.undoStack == [Fixtures.exposure(0)])
  }

  @Test func `The limit keeps the newest undo steps on commit`() throws {
    var document = try Fixtures.makeDocument(history: .init(limit: 2))
    for value in 1...4 {
      document.feature = Fixtures.exposure(Double(value))
      document.commit()
    }
    #expect(document.history.undoStack == [Fixtures.exposure(2), Fixtures.exposure(3)])

    document.undo()
    document.undo()
    #expect(document.feature == Fixtures.exposure(2))
    #expect(!document.canUndo)
  }

  @Test func `The limit applies to redo`() throws {
    var document = try Fixtures.makeDocument(history: .init(limit: 2))
    for value in 1...2 {
      document.feature = Fixtures.exposure(Double(value))
      document.commit()
    }
    document.undo()
    document.undo()
    document.history.limit = 1
    #expect(document.history.undoStack.isEmpty)

    document.redo()
    document.redo()
    #expect(document.feature == Fixtures.exposure(2))
    #expect(document.history.undoStack == [Fixtures.exposure(1)])
  }

  @Test func `Lowering the limit drops the oldest steps`() throws {
    var document = try Fixtures.makeDocument()
    for value in 1...5 {
      document.feature = Fixtures.exposure(Double(value))
      document.commit()
    }
    document.history.limit = 2
    #expect(document.history.undoStack == [Fixtures.exposure(3), Fixtures.exposure(4)])

    document.history.limit = 0
    #expect(document.history.undoStack.isEmpty)
    #expect(!document.canUndo)
    #expect(document.feature == Fixtures.exposure(5))
  }

  @Test func `A nil limit keeps every step`() throws {
    var document = try Fixtures.makeDocument(history: .init(limit: nil))
    for value in 1...150 {
      document.feature = Fixtures.exposure(Double(value))
      document.commit()
    }
    #expect(document.history.undoStack.count == 150)
  }

  @Test func `Removing all steps keeps the feature and the limit`() throws {
    var document = try Fixtures.makeDocument(history: .init(limit: 7))
    document.feature = Fixtures.exposure(1)
    document.commit()
    document.feature = Fixtures.exposure(2)
    document.commit()
    document.undo()
    document.feature = Fixtures.exposure(9)

    document.history.removeAll()
    #expect(document.history.undoStack.isEmpty)
    #expect(document.history.redoStack.isEmpty)
    #expect(document.history.limit == 7)
    #expect(document.feature == Fixtures.exposure(9))

    // The committed state is kept, so uncommitted changes can still be undone.
    #expect(document.hasUncommittedChanges)
    document.undo()
    #expect(document.feature == Fixtures.exposure(1))
    #expect(!document.canUndo)
  }

  @Test func `A saved history restores`() throws {
    var document = try Fixtures.makeDocument()
    document.feature = Fixtures.exposure(1)
    document.commit()
    document.feature = Fixtures.exposure(2)
    document.commit()
    document.undo()

    // An app that saves history writes the stacks in its own format.
    let saved = document.history
    var restored = EditingDocument(
      image: document.image,
      feature: document.feature,
      history: .init(undoStack: saved.undoStack, redoStack: saved.redoStack, limit: saved.limit)
    )
    #expect(restored == document)

    restored.redo()
    #expect(restored.feature == Fixtures.exposure(2))
    restored.undo()
    restored.undo()
    #expect(restored.feature == Fixtures.exposure(0))
  }

  @Test func `Restoring trims to the limit`() throws {
    let history = EditingDocument<PhotosCropFeature>.History(
      undoStack: (0..<5).map { Fixtures.exposure(Double($0)) },
      redoStack: [Fixtures.exposure(9)],
      limit: 3
    )
    #expect(history.undoStack == [Fixtures.exposure(2), Fixtures.exposure(3), Fixtures.exposure(4)])
    #expect(history.redoStack == [Fixtures.exposure(9)])
  }

  @Test func `Restoring folds uncommitted changes into the committed state`() throws {
    var document = try Fixtures.makeDocument()
    document.feature = Fixtures.exposure(1)

    let restored = EditingDocument(image: document.image, feature: document.feature, history: document.history)
    #expect(!restored.hasUncommittedChanges)
    #expect(!restored.canUndo)
  }

  @Test func `Copies are independent`() throws {
    var document = try Fixtures.makeDocument()
    document.feature = Fixtures.exposure(1)
    document.commit()

    var copy = document
    copy.undo()
    copy.history.limit = 1

    #expect(document.feature == Fixtures.exposure(1))
    #expect(document.history.undoStack == [Fixtures.exposure(0)])
    #expect(document.history.limit == 100)
    #expect(copy.feature == Fixtures.exposure(0))
  }
}
