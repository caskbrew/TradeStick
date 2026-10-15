import Domain
import Foundation
import Testing
@testable import Presentation

func dec(_ s: String) -> Decimal { Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))! }
let now = Date(timeIntervalSince1970: 1_700_000_000)

@Suite struct DecimalInputTests {
    @Test func acceptsDotCommaAndSpaces() {
        #expect(DecimalInput.parse("1.5") == dec("1.5"))
        #expect(DecimalInput.parse("1,5") == dec("1.5"))
        #expect(DecimalInput.parse("1 234,56") == dec("1234.56"))
        #expect(DecimalInput.parse("1\u{00A0}000") == 1000)
        #expect(DecimalInput.parse(".5") == dec("0.5"))
        #expect(DecimalInput.parse("5.") == 5)
        #expect(DecimalInput.parse("0.00000001") == dec("0.00000001"))
    }

    @Test func rejectsEverythingElse() {
        for bad in ["", " ", "-1", "+1", "abc", "1e5", "1.2.3", "1,2,3", "1,234.5", ".", ",", "1/2", "٣"] {
            #expect(DecimalInput.parse(bad) == nil, "\(bad)")
        }
    }
}

@Suite struct NumberFormatTests {
    @Test func pricesHaveAFixedScalePerMagnitude() {
        #expect(NumberFormat.price(dec("1.34")) == "1.3400")
        #expect(NumberFormat.price(dec("0.055")) == "0.055000")
        #expect(NumberFormat.price(dec("0.0533333333")) == "0.053333")
        #expect(NumberFormat.price(dec("67432.1")) == "67432.10")
        #expect(NumberFormat.price(dec("1.123456789")) == "1.1235")
        #expect(NumberFormat.price(dec("1")) == "1.0000")
        #expect(NumberFormat.price(dec("0.5")) == "0.500000")
        #expect(NumberFormat.price(dec("0.000001234567")) == "0.000001235")
        #expect(NumberFormat.price(dec("0.00000000012345")) == "0.0000000001") // 10 decimals at most
    }

    @Test func transactionAmountsShowUpToSixDecimals() {
        #expect(NumberFormat.amount(dec("40")) == "40.00")
        #expect(NumberFormat.amount(dec("40.123456789")) == "40.123457")
        #expect(NumberFormat.amount(dec("1234.5")) == "1,234.50")
        #expect(NumberFormat.amount(dec("0.1")) == "0.10")
    }

    @Test func quoteAmountsUseTwoDecimalsOrFourBelowOne() {
        #expect(NumberFormat.quote(dec("48")) == "48.00")
        #expect(NumberFormat.quote(dec("9.5")) == "9.50")
        #expect(NumberFormat.quote(dec("0.5")) == "0.50")
        #expect(NumberFormat.quote(dec("0.12345")) == "0.1235")
        #expect(NumberFormat.quote(dec("1234.567")) == "1234.57")
    }

    @Test func signedAmountsAlwaysCarryASignExceptZero() {
        #expect(NumberFormat.signedQuote(dec("9.5")) == "+9.50")
        #expect(NumberFormat.signedQuote(dec("-4.5")) == "\u{2212}4.50")
        #expect(NumberFormat.signedQuote(0) == "0.00")
        #expect(NumberFormat.signedQuote(dec("-0.05")) == "\u{2212}0.05")
    }

    @Test func aTinyValueThatRoundsToZeroHasNoSignAndIsNotColoured() {
        #expect(NumberFormat.signedQuote(dec("0.00004")) == "0.00")
        #expect(NumberFormat.signedQuote(dec("-0.00004")) == "0.00")
        #expect(NumberFormat.displayedQuote(dec("0.00004")) == 0)
        #expect(NumberFormat.signedQuote(dec("0.0004")) == "+0.0004")
        #expect(NumberFormat.signedQuote(dec("1234.004")) == "+1234.00")
        #expect(NumberFormat.displayedPercent(dec("0.00004")) == 0)
        #expect(NumberFormat.signedPercent(dec("-0.00004")) == "0.00%")
    }

    @Test func quantitiesAreGroupedAndTrimmed() {
        #expect(NumberFormat.quantity(1500) == "1,500.00")
        #expect(NumberFormat.quantity(dec("0.5")) == "0.50")
        #expect(NumberFormat.quantity(dec("1234567.12345678")) == "1,234,567.12345678")
        #expect(NumberFormat.quantity(dec("0.123456789")) == "0.12345679")
    }

    @Test func percentsHaveTwoDecimalsAndASign() {
        #expect(NumberFormat.signedPercent(dec("0.11875")) == "+11.88%")
        #expect(NumberFormat.signedPercent(dec("-0.012")) == "\u{2212}1.20%")
        #expect(NumberFormat.signedPercent(0) == "0.00%")
        #expect(NumberFormat.signedPercent(dec("0.17500")) == "+17.50%")
    }
}

@Suite struct TransactionDraftTests {
    func draft() -> TransactionDraft { TransactionDraft(side: .buy, occurredAt: now) }

    @Test func rateIsComputedFromQuantityAndAmount() {
        var d = draft()
        d.edit(.quantity, "500")
        d.edit(.amount, "30")
        #expect(d.rateText == "0.060000") // 30 / 500, the reference-image error C25
        #expect(d.isAuto(.rate) && !d.isAuto(.amount))
        #expect(d.savable(now: now)?.amount == 30)
    }

    @Test func editingRateMakesAmountComputedAndRoundsToEightDecimals() {
        var d = draft()
        d.edit(.quantity, "500")
        d.edit(.amount, "30")
        d.edit(.rate, "0.07")
        #expect(d.amountText == "35")
        #expect(d.isAuto(.amount) && !d.isAuto(.rate))

        d.edit(.quantity, "3")
        d.edit(.rate, "0.333333333")
        #expect(d.amount == dec("1")) // 0.999999999 rounds to 1.00000000
        #expect(d.savable(now: now)?.amount == 1)
    }

    @Test func changingQuantityRecomputesTheDerivedField() {
        var d = draft()
        d.edit(.quantity, "100")
        d.edit(.amount, "10")
        d.edit(.quantity, "200")
        #expect(d.rateText == "0.050000") // amount stays, rate follows

        d.edit(.rate, "0.1")
        d.edit(.quantity, "50")
        #expect(d.amountText == "5") // rate stays, amount follows
    }

    @Test func derivedFieldIsEmptyWhileQuantityIsEmptyOrZero() {
        var d = draft()
        d.edit(.amount, "30")
        #expect(d.rateText == "")
        d.edit(.quantity, "0")
        #expect(d.rateText == "")
        d.edit(.quantity, "500")
        #expect(d.rateText == "0.060000")
    }

    @Test func commaInputWorks() {
        var d = draft()
        d.edit(.quantity, "1 000,5")
        d.edit(.amount, "55,5")
        #expect(d.quantity == dec("1000.5"))
        #expect(d.savable(now: now)?.amount == dec("55.5"))
    }

    @Test func untouchedFormIsNotSavableButShowsNoError() {
        let d = draft()
        #expect(d.savable(now: now) == nil)
        #expect(d.problems(now: now).isEmpty)
    }

    @Test func invalidInputIsReportedAndBlocksSaving() {
        var d = draft()
        d.edit(.quantity, "abc")
        d.edit(.amount, "-5")
        #expect(d.problems(now: now) == [.quantityInvalid, .amountInvalid])
        #expect(d.savable(now: now) == nil)

        d.edit(.quantity, "10")
        d.edit(.rate, "0")
        #expect(d.problems(now: now) == [.rateInvalid])

        d.edit(.rate, "0.0000000001") // 10 × 1e-10 = 1e-9 rounds to 0 at 8 decimals
        #expect(d.problems(now: now) == [.amountInvalid])
        #expect(d.savable(now: now) == nil)
    }

    @Test func rateWithoutQuantityIsNotBlamedOnAmount() {
        var d = draft()
        d.edit(.rate, "0.05")
        #expect(d.problems(now: now).isEmpty)
        #expect(d.savable(now: now) == nil)
    }

    @Test func timeMayBeAtMostOneMinuteAhead() {
        var d = draft()
        d.edit(.quantity, "1")
        d.edit(.amount, "1")
        d.isNow = false
        d.occurredAt = now.addingTimeInterval(59)
        #expect(d.savable(now: now) != nil)
        d.occurredAt = now.addingTimeInterval(61)
        #expect(d.problems(now: now) == [.timeInFuture])
        #expect(d.savable(now: now) == nil)
    }

    @Test func nowIsStampedAtSaveTimeUntilATimeIsPicked() {
        var d = draft() // opened an hour ago
        #expect(d.isNow && d.time(at: now) == now)
        d.isNow = false
        d.occurredAt = now.addingTimeInterval(-3600)
        #expect(d.time(at: now) == now.addingTimeInterval(-3600))
    }

    @Test func closePrefillsWholeQuantityAtCurrentPrice() {
        let d = TransactionDraft(side: .sell, occurredAt: now, quantity: 900, rate: dec("0.055"))
        #expect(d.quantityText == "900")
        #expect(d.rateText == "0.055000")
        #expect(d.amountText == "49.5")
        #expect(d.savable(now: now)?.amount == dec("49.5"))
    }
}

@Suite struct InstrumentParserTests {
    let gramUsdt = Instrument(base: "GRAM", quote: "USDT")

    @Test func separatorsAndCaseAreFree() {
        for input in ["GRAM/USDT", "gram/usdt", "GRAM-USDT", "gram_usdt", " gram usdt ", "Gram / Usdt"] {
            #expect(InstrumentParser.candidates(input) == [gramUsdt], "\(input)")
        }
    }

    @Test func symbolWithoutSeparatorSplitsOnKnownQuotes() {
        #expect(InstrumentParser.candidates("GRAMUSDT") == [gramUsdt])
        #expect(InstrumentParser.candidates("btceur") == [Instrument(base: "BTC", quote: "EUR")])
        // Ambiguous: the exchange list decides which candidate exists.
        #expect(InstrumentParser.candidates("ETHBTC") == [Instrument(base: "ETH", quote: "BTC")])
        #expect(InstrumentParser.candidates("BNBBTC").count == 1)
    }

    @Test func garbageGivesNoCandidates() {
        for input in ["", "   ", "USDT", "GRAM/", "A/B/C", "GR@M/USDT", "GRAMXYZ"] {
            #expect(InstrumentParser.candidates(input).isEmpty, "\(input)")
        }
    }
}

@Suite struct ElapsedTests {
    @Test func formats() {
        #expect(Elapsed.duration(30) == "<1m")
        #expect(Elapsed.duration(60) == "1m")
        #expect(Elapsed.duration(59 * 60 + 59) == "59m")
        #expect(Elapsed.duration(3600) == "1h")
        #expect(Elapsed.duration(5 * 3600 + 12 * 60) == "5h 12m")
        #expect(Elapsed.duration(86400 + 4 * 3600 + 59) == "1d 4h")
        #expect(Elapsed.duration(86400) == "1d")
        #expect(Elapsed.duration(-5) == "<1m")
        #expect(Elapsed.age(30) == "<1m" && Elapsed.age(90 * 60) == "90m" && Elapsed.age(91 * 60) == "1h")
        #expect(Elapsed.age(73 * 3600 + 59) == "73h" && Elapsed.age(74 * 3600) == "3d" && Elapsed.age(10 * 86400) == "10d")
    }
}

@Suite struct DraftEditTests {
    @Test func prefilledFromTransactionKeepsAmountAndDerivesRate() {
        let d = TransactionDraft(side: .buy, occurredAt: now, quantity: dec("1000"), amount: dec("50.123456"))
        #expect(d.quantityText == "1000" && d.amountText == "50.123456" && d.rateText == "0.050123")
        #expect(d.driver == .amount)
    }
}

@Suite struct TimeInputTests {
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    // 2026-10-15 12:00 UTC
    let ref = Date(timeIntervalSince1970: 1_792_065_600)

    func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    @Test func parsesTimeOnlyDateAndYear() {
        #expect(TimeInput.parse("9:05", now: ref, calendar: cal) == at(2026, 10, 15, 9, 5))
        #expect(TimeInput.parse("03.10 18:30", now: ref, calendar: cal) == at(2026, 10, 3, 18, 30))
        #expect(TimeInput.parse("3-10-25 18:30", now: ref, calendar: cal) == at(2025, 10, 3, 18, 30))
        #expect(TimeInput.parse(" 03/10/2025  18:30 ", now: ref, calendar: cal) == at(2025, 10, 3, 18, 30))
        #expect(TimeInput.parse("03.10 18:30:45", now: ref, calendar: cal) == at(2026, 10, 3, 18, 30).addingTimeInterval(45))
        #expect(TimeInput.parse("07:08:09", now: ref, calendar: cal) == at(2026, 10, 15, 7, 8).addingTimeInterval(9))
    }

    @Test func rejectsGarbageAndImpossibleDates() {
        for bad in ["", "abc", "25:00", "12:60", "31.02 10:00", "10.13 10:00", "10.10", "1 2 3", "12.10.2025.1 10:00", "12:1x", "12:00:61", "12:00:", "1:2:3:4"] {
            #expect(TimeInput.parse(bad, now: ref, calendar: cal) == nil, "\(bad)")
        }
    }

    @Test func formatRoundTrips() {
        let d = at(2025, 10, 3, 18, 30)
        #expect(TimeInput.format(d, calendar: cal) == "03.10.25 18:30:00")
        #expect(TimeInput.parse(TimeInput.format(d, calendar: cal), now: ref, calendar: cal) == d)
    }

    @Test func invalidTimeBlocksSaving() {
        var d = TransactionDraft(side: .buy, occurredAt: ref)
        d.edit(.quantity, "1"); d.edit(.amount, "1")
        d.timeInvalid = true
        #expect(d.problems(now: ref) == [.timeInvalid])
        #expect(d.savable(now: ref) == nil)
    }
}
