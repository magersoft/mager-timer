import Foundation
import Testing
@testable import TimerCore

struct LunchTests {
  /// 07:00–15:00 with the lunch reminder at 13:00, at 1 700 ₽/h.
  let morning = Schedule(start: t(7, 0), end: t(15, 0), lunchStart: t(13, 0))

  func engine(_ schedule: Schedule? = nil) throws -> Engine { try makeEngine(schedule: schedule ?? morning) }

  func tracker() -> DayTracker { DayTracker(today: started("2026-10-27", at: "07:00"), history: []) }

  func phase(_ tracker: DayTracker, _ engine: Engine, _ time: String) -> DayPhase {
    let now = at("2026-10-27 \(time)")
    return engine.phase(at: now, status: tracker.status(engine: engine, now: now), overtime: tracker.today.overtime)
  }

  func tick(_ tracker: inout DayTracker, _ engine: Engine, _ time: String) -> [DayTracker.Event] {
    tracker.tick(now: at("2026-10-27 \(time)"), idleSeconds: 0, latestFX: nil, engine: engine)
  }

  /// Ticks every minute from `from` to `to`, collecting the events.
  func run(_ tracker: inout DayTracker, _ engine: Engine, from: String, to: String) -> [DayTracker.Event] {
    var events: [DayTracker.Event] = []
    var now = at("2026-10-27 \(from)")
    while now <= at("2026-10-27 \(to)") {
      events += tracker.tick(now: now, idleSeconds: 0, latestFX: nil, engine: engine)
      now.addTimeInterval(60)
    }
    return events
  }

  func lunches(_ tracker: DayTracker) -> [[Date?]] { tracker.today.lunches.map { [$0.start, $0.end] } }

  // MARK: - Phase and money

  @Test func `lunch is the phase only while it is on`() throws {
    let engine = try engine()
    var tracker = tracker()
    #expect(phase(tracker, engine, "13:20") == .working)
    tracker.startLunch(now: at("2026-10-27 13:00"), engine: engine)
    #expect(phase(tracker, engine, "13:20") == .lunch)
  }

  @Test func `lunch changes neither the money nor the end`() throws {
    let engine = try engine()
    var tracker = tracker()
    tracker.startLunch(now: at("2026-10-27 11:30"), engine: engine)
    tracker.endLunch(now: at("2026-10-27 11:50"), engine: engine)
    tracker.startLunch(now: at("2026-10-27 13:00"), engine: engine)
    _ = tick(&tracker, engine, "13:40")
    #expect(abs(tracker.today.earnedRUB - 11_333.33) < 0.01)
    #expect(tracker.status(engine: engine, now: at("2026-10-27 13:40")).plan?.end == at("2026-10-27 15:00"))
  }

  @Test func `a day without lunch ends on time with the full pay`() throws {
    let engine = try engine()
    var tracker = tracker()
    _ = tick(&tracker, engine, "15:00")
    #expect(tracker.status(engine: engine, now: at("2026-10-27 15:00")).plan?.end == at("2026-10-27 15:00"))
    #expect(tracker.today.earnedRUB == 13_600)
    #expect(tracker.today.undertimeSeconds == 0 && tracker.today.overtimeSeconds == 0)
  }

  @Test func `a pause across the reminder time moves the end by all of it`() throws {
    let engine = try makeEngine(schedule: Schedule(start: t(9, 0), end: t(18, 0), lunchStart: t(13, 0)))
    var tracker = DayTracker(today: started("2026-10-27"), history: [])
    tracker.pause(now: at("2026-10-27 12:30"), engine: engine)
    tracker.resume(now: at("2026-10-27 14:30"), engine: engine)
    #expect(tracker.status(engine: engine, now: at("2026-10-27 15:00")).plan?.end == at("2026-10-27 20:00"))
  }

  // MARK: - Taking lunch

  @Test func `lunch starts by the button and ends by "back"`() throws {
    let engine = try engine()
    var tracker = tracker()
    tracker.startLunch(now: at("2026-10-27 11:30"), engine: engine)
    #expect(phase(tracker, engine, "11:40") == .lunch)
    tracker.endLunch(now: at("2026-10-27 11:50"), engine: engine)
    #expect(phase(tracker, engine, "11:51") == .working)
    #expect(tracker.today.closedLunchTime == 20 * 60)
  }

  @Test func `lunch cannot start before the start, on pause, in overtime, closed or with the hour used up`() throws {
    let engine = try engine()
    var early = DayTracker(today: DayRecord(date: day("2026-10-27")), history: [])
    #expect(!early.canStartLunch(now: at("2026-10-27 10:00"), engine: engine))
    early.startLunch(now: at("2026-10-27 10:00"), engine: engine)
    #expect(early.today.lunches.isEmpty)

    var paused = tracker()
    paused.pause(now: at("2026-10-27 10:00"), engine: engine)
    #expect(!paused.canStartLunch(now: at("2026-10-27 10:10"), engine: engine))

    let overtime = tracker()
    #expect(!overtime.canStartLunch(now: at("2026-10-27 15:10"), engine: engine))

    var closed = tracker()
    closed.finishEarly(now: at("2026-10-27 14:00"), engine: engine)
    #expect(!closed.canStartLunch(now: at("2026-10-27 14:10"), engine: engine))

    var used = tracker()
    used.today.lunches = [Lunch(start: at("2026-10-27 11:00"), end: at("2026-10-27 12:00"))]
    #expect(!used.canStartLunch(now: at("2026-10-27 13:00"), engine: engine))
  }

  @Test func `lunch in parts adds up to the hour`() throws {
    let engine = try engine()
    var tracker = tracker()
    tracker.startLunch(now: at("2026-10-27 11:30"), engine: engine)
    tracker.endLunch(now: at("2026-10-27 11:50"), engine: engine)
    tracker.startLunch(now: at("2026-10-27 13:00"), engine: engine)
    tracker.endLunch(now: at("2026-10-27 13:20"), engine: engine)
    #expect(tracker.today.closedLunchTime == 40 * 60)
    #expect(tracker.canStartLunch(now: at("2026-10-27 13:30"), engine: engine))
  }

  // MARK: - Lunch ending by itself

  @Test func `a lunch left on ends when the hour is used up`() throws {
    let engine = try engine()
    var tracker = tracker()
    tracker.today.lunches = [Lunch(start: at("2026-10-27 11:30"), end: at("2026-10-27 11:50"))]
    tracker.startLunch(now: at("2026-10-27 13:00"), engine: engine)
    _ = tick(&tracker, engine, "13:45")
    #expect(lunches(tracker).last == [at("2026-10-27 13:00"), at("2026-10-27 13:40")])
    #expect(phase(tracker, engine, "13:45") == .working)
    #expect(tracker.today.breaks.lastRestAt == at("2026-10-27 13:40"))
  }

  @Test func `a lunch on at the end of the day ends with it`() throws {
    let engine = try engine()
    var tracker = tracker()
    tracker.startLunch(now: at("2026-10-27 14:40"), engine: engine)
    _ = tick(&tracker, engine, "15:01")
    #expect(lunches(tracker).last == [at("2026-10-27 14:40"), at("2026-10-27 15:00")])
    #expect(phase(tracker, engine, "15:01") == .afterHours)
  }

  @Test func `a day left on lunch is closed the next day with the full pay`() throws {
    let engine = try engine()
    var record = started("2026-10-27", at: "07:00")
    record.lunches = [Lunch(start: at("2026-10-27 13:00"))]
    let (tracker, _) = DayTracker.restore(records: [record], now: at("2026-10-28 09:00"), latestFX: nil, engine: engine)
    let past = try #require(tracker.history.first { $0.date == day("2026-10-27") })
    #expect(past.lunches.map(\.end) == [at("2026-10-27 14:00")])
    #expect(past.earnedRUB == 13_600)
  }

  @Test func `a restart on lunch keeps the lunch going`() throws {
    let engine = try engine()
    var record = started("2026-10-27", at: "07:00")
    record.lunches = [Lunch(start: at("2026-10-27 13:00"))]
    let (tracker, _) = DayTracker.restore(records: [record], now: at("2026-10-27 13:10"), latestFX: nil, engine: engine)
    #expect(phase(tracker, engine, "13:10") == .lunch)
    #expect(tracker.today.openLunch?.start == at("2026-10-27 13:00"))
  }

  @Test func `resetting the start drops the lunches`() throws {
    let engine = try engine()
    var tracker = tracker()
    tracker.startLunch(now: at("2026-10-27 11:30"), engine: engine)
    tracker.resetStart(now: at("2026-10-27 11:40"), engine: engine)
    #expect(tracker.today.lunches.isEmpty)
  }

  // MARK: - Pause and finishing

  @Test func `there is no pause at lunch`() throws {
    let engine = try engine()
    var tracker = tracker()
    tracker.startLunch(now: at("2026-10-27 13:00"), engine: engine)
    tracker.pause(now: at("2026-10-27 13:05"), engine: engine)
    #expect(tracker.today.pauses.isEmpty)
    #expect(phase(tracker, engine, "13:06") == .lunch)
  }

  @Test func `finishing the day from lunch ends the lunch`() throws {
    let engine = try makeEngine(schedule: Schedule(start: t(9, 0), end: t(18, 0), lunchStart: t(13, 0)))
    var tracker = DayTracker(today: started("2026-10-27"), history: [])
    tracker.startLunch(now: at("2026-10-27 16:30"), engine: engine)
    tracker.finishEarly(now: at("2026-10-27 16:45"), engine: engine)
    #expect(lunches(tracker) == [[at("2026-10-27 16:30"), at("2026-10-27 16:45")]])
    #expect(tracker.today.undertimeSeconds == 75 * 60)
    #expect(tracker.today.overtime.isClosed)
  }

  // MARK: - Reminder

  @Test func `the reminder comes once at its time`() throws {
    let engine = try engine()
    var tracker = tracker()
    #expect(!run(&tracker, engine, from: "12:58", to: "12:59").contains(.lunchTime))
    #expect(tick(&tracker, engine, "13:00") == [.lunchTime])
    #expect(!run(&tracker, engine, from: "13:01", to: "13:30").contains(.lunchTime))
  }

  @Test func `the reminder comes when part of the hour is taken`() throws {
    let engine = try engine()
    var tracker = tracker()
    tracker.today.lunches = [Lunch(start: at("2026-10-27 12:00"), end: at("2026-10-27 12:20"))]
    #expect(run(&tracker, engine, from: "12:59", to: "13:01").contains(.lunchTime))
  }

  @Test func `no reminder at lunch, on pause, after sleeping through, or switched off`() throws {
    let engine = try engine()
    var atLunch = tracker()
    atLunch.startLunch(now: at("2026-10-27 12:50"), engine: engine)
    #expect(!run(&atLunch, engine, from: "12:59", to: "13:30").contains(.lunchTime))

    var paused = tracker()
    paused.pause(now: at("2026-10-27 12:30"), engine: engine)
    var events = run(&paused, engine, from: "12:59", to: "13:30")
    paused.resume(now: at("2026-10-27 13:30"), engine: engine)
    events += run(&paused, engine, from: "13:30", to: "14:00")
    #expect(!events.contains(.lunchTime))

    var slept = tracker()
    _ = tick(&slept, engine, "12:50")
    #expect(!tick(&slept, engine, "14:10").contains(.lunchTime))

    var quiet = try self.engine(Schedule(start: t(7, 0), end: t(15, 0), lunchStart: t(13, 0), lunchReminder: false))
    quiet.settings.breaks.enabled = true
    var off = tracker()
    #expect(!run(&off, quiet, from: "12:59", to: "13:30").contains(.lunchTime))
    #expect(off.canStartLunch(now: at("2026-10-27 13:30"), engine: quiet))
  }

  // MARK: - Breaks

  @Test func `the settings hint plans the day with an hour of lunch at the reminder`() throws {
    let engine = try makeEngine(schedule: Schedule(start: t(7, 0), end: t(15, 0), lunchStart: t(12, 0)))
    let date = day("2026-10-27")
    #expect(engine.plannedBreaks(engine.plan(for: date, isShort: false), assumedLunch: engine.lunchWindow(on: date)) == 6)
  }

  @Test func `a break in the lunch hour offers to go for lunch, and leaving uncounts it`() throws {
    let engine = try engine()
    var tracker = tracker()
    tracker.today.breaks.activeSince = at("2026-10-27 13:10")
    let screen = try #require(tracker.snapshot(now: at("2026-10-27 13:11"), engine: engine).breakScreen)
    #expect(screen.offersLunch)
    tracker.lunchFromBreak(now: at("2026-10-27 13:11"), engine: engine)
    #expect(!tracker.today.breaks.isActive)
    #expect(phase(tracker, engine, "13:12") == .lunch)
    #expect(tracker.today.breaks.taken == 0 && tracker.today.breaks.skipped == 0)
  }

  @Test func `other breaks do not offer lunch`() throws {
    let engine = try engine()
    var regular = tracker()
    regular.today.breaks.activeSince = at("2026-10-27 10:50")
    #expect(regular.snapshot(now: at("2026-10-27 10:51"), engine: engine).breakScreen?.offersLunch == false)

    var used = tracker()
    used.today.lunches = [Lunch(start: at("2026-10-27 11:00"), end: at("2026-10-27 12:00"))]
    used.today.breaks.activeSince = at("2026-10-27 13:30")
    #expect(used.snapshot(now: at("2026-10-27 13:31"), engine: engine).breakScreen?.offersLunch == false)

    var quiet = try self.engine(Schedule(start: t(7, 0), end: t(15, 0), lunchStart: t(13, 0), lunchReminder: false))
    quiet.settings.breaks.enabled = true
    var off = tracker()
    off.today.breaks.activeSince = at("2026-10-27 13:10")
    #expect(off.snapshot(now: at("2026-10-27 13:11"), engine: quiet).breakScreen?.offersLunch == false)
  }

  // MARK: - Menu

  @Test func `the menu offers lunch with what is left of the hour`() throws {
    let engine = try engine()
    var tracker = tracker()
    var s = tracker.snapshot(now: at("2026-10-27 10:00"), engine: engine)
    #expect(s.actions.prefix(3) == [.lunch, .pause, .finishEarly])
    #expect(s.today?.lunchButton == "Обед")
    tracker.today.lunches = [Lunch(start: at("2026-10-27 11:30"), end: at("2026-10-27 11:50"))]
    s = tracker.snapshot(now: at("2026-10-27 12:00"), engine: engine)
    #expect(s.today?.lunchButton == "Обед (осталось 40 мин)")
    tracker.today.lunches.append(Lunch(start: at("2026-10-27 12:00"), end: at("2026-10-27 12:40")))
    s = tracker.snapshot(now: at("2026-10-27 13:00"), engine: engine)
    #expect(!s.actions.contains(.lunch) && s.today?.lunchButton == nil)
  }

  @Test func `at lunch the menu shows what is left and the way back`() throws {
    let engine = try engine()
    var tracker = tracker()
    tracker.today.lunches = [Lunch(start: at("2026-10-27 11:30"), end: at("2026-10-27 11:50"))]
    tracker.startLunch(now: at("2026-10-27 13:00"), engine: engine)
    _ = tick(&tracker, engine, "13:02")
    let s = tracker.snapshot(now: at("2026-10-27 13:02"), engine: engine)
    #expect(s.today?.lunch == "Обед · осталось 38 мин")
    #expect(s.actions.prefix(2) == [.endLunch, .finishEarly])
    #expect(!s.actions.contains(.pause) && !s.actions.contains(.lunch))
    // 6 h 2 min of 8 at 13 600 ₽: the money keeps running at lunch.
    #expect(s.title == "🍜 10 257 ₽")
  }

  @Test func `the ribbon marks the hours mostly taken by lunch`() throws {
    let engine = try engine()
    var tracker = tracker()
    tracker.today.lunches = [
      Lunch(start: at("2026-10-27 11:30"), end: at("2026-10-27 11:50")),
      Lunch(start: at("2026-10-27 13:00"), end: at("2026-10-27 13:40")),
    ]
    let hours = try #require(tracker.snapshot(now: at("2026-10-27 14:00"), engine: engine).today?.hours)
    #expect(hours.map(\.startLabel) == ["07", "08", "09", "10", "11", "12", "13", "14"])
    #expect(hours.map(\.isLunch) == [false, false, false, false, false, false, true, false])
  }

  @Test func `hidden amounts mask the lunch title too`() throws {
    var engine = try engine()
    engine.settings.hidesAmounts = true
    var tracker = tracker()
    tracker.startLunch(now: at("2026-10-27 13:00"), engine: engine)
    #expect(tracker.snapshot(now: at("2026-10-27 13:05"), engine: engine).title == "🍜 •••")
  }
}
