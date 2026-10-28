import Foundation
import Testing
@testable import TimerCore

struct EarningsTests {
  @Test func `rate is the sum of incomes over the month norm`() throws {
    let engine = try makeEngine([Income(name: "a", amount: 340_000, currency: .rub)])
    #expect(engine.rate(year: 2026, month: 10, fx: nil).perHourRUB == 340_000.0 / 176)
    #expect(try makeEngine().rate(year: 2026, month: 10, fx: nil).perHourRUB == 1700)
  }

  @Test func `foreign incomes are converted at the CBR rate`() throws {
    let engine = try makeEngine([october1700, Income(name: "US", amount: 1000, currency: .usd)])
    #expect(engine.rate(year: 2026, month: 10, fx: usdFX).perHourRUB == 1700 + 87_400.0 / 176)
  }

  @Test func `an income without a known rate is excluded`() throws {
    let usd = Income(name: "US", amount: 1000, currency: .usd)
    let rate = try makeEngine([october1700, usd]).rate(year: 2026, month: 10, fx: nil)
    #expect(rate.perHourRUB == 1700)
    #expect(rate.excluded == [usd])
  }

  @Test func `a full month with a shortened day pays exactly the salary`() throws {
    let engine = try makeEngine([Income(name: "a", amount: 200_000, currency: .rub)])
    let rate = engine.rate(year: 2026, month: 11, fx: nil).perHourRUB
    let total = engine.workCalendar.days(inMonth: 2026, 11, calendar: moscow)
      .compactMap { engine.status(on: $0).plan }
      .reduce(0) { $0 + $1.dayPay(rate: rate) }
    #expect(abs(total - 200_000) < 0.001)
  }

  @Test func `vacation does not change the rate`() throws {
    let base = try makeEngine().rate(year: 2026, month: 10, fx: nil)
    let withVacation = try makeEngine(vacations: [VacationRange(from: day("2026-10-12"), to: day("2026-10-16"))])
    #expect(withVacation.rate(year: 2026, month: 10, fx: nil) == base)
  }

  @Test(arguments: [
    ("2026-10-27 08:00", 0.0),
    ("2026-10-27 09:00", 0.0),
    ("2026-10-27 13:30", 7650.0),  // lunch keeps paying
    ("2026-10-27 13:15", 7225.0),
    ("2026-10-27 17:00", 13_600.0),
    ("2026-10-27 19:30", 13_600.0),  // overtime adds nothing
  ])
  func `earnings grow evenly through the day`(moment: String, expected: Double) throws {
    let plan = try #require(try makeEngine().status(on: day("2026-10-27")).plan)
    #expect(abs(plan.earned(rate: 1700, at: at(moment)) - expected) < 0.001)
  }

  @Test func `a schedule longer than the norm spreads the day's pay over it`() throws {
    let engine = try makeEngine(schedule: Schedule(start: t(9, 0), end: t(18, 0), lunchStart: t(13, 0)))
    let plan = try #require(engine.status(on: day("2026-10-27")).plan)
    #expect(plan.earned(rate: 1700, at: at("2026-10-27 18:00")) == 13_600)
    #expect(abs(plan.earned(rate: 1700, at: at("2026-10-27 10:00")) - 13_600.0 / 9) < 0.001)
  }

  @Test func `hourly breakdown marks finished and running hours`() throws {
    let plan = try #require(try makeEngine().status(on: day("2026-10-27")).plan)
    let slots = plan.hourSlots(rate: 1700, at: at("2026-10-27 11:30"))
    #expect(slots.count == 8)
    #expect(slots[0].state == .done && slots[0].earnedRUB == 1700)
    #expect(slots[1].state == .done && slots[1].earnedRUB == 1700)
    #expect(slots[2].state == .inProgress && abs(slots[2].earnedRUB - 850) < 0.001)
    #expect(slots[3].state == .upcoming && slots[3].earnedRUB == 0)
  }

  @Test func `CBR payload is parsed per unit`() throws {
    let fx = try FXRates.parseCBR(fixture("cbr-daily.json"))
    #expect(fx.date == day("2026-10-27"))
    #expect(fx.rubPer(.usd) == 80.4909)
    #expect(fx.rubPer(.eur) == 90.0935)
    #expect(fx.rubPer(.rub) == 1)
    #expect(throws: (any Error).self) { try FXRates.parseCBR(Data("{}".utf8)) }
  }

  @Test func `conversion goes both ways`() {
    #expect(usdFX.toRUB(100, from: .usd) == 8740)
    #expect(usdFX.fromRUB(8740, to: .usd) == 100)
    #expect(usdFX.toRUB(5, from: .rub) == 5)
  }

  @Test(arguments: [
    (8452.0, Currency.rub, "8 452 ₽"),
    (1_234_567.6, .rub, "1 234 568 ₽"),
    (0, .rub, "0 ₽"),
    (100, .usd, "$100.00"),
    (1234.5, .eur, "€1,234.50"),
  ])
  func `money formatting`(amount: Double, currency: Currency, expected: String) {
    #expect(MoneyFormatter.format(amount, currency) == expected)
  }

  @Test func `amounts are shown in the display currency`() {
    #expect(MoneyFormatter.format(rub: 8740, in: .usd, fx: usdFX) == "$100.00")
    #expect(MoneyFormatter.format(rub: 8740, in: .usd, fx: nil) == nil)
    #expect(MoneyFormatter.format(rub: 8740, in: .rub, fx: nil) == "8 740 ₽")
  }
}
