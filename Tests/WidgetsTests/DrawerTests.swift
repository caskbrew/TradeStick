import Domain
import Foundation
import SwiftUI
import Testing
@testable import Widgets

/// The form and the list live in their own windows next to the sticker; these tests open them like the app does.
extension UITests {
@MainActor @Suite(.timeLimit(.minutes(2)), .serialized) struct DrawerTests {
    let layout = UITests.StickerLayoutTests()
    let normal = UITests.StickerLayoutTests.cases[0]

    func drawer(_ model: StickerModel) -> TestWindow { TestWindow(FormWindowView(model: model)) }

    @Test func theFormOpensWithTheCursorInQtyAndFillsTheAmountFromQtyAndRate() async throws {
        let (_, model) = try await layout.sticker(normal)
        model.openForm(side: .buy)
        let window = drawer(model)
        window.settle(0.4)
        let qty = try #require(window.textField(placeholder: "qty"))
        #expect((window.firstResponder as? NSTextView)?.delegate as? NSTextField === qty)
        window.type("300", into: qty)
        window.type("0.06", into: try #require(window.textField(placeholder: "rate")))
        #expect(model.form?.quantityText == "300")
        #expect(model.form?.amountText == "18")
        window.snapshot("window-form-add")
    }

    @Test func aWrongTimeIsFlaggedAndFixedAgain() async throws {
        let (_, model) = try await layout.sticker(normal)
        model.openForm(side: .sell)
        let window = drawer(model)
        window.settle(0.4)
        window.type("abc", into: try #require(window.allViews().compactMap { $0 as? NSTextField }.last { $0.isEditable }))
        #expect(model.form?.timeInvalid == true)
        window.snapshot("window-form-bad-time")
    }

    @Test func escapeClosesTheFormAndSavingAddsARow() async throws {
        let (_, model) = try await layout.sticker(normal)
        model.openForm(side: .buy)
        let window = drawer(model)
        window.settle(0.4)
        window.press(.escape)
        #expect(model.form == nil)

        model.openForm(side: .buy)
        window.settle(0.4)
        model.edit(.quantity, "10"); model.edit(.rate, "0.05")
        await model.submit()
        #expect(model.form == nil)
        #expect(model.transactions.count == 3)
    }

    @Test func aFormThatCannotBeSavedShowsTheReason() async throws {
        let (_, model) = try await layout.sticker(normal)
        model.openForm(side: .sell)
        let window = drawer(model)
        window.settle(0.4)
        model.edit(.quantity, "0"); model.edit(.rate, "0.05")
        await model.submit()
        window.settle(0.3)
        #expect(model.form != nil)
        #expect(!model.formProblems.isEmpty)
        #expect(model.transactions.count == 2)
        window.snapshot("window-form-error")
    }

    @Test func editingARowOpensItInTheSameForm() async throws {
        let (_, model) = try await layout.sticker(normal)
        let first = try #require(model.transactions.first)
        model.openEditForm(id: first.id)
        let window = drawer(model)
        window.settle(0.4)
        #expect(model.editingID == first.id)
        model.edit(.quantity, "1200")
        await model.submit()
        #expect(model.transactions.contains { $0.id == first.id && $0.quantity == 1200 })
        window.snapshot("window-form-edit")
    }

    @Test func theListShowsTheRowsAndDeletingOneUpdatesIt() async throws {
        let (_, model) = try await layout.sticker(normal)
        model.setExpanded(true)
        let window = TestWindow(ListWindowView(model: model))
        window.settle(0.4)
        window.snapshot("window-list-rows")
        await model.deleteTransaction(id: try #require(model.transactions.first).id)
        window.settle(0.3)
        #expect(model.transactions.count == 1)
    }

    @Test func deletingABuyThatASellNeedsShowsAnErrorInTheList() async throws {
        let (_, model) = try await layout.sticker(UITests.StickerLayoutTests.Case(
            name: "x", base: "GRAM", quote: "USDT", direction: .buyFirst,
            txs: [(.buy, "100", "10"), (.sell, "50", "7")], price: "0.1", open: "0.1"))
        model.setExpanded(true)
        let window = TestWindow(ListWindowView(model: model))
        let oldest = try #require(model.transactions.min { $0.occurredAt < $1.occurredAt })
        await model.deleteTransaction(id: oldest.id)
        window.settle(0.3)
        #expect(model.listError != nil)
        #expect(model.transactions.count == 2)
        window.snapshot("window-list-error")
    }

    @Test func theStickerWithItsFormAndListSideBySide() async throws {
        let (_, model) = try await layout.sticker(normal)
        model.setExpanded(true)
        model.openForm(side: .buy)
        model.edit(.quantity, "300"); model.edit(.rate, "0.06")
        let window = TestWindow(VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                StickerView(model: model, actions: StickerActions(hide: {}, delete: {}))
                FormWindowView(model: model)
            }
            ListWindowView(model: model)
        })
        window.settle(0.5)
        window.snapshot("window-sticker-with-drawers")
    }
}
}
