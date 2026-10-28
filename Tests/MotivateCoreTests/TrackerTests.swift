import Foundation
import Testing
@testable import MotivateCore

struct TrackerTests {
  /// Ticks every minute and collects events.
  @discardableResult
  func run(_ tracker: inout DayTracker, _ engine: Engine, from: String, to: String, fx: FXRates? = nil, active: (Date) -> Bool = { _ in true }) -> [DayTracker.Event] {
    var events: [DayTracker.Event] = []
    var lastInput = at(from)
    var now = at(from)
    while now <= at(to) {
      if active(now) { lastInput = now }
      events += tracker.tick(now: now, idleSeconds: now.timeIntervalSince(lastInput), latestFX: fx, engine: engine)
      now.addTimeInterval(60)
    }
    return events
  }

  @Test func `start and end notifications fire once at the right moments`() throws {
    let engine = try makeEngine()
    var tracker = DayTracker(today: started("2026-10-27"), history: [])
    let events = run(&tracker, engine, from: "2026-10-27 08:50", to: "2026-10-27 17:10")
    #expect(events == [.dayStarted(expectedRUB: 13_600), .dayEnded(totalRUB: 13_600)])
  }

  @Test func `waking after the start delivers the start notification once`() throws {
    let engine = try makeEngine()
    var tracker = DayTracker(today: started("2026-10-27"), history: [])
    #expect(tracker.tick(now: at("2026-10-27 09:40"), idleSeconds: 1, latestFX: nil, engine: engine) == [.dayStarted(expectedRUB: 13_600)])
    #expect(tracker.tick(now: at("2026-10-27 09:41"), idleSeconds: 1, latestFX: nil, engine: engine) == [])
  }

  @Test func `waking long after the end sends nothing stale`() throws {
    let engine = try makeEngine()
    var tracker = DayTracker(today: started("2026-10-27"), history: [])
    #expect(tracker.tick(now: at("2026-10-27 20:00"), idleSeconds: 1, latestFX: nil, engine: engine) == [])
    #expect(tracker.today.earnedRUB == 13_600)
  }

  @Test func `overtime reminds every full hour until the day closes`() throws {
    let engine = try makeEngine()
    var tracker = DayTracker(today: started("2026-10-27"), history: [])
    let events = run(&tracker, engine, from: "2026-10-27 16:59", to: "2026-10-27 19:30") { $0 <= at("2026-10-27 19:05") }
    #expect(events.filter { if case .overtime = $0 { true } else { false } } == [.overtime(hours: 1), .overtime(hours: 2)])
    #expect(tracker.today.overtime.isClosed)
    #expect(tracker.today.overtimeSeconds == 125 * 60)
  }

  @Test func `no events or earnings on a non-working day`() throws {
    let engine = try makeEngine()
    var tracker = DayTracker(today: started("2026-11-04"), history: [])
    #expect(run(&tracker, engine, from: "2026-11-04 08:00", to: "2026-11-04 19:00").isEmpty)
    #expect(tracker.today.earnedRUB == 0)
  }

  @Test func `a day off zeroes the day and can be undone`() throws {
    let engine = try makeEngine()
    var tracker = DayTracker(today: started("2026-10-27"), history: [])
    _ = tracker.tick(now: at("2026-10-27 11:00"), idleSeconds: 1, latestFX: nil, engine: engine)
    tracker.setDayOff(.unpaid)
    _ = tracker.tick(now: at("2026-10-27 11:01"), idleSeconds: 1, latestFX: nil, engine: engine)
    #expect(tracker.today.earnedRUB == 0)
    tracker.setDayOff(nil)
    _ = tracker.tick(now: at("2026-10-27 11:00"), idleSeconds: 1, latestFX: nil, engine: engine)
    #expect(tracker.today.earnedRUB == 2 * 1700)
  }

  @Test func `the exchange rate is fixed on the first calculation of the day`() throws {
    let engine = try makeEngine([october1700, Income(name: "US", amount: 1000, currency: .usd)])
    var tracker = DayTracker(today: started("2026-10-27"), history: [])
    _ = tracker.tick(now: at("2026-10-27 09:30"), idleSeconds: 1, latestFX: usdFX, engine: engine)
    var later = usdFX
    later.rubPerUnit["USD"] = 100
    _ = tracker.tick(now: at("2026-10-27 15:00"), idleSeconds: 1, latestFX: later, engine: engine)
    #expect(tracker.today.fx == usdFX)
    #expect(tracker.today.rateRUB == 1700 + 87_400.0 / 176)
  }

  @Test func `missed working days are filled with a full day and no overtime`() throws {
    let engine = try makeEngine()
    let monday = DayRecord(date: day("2026-10-26"), earnedRUB: 13_600, rateRUB: 1700, normHours: 8, scheduleHours: 8,
                           overtime: OvertimeState(closedAt: at("2026-10-26 17:15"), finalOvertime: 0))
    let (tracker, changed) = DayTracker.restore(records: [monday], now: at("2026-10-29 10:00"), latestFX: nil, engine: engine)
    #expect(changed.map(\.date) == [day("2026-10-27"), day("2026-10-28")])
    #expect(changed.allSatisfy { $0.earnedRUB == 13_600 && $0.overtimeSeconds == 0 && $0.overtime.isClosed })
    #expect(tracker.history.count == 3)
    #expect(tracker.today.date == day("2026-10-29"))
  }

  @Test func `a past day left open is finalized at full pay with its observed overtime`() throws {
    let engine = try makeEngine()
    let open = DayRecord(date: day("2026-10-27"), earnedRUB: 5000, overtime: OvertimeState(lastActivityAt: at("2026-10-27 17:40")))
    let (tracker, changed) = DayTracker.restore(records: [open], now: at("2026-10-28 09:00"), latestFX: nil, engine: engine)
    let record = try #require(changed.first)
    #expect(record.earnedRUB == 13_600)
    #expect(record.overtimeSeconds == 40 * 60)
    #expect(tracker.history.first == record)
  }

  @Test func `restarting in the evening keeps accumulated overtime`() throws {
    let engine = try makeEngine()
    var tracker = DayTracker(today: started("2026-10-27"), history: [])
    run(&tracker, engine, from: "2026-10-27 17:00", to: "2026-10-27 17:40")
    let saved = tracker.today
    var (restored, _) = DayTracker.restore(records: [saved], now: at("2026-10-27 17:41"), latestFX: nil, engine: engine)
    _ = restored.tick(now: at("2026-10-27 17:41"), idleSeconds: 0, latestFX: nil, engine: engine)
    #expect(restored.today.overtimeSeconds == 41 * 60)
  }

  @Test func `changing the salary mid-month leaves history untouched`() throws {
    let past = DayRecord(date: day("2026-10-14"), earnedRUB: 13_600, rateRUB: 1700, normHours: 8,
                         overtime: OvertimeState(closedAt: at("2026-10-14 17:15"), finalOvertime: 0))
    var engine = try makeEngine()
    engine.settings.incomes = [Income(name: "Работа", amount: 2000 * 176, currency: .rub)]
    var tracker = DayTracker(today: started("2026-10-15"), history: [past])
    _ = tracker.tick(now: at("2026-10-15 17:00"), idleSeconds: 1, latestFX: nil, engine: engine)
    #expect(tracker.history[0].earnedRUB == 13_600)
    #expect(tracker.today.earnedRUB == 16_000)
    #expect(tracker.monthSummary(engine: engine).earnedRUB == 29_600)
  }

  @Test func `midnight rolls the day over into history`() throws {
    let engine = try makeEngine()
    var tracker = DayTracker(today: started("2026-10-27"), history: [])
    run(&tracker, engine, from: "2026-10-27 16:00", to: "2026-10-27 17:30")
    let changed = tracker.rollOver(now: at("2026-10-28 00:01"), latestFX: nil, engine: engine)
    #expect(changed.map(\.date) == [day("2026-10-27")])
    #expect(tracker.today.date == day("2026-10-28"))
    #expect(tracker.history.last?.earnedRUB == 13_600)
  }

  @Test func `month summary counts gifted overtime at each day's rate`() throws {
    let engine = try makeEngine()
    let a = DayRecord(date: day("2026-10-20"), earnedRUB: 13_600, rateRUB: 1700, overtimeSeconds: 3 * 3600)
    let b = DayRecord(date: day("2026-10-21"), earnedRUB: 14_000, rateRUB: 1750, overtimeSeconds: 2 * 3600)
    let tracker = DayTracker(today: started("2026-10-31"), history: [a, b])
    let summary = tracker.monthSummary(engine: engine)
    #expect(summary.overtimeSeconds == 5 * 3600)
    #expect(summary.giftedRUB == 8600)
    #expect(summary.earnedRUB == 27_600)
    #expect(summary.expectedRUB == 299_200)
  }

  @Test func `vacation is paid in full, an unpaid day off is not`() throws {
    let engine = try makeEngine(vacations: [VacationRange(from: day("2026-10-12"), to: day("2026-10-16"))])
    let unpaid = DayRecord(date: day("2026-10-20"), dayOff: .unpaid)
    let tracker = DayTracker(today: started("2026-10-27"), history: [unpaid])
    #expect(tracker.monthSummary(engine: engine).expectedRUB == 299_200 - 13_600)
  }

  @Test func `money flows on a vacation day without notifications or overtime`() throws {
    let engine = try makeEngine(vacations: [VacationRange(from: day("2026-10-27"), to: day("2026-10-27"))])
    var tracker = DayTracker(today: started("2026-10-27"), history: [])
    #expect(run(&tracker, engine, from: "2026-10-27 08:50", to: "2026-10-27 19:00").isEmpty)
    #expect(tracker.today.earnedRUB == 13_600)
    #expect(tracker.today.overtimeSeconds == 0)
    #expect(tracker.snapshot(now: at("2026-10-27 13:00"), engine: engine).title == "🌴 13 600 ₽")
  }

  @Test func `a paid day off keeps paying`() throws {
    let engine = try makeEngine()
    var tracker = DayTracker(today: started("2026-10-27"), history: [])
    tracker.setDayOff(.paid)
    _ = tracker.tick(now: at("2026-10-27 13:00"), idleSeconds: 1, latestFX: nil, engine: engine)
    #expect(tracker.today.earnedRUB == 4 * 1700)
    let snapshot = tracker.snapshot(now: at("2026-10-27 13:00"), engine: engine)
    #expect(snapshot.title == "🌴 6 800 ₽")
    #expect(snapshot.actions == [.undoDayOff])
    #expect(snapshot.nonWorkingLabel == "Оплачиваемый выходной · 6 800 ₽ из 13 600 ₽")
  }

  @Test func `the first launch fills the month from its first day`() throws {
    let engine = try makeEngine()
    let (tracker, changed) = DayTracker.restore(records: [], now: at("2026-10-27 10:00"), latestFX: nil, engine: engine)
    #expect(changed.count == 18)  // 1–26 October: 18 working days
    #expect(changed.first?.date == day("2026-10-01"))
    #expect(tracker.monthSummary(engine: engine).earnedRUB == 18 * 13_600)
  }

  @Test func `missed vacation days are filled as paid`() throws {
    let engine = try makeEngine(vacations: [VacationRange(from: day("2026-10-27"), to: day("2026-10-28"))])
    let monday = DayRecord(date: day("2026-10-26"), earnedRUB: 13_600, overtime: OvertimeState(closedAt: at("2026-10-26 17:15"), finalOvertime: 0))
    let (_, changed) = DayTracker.restore(records: [monday], now: at("2026-10-29 10:00"), latestFX: nil, engine: engine)
    #expect(changed.map(\.earnedRUB) == [13_600, 13_600])
  }
}
