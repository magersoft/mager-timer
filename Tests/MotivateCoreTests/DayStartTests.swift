import Foundation
import Testing
@testable import MotivateCore

struct DayStartTests {
  /// 07:00–15:00 with lunch at 11:00, as in the spec examples.
  let morning = Schedule(start: t(7, 0), end: t(15, 0), lunchStart: t(11, 0))

  func engine(_ schedule: Schedule? = nil, vacations: [VacationRange] = []) throws -> Engine {
    try makeEngine(schedule: schedule ?? morning, vacations: vacations)
  }

  func fresh(_ date: String = "2026-10-27") -> DayTracker { DayTracker(today: DayRecord(date: day(date)), history: []) }

  /// Ticks every minute; `active` says whether the user touched the Mac, last touched at `lastInput` before `from`.
  func run(
    _ tracker: inout DayTracker, _ engine: Engine, from: String, to: String, lastInput: String = "2026-10-27 05:00",
    active: (Date) -> Bool = { _ in false }
  ) -> [DayTracker.Event] {
    var events: [DayTracker.Event] = []
    var input = at(lastInput)
    var now = at(from)
    while now <= at(to) {
      if active(now) { input = now }
      events += tracker.tick(now: now, idleSeconds: now.timeIntervalSince(input), latestFX: nil, engine: engine)
      now.addTimeInterval(60)
    }
    return events
  }

  // MARK: - Record

  @Test func `old day files read as not started, the start survives a round trip`() throws {
    let old = try JSONDecoder().decode(DayRecord.self, from: Data(#"{"date":"2026-10-27"}"#.utf8))
    #expect(old.startedAt == nil)
    let record = started("2026-10-27", at: "06:40")
    let copy = try JSONDecoder().decode(DayRecord.self, from: JSONEncoder().encode(record))
    #expect(copy.startedAt == at("2026-10-27 06:40"))
  }

  // MARK: - Plan

  @Test(arguments: [
    ("2026-10-27", "06:40", "14:40"),
    ("2026-10-27", "07:30", "15:30"),
    ("2026-11-03", "07:30", "14:30"),  // shortened
  ])
  func `the day keeps its length from the actual start`(date: String, start: String, end: String) throws {
    let plan = try #require(try engine().status(on: day(date), start: .at(at("\(date) \(start)"))).plan)
    #expect(plan.start == at("\(date) \(start)"))
    #expect(plan.end == at("\(date) \(end)"))
    #expect(plan.isStarted)
  }

  @Test func `lunch stays on the clock and is dropped outside the day`() throws {
    let engine = try engine()
    let late = engine.plan(for: day("2026-10-27"), isShort: false, start: .at(at("2026-10-27 07:30")))
    #expect(late.lunchStart == at("2026-10-27 11:00"))
    #expect(late.lunchEnd == at("2026-10-27 12:00"))
    let afterLunch = engine.plan(for: day("2026-10-27"), isShort: false, start: .at(at("2026-10-27 12:30")))
    #expect(afterLunch.end == at("2026-10-27 20:30"))
    #expect(afterLunch.lunchStart == afterLunch.lunchEnd)
  }

  @Test func `a schedule edited mid-day moves the end from the same start`() throws {
    let longer = try engine(Schedule(start: t(7, 0), end: t(16, 0), lunchStart: t(11, 0)))
    #expect(longer.plan(for: day("2026-10-27"), isShort: false, start: .at(at("2026-10-27 07:30"))).end == at("2026-10-27 16:30"))
  }

  @Test func `earnings run from the actual start to the shifted end`() throws {
    let engine = try engine()
    let late = engine.plan(for: day("2026-10-27"), isShort: false, start: .at(at("2026-10-27 07:30")))
    #expect(late.earned(rate: 1700, at: at("2026-10-27 11:30")) == 6_800)
    let early = engine.plan(for: day("2026-10-27"), isShort: false, start: .at(at("2026-10-27 06:40")))
    #expect(early.earned(rate: 1700, at: at("2026-10-27 14:40")) == 13_600)
  }

  @Test func `a day not started earns nothing and has every hour ahead`() throws {
    let plan = try engine().plan(for: day("2026-10-27"), isShort: false, start: .notStarted)
    #expect(!plan.isStarted)
    #expect(plan.earned(rate: 1700, at: at("2026-10-27 12:00")) == 0)
    #expect(plan.hourSlots(rate: 1700, at: at("2026-10-27 12:00")).allSatisfy { $0.state == .upcoming && $0.earnedRUB == 0 })
  }

  @Test func `a day not started stays before the start; paid leave needs no start`() throws {
    let engine = try engine(vacations: [VacationRange(from: day("2026-10-28"), to: day("2026-10-28"))])
    let status = engine.status(on: day("2026-10-27"), start: .notStarted)
    #expect(engine.phase(at: at("2026-10-27 07:10"), status: status, overtime: OvertimeState()) == .beforeStart)
    let leave = try #require(engine.status(on: day("2026-10-28"), start: .notStarted).paidPlan)
    #expect(leave.isStarted)
    #expect(leave.earned(rate: 1700, at: at("2026-10-28 11:00")) == 6_800)
  }

  // MARK: - Button

  @Test func `the button starts the day once, at any hour`() throws {
    let engine = try engine()
    var tracker = fresh()
    tracker.startDay(now: at("2026-10-27 06:40"), engine: engine)
    #expect(tracker.today.startedAt == at("2026-10-27 06:40"))
    tracker.startDay(now: at("2026-10-27 08:00"), engine: engine)
    #expect(tracker.today.startedAt == at("2026-10-27 06:40"))
    _ = tracker.tick(now: at("2026-10-27 06:41"), idleSeconds: 0, latestFX: nil, engine: engine)
    #expect(engine.phase(at: at("2026-10-27 06:41"), status: tracker.status(engine: engine), overtime: tracker.today.overtime) == .working)

    var night = fresh()
    night.startDay(now: at("2026-10-27 04:00"), engine: engine)
    #expect(night.today.startedAt == at("2026-10-27 04:00"))
  }

  @Test func `the button does nothing on a day off`() throws {
    let engine = try engine()
    var saturday = fresh("2026-10-31")
    saturday.startDay(now: at("2026-10-31 07:00"), engine: engine)
    #expect(saturday.today.startedAt == nil)
    var unpaid = fresh()
    unpaid.setDayOff(.unpaid)
    unpaid.startDay(now: at("2026-10-27 07:00"), engine: engine)
    #expect(unpaid.today.startedAt == nil)
  }

  // MARK: - Auto start

  @Test func `forgot to press: the first activity after the scheduled start starts the day`() throws {
    let engine = try engine()
    var tracker = fresh()
    _ = run(&tracker, engine, from: "2026-10-27 06:00", to: "2026-10-27 08:00") { $0 == at("2026-10-27 07:20") }
    #expect(tracker.today.startedAt == at("2026-10-27 07:20"))
    #expect(tracker.status(engine: engine).plan?.end == at("2026-10-27 15:20"))
  }

  @Test func `at the Mac since before the schedule: the day starts on time`() throws {
    let engine = try engine()
    var tracker = fresh()
    _ = run(&tracker, engine, from: "2026-10-27 06:45", to: "2026-10-27 07:30") { _ in true }
    #expect(tracker.today.startedAt == at("2026-10-27 07:00"))
  }

  @Test func `activity before the schedule does not start the day`() throws {
    let engine = try engine()
    var tracker = fresh()
    _ = run(&tracker, engine, from: "2026-10-27 06:00", to: "2026-10-27 08:09") { $0 == at("2026-10-27 06:50") }
    #expect(tracker.today.startedAt == nil)
    _ = run(&tracker, engine, from: "2026-10-27 08:10", to: "2026-10-27 08:12", lastInput: "2026-10-27 06:50") { $0 == at("2026-10-27 08:10") }
    #expect(tracker.today.startedAt == at("2026-10-27 08:10"))
  }

  @Test func `no auto start while the Mac sleeps or is locked`() throws {
    let engine = try engine()
    var tracker = fresh()
    _ = tracker.tick(now: at("2026-10-27 09:00"), idleSeconds: nil, latestFX: nil, engine: engine)
    #expect(tracker.today.startedAt == nil)
    #expect(tracker.awaitsStart(now: at("2026-10-27 09:00"), engine: engine))
  }

  @Test func `outside the scheduled hours activity does not start the day`() throws {
    let engine = try engine()
    var evening = fresh()
    _ = run(&evening, engine, from: "2026-10-27 17:59", to: "2026-10-27 18:05") { $0 == at("2026-10-27 18:00") }
    #expect(evening.today.startedAt == nil)
    #expect(!evening.awaitsStart(now: at("2026-10-27 18:00"), engine: engine))
    // A shortened day's hours end at 14:00.
    var short = fresh("2026-11-03")
    _ = run(&short, engine, from: "2026-11-03 14:29", to: "2026-11-03 14:31", lastInput: "2026-11-03 05:00") { $0 == at("2026-11-03 14:30") }
    #expect(short.today.startedAt == nil)
    // The button still works in the evening.
    evening.startDay(now: at("2026-10-27 18:10"), engine: engine)
    #expect(evening.today.startedAt == at("2026-10-27 18:10"))
  }

  // MARK: - Reset

  @Test func `a reset puts the day back as not started and leaves only the button`() throws {
    let engine = try engine()
    var tracker = fresh()
    _ = run(&tracker, engine, from: "2026-10-27 07:59", to: "2026-10-27 09:00") { _ in true }
    #expect(tracker.today.startedAt == at("2026-10-27 07:59"))
    tracker.today.breaks.skipped = 1
    tracker.resetStart(engine: engine)
    #expect(tracker.today.startedAt == nil)
    #expect(tracker.today.earnedRUB == 0)
    #expect(tracker.today.breaks == BreakState())
    let snapshot = tracker.snapshot(now: at("2026-10-27 09:00"), engine: engine)
    #expect(snapshot.actions.contains(.startDay))
    #expect(snapshot.today?.startTime == nil)

    // At the Mac again, still no auto start.
    let events = run(&tracker, engine, from: "2026-10-27 09:01", to: "2026-10-27 10:00") { _ in true }
    #expect(tracker.today.startedAt == nil)
    #expect(events.isEmpty)
    #expect(!tracker.awaitsStart(now: at("2026-10-27 10:00"), engine: engine))

    // The real start notifies again.
    tracker.startDay(now: at("2026-10-27 10:00"), engine: engine)
    #expect(tracker.tick(now: at("2026-10-27 10:01"), idleSeconds: 0, latestFX: nil, engine: engine) == [.dayStarted(expectedRUB: 13_600)])
    #expect(tracker.snapshot(now: at("2026-10-27 10:01"), engine: engine).today?.startTime == "10:00")
  }

  @Test func `a closed day keeps its start`() throws {
    let engine = try engine()
    var tracker = DayTracker(today: started("2026-10-27", at: "07:00"), history: [])
    _ = tracker.tick(now: at("2026-10-27 15:10"), idleSeconds: 0, latestFX: nil, engine: engine)
    tracker.finish(now: at("2026-10-27 15:10"), engine: engine)
    tracker.resetStart(engine: engine)
    #expect(tracker.today.startedAt == at("2026-10-27 07:00"))
    #expect(!tracker.snapshot(now: at("2026-10-27 15:11"), engine: engine).actions.contains(.resetStart))
  }

  @Test func `a reset survives a restart`() throws {
    let record = DayRecord(date: day("2026-10-27"), manualStartOnly: true)
    let copy = try JSONDecoder().decode(DayRecord.self, from: JSONEncoder().encode(record))
    #expect(copy.manualStartOnly)
    let old = try JSONDecoder().decode(DayRecord.self, from: Data(#"{"date":"2026-10-27"}"#.utf8))
    #expect(!old.manualStartOnly)
  }

  // MARK: - What follows the start

  @Test func `a day not started brings no events, money or overtime`() throws {
    let engine = try engine()
    var tracker = fresh()
    let events = run(&tracker, engine, from: "2026-10-27 06:00", to: "2026-10-27 16:00")
    #expect(events.isEmpty)
    #expect(tracker.today.earnedRUB == 0)
    #expect(tracker.today.overtimeSeconds == 0)
    #expect(!tracker.today.overtime.isClosed)
  }

  @Test func `overtime and the evening prompt follow the shifted end`() throws {
    let engine = try engine()
    var late = DayTracker(today: started("2026-10-27", at: "07:30"), history: [])
    let events = run(&late, engine, from: "2026-10-27 07:30", to: "2026-10-27 15:40") { _ in true }
    #expect(events.contains(.dayStarted(expectedRUB: 13_600)))
    #expect(events.contains(.dayEnded(totalRUB: 13_600)))
    #expect(late.today.overtimeSeconds == 10 * 60)

    var early = DayTracker(today: started("2026-10-27", at: "06:40"), history: [])
    _ = early.tick(now: at("2026-10-27 14:45"), idleSeconds: 0, latestFX: nil, engine: engine)
    let snapshot = early.snapshot(now: at("2026-10-27 14:45"), engine: engine)
    #expect(snapshot.phase == .afterHours)
    #expect(snapshot.actions.contains(.finish))
  }

  // MARK: - Restore

  @Test func `past days count in full whether started or not; unpaid days stay at zero`() throws {
    let engine = try engine()
    let late = started("2026-10-26", at: "07:30")
    let forgotten = DayRecord(date: day("2026-10-27"))
    let unpaid = DayRecord(date: day("2026-10-28"), dayOff: .unpaid)
    let (tracker, _) = DayTracker.restore(records: [late, forgotten, unpaid], now: at("2026-10-29 06:00"), latestFX: nil, engine: engine)
    let history = Dictionary(uniqueKeysWithValues: tracker.history.map { ($0.date, $0) })
    #expect(history[day("2026-10-26")]?.earnedRUB == 13_600)
    #expect(history[day("2026-10-27")]?.earnedRUB == 13_600)
    #expect(history[day("2026-10-27")]?.startedAt == at("2026-10-27 07:00"))
    #expect(history[day("2026-10-27")]?.overtimeSeconds == 0)
    #expect(history[day("2026-10-28")]?.earnedRUB == 0)
  }

  @Test func `days the app never saw are filled as started by the schedule`() throws {
    let engine = try engine()
    let monday = started("2026-10-26", at: "07:00")
    let (tracker, changed) = DayTracker.restore(records: [monday], now: at("2026-10-28 06:00"), latestFX: nil, engine: engine)
    #expect(changed.map(\.date).contains(day("2026-10-27")))
    #expect(tracker.history.last?.startedAt == at("2026-10-27 07:00"))
    #expect(tracker.history.last?.earnedRUB == 13_600)
  }

  @Test func `today saved by the old version keeps earning from the schedule`() throws {
    let engine = try engine()
    let legacy = DayRecord(date: day("2026-10-27"), earnedRUB: 5_000)
    let (tracker, _) = DayTracker.restore(records: [legacy], now: at("2026-10-27 10:00"), latestFX: nil, engine: engine)
    #expect(tracker.today.startedAt == at("2026-10-27 07:00"))
    let untouched = DayRecord(date: day("2026-10-27"))
    #expect(DayTracker.restore(records: [untouched], now: at("2026-10-27 10:00"), latestFX: nil, engine: engine).0.today.startedAt == nil)
  }

  // MARK: - Breaks

  @Test func `breaks count from the actual start and wait for it`() throws {
    let engine = try engine()
    var waiting = fresh()
    var now = at("2026-10-27 07:00")
    var events: [DayTracker.BreakEvent] = []
    while now <= at("2026-10-27 09:00") {
      events += waiting.tickBreaks(now: now, idleSeconds: 0, inCall: false, engine: engine)
      now.addTimeInterval(60)
    }
    #expect(events.isEmpty)
    #expect(!waiting.breaksRunning(phase: .beforeStart, engine: engine))
    waiting.startBreakNow(now: at("2026-10-27 09:00"), engine: engine)
    #expect(!waiting.today.breaks.isActive)

    var late = DayTracker(today: started("2026-10-27", at: "07:30"), history: [])
    now = at("2026-10-27 07:30")
    var first: Date?
    while now <= at("2026-10-27 09:00"), first == nil {
      if late.tickBreaks(now: now, idleSeconds: 0, inCall: false, engine: engine).contains(.started) { first = now }
      now.addTimeInterval(60)
    }
    #expect(first == at("2026-10-27 08:20"))
  }

  // MARK: - Snapshot

  @Test func `before the start the menu offers to start the day`() throws {
    let engine = try engine(vacations: [VacationRange(from: day("2026-10-28"), to: day("2026-10-28"))])
    var tracker = fresh()
    _ = tracker.tick(now: at("2026-10-27 07:10"), idleSeconds: nil, latestFX: nil, engine: engine)
    let waiting = tracker.snapshot(now: at("2026-10-27 07:10"), engine: engine)
    #expect(waiting.title == "☕ 07:00")
    #expect(waiting.actions == [.startDay, .dayOff])
    #expect(waiting.today?.nowFraction == nil)
    #expect(waiting.today?.remaining == nil)
    #expect(waiting.today?.hours.allSatisfy { $0.fraction == 0 } == true)

    tracker.startDay(now: at("2026-10-27 07:10"), engine: engine)
    _ = tracker.tick(now: at("2026-10-27 07:11"), idleSeconds: 0, latestFX: nil, engine: engine)
    #expect(!tracker.snapshot(now: at("2026-10-27 07:11"), engine: engine).actions.contains(.startDay))

    var vacation = fresh("2026-10-28")
    _ = vacation.tick(now: at("2026-10-28 08:00"), idleSeconds: nil, latestFX: nil, engine: engine)
    #expect(!vacation.snapshot(now: at("2026-10-28 08:00"), engine: engine).actions.contains(.startDay))
  }
}
