import CoreGraphics
import Testing

@testable import BrightroomParametric
@testable import BrightroomUI

/// Commit-style history over `PhotosCropFeature` states (the semantics the
/// Engine's `EditingHistory` had before the UI took over the document).
struct EditingHistoryTests {

  private let imageSize = CGSize(width: 40, height: 20)

  private var v0: PhotosCropFeature {
    PhotosCropFeature(imageSize: imageSize)
  }

  private var v1: PhotosCropFeature {
    var document = v0
    PhotosCropAdjustmentParameter.brightness.apply(sliderValue: 50, to: &document.effects)
    return document
  }

  private var v2: PhotosCropFeature {
    var document = v1
    document.appendBlurMaskStroke(
      BrushMaskStroke(stamps: [CGPoint(x: 10, y: 10)], brush: .init(diameter: 4, hardness: 1, opacity: 1))
    )
    return document
  }

  @Test func `Undo redo walks versions`() {
    var history = EditingHistory(initial: v0)

    history.commitCurrent()
    history.current = v1

    history.commitCurrent()
    history.current = v2

    history.undo()
    #expect(history.current == v1)
    #expect(history.canRedo)

    history.undo()
    #expect(history.current == v0)

    history.redo()
    #expect(history.current == v1)

    history.redo()
    #expect(history.current == v2)
    #expect(!history.canRedo)
  }

  @Test func `Commit style checkpoint undo changes state on first press`() {
    // PhotosCrop commits AFTER mutating: the latest checkpoint can equal the
    // current document at settled states. One undo press must still change
    // state.
    var history = EditingHistory(initial: v0)

    history.current = v1
    history.commitCurrent()

    history.current = v2
    history.commitCurrent()

    #expect(history.canUndo)
    history.undo()
    #expect(history.current == v1)

    history.undo()
    #expect(history.current == v0)

    history.redo()
    #expect(history.current == v1)
    history.redo()
    #expect(history.current == v2)
    #expect(!history.canRedo)
  }

  @Test func `New version clears redo`() {
    var history = EditingHistory(initial: v0)

    history.commitCurrent()
    history.current = v1

    history.undo()
    #expect(history.canRedo)

    var divergent = history.current
    PhotosCropAdjustmentParameter.contrast.apply(sliderValue: 50, to: &divergent.effects)
    history.current = divergent
    history.commitCurrent()

    #expect(!history.canRedo)
  }

  @Test func `Commit if needed skips duplicate checkpoints`() {
    var history = EditingHistory(initial: v0)

    history.commitCurrentIfNeeded()
    #expect(history.revision == 0)

    history.current = v1
    history.commitCurrentIfNeeded()
    #expect(history.revision == 1)

    history.commitCurrentIfNeeded()
    #expect(history.revision == 1)
  }

  @Test func `Revert returns to the latest checkpoint or initial`() {
    var history = EditingHistory(initial: v0)

    history.current = v1
    history.discardUncommittedChanges()
    #expect(history.current == v0)
    #expect(!history.isDirty)

    history.current = v1
    history.commitCurrent()
    history.current = v2
    #expect(history.hasUncommittedChanges)

    history.discardUncommittedChanges()
    #expect(history.current == v1)
    #expect(!history.hasUncommittedChanges)
    #expect(history.isDirty)
  }
}
