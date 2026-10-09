import Foundation
import Testing

@testable import LoamKit

/// Ticket 98: the geometry of a drag that reorders tabs or plots.
@Suite struct ReorderTests {
    /// Three pills 100, 60 and 80 wide, 4 apart, from x = 8.
    let pills = (starts: [8.0, 112.0, 176.0], lengths: [100.0, 60.0, 80.0])

    @Test func theSlotChangesOnlyWhenThePointerPassesAMidpoint() {
        let drag = Reorder(starts: pills.starts, lengths: pills.lengths, spacing: 4, dragged: 0)
        #expect(drag.slot(pointer: 50) == 0)
        #expect(drag.slot(pointer: 141) == 0)  // the midpoint of tab 2 is 142
        #expect(drag.slot(pointer: 143) == 1)
        #expect(drag.slot(pointer: 217) == 2)  // past the midpoint of tab 3 (216)
        #expect(drag.slot(pointer: 900) == 2)
        #expect(drag.slot(pointer: -50) == 0)
    }

    @Test func draggingLeftCountsTheItemsBefore() {
        let drag = Reorder(starts: pills.starts, lengths: pills.lengths, spacing: 4, dragged: 2)
        #expect(drag.slot(pointer: 200) == 2)
        #expect(drag.slot(pointer: 141) == 1)
        #expect(drag.slot(pointer: 57) == 0)
    }

    @Test func theItemsBetweenSlideByTheDraggedLengthAndTheSpacing() {
        let drag = Reorder(starts: pills.starts, lengths: pills.lengths, spacing: 4, dragged: 0)
        #expect(drag.offset(of: 0, slot: 2) == 0)
        #expect(drag.offset(of: 1, slot: 2) == -104)
        #expect(drag.offset(of: 2, slot: 2) == -104)
        #expect(drag.offset(of: 2, slot: 1) == 0)
        let back = Reorder(starts: pills.starts, lengths: pills.lengths, spacing: 4, dragged: 2)
        #expect(back.offset(of: 0, slot: 0) == 84)
        #expect(back.offset(of: 1, slot: 1) == 84)
        #expect(back.offset(of: 0, slot: 1) == 0)
    }

    @Test func theDraggedItemSettlesWhereTheNewOrderPutsIt() {
        let drag = Reorder(starts: pills.starts, lengths: pills.lengths, spacing: 4, dragged: 0)
        // New order 2, 3, 1: tab 1 starts at 8 + 64 + 84 = 156.
        #expect(drag.settleOffset(slot: 2) == 148)
        #expect(drag.settleOffset(slot: 0) == 0)
        let back = Reorder(starts: pills.starts, lengths: pills.lengths, spacing: 4, dragged: 2)
        #expect(back.settleOffset(slot: 0) == -168)
    }

    @Test func rowsWithNoSpacingPartByTheBlockHeight() {
        // A collapsed plot (30), an open plot with three rows (90), and a collapsed plot (30).
        let drag = Reorder(starts: [0, 30, 120], lengths: [30, 90, 30], dragged: 1)
        #expect(drag.slot(pointer: 20) == 1)
        #expect(drag.slot(pointer: 14) == 0)
        #expect(drag.offset(of: 0, slot: 0) == 90)
        #expect(drag.settleOffset(slot: 0) == -30)
        #expect(drag.slot(pointer: 140) == 2)
        #expect(drag.offset(of: 2, slot: 2) == -90)
        #expect(drag.settleOffset(slot: 2) == 30)
    }

    /// A plot row drags by its own edges, so an open plot of 90 pt lands where it shows.
    @Test func aTallBlockLandsByItsEdges() {
        let drag = Reorder(starts: [0, 90, 120, 150], lengths: [90, 30, 30, 30], dragged: 0)
        #expect(drag.slot(start: 0) == 0)
        #expect(drag.slot(start: 14) == 0)  // the bottom (104) is short of the midpoint of row 2 (105)
        #expect(drag.slot(start: 16) == 1)
        #expect(drag.slot(start: 46) == 2)
        #expect(drag.slot(start: 90) == 3)
        let up = Reorder(starts: [0, 30, 60], lengths: [30, 30, 90], dragged: 2)
        #expect(up.slot(start: 46) == 2)
        #expect(up.slot(start: 44) == 1)
        #expect(up.slot(start: 14) == 0)
    }

    @Test func theInsertionLineSitsInTheSpacingAtTheSlot() {
        let drag = Reorder(starts: pills.starts, lengths: pills.lengths, spacing: 4, dragged: 1)
        #expect(drag.insertionPoint(slot: 1) == nil)
        #expect(drag.insertionPoint(slot: 0) == 6)
        #expect(drag.insertionPoint(slot: 2) == 258)
    }

    @Test func aSlideEasesFromItsStartToItsEnd() {
        let slide = Slide(from: 0, to: 100, start: 10, duration: LoamTheme.durationBase)
        #expect(slide.value(at: 10) == 0)
        #expect(slide.value(at: 10.2) == 100)
        #expect(slide.isDone(at: 10.2))
        // ease-settle is fast at first: half the time covers far more than half the way.
        let half = slide.value(at: 10.1)
        #expect(half > 80 && half < 100)
        #expect(Slide.at(42).value(at: 0) == 42)
    }

    @Test func theEasingMatchesItsEndsAndIsMonotonic() {
        let easing = LoamTheme.easeSettle
        #expect(abs(easing.progress(at: 0)) < 1e-6)
        #expect(abs(easing.progress(at: 1) - 1) < 1e-6)
        var last = 0.0
        for step in 1...50 {
            let value = easing.progress(at: Double(step) / 50)
            #expect(value >= last - 1e-9)
            last = value
        }
        // The linear curve gives the time back.
        let linear = LoamTheme.Easing(x1: 0, y1: 0, x2: 1, y2: 1)
        #expect(abs(linear.progress(at: 0.3) - 0.3) < 1e-4)
    }
}
