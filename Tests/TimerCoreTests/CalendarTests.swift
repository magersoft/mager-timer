import Foundation
import Testing
@testable import TimerCore

struct CalendarTests {
  @Test func `holidays, weekends and shortened days follow the 2026 production calendar`() throws {
    let cal = try calendar2026()
    #expect(cal.kind(of: day("2026-11-04"), calendar: moscow) == .nonWorking)  // Wednesday, holiday
    #expect(cal.kind(of: day("2026-11-03"), calendar: moscow) == .short)
    #expect(cal.kind(of: day("2026-10-27"), calendar: moscow) == .working)
    #expect(cal.kind(of: day("2026-10-31"), calendar: moscow) == .nonWorking)  // Saturday
    #expect(cal.kind(of: day("2026-01-05"), calendar: moscow) == .nonWorking)  // Monday, New Year holidays
  }

  @Test func `a Saturday declared working by transfer is a working day`() throws {
    var raw = Array(try calendar2026().years[2026]!)
    let index = moscow.ordinality(of: .day, in: .year, for: at("2026-10-31 12:00"))! - 1
    raw[index] = "0"
    let cal = WorkCalendar(years: [2026: String(raw)])
    #expect(cal.kind(of: day("2026-10-31"), calendar: moscow) == .working)
  }

  @Test func `without data weekdays are working and the calendar is approximate`() throws {
    let engine = try makeEngine()
    #expect(engine.isCalendarApproximate(for: day("2027-03-08")))
    #expect(engine.workCalendar.kind(of: day("2027-03-08"), calendar: moscow) == .working)  // holiday unknown
    #expect(engine.workCalendar.kind(of: day("2027-03-06"), calendar: moscow) == .nonWorking)
    #expect(!engine.isCalendarApproximate(for: day("2026-03-09")))
  }

  @Test func `malformed isdayoff payloads are rejected`() {
    #expect(throws: WorkCalendar.ParseError.wrongLength(3)) { try WorkCalendar.validate("010", year: 2026, calendar: moscow) }
    #expect(throws: WorkCalendar.ParseError.badCharacter("x")) {
      try WorkCalendar.validate(String(repeating: "0", count: 364) + "x", year: 2026, calendar: moscow)
    }
  }

  @Test func `month norm counts 8 hours per day and 7 per shortened day`() throws {
    let cal = try calendar2026()
    #expect(cal.normHours(year: 2026, month: 10, calendar: moscow) == 176)
    #expect(cal.normHours(year: 2026, month: 11, calendar: moscow) == 19 * 8 + 7)
  }

  @Test func `shortened day ends an hour earlier`() throws {
    let plan = try #require(try makeEngine().status(on: day("2026-11-03")).plan)
    #expect(plan.isShort)
    #expect(plan.start == at("2026-11-03 09:00"))
    #expect(plan.end == at("2026-11-03 16:00"))
    #expect(plan.normHours == 7)
  }

  @Test func `vacation and a paid day off are paid leave, an unpaid day off is not paid`() throws {
    let engine = try makeEngine(vacations: [VacationRange(from: day("2026-11-10"), to: day("2026-11-24"))])
    let plan = try #require(engine.status(on: day("2026-11-12")).paidPlan)
    #expect(engine.status(on: day("2026-11-12")) == .paidLeave(plan, .vacation))
    #expect(engine.status(on: day("2026-11-12")).plan == nil)
    #expect(engine.status(on: day("2026-11-24")).paidPlan != nil)
    #expect(engine.status(on: day("2026-11-25")).plan != nil)
    #expect(engine.status(on: day("2026-11-14")) == .nonWorking(.holiday))  // a Saturday inside the vacation
    let today = day("2026-10-27")
    #expect(engine.status(on: today, dayOffs: [today: .unpaid]) == .nonWorking(.unpaidDayOff))
    if case .paidLeave(_, .paidDayOff) = engine.status(on: today, dayOffs: [today: .paid]) {} else { Issue.record("expected paid day off") }
    #expect(engine.status(on: day("2026-11-04")) == .nonWorking(.holiday))
  }

  @Test(arguments: [
    ([10, 25], "2026-10-27", "2026-11-10"),
    ([10, 25], "2026-10-23", "2026-10-23"),  // 25 Oct is a Sunday: paid on Friday 23rd
    ([25], "2026-10-22", "2026-10-23"),
    ([4], "2026-11-01", "2026-11-03"),  // 4 Nov holiday → 3 Nov
    ([31], "2026-11-01", "2026-11-30"),  // clamped to the month's length
    ([5], "2026-12-31", "2027-01-05"),
  ])
  func `next payday moves off weekends and holidays`(paydays: [Int], today: String, expected: String) throws {
    var income = october1700
    income.payouts = paydays.map { Payout(day: $0, percent: 100 / paydays.count) }
    let engine = try makeEngine([income])
    #expect(engine.nextPayout(onOrAfter: day(today))?.date == day(expected))
  }

  @Test func `no paydays, no payday`() throws {
    #expect(try makeEngine().nextPayout(onOrAfter: day("2026-10-27")) == nil)
  }

  @Test func `payout collects every income paid that day`() throws {
    let salary = Income(name: "ЗП", amount: 100_000, currency: .rub, payouts: [Payout(day: 25, percent: 40), Payout(day: 10, percent: 60)])
    let contract = Income(name: "Контракт", amount: 2000, currency: .usd, payouts: [Payout(day: 10, percent: 100)])
    let engine = try makeEngine([salary, contract])
    let november = try #require(engine.nextPayout(onOrAfter: day("2026-10-27")))
    #expect(november.date == day("2026-11-10"))
    #expect(november.shares.map(\.income.name) == ["ЗП", "Контракт"])
    #expect(november.shares.map(\.amount) == [60_000, 2000])
    // 25 Oct is a Sunday: only the salary advance, on Friday 23rd.
    let advance = try #require(engine.nextPayout(onOrAfter: day("2026-10-21")))
    #expect(advance.date == day("2026-10-23") && advance.shares.map(\.amount) == [40_000])
  }

  @Test(arguments: [
    ("2026-10-27 08:30", DayPhase.beforeStart),
    ("2026-10-27 09:00", .working),
    ("2026-10-27 13:20", .lunch),
    ("2026-10-27 14:00", .working),
    ("2026-10-27 17:05", .afterHours),
  ])
  func `phase of the moment`(moment: String, phase: DayPhase) throws {
    let engine = try makeEngine()
    let status = engine.status(on: day("2026-10-27"))
    #expect(engine.phase(at: at(moment), status: status, overtime: OvertimeState()) == phase)
  }

  @Test func `a closed day is in the closed phase`() throws {
    let engine = try makeEngine()
    let closed = OvertimeState(closedAt: at("2026-10-27 17:15"), finalOvertime: 0)
    #expect(engine.phase(at: at("2026-10-27 19:00"), status: engine.status(on: day("2026-10-27")), overtime: closed) == .closed)
  }
}
