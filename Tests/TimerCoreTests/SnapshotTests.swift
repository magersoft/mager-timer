import Foundation
import Testing
@testable import TimerCore

struct SnapshotTests {
  func snapshot(_ engine: Engine, date: String, ticks: [(String, TimeInterval?)], fx: FXRates? = nil,
                history: [DayRecord] = [], configure: (inout DayTracker) -> Void = { _ in }) -> DaySnapshot {
    var tracker = DayTracker(today: started(date), history: history)
    configure(&tracker)
    for (moment, idle) in ticks { _ = tracker.tick(now: at(moment), idleSeconds: idle, latestFX: fx, engine: engine) }
    return tracker.snapshot(now: at(ticks.last!.0), engine: engine)
  }

  @Test(arguments: [
    ("2026-10-27 08:30", "☕ 09:00", false),
    ("2026-10-27 13:30", "🍜 7 650 ₽", false),
    ("2026-10-27 11:00", "💰 3 400 ₽", false),
    ("2026-11-04 12:00", "🌴", false),
  ])
  func `title follows the phase`(moment: String, title: String, alert: Bool) throws {
    let s = snapshot(try makeEngine(), date: String(moment.prefix(10)), ticks: [(moment, 1)])
    #expect(s.title == title)
    #expect(s.isAlert == alert)
  }

  @Test func `overtime shows a red counter and the real rate`() throws {
    let engine = try makeEngine()
    var ticks: [(String, TimeInterval?)] = []
    for minute in stride(from: 0, through: 120, by: 5) {
      ticks.append((String(format: "2026-10-27 %02d:%02d", 17 + minute / 60, minute % 60), 0))
    }
    let s = snapshot(engine, date: "2026-10-27", ticks: ticks)
    #expect(s.title == "🔥 +2:00")
    #expect(s.isAlert)
    #expect(s.today?.realRate == "1 360 ₽/ч (−20%)")
    #expect(s.today?.overtime == "2 ч")
    #expect(s.actions == [.stillWorking, .finish, .resetStart])
    #expect(s.month.overtime == "Переработано: 2 ч ≈ 3 400 ₽ подарено")
  }

  @Test(arguments: [
    ("2026-10-27 08:30", "☕ •••"),
    ("2026-10-27 11:00", "💰 •••"),
    ("2026-10-27 13:30", "🍜 •••"),
    ("2026-11-04 12:00", "🌴"),
  ])
  func `hidden amounts leave the phase icon and a mask`(moment: String, title: String) throws {
    var engine = try makeEngine()
    engine.settings.hidesAmounts = true
    let s = snapshot(engine, date: String(moment.prefix(10)), ticks: [(moment, 1)])
    #expect(s.title == title)
  }

  @Test func `hidden amounts mask overtime without the red, the menu keeps the numbers`() throws {
    var engine = try makeEngine()
    engine.settings.hidesAmounts = true
    var ticks: [(String, TimeInterval?)] = []
    for minute in stride(from: 0, through: 80, by: 5) {
      ticks.append((String(format: "2026-10-27 %02d:%02d", 17 + minute / 60, minute % 60), 0))
    }
    let s = snapshot(engine, date: "2026-10-27", ticks: ticks)
    #expect(s.title == "🔥 •••")
    #expect(!s.isAlert)
    #expect(s.today?.earned == "13 600 ₽")
    engine.settings.hidesAmounts = false
    #expect(snapshot(engine, date: "2026-10-27", ticks: ticks).title == "🔥 +1:20")
  }

  @Test func `after finishing the title shows the day total`() throws {
    let s = snapshot(try makeEngine(), date: "2026-10-27", ticks: [("2026-10-27 17:00", 0), ("2026-10-27 17:20", nil)])
    #expect(s.title == "✓ 13 600 ₽")
    #expect(s.phase == .closed)
    #expect(s.actions.isEmpty)
  }

  @Test func `actions depend on the phase`() throws {
    let engine = try makeEngine()
    #expect(snapshot(engine, date: "2026-10-27", ticks: [("2026-10-27 08:30", 1)]).actions == [.dayOff])
    #expect(snapshot(engine, date: "2026-10-27", ticks: [("2026-10-27 10:00", 1)]).actions == [.resetStart, .dayOff])
    #expect(snapshot(engine, date: "2026-10-27", ticks: [("2026-10-27 17:01", 0)]).actions == [.stillWorking, .finish, .resetStart])
    let off = snapshot(engine, date: "2026-10-27", ticks: [("2026-10-27 10:00", 1)]) { $0.setDayOff(.unpaid) }
    #expect(off.actions == [.undoDayOff])
    #expect(off.title == "🌴")
    let manual = snapshot(engine, date: "2026-10-27", ticks: [("2026-10-27 17:01", 0)]) { t in
      _ = t.tick(now: at("2026-10-27 17:00"), idleSeconds: 0, latestFX: nil, engine: engine)
      t.stillWorking(now: at("2026-10-27 17:00"), engine: engine)
    }
    #expect(manual.actions == [.finish, .resetStart])
  }

  @Test func `today section shows progress, hours and remaining time`() throws {
    let s = snapshot(try makeEngine(), date: "2026-10-27", ticks: [("2026-10-27 11:30", 1)])
    let today = try #require(s.today)
    #expect(today.earned == "4 250 ₽")
    #expect(today.dayPay == "13 600 ₽")
    #expect(today.remaining == "5:30")
    #expect(today.rate == "1 700 ₽/ч")
    #expect(today.hours.prefix(3).map(\.amount) == ["1 700 ₽", "1 700 ₽", "850 ₽"])
    #expect(today.hours[0].label == "09:00–10:00")
    #expect(today.hours.map(\.startLabel) == ["09", "10", "11", "12", "13", "14", "15", "16"])
    #expect(today.hours.map(\.fraction).prefix(4) == [1, 1, 0.5, 0])
    #expect(today.hours.map(\.isLunch) == [false, false, false, false, true, false, false, false])
    #expect(today.endLabel == "17" && today.endTime == "17:00")
    #expect(today.nowFraction == 2.5 / 8)
    #expect(today.overtimeHours == 0)
  }

  @Test func `amounts can be shown in dollars`() throws {
    let s = snapshot(try makeEngine(display: .usd), date: "2026-10-27", ticks: [("2026-10-27 17:00", 1)], fx: usdFX)
    #expect(s.title == "⏳ $155.61")
  }

  @Test func `warnings explain missing or stale data`() throws {
    let usd = Income(name: "Контракт", amount: 1000, currency: .usd)
    let none = snapshot(try makeEngine([october1700, usd]), date: "2026-10-27", ticks: [("2026-10-27 10:00", 1)])
    #expect(none.warnings == ["«Контракт» не учтён: нет курса USD", "Курс ЦБ ещё не загружен: суммы в ₽, доходы в $ и € не учтены"])

    var stale = usdFX
    stale.date = day("2026-10-24")
    let old = snapshot(try makeEngine([october1700, usd]), date: "2026-10-27", ticks: [("2026-10-27 10:00", 1)], fx: stale)
    #expect(old.warnings == ["Курс ЦБ от 24.10"])

    let empty = snapshot(try makeEngine([]), date: "2026-10-27", ticks: [("2026-10-27 10:00", 1)])
    #expect(empty.warnings == ["Добавьте доход в настройках"])
    #expect(empty.title == "💰 0 ₽")

    let engine2027 = try makeEngine()
    let approx = snapshot(engine2027, date: "2027-03-09", ticks: [("2027-03-09 10:00", 1)])
    #expect(approx.warnings == ["Календарь приблизительный: праздники не учтены"])
  }

  @Test func `payday line counts down to the next payday`() throws {
    var income = october1700
    income.payouts = [Payout(day: 10, percent: 60), Payout(day: 25, percent: 40)]
    let engine = try makeEngine([income])
    #expect(snapshot(engine, date: "2026-10-27", ticks: [("2026-10-27 10:00", 1)]).payday?.title == "Выплата 10 нояб. · через 14 дн.")
    #expect(snapshot(engine, date: "2026-11-09", ticks: [("2026-11-09 10:00", 1)]).payday?.title == "Выплата завтра")
    #expect(snapshot(engine, date: "2026-11-10", ticks: [("2026-11-10 10:00", 1)]).payday?.title == "Выплата сегодня 🎉")
    #expect(snapshot(try makeEngine(), date: "2026-10-27", ticks: [("2026-10-27 10:00", 1)]).payday == nil)
  }

  @Test func `payday shows the amount and whose money it is`() throws {
    let salary = Income(name: "ЗП", amount: 100_000, currency: .rub, payouts: [Payout(day: 10, percent: 60), Payout(day: 25, percent: 40)])
    let contract = Income(name: "Контракт", amount: 1000, currency: .usd, payouts: [Payout(day: 10, percent: 100)])
    let engine = try makeEngine([salary, contract])
    let ticks = [("2026-10-27 10:00", 1.0)]
    var tracker = DayTracker(today: started("2026-10-27"), history: [])
    _ = tracker.tick(now: at(ticks[0].0), idleSeconds: 1, latestFX: usdFX, engine: engine)
    let payday = try #require(tracker.snapshot(now: at(ticks[0].0), engine: engine).payday)
    #expect(payday.amount == "≈ 147 400 ₽")
    #expect(payday.sources == "ЗП 60% · Контракт")
    // Without a rate the parts stay in their own currencies.
    let noFX = try #require(snapshot(engine, date: "2026-10-27", ticks: ticks).payday)
    #expect(noFX.amount == "60 000 ₽ + $1,000.00")
  }

  @Test func `goal section shows progress and forecast`() throws {
    let goal = Goal(name: "Грузия", amount: 34_000, currency: .rub, createdOn: day("2026-10-31"))
    let s = snapshot(try makeEngine(goals: [goal]), date: "2026-10-31", ticks: [("2026-10-31 12:00", 1)])
    let g = try #require(s.goals.first)
    #expect(!s.canAddGoal)
    #expect(g.name == "Грузия")
    #expect(g.saved == "0 ₽" && g.target == "34 000 ₽")
    #expect(g.forecast == "~ 5 нояб.")
    #expect(s.nonWorkingLabel == "Выходной")
  }
}
