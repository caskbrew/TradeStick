# TradeStick M0 (Window Spike) + M1 (Domain) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create the repository and SwiftPM package, build and unit-test the pure trade-accounting core (Domain), and prove with a throwaway macOS spike how sticker windows behave (Spaces, fullscreen, Mission Control, typing, animation).

**Architecture:** One SwiftPM package. `Domain` is a dependency-free library (Decimal math, no UI, no network) holding the average-cost PnL calculator. `WindowSpike` is a throwaway executable (AppKit `NSPanel` + SwiftUI content, menu bar agent) used only to answer risk R1 from the spec; its findings are written to a report and later drive the real window layer (plan for M4).

**Tech Stack:** Swift 6 (tools 6.0, strict concurrency), SwiftPM, Swift Testing (`import Testing`), AppKit, SwiftUI. macOS 15+.

**Spec:** `docs/specs/2026-10-13-trade-sticker-mvp-spec.md` (v0.3). This plan covers spec §5 (calculation model), FR-TX-3/4 (validation, invariant 5.4), and risk R1 / open question Q3 (window behaviour). Milestones M2–M5 get separate plans after the M0 report exists.

## Global Constraints

- Platform: **macOS 15+**, Apple Silicon (spec NFR-1).
- Swift 6 language mode, strict concurrency, no data-race warnings (NFR-9). AppKit code is `@MainActor`.
- **Money and quantities are `Decimal`, never `Double`** (FR-STORE-2, FR-FMT-1). Build `Decimal` from strings in tests (`Decimal(string:)`), never from float literals.
- Status, averages and PnL are **derived from transactions, never stored** (FR-STORE-3, §5.3).
- Calculator is a pure function of `(Direction, [Transaction])` plus an optional price; no GUI, no network (NFR-10).
- Invariant 5.4: at every point of the chronological replay `openQty >= 0`; a violating set of transactions is rejected as a whole.
- Replay order: `occurredAt`, then creation `sequence` (spec §5.1, FR-TX-5).
- Code, identifiers and comments in English; docs and explanations in Russian.
- Tests use Swift Testing, not XCTest.
- Every commit message ends with the line `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- Spike code is **throwaway**: never imported by later modules, labelled as such in the report.

## Review Focus

Failure modes the spec implies that are easy to miss; each is pinned by a test or a manual check.

1. **Backdated sell before the first buy** — totals look balanced but the position is negative at that moment; must be rejected (Task 3 test `backdatedSellBeforeBuyIsRejectedEvenIfTotalsBalance`).
2. **Equal timestamps** — two transactions in the same minute must be replayed by creation order, not array order (Task 3 test `equalTimestampsUseCreationOrder`).
3. **Repeating decimals on a full close** — buy 7 for 1, sell 1, sell 6 must leave `openCost == 0` exactly, not `1e-38` (Task 3 test `fullCloseLeavesNoDecimalResidue`).
4. **Unknown price** — `pnl(at: nil)` must still return `realized`, with `unrealized`/`total`/`ratio` all `nil` (Task 2 test `unknownPriceKeepsRealized`).
5. **Typing into a non-activating panel** — a text field must accept typing without the app stealing focus from the frontmost app (Task 5 manual check M0-3).

## File Structure

```
.gitignore
Package.swift
Sources/Domain/Transaction.swift        Side, Direction, Transaction (input data)
Sources/Domain/TradeSummary.swift       TradeStatus, PnL, TradeSummary (derived results)
Sources/Domain/TradeCalculator.swift    LedgerError, TradeCalculator.summarize (replay + validation)
Tests/DomainTests/TestSupport.swift     d(), tx(), approx() helpers
Tests/DomainTests/TradeCalculatorTests.swift
Sources/WindowSpike/StickerPanel.swift  NSPanel subclass with pin / stationary / expand toggles
Sources/WindowSpike/SpikeView.swift     SwiftUI content with a text field
Sources/WindowSpike/main.swift          menu bar agent wiring
docs/specs/m0-window-spike-report.md    results of the manual spike (created in Task 5)
```

---

### Task 1: Initialise the repository

**Files:**
- Create: `/Users/joe/dev/github/sgoroshko-trade-stickies/.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: a git repository on branch `main` with the existing `docs/` committed; later tasks commit into it.

- [ ] **Step 1: Create `.gitignore`**

```gitignore
.DS_Store
.build/
.swiftpm/
*.xcodeproj/xcuserdata/
DerivedData/

# Large design reference images stay local for now (about 20 MB).
docs/*.png
```

- [ ] **Step 2: Initialise git and commit the existing documents**

Run (from the repository root `/Users/joe/dev/github/sgoroshko-trade-stickies`):

```bash
git init -b main
git add .gitignore docs
git status --short
```

Expected: `.gitignore`, `docs/specs/...`, `docs/superpowers/plans/...`, `docs/tradestick-ui-spec.md` are staged; no `.png` files are listed.

- [ ] **Step 3: Commit**

```bash
git commit -m "chore: initialise repository with spec and plan

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

Expected: one commit created on `main`.

---

### Task 2: Domain core: types and calculator for the happy paths

**Files:**
- Create: `Package.swift`, `Sources/Domain/Transaction.swift`, `Sources/Domain/TradeSummary.swift`, `Sources/Domain/TradeCalculator.swift`
- Create: `Tests/DomainTests/TestSupport.swift`, `Tests/DomainTests/TradeCalculatorTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces (used by Task 3 and later milestones):
  - `enum Side { case buy, sell }`
  - `enum Direction { case buyFirst, sellFirst; var openingSide: Side; var closingSide: Side }`
  - `struct Transaction { id: UUID; side: Side; quantity: Decimal; amount: Decimal; occurredAt: Date; sequence: Int; var rate: Decimal? }`
  - `enum TradeStatus { case empty, open, closed }`
  - `struct PnL { realized: Decimal; unrealized: Decimal?; total: Decimal?; ratio: Decimal? }`
  - `struct TradeSummary` with `status`, `avgBuyRate`, `avgSellRate`, `entryPrice`, `pnl(at:)` and the stored totals
  - `enum LedgerError: Error { case nonPositiveValue(transactionID:), closingExceedsOpen(transactionID:, available:) }` (declared here, thrown from Task 3)
  - `TradeCalculator.summarize(direction:transactions:) throws(LedgerError) -> TradeSummary`

- [ ] **Step 1: Create `Package.swift` and the input types**

`Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TradeStick",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Domain", targets: ["Domain"]),
    ],
    targets: [
        .target(name: "Domain"),
        .testTarget(name: "DomainTests", dependencies: ["Domain"]),
    ]
)
```

`Sources/Domain/Transaction.swift`:

```swift
import Foundation

public enum Side: String, Codable, Sendable, Equatable {
    case buy, sell
}

public enum Direction: String, Codable, Sendable, Equatable {
    case buyFirst, sellFirst

    public var openingSide: Side { self == .buyFirst ? .buy : .sell }
    public var closingSide: Side { self == .buyFirst ? .sell : .buy }
}

/// One manually entered transaction. Rate is derived, never stored.
public struct Transaction: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var side: Side
    public var quantity: Decimal
    public var amount: Decimal
    public var occurredAt: Date
    /// Creation order; breaks ties between equal `occurredAt`.
    public var sequence: Int

    public init(id: UUID = UUID(), side: Side, quantity: Decimal, amount: Decimal, occurredAt: Date, sequence: Int) {
        self.id = id
        self.side = side
        self.quantity = quantity
        self.amount = amount
        self.occurredAt = occurredAt
        self.sequence = sequence
    }

    public var rate: Decimal? { quantity > 0 ? amount / quantity : nil }
}
```

- [ ] **Step 2: Write the test helpers and the failing tests**

`Tests/DomainTests/TestSupport.swift`:

```swift
import Foundation
@testable import Domain

func d(_ s: String) -> Decimal { Decimal(string: s)! }

/// `minute` offsets from a fixed base date, so tests read as a timeline.
func tx(_ side: Side, _ quantity: String, _ amount: String, minute: Int, seq: Int) -> Transaction {
    Transaction(
        side: side, quantity: d(quantity), amount: d(amount),
        occurredAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(minute) * 60), sequence: seq
    )
}

func approx(_ a: Decimal?, _ b: String, tolerance: String = "0.000000001") -> Bool {
    guard let a else { return false }
    let diff = a - d(b)
    return (diff < 0 ? -diff : diff) <= d(tolerance)
}
```

`Tests/DomainTests/TradeCalculatorTests.swift`:

```swift
import Foundation
import Testing
@testable import Domain

@Suite struct TradeCalculatorTests {
    // Spec 5.5, example A.
    static let exampleA = [
        tx(.buy, "1000", "50", minute: 1, seq: 1),
        tx(.buy, "500", "30", minute: 2, seq: 2),
        tx(.sell, "600", "40", minute: 3, seq: 3),
    ]

    @Test func emptyTradeIsEmpty() throws {
        let s = try TradeCalculator.summarize(direction: .buyFirst, transactions: [])
        #expect(s.status == .empty)
        #expect(s.entryPrice == nil)
        #expect(s.pnl(at: d("0.055")).total == 0)
    }

    @Test func exampleA_buyFirst() throws {
        let s = try TradeCalculator.summarize(direction: .buyFirst, transactions: Self.exampleA)
        #expect(s.status == .open)
        #expect(s.openQuantity == 900)
        #expect(s.openCost == 48)
        #expect(s.realized == 8)
        #expect(s.boughtQuantity == 1500 && s.boughtAmount == 80)
        #expect(s.soldQuantity == 600 && s.soldAmount == 40)
        #expect(approx(s.entryPrice, "0.0533333333"))
        #expect(approx(s.avgBuyRate, "0.0533333333"))
        #expect(approx(s.avgSellRate, "0.0666666667", tolerance: "0.0000000001"))

        let pnl = s.pnl(at: d("0.055"))
        #expect(pnl.unrealized == d("1.5"))
        #expect(pnl.total == d("9.5"))
        #expect(pnl.ratio == d("0.11875"))
    }

    @Test func exampleB_sellFirst() throws {
        let txs = [
            tx(.sell, "1000", "60", minute: 1, seq: 1),
            tx(.sell, "1000", "50", minute: 2, seq: 2),
            tx(.buy, "500", "20", minute: 3, seq: 3),
        ]
        let s = try TradeCalculator.summarize(direction: .sellFirst, transactions: txs)
        #expect(s.openQuantity == 1500)
        #expect(s.openCost == d("82.5"))
        #expect(s.realized == d("7.5"))
        #expect(s.entryPrice == d("0.055"))

        let pnl = s.pnl(at: d("0.058"))
        #expect(pnl.unrealized == d("-4.5"))
        #expect(pnl.total == 3)
        #expect(approx(pnl.ratio, "0.0272727272", tolerance: "0.0000000001"))
    }

    @Test func exampleC_fullCloseBecomesClosed() throws {
        let txs = Self.exampleA + [tx(.sell, "900", "54", minute: 4, seq: 4)]
        let s = try TradeCalculator.summarize(direction: .buyFirst, transactions: txs)
        #expect(s.status == .closed)
        #expect(s.openQuantity == 0)
        #expect(s.openCost == 0)
        #expect(s.realized == 14)
        #expect(s.pnl(at: d("0.05")).total == 14) // price no longer matters
        #expect(s.pnl(at: nil).realized == 14)
        #expect(s.pnl(at: d("0.05")).ratio == d("0.175"))
    }

    @Test func unknownPriceKeepsRealized() throws {
        let s = try TradeCalculator.summarize(direction: .buyFirst, transactions: Self.exampleA)
        let pnl = s.pnl(at: nil)
        #expect(pnl.realized == 8)
        #expect(pnl.unrealized == nil && pnl.total == nil && pnl.ratio == nil)
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test`
Expected: build FAILS with errors such as `cannot find 'TradeCalculator' in scope` and `value of type ... has no member 'status'` (the calculator and summary do not exist yet).

- [ ] **Step 4: Implement `TradeSummary` and a minimal `TradeCalculator`**

`Sources/Domain/TradeSummary.swift`:

```swift
import Foundation

public enum TradeStatus: Equatable, Sendable {
    case empty, open, closed
}

public struct PnL: Equatable, Sendable {
    public let realized: Decimal
    /// nil when the current price is unknown.
    public let unrealized: Decimal?
    public let total: Decimal?
    /// total / sum of opening-side amounts, as a fraction (0.1188 = 11.88 %).
    public let ratio: Decimal?
}

public struct TradeSummary: Equatable, Sendable {
    public let direction: Direction
    public let hasTransactions: Bool
    public let boughtQuantity: Decimal
    public let boughtAmount: Decimal
    public let soldQuantity: Decimal
    public let soldAmount: Decimal
    public let openQuantity: Decimal
    /// Quote amount attributed to the still-open quantity (average-cost method).
    public let openCost: Decimal
    public let realized: Decimal
    /// Sum of amounts of all opening-side transactions (PnL % base).
    public let openingAmount: Decimal

    public var status: TradeStatus {
        if !hasTransactions { return .empty }
        return openQuantity > 0 ? .open : .closed
    }

    public var avgBuyRate: Decimal? { boughtQuantity > 0 ? boughtAmount / boughtQuantity : nil }
    public var avgSellRate: Decimal? { soldQuantity > 0 ? soldAmount / soldQuantity : nil }
    public var entryPrice: Decimal? { openQuantity > 0 ? openCost / openQuantity : nil }

    public func pnl(at price: Decimal?) -> PnL {
        guard let price else {
            return PnL(realized: realized, unrealized: nil, total: nil, ratio: nil)
        }
        let unrealized = direction == .buyFirst
            ? openQuantity * price - openCost
            : openCost - openQuantity * price
        let total = realized + unrealized
        let ratio: Decimal? = openingAmount > 0 ? total / openingAmount : nil
        return PnL(realized: realized, unrealized: unrealized, total: total, ratio: ratio)
    }
}
```

`Sources/Domain/TradeCalculator.swift` (deliberately minimal: no sorting, no validation yet; Task 3 adds them test-first):

```swift
import Foundation

public enum LedgerError: Error, Equatable, Sendable {
    case nonPositiveValue(transactionID: UUID)
    /// A closing transaction is larger than the open quantity at its point in time.
    case closingExceedsOpen(transactionID: UUID, available: Decimal)
}

public enum TradeCalculator {
    public static func summarize(direction: Direction, transactions: [Transaction]) throws(LedgerError) -> TradeSummary {
        let ordered = transactions

        var boughtQuantity: Decimal = 0, boughtAmount: Decimal = 0
        var soldQuantity: Decimal = 0, soldAmount: Decimal = 0
        var openQuantity: Decimal = 0, openCost: Decimal = 0
        var realized: Decimal = 0, openingAmount: Decimal = 0

        for tx in ordered {
            switch tx.side {
            case .buy: boughtQuantity += tx.quantity; boughtAmount += tx.amount
            case .sell: soldQuantity += tx.quantity; soldAmount += tx.amount
            }

            if tx.side == direction.openingSide {
                openQuantity += tx.quantity
                openCost += tx.amount
                openingAmount += tx.amount
            } else {
                let closedCost = openCost * tx.quantity / openQuantity
                realized += direction == .buyFirst ? tx.amount - closedCost : closedCost - tx.amount
                openQuantity -= tx.quantity
                openCost -= closedCost
            }
        }

        return TradeSummary(
            direction: direction,
            hasTransactions: !ordered.isEmpty,
            boughtQuantity: boughtQuantity, boughtAmount: boughtAmount,
            soldQuantity: soldQuantity, soldAmount: soldAmount,
            openQuantity: openQuantity, openCost: openCost,
            realized: realized, openingAmount: openingAmount
        )
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test`
Expected: `Test run with 5 tests in 1 suite passed`.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/Domain Tests/DomainTests
git commit -m "feat(domain): average-cost trade summary and PnL for both directions

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Domain validation: ordering, invariant 5.4, residue-free full close

**Files:**
- Modify: `Tests/DomainTests/TradeCalculatorTests.swift` (append tests)
- Modify: `Sources/Domain/TradeCalculator.swift` (sorting, guards, full-close shortcut)

**Interfaces:**
- Consumes: everything from Task 2.
- Produces: `TradeCalculator.summarize` now enforces spec FR-TX-3/FR-TX-4/§5.4: throws `LedgerError.nonPositiveValue` or `.closingExceedsOpen(transactionID:available:)`, replays in `(occurredAt, sequence)` order. Later milestones (storage, UI) call it to validate add/edit/delete by summarising the would-be transaction list.

- [ ] **Step 1: Add the failing tests**

Append these methods inside `TradeCalculatorTests`, before the closing `}` of the struct:

```swift
    @Test func exampleD_oversellIsRejected() {
        let txs = Self.exampleA + [tx(.sell, "1600", "100", minute: 4, seq: 4)]
        #expect(throws: LedgerError.self) {
            try TradeCalculator.summarize(direction: .buyFirst, transactions: txs)
        }
    }

    @Test func backdatedSellBeforeBuyIsRejectedEvenIfTotalsBalance() {
        // Sell at minute 0 precedes the only buy at minute 1: invalid at that moment.
        let txs = [tx(.buy, "100", "10", minute: 1, seq: 1), tx(.sell, "50", "6", minute: 0, seq: 2)]
        let result = Result { () throws(LedgerError) -> TradeSummary in
            try TradeCalculator.summarize(direction: .buyFirst, transactions: txs)
        }
        guard case .failure(let error) = result, case .closingExceedsOpen(let id, let available) = error else {
            Issue.record("expected closingExceedsOpen"); return
        }
        #expect(id == txs[1].id)
        #expect(available == 0)
    }

    @Test func equalTimestampsUseCreationOrder() throws {
        // Same minute: buy has sequence 1, sell sequence 2, so the sell is valid.
        let txs = [tx(.sell, "50", "6", minute: 1, seq: 2), tx(.buy, "100", "10", minute: 1, seq: 1)]
        let s = try TradeCalculator.summarize(direction: .buyFirst, transactions: txs)
        #expect(s.openQuantity == 50)
        #expect(s.realized == 1)
    }

    @Test func nonPositiveValuesAreRejected() {
        for bad in [tx(.buy, "0", "10", minute: 1, seq: 1), tx(.buy, "10", "0", minute: 1, seq: 1), tx(.buy, "-1", "10", minute: 1, seq: 1)] {
            #expect(throws: LedgerError.self) {
                try TradeCalculator.summarize(direction: .buyFirst, transactions: [bad])
            }
        }
    }

    @Test func fullCloseLeavesNoDecimalResidue() throws {
        // 1/7 is a repeating decimal: without the full-close shortcut openCost ends at 1e-38, not 0.
        let txs = [
            tx(.buy, "7", "1", minute: 1, seq: 1),
            tx(.sell, "1", "1", minute: 2, seq: 2),
            tx(.sell, "6", "1", minute: 3, seq: 3),
        ]
        let s = try TradeCalculator.summarize(direction: .buyFirst, transactions: txs)
        #expect(s.status == .closed)
        #expect(s.openCost == 0)
        #expect(s.realized == 1) // received 2, spent 1
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test`
Expected: FAIL. These five tests fail: `exampleD_oversellIsRejected`, `backdatedSellBeforeBuyIsRejectedEvenIfTotalsBalance`, `equalTimestampsUseCreationOrder`, `nonPositiveValuesAreRejected`, `fullCloseLeavesNoDecimalResidue`. The five tests from Task 2 still pass.

- [ ] **Step 3: Implement sorting, guards and the full-close shortcut**

In `Sources/Domain/TradeCalculator.swift`, replace the whole `TradeCalculator` enum (keep `LedgerError` as is) with:

```swift
public enum TradeCalculator {
    /// Replays transactions chronologically (time, then creation order) using the average-cost method.
    public static func summarize(direction: Direction, transactions: [Transaction]) throws(LedgerError) -> TradeSummary {
        let ordered = transactions.sorted { ($0.occurredAt, $0.sequence) < ($1.occurredAt, $1.sequence) }

        var boughtQuantity: Decimal = 0, boughtAmount: Decimal = 0
        var soldQuantity: Decimal = 0, soldAmount: Decimal = 0
        var openQuantity: Decimal = 0, openCost: Decimal = 0
        var realized: Decimal = 0, openingAmount: Decimal = 0

        for tx in ordered {
            guard tx.quantity > 0, tx.amount > 0 else {
                throw .nonPositiveValue(transactionID: tx.id)
            }
            switch tx.side {
            case .buy: boughtQuantity += tx.quantity; boughtAmount += tx.amount
            case .sell: soldQuantity += tx.quantity; soldAmount += tx.amount
            }

            if tx.side == direction.openingSide {
                openQuantity += tx.quantity
                openCost += tx.amount
                openingAmount += tx.amount
            } else {
                guard tx.quantity <= openQuantity else {
                    throw .closingExceedsOpen(transactionID: tx.id, available: openQuantity)
                }
                // Multiply before dividing, and take the whole cost on a full close, to avoid repeating-decimal residue.
                let closedCost = tx.quantity == openQuantity ? openCost : openCost * tx.quantity / openQuantity
                realized += direction == .buyFirst ? tx.amount - closedCost : closedCost - tx.amount
                openQuantity -= tx.quantity
                openCost -= closedCost
            }
        }

        return TradeSummary(
            direction: direction,
            hasTransactions: !ordered.isEmpty,
            boughtQuantity: boughtQuantity, boughtAmount: boughtAmount,
            soldQuantity: soldQuantity, soldAmount: soldAmount,
            openQuantity: openQuantity, openCost: openCost,
            realized: realized, openingAmount: openingAmount
        )
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test`
Expected: `Test run with 10 tests in 1 suite passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Domain Tests/DomainTests
git commit -m "feat(domain): enforce chronological replay and closing-quantity invariant

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Window spike executable (throwaway)

**Files:**
- Modify: `Package.swift` (add the `WindowSpike` executable target)
- Create: `Sources/WindowSpike/StickerPanel.swift`, `Sources/WindowSpike/SpikeView.swift`, `Sources/WindowSpike/main.swift`

**Interfaces:**
- Consumes: nothing from Domain (the spike is deliberately independent).
- Produces: `swift run WindowSpike` starts a menu bar agent ("TS" in the menu bar, no Dock icon) with menu items: New Sticker, Toggle Pin, Toggle Stationary, Toggle Expand, Print State, Quit. Task 5 exercises it by hand.

- [ ] **Step 1: Add the target to `Package.swift`**

Replace `Package.swift` with:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TradeStick",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "Domain", targets: ["Domain"]),
        .executable(name: "WindowSpike", targets: ["WindowSpike"]),
    ],
    targets: [
        .target(name: "Domain"),
        .testTarget(name: "DomainTests", dependencies: ["Domain"]),
        // Throwaway spike for risk R1 (window behaviour). Not used by any other target.
        .executableTarget(name: "WindowSpike"),
    ]
)
```

- [ ] **Step 2: Create `Sources/WindowSpike/StickerPanel.swift`**

```swift
import AppKit

/// Borderless floating panel. `canBecomeKey` lets text fields receive typing
/// even though the panel is non-activating (the app stays in the background).
final class StickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    static let collapsedHeight: CGFloat = 140
    static let expandedHeight: CGFloat = 340

    convenience init(index: Int) {
        let offset = CGFloat(index) * 30
        self.init(
            contentRect: NSRect(x: 200 + offset, y: 500 - offset, width: 340, height: Self.collapsedHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        setFrameAutosaveName("spike-sticker-\(index)")
    }

    var isPinned: Bool {
        get { level == .floating }
        set { level = newValue ? .floating : .normal }
    }

    var isStationary: Bool {
        get { collectionBehavior.contains(.stationary) }
        set {
            if newValue { collectionBehavior.insert(.stationary) } else { collectionBehavior.remove(.stationary) }
        }
    }

    var isExpanded: Bool { frame.height > Self.collapsedHeight + 1 }

    /// Grows downward: the top edge stays put (AppKit's origin is bottom-left).
    func setExpanded(_ expanded: Bool) {
        let newHeight = expanded ? Self.expandedHeight : Self.collapsedHeight
        var f = frame
        f.origin.y += f.height - newHeight
        f.size.height = newHeight
        setFrame(f, display: true, animate: true)
    }
}
```

- [ ] **Step 3: Create `Sources/WindowSpike/SpikeView.swift`**

```swift
import SwiftUI

struct SpikeView: View {
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GRAM / USDT").font(.headline)
            Text("0.05500")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
            TextField("type here (focus test)", text: $text)
                .textFieldStyle(.roundedBorder)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
    }
}
```

- [ ] **Step 4: Create `Sources/WindowSpike/main.swift`**

```swift
import AppKit
import SwiftUI

@MainActor
final class SpikeController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panels: [StickerPanel] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu bar agent, no Dock icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "TS"
        statusItem.menu = makeMenu()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [
            ("New Sticker", #selector(newSticker)),
            ("Toggle Pin (floating / normal)", #selector(togglePin)),
            ("Toggle Stationary (Mission Control)", #selector(toggleStationary)),
            ("Toggle Expand (animated)", #selector(toggleExpand)),
            ("Print State", #selector(printState)),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc private func newSticker() {
        let panel = StickerPanel(index: panels.count)
        let hosting = NSHostingView(rootView: SpikeView())
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 18
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting
        panel.orderFrontRegardless()
        panels.append(panel)
    }

    @objc private func togglePin() { panels.forEach { $0.isPinned.toggle() } }
    @objc private func toggleStationary() { panels.forEach { $0.isStationary.toggle() } }
    @objc private func toggleExpand() { panels.forEach { $0.setExpanded(!$0.isExpanded) } }

    @objc private func printState() {
        for (i, p) in panels.enumerated() {
            print("sticker \(i): pinned=\(p.isPinned) stationary=\(p.isStationary) expanded=\(p.isExpanded) frame=\(p.frame) screen=\(p.screen?.localizedName ?? "none")")
        }
    }
}

let app = NSApplication.shared
let controller = SpikeController()
app.delegate = controller
app.run()
```

- [ ] **Step 5: Build and verify nothing else broke**

Run: `swift build && swift test`
Expected: `Build complete!` with no warnings about concurrency, then `Test run with 10 tests in 1 suite passed`.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/WindowSpike
git commit -m "spike: throwaway menu bar agent with floating NSPanel for window behaviour tests

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Run the spike by hand and write the M0 report

This task needs a person at the Mac (Claude cannot observe the desktop). The executor runs the spike, the person performs each check, and the result is recorded.

**Files:**
- Create: `docs/specs/m0-window-spike-report.md`
- Modify: `docs/specs/2026-10-13-trade-sticker-mvp-spec.md` (FR-WIN-9, R1, Q3 updated with the findings)

**Interfaces:**
- Consumes: the `WindowSpike` executable from Task 4.
- Produces: a report that fixes the final `collectionBehavior`, window `level`, activation policy and the expand/shift-up approach, used by the M4 plan.

- [ ] **Step 1: Start the spike**

Run: `swift run WindowSpike`
Expected: a `TS` item appears in the menu bar; no Dock icon. Leave the process running; output of "Print State" appears in this terminal.

- [ ] **Step 2: Perform the checks and note PASS / FAIL / observation for each**

Menu: `TS → New Sticker` (use it twice for M0-2).

| ID | Check | Expected |
|---|---|---|
| M0-1 | App starts | `TS` in menu bar, no Dock icon, no app menu bar takeover |
| M0-2 | Two stickers | Two independent windows; drag each by its background; both stay |
| M0-3 | **Typing without stealing focus**: click Safari/Finder first, then click into the sticker text field and type | Text appears in the sticker field; the previously active app stays frontmost (its menu bar remains) |
| M0-4 | Spaces: switch with Ctrl+→ / Ctrl+← | Stickers visible on every Space |
| M0-5 | **Over a fullscreen app**: make Safari fullscreen, switch to its Space | Stickers visible above the fullscreen window (record yes/no) |
| M0-6 | Mission Control (F3) with default behaviour | Record what happens to stickers (stay on screen / hidden / shown as separate window) |
| M0-7 | `Toggle Stationary`, repeat M0-6 and M0-5 | Record the difference |
| M0-8 | `Toggle Pin`, then click a normal app window over the sticker | After unpinning the sticker goes behind it; pinning again brings it above |
| M0-9 | `Toggle Expand` | Window grows downward smoothly, top edge fixed; collapses back to the same top edge |
| M0-10 | Expand a sticker placed at the very bottom of the screen | Record whether it goes off-screen (the real app must shift it up, FR-TX-8) |
| M0-11 | Second display (if available): drag a sticker across; then unplug/replug or change resolution | Record where the window ends up; whether it stays reachable |
| M0-12 | Sleep and wake the Mac | Stickers still present and responsive |
| M0-13 | Quit (`TS → Quit`) and run `swift run WindowSpike` again, `New Sticker` twice | Positions are restored from the frame autosave (record yes/no, and whether the second sticker also restores) |

- [ ] **Step 3: Write `docs/specs/m0-window-spike-report.md`**

Fill every `<…>` with what was observed. Structure (keep it short, one line per check plus a conclusion):

```markdown
# M0 Window Spike — Report

Date: <date>. macOS <version>. Displays: <count>. Spike commit: <git short sha>.

## Results

| ID | Result (PASS/FAIL) | Observation |
|---|---|---|
| M0-1 | <…> | <…> |
| … one row per check M0-1 … M0-13 | | |

## Decisions for the real window layer (M4)

- Style mask / panel class: <final choice, e.g. borderless + nonactivatingPanel NSPanel subclass with canBecomeKey>
- Window level when pinned / unpinned: <…>
- collectionBehavior: <final set, with `.stationary` yes/no and why>
- Over fullscreen apps: <supported / not supported, requirement>
- Typing: <works / needs workaround X>
- Expand near screen bottom: <approach, e.g. shift up by overflow>
- Multi-display / resolution change: <approach, e.g. validate saved frame against NSScreen.screens on restore>
- Spike code is throwaway: do not import it; copy only the verified settings.
```

- [ ] **Step 4: Update the spec with the findings**

In `docs/specs/2026-10-13-trade-sticker-mvp-spec.md`:
- Replace the body of **FR-WIN-9** with the observed behaviour (the exact supported combination for fullscreen / Mission Control).
- In section 11, mark **R1** as closed with a pointer to `docs/specs/m0-window-spike-report.md`.
- In section 12, set **Q3** to the decision.
- If any check M0-3 … M0-5 FAILED, add an explicit line to section 11 naming the workaround or the accepted limitation.

- [ ] **Step 5: Commit**

```bash
git add docs/specs
git commit -m "docs: M0 window spike report and spec updates

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

## Self-Review Notes

- **Spec coverage:** §5.1–5.4 and examples A–D (Tasks 2–3), FR-TX-3/FR-TX-4 validation (Task 3), FR-STORE-3 "status derived" (`TradeSummary.status`), R1/Q3 and FR-WIN-9 (Tasks 4–5). Not covered here by design: FR-TX-2 rate/amount/quantity linking, persistence, market data, UI (later plans). Example E was removed from the spec with Target.
- **Types:** `Side`, `Direction`, `Transaction`, `TradeStatus`, `PnL`, `TradeSummary`, `LedgerError`, `TradeCalculator.summarize(direction:transactions:)` are defined in Task 2 and used with the same names and signatures in Task 3 and the tests.
- **Verified before writing:** the Domain sources and the ten tests, and the spike sources, were compiled and run with Swift 6.4 / Xcode 27 in a scratch package (10 tests pass; spike builds in Swift 6 mode). The five Task 3 tests fail against the Task 2 calculator and pass against the Task 3 calculator.
