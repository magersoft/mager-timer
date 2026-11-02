import Foundation
import Testing
@testable import TimerCore

/// Pauses, finishing early and getting back to work, on the spec's 09:00–18:00 day with lunch at 13:00.
struct PauseTests {
  let nine = Schedule(start: t(9, 0), end: t(18, 0), lunchStart: t(13, 0))

  func engine(_ schedule: Schedule? = nil) throws -> Engine { try makeEngine(schedule: schedule ?? nine) }

  func tracker(at start: String = "09:00") -> DayTracker { DayTracker(today: started("2026-10-27", at: start), history: []) }

  @discardableResult
  func tick(_ tracker: inout DayTracker, _ engine: Engine, _ time: String, idle: TimeInterval? = 0) -> [DayTracker.Event] {
    tracker.tick(now: at("2026-10-27 \(time)"), idleSeconds: idle, latestFX: nil, engine: engine)
  }

  func plan(_ tracker: DayTracker, _ engine: Engine, _ time: String) throws -> DayPlan {
    try #require(tracker.status(engine: engine, now: at("2026-10-27 \(time)")).plan)
  }

  func pause(_ tracker: inout DayTracker, _ engine: Engine, _ from: String, _ to: String? = nil) {
    tracker.pause(now: at("2026-10-27 \(from)"), engine: engine)
    if let to { tracker.resume(now: at("2026-10-27 \(to)"), engine: engine) }
  }

  func phase(_ tracker: DayTracker, _ engine: Engine, _ time: String) -> DayPhase {
    let now = at("2026-10-27 \(time)")
    return engine.phase(at: now, status: tracker.status(engine: engine, now: now), overtime: tracker.today.overtime)
  }

  // MARK: - Plan

  @Test func `a pause stops the money and moves the end by its length`() throws {
    let engine = try engine()
    var tracker = tracker()
    pause(&tracker, engine, "14:00", "15:00")
    let plan = try plan(tracker, engine, "16:00")
    #expect(plan.end == at("2026-10-27 19:00"))
    #expect(abs(plan.earned(rate: 1700, at: at("2026-10-27 16:00")) - 13_600.0 * 6 / 9) < 0.01)
    #expect(plan.earned(rate: 1700, at: at("2026-10-27 19:00")) == 13_600)
    #expect(plan.dayPay(rate: 1700) == 13_600)
  }

  @Test func `money stands still while the pause lasts`() throws {
    let engine = try engine()
    var tracker = tracker()
    pause(&tracker, engine, "14:00")
    tick(&tracker, engine, "14:40")
    #expect(abs(tracker.today.earnedRUB - 13_600.0 * 5 / 9) < 0.01)
    #expect(try plan(tracker, engine, "14:40").end == at("2026-10-27 18:40"))
  }

  @Test func `pauses add up, lunch or not`() throws {
    let engine = try engine()
    var lunch = tracker()
    pause(&lunch, engine, "12:30", "14:30")
    #expect(try plan(lunch, engine, "15:00").end == at("2026-10-27 20:00"))
    var two = tracker()
    pause(&two, engine, "11:00", "11:20")
    pause(&two, engine, "14:00", "14:40")
    #expect(try plan(two, engine, "15:00").end == at("2026-10-27 19:00"))
  }

  @Test func `a late start and a pause both move the end`() throws {
    let engine = try engine(Schedule(start: t(7, 0), end: t(15, 0), lunchStart: t(12, 0)))
    var tracker = tracker(at: "07:30")
    pause(&tracker, engine, "10:00", "10:45")
    #expect(try plan(tracker, engine, "11:00").end == at("2026-10-27 16:15"))
  }

  @Test func `hours count only the active time and run to the moved end`() throws {
    let engine = try makeEngine()
    var tracker = tracker()
    pause(&tracker, engine, "10:00", "10:30")
    let plan = try plan(tracker, engine, "12:00")
    let slots = plan.hourSlots(rate: 1700, at: at("2026-10-27 12:00"))
    #expect(slots[1].earnedRUB == 850)
    #expect(slots.last?.start == at("2026-10-27 17:00"))
    #expect(slots.last?.end == at("2026-10-27 17:30"))
    let hours = try #require(tracker.snapshot(now: at("2026-10-27 12:00"), engine: engine).today?.hours)
    #expect(hours[1].pauses == ["пауза 10:00–10:30"])
    #expect(hours[0].pauses.isEmpty)
  }

  @Test func `a paused hour earns nothing and the day still adds up`() throws {
    let engine = try engine()
    var tracker = tracker()
    pause(&tracker, engine, "14:00", "15:00")
    let slots = try plan(tracker, engine, "19:00").hourSlots(rate: 1700, at: at("2026-10-27 19:00"))
    #expect(slots[5].start == at("2026-10-27 14:00"))
    #expect(slots[5].earnedRUB == 0)
    #expect(slots.last?.end == at("2026-10-27 19:00"))
    #expect(abs(slots.reduce(0) { $0 + $1.earnedRUB } - 13_600) < 0.01)
    let hours = try #require(tracker.snapshot(now: at("2026-10-27 19:00"), engine: engine).today?.hours)
    #expect(hours[5].isPaused)
  }

  @Test func `phases of a paused and of an early finished day`() throws {
    let engine = try engine()
    var tracker = tracker()
    pause(&tracker, engine, "13:10")
    #expect(phase(tracker, engine, "13:30") == .paused)
    tracker.resume(now: at("2026-10-27 13:40"), engine: engine)
    #expect(phase(tracker, engine, "13:45") == .working)
    tracker.finishEarly(now: at("2026-10-27 17:00"), engine: engine)
    #expect(phase(tracker, engine, "17:01") == .closed)
  }

  // MARK: - Pause and resume

  @Test func `a pause needs a running day before its end`() throws {
    let engine = try engine()
    var notStarted = DayTracker(today: DayRecord(date: day("2026-10-27")), history: [])
    notStarted.pause(now: at("2026-10-27 10:00"), engine: engine)
    #expect(notStarted.today.pauses.isEmpty)
    var evening = tracker()
    evening.pause(now: at("2026-10-27 18:30"), engine: engine)
    #expect(evening.today.pauses.isEmpty)
    var weekend = DayTracker(today: started("2026-10-31"), history: [])
    weekend.pause(now: at("2026-10-31 10:00"), engine: engine)
    #expect(weekend.today.pauses.isEmpty)
    var twice = tracker()
    pause(&twice, engine, "10:00")
    pause(&twice, engine, "10:05")
    #expect(twice.today.pauses == [Pause(start: at("2026-10-27 10:00"))])
  }

  @Test func `idle time is not a pause`() throws {
    let engine = try engine()
    var tracker = tracker()
    tick(&tracker, engine, "11:00", idle: 40 * 60)
    #expect(tracker.today.pauses.isEmpty)
    #expect(try plan(tracker, engine, "11:00").end == at("2026-10-27 18:00"))
  }

  // MARK: - Finishing early

  @Test func `finishing an hour early pays the day and leaves an hour undertime`() throws {
    let engine = try engine()
    var tracker = tracker()
    tick(&tracker, engine, "16:59")
    tracker.finishEarly(now: at("2026-10-27 17:00"), engine: engine)
    #expect(tracker.today.undertimeSeconds == 3600)
    #expect(tracker.today.earnedRUB == 13_600)
    tick(&tracker, engine, "17:30")
    #expect(tracker.today.earnedRUB == 13_600)
    let events = tick(&tracker, engine, "18:05")
    #expect(!events.contains(.dayEnded(totalRUB: 13_600)))
  }

  @Test func `undertime counts from the moved end`() throws {
    let engine = try engine()
    var after = tracker()
    pause(&after, engine, "14:00", "15:00")
    after.finishEarly(now: at("2026-10-27 17:00"), engine: engine)
    #expect(after.today.undertimeSeconds == 2 * 3600)
    var paused = tracker()
    pause(&paused, engine, "15:30")
    paused.finishEarly(now: at("2026-10-27 16:10"), engine: engine)
    #expect(paused.today.undertimeSeconds == 150 * 60)
  }

  // MARK: - Back to work

  @Test func `back to work after finishing early runs to the new end`() throws {
    let engine = try engine()
    var tracker = tracker()
    tick(&tracker, engine, "16:59")
    tracker.finishEarly(now: at("2026-10-27 17:00"), engine: engine)
    tracker.resumeWork(now: at("2026-10-27 20:00"), engine: engine)
    #expect(tracker.today.undertimeSeconds == 0)
    #expect(try plan(tracker, engine, "20:00").end == at("2026-10-27 21:00"))
    tick(&tracker, engine, "20:30", idle: 30 * 60)
    #expect(phase(tracker, engine, "20:30") == .working)
    #expect(tick(&tracker, engine, "21:00").contains(.dayEnded(totalRUB: 13_600)))
    tick(&tracker, engine, "21:30", idle: 30 * 60)
    #expect(!tracker.today.overtime.isClosed)
    tracker.finish(now: at("2026-10-27 21:40"), engine: engine)
    #expect(tracker.today.overtimeSeconds == 40 * 60)
  }

  @Test func `back to work after the end adds overtime and notifies new hours only`() throws {
    let engine = try engine()
    var tracker = tracker()
    tick(&tracker, engine, "18:00")
    tracker.stillWorking(now: at("2026-10-27 18:00"), engine: engine)
    tick(&tracker, engine, "18:30")
    tracker.finish(now: at("2026-10-27 18:30"), engine: engine)
    tracker.resumeWork(now: at("2026-10-27 21:00"), engine: engine)
    #expect(tick(&tracker, engine, "21:30", idle: 0) == [.overtime(hours: 1)])
    #expect(tick(&tracker, engine, "22:30", idle: 50 * 60) == [.overtime(hours: 2)])
    tracker.finish(now: at("2026-10-27 23:00"), engine: engine)
    #expect(tracker.today.overtimeSeconds == 150 * 60)
  }

  @Test func `an hour of overtime already notified is not notified again`() throws {
    let engine = try engine()
    var tracker = tracker()
    tick(&tracker, engine, "18:00")
    tracker.stillWorking(now: at("2026-10-27 18:00"), engine: engine)
    #expect(tick(&tracker, engine, "19:05") == [.overtime(hours: 1)])
    tracker.finish(now: at("2026-10-27 19:10"), engine: engine)
    tracker.resumeWork(now: at("2026-10-27 21:00"), engine: engine)
    #expect(tick(&tracker, engine, "21:10").isEmpty)
  }

  @Test func `activity after closing adds nothing without the button`() throws {
    let engine = try engine()
    var tracker = tracker()
    tick(&tracker, engine, "18:00")
    tracker.finish(now: at("2026-10-27 18:00"), engine: engine)
    tick(&tracker, engine, "22:00", idle: 0)
    #expect(tracker.today.overtimeSeconds == 0)
    #expect(tracker.today.overtime.isClosed)
  }

  @Test func `a pause left open finishes the day where it began`() throws {
    let engine = try engine()
    var tracker = tracker()
    tick(&tracker, engine, "15:59")
    pause(&tracker, engine, "16:00")
    _ = tracker.rollOver(now: at("2026-10-28 00:01"), latestFX: nil, engine: engine)
    let past = try #require(tracker.history.last)
    #expect(past.date == day("2026-10-27"))
    #expect(past.earnedRUB == 13_600)
    #expect(past.undertimeSeconds == 2 * 3600)
    #expect(past.overtimeSeconds == 0)
  }

  @Test func `a reset clears the pauses`() throws {
    let engine = try engine()
    var tracker = tracker()
    pause(&tracker, engine, "10:00", "10:30")
    tracker.resetStart(now: at("2026-10-27 10:40"), engine: engine)
    #expect(tracker.today.pauses.isEmpty)
    tracker.startDay(now: at("2026-10-27 11:00"), engine: engine)
    #expect(try plan(tracker, engine, "11:00").end == at("2026-10-27 20:00"))
  }

  // MARK: - Month

  @Test func `undertime and overtime are summed apart`() throws {
    let engine = try engine()
    let past = DayRecord(date: day("2026-10-26"), rateRUB: 1700, overtimeSeconds: 3 * 3600, undertimeSeconds: 0)
    var today = started("2026-10-27")
    today.undertimeSeconds = 3600
    let tracker = DayTracker(today: today, history: [past])
    let summary = tracker.monthSummary(engine: engine)
    #expect(summary.undertimeSeconds == 3600)
    #expect(summary.giftedRUB == 3 * 1700)
    let month = tracker.snapshot(now: at("2026-10-27 10:00"), engine: engine).month
    #expect(month.undertime == "Недоработано: 1 ч")
    #expect(month.balance == "Баланс: +2 ч")
  }

  @Test func `undertime alone gives a negative balance and no overtime line`() throws {
    let engine = try engine()
    var today = started("2026-10-27")
    today.undertimeSeconds = 90 * 60
    let month = DayTracker(today: today, history: []).snapshot(now: at("2026-10-27 10:00"), engine: engine).month
    #expect(month.overtime == nil)
    #expect(month.undertime == "Недоработано: 1 ч 30 мин")
    #expect(month.balance == "Баланс: −1 ч 30 мин")
  }

  // MARK: - Breaks

  @Test func `no break during a pause, and a long pause is a rest`() throws {
    let engine = try engine()
    var tracker = tracker()
    tracker.today.breaks.lastRestAt = at("2026-10-27 10:30")
    pause(&tracker, engine, "11:00")
    var now = at("2026-10-27 11:00")
    while now <= at("2026-10-27 11:30") {
      #expect(tracker.tickBreaks(now: now, idleSeconds: 0, inCall: false, engine: engine).isEmpty)
      now.addTimeInterval(60)
    }
    tracker.resume(now: at("2026-10-27 11:30"), engine: engine)
    #expect(tracker.breakDue(now: at("2026-10-27 11:30"), engine: engine) == at("2026-10-27 12:20"))
  }

  @Test func `a short pause keeps the break countdown`() throws {
    let engine = try engine()
    var tracker = tracker()
    tracker.today.breaks.lastRestAt = at("2026-10-27 10:30")
    pause(&tracker, engine, "11:00", "11:05")
    #expect(tracker.breakDue(now: at("2026-10-27 11:05"), engine: engine) == at("2026-10-27 11:20"))
  }

  @Test func `a pause on screen during a break takes the break away`() throws {
    let engine = try engine()
    var tracker = tracker()
    tracker.today.breaks.activeSince = at("2026-10-27 10:50")
    pause(&tracker, engine, "10:52")
    #expect(!tracker.today.breaks.isActive)
  }

  @Test func `planned breaks start over after a pause`() throws {
    let engine = try engine()
    var tracker = tracker()
    pause(&tracker, engine, "10:00", "11:00")
    // 09:50; 11:50, 12:50, 13:50, 14:50, 15:50, 16:50, 17:50 (18:50 is too close to 19:00).
    #expect(engine.plannedBreaks(try plan(tracker, engine, "11:00")) == 8)
  }

  // MARK: - Snapshot

  @Test func `actions follow the state of the day`() throws {
    let engine = try engine()
    var tracker = tracker()
    pause(&tracker, engine, "10:00")
    #expect(tracker.snapshot(now: at("2026-10-27 10:10"), engine: engine).actions == [.resume, .finishEarly, .resetStart, .dayOff])
    tracker.finishEarly(now: at("2026-10-27 10:10"), engine: engine)
    #expect(tracker.snapshot(now: at("2026-10-27 10:11"), engine: engine).actions == [.resumeWork])
  }

  @Test func `the paused day shows its pause, the frozen sum and what finishing would leave`() throws {
    var engine = try engine()
    var tracker = tracker()
    tick(&tracker, engine, "14:00")
    pause(&tracker, engine, "14:00")
    tick(&tracker, engine, "14:42")
    let s = tracker.snapshot(now: at("2026-10-27 14:42"), engine: engine)
    #expect(s.phase == .paused)
    #expect(s.title == "⏸ \(MoneyFormatter.format(13_600.0 * 5 / 9, .rub))")
    #expect(s.today?.pause == "на паузе 0:42 · конец в 18:42")
    #expect(s.today?.finishPrompt == "Недоработано 4 ч. Закончить?")
    #expect(s.today?.remaining == nil)
    #expect(s.breaks?.status == "Пауза, перерывы после неё")
    engine.settings.hidesAmounts = true
    #expect(tracker.snapshot(now: at("2026-10-27 14:42"), engine: engine).title == "⏸ •••")
  }

  @Test func `the finish prompt names the undertime`() throws {
    let engine = try engine()
    var tracker = tracker()
    tick(&tracker, engine, "16:55")
    #expect(tracker.snapshot(now: at("2026-10-27 16:55"), engine: engine).today?.finishPrompt == "Недоработано 1 ч 5 мин. Закончить?")
  }
}
