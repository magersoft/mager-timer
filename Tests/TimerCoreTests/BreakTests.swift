import Foundation
import Testing
@testable import TimerCore

struct BreakTests {
  /// 07:00–15:00 with lunch at 12:00, as in the spec examples.
  let morning = Schedule(start: t(7, 0), end: t(15, 0), lunchStart: t(12, 0))

  struct Moment: Equatable {
    var time: Date
    var event: DayTracker.BreakEvent
  }

  /// Ticks every `step` seconds; `active` says whether the user touched the Mac at that moment.
  @discardableResult
  func run(
    _ tracker: inout DayTracker, _ engine: Engine, from: String, to: String, step: TimeInterval = 60,
    inCall: (Date) -> Bool = { _ in false }, active: (Date) -> Bool = { _ in true }
  ) -> [Moment] {
    var moments: [Moment] = []
    var lastInput = at(from)
    var now = at(from)
    while now <= at(to) {
      if active(now) { lastInput = now }
      moments += tracker.tickBreaks(now: now, idleSeconds: now.timeIntervalSince(lastInput), inCall: inCall(now), engine: engine)
        .map { Moment(time: now, event: $0) }
      now.addTimeInterval(step)
    }
    return moments
  }

  func starts(_ moments: [Moment]) -> [Date] { moments.filter { $0.event == .started }.map(\.time) }

  func tracker(_ date: String = "2026-10-27") -> DayTracker { DayTracker(today: started(date, at: "07:00"), history: []) }

  // MARK: - Settings

  @Test func `old settings files get breaks on at 50 and 10 minutes`() throws {
    let json = #"{"incomes":[],"displayCurrency":"RUB","schedule":{"start":"09:00","end":"17:00","lunchStart":"13:00"},"vacations":[],"goals":[],"launchAtLogin":true}"#
    let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(settings.breaks == BreakSettings(enabled: true, workMinutes: 50, lengthMinutes: 10))
  }

  @Test func `break settings survive a round trip`() throws {
    let settings = Settings(breaks: BreakSettings(enabled: false, workMinutes: 90, lengthMinutes: 15))
    #expect(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)) == settings)
  }

  @Test func `break settings out of range are rejected`() {
    #expect(throws: SettingsError.breakWorkOutOfRange) { try Settings(breaks: BreakSettings(workMinutes: 5)).validate() }
    #expect(throws: SettingsError.breakWorkOutOfRange) { try Settings(breaks: BreakSettings(workMinutes: 121)).validate() }
    #expect(throws: SettingsError.breakLengthOutOfRange) { try Settings(breaks: BreakSettings(lengthMinutes: 0)).validate() }
    #expect(throws: SettingsError.breakLengthOutOfRange) { try Settings(breaks: BreakSettings(lengthMinutes: 31)).validate() }
    #expect(throws: Never.self) { try Settings(breaks: BreakSettings(workMinutes: 20, lengthMinutes: 30)).validate() }
  }

  @Test func `old day files read with an empty tally, and the tally survives a round trip`() throws {
    let old = #"{"date":"2026-10-27","earnedRUB":0,"rateRUB":0,"normHours":8,"scheduleHours":8,"overtime":{"mode":"auto"},"overtimeSeconds":0,"notified":[]}"#
    #expect(try JSONDecoder().decode(DayRecord.self, from: Data(old.utf8)).breaks == BreakState())

    var record = DayRecord(date: day("2026-10-27"))
    record.breaks.skipped = 2
    record.breaks.taken = 3
    record.breaks.lastRestAt = at("2026-10-27 10:00")
    #expect(try JSONDecoder().decode(DayRecord.self, from: JSONEncoder().encode(record)) == record)
  }

  // MARK: - Plan

  @Test func `planned breaks follow the schedule`() throws {
    let engine = try makeEngine(schedule: morning)
    #expect(engine.plannedBreaks(engine.plan(for: day("2026-10-27"), isShort: false)) == 5)
    let lateLunch = try makeEngine(schedule: Schedule(start: t(7, 0), end: t(15, 0), lunchStart: t(13, 0)))
    #expect(lateLunch.plannedBreaks(lateLunch.plan(for: day("2026-10-27"), isShort: false)) == 5)
    var off = engine
    off.settings.breaks.enabled = false
    #expect(off.plannedBreaks(off.plan(for: day("2026-10-27"), isShort: false)) == 0)
  }

  @Test func `a shortened day plans fewer breaks`() throws {
    let engine = try makeEngine()
    #expect(engine.plannedBreaks(engine.plan(for: day("2026-10-27"), isShort: false)) == 5)
    #expect(engine.plannedBreaks(engine.plan(for: day("2026-11-03"), isShort: true)) == 4)
  }

  // MARK: - Schedule

  @Test func `the first break comes after fifty minutes, warned a minute ahead`() throws {
    let engine = try makeEngine(schedule: morning)
    var tracker = tracker()
    let moments = run(&tracker, engine, from: "2026-10-27 06:50", to: "2026-10-27 07:50")
    #expect(moments == [Moment(time: at("2026-10-27 07:49"), event: .warn(canSnooze: true)), Moment(time: at("2026-10-27 07:50"), event: .started)])
  }

  @Test func `a whole day: breaks skip lunch and its last minutes, and go on into overtime`() throws {
    let engine = try makeEngine(schedule: morning)
    var tracker = tracker()
    let moments = run(&tracker, engine, from: "2026-10-27 07:00", to: "2026-10-27 15:45")
    #expect(starts(moments) == ["07:50", "08:50", "09:50", "10:50", "13:50", "15:40"].map { at("2026-10-27 \($0)") })
    #expect(tracker.today.breaks.taken == 5)
    #expect(tracker.today.breaks.overtimeBreaks == 1)
    #expect(tracker.today.breaks.skipped == 0)
  }

  @Test func `stepping away for a break's length restarts the countdown`() throws {
    let engine = try makeEngine(schedule: morning)
    var tracker = tracker()
    tracker.today.breaks.lastRestAt = at("2026-10-27 08:00")
    let away = at("2026-10-27 08:20")..<at("2026-10-27 08:32")
    let moments = run(&tracker, engine, from: "2026-10-27 08:00", to: "2026-10-27 09:25", step: 1, active: { !away.contains($0) })
    let start = try #require(starts(moments).first)
    #expect(abs(start.timeIntervalSince(at("2026-10-27 09:22"))) <= 1)
  }

  @Test func `a short pause does not restart the countdown`() throws {
    let engine = try makeEngine(schedule: morning)
    var tracker = tracker()
    let away = at("2026-10-27 07:20")..<at("2026-10-27 07:24")
    let moments = run(&tracker, engine, from: "2026-10-27 07:00", to: "2026-10-27 07:55", active: { !away.contains($0) })
    #expect(starts(moments) == [at("2026-10-27 07:50")])
  }

  @Test func `the Mac asleep counts as rest`() throws {
    let engine = try makeEngine(schedule: morning)
    var tracker = tracker()
    run(&tracker, engine, from: "2026-10-27 07:00", to: "2026-10-27 07:30")
    let moments = run(&tracker, engine, from: "2026-10-27 07:45", to: "2026-10-27 08:40")
    #expect(starts(moments) == [at("2026-10-27 08:35")])
  }

  @Test func `nothing on a day off, and nothing after the day is closed`() throws {
    let engine = try makeEngine(schedule: morning)
    var holiday = tracker("2026-11-04")
    #expect(run(&holiday, engine, from: "2026-11-04 07:00", to: "2026-11-04 15:00").isEmpty)

    var closed = tracker()
    closed.today.breaks.lastRestAt = at("2026-10-27 14:50")
    _ = closed.tick(now: at("2026-10-27 15:05"), idleSeconds: 0, latestFX: nil, engine: engine)
    closed.finish(now: at("2026-10-27 15:05"), engine: engine)
    #expect(run(&closed, engine, from: "2026-10-27 15:05", to: "2026-10-27 18:00").isEmpty)
  }

  @Test func `overtime breaks add to the plan`() throws {
    let engine = try makeEngine(schedule: morning)
    var tracker = tracker()
    tracker.today.breaks.lastRestAt = at("2026-10-27 14:20")
    let moments = run(&tracker, engine, from: "2026-10-27 14:20", to: "2026-10-27 15:11")
    #expect(starts(moments) == [at("2026-10-27 15:10")])
    #expect(tracker.today.breaks.overtimeBreaks == 1)
  }

  // MARK: - Calls

  @Test func `a call holds the break and its warning until it ends`() throws {
    let engine = try makeEngine(schedule: morning)
    var tracker = tracker()
    let call = at("2026-10-27 07:40")..<at("2026-10-27 08:05")
    let moments = run(&tracker, engine, from: "2026-10-27 07:00", to: "2026-10-27 08:06", inCall: { call.contains($0) })
    #expect(moments == [Moment(time: at("2026-10-27 08:05"), event: .started)])
    #expect(tracker.today.breaks.skipped == 0)
    #expect(tracker.today.breaks.snoozes == 0)
  }

  @Test func `a break waiting for a call shows it`() throws {
    let engine = try makeEngine(schedule: morning)
    var tracker = tracker()
    run(&tracker, engine, from: "2026-10-27 07:00", to: "2026-10-27 07:52", inCall: { $0 >= at("2026-10-27 07:30") })
    #expect(tracker.today.breaks.waitingForCall)
    #expect(!tracker.today.breaks.isActive)
  }

  @Test func `a call lasting until the day is closed takes the break away uncounted`() throws {
    let engine = try makeEngine(schedule: morning)
    var tracker = tracker()
    tracker.today.breaks.lastRestAt = at("2026-10-27 14:20")
    run(&tracker, engine, from: "2026-10-27 14:20", to: "2026-10-27 15:30", inCall: { _ in true })
    _ = tracker.tick(now: at("2026-10-27 15:30"), idleSeconds: 0, latestFX: nil, engine: engine)
    tracker.finish(now: at("2026-10-27 15:30"), engine: engine)
    #expect(run(&tracker, engine, from: "2026-10-27 15:31", to: "2026-10-27 17:00").isEmpty)
    #expect(tracker.today.breaks.skipped == 0)
    #expect(tracker.today.breaks.overtimeBreaks == 0)
  }

  // MARK: - Actions

  @Test func `snoozing moves the break and is not a skip`() throws {
    let engine = try makeEngine(schedule: morning)
    var tracker = tracker()
    run(&tracker, engine, from: "2026-10-27 07:00", to: "2026-10-27 07:50")
    #expect(tracker.today.breaks.isActive)
    tracker.snoozeBreak(minutes: 10, now: at("2026-10-27 07:50"), engine: engine)
    #expect(!tracker.today.breaks.isActive)
    let moments = run(&tracker, engine, from: "2026-10-27 07:51", to: "2026-10-27 08:00")
    #expect(starts(moments) == [at("2026-10-27 08:00")])
    #expect(tracker.today.breaks.skipped == 0)
    #expect(tracker.today.breaks.snoozes == 1)
  }

  @Test func `snoozing from the warning moves the break five minutes past its time`() throws {
    let engine = try makeEngine(schedule: morning)
    var tracker = tracker()
    run(&tracker, engine, from: "2026-10-27 07:00", to: "2026-10-27 07:49")
    tracker.snoozeBreak(minutes: 5, now: at("2026-10-27 07:49"), engine: engine)
    let moments = run(&tracker, engine, from: "2026-10-27 07:50", to: "2026-10-27 07:55")
    #expect(moments == [Moment(time: at("2026-10-27 07:54"), event: .warn(canSnooze: true)), Moment(time: at("2026-10-27 07:55"), event: .started)])
  }

  @Test func `a break can be snoozed twice at most`() throws {
    let engine = try makeEngine(schedule: morning)
    var tracker = tracker()
    run(&tracker, engine, from: "2026-10-27 07:00", to: "2026-10-27 07:50")
    tracker.snoozeBreak(minutes: 5, now: at("2026-10-27 07:50"), engine: engine)
    run(&tracker, engine, from: "2026-10-27 07:51", to: "2026-10-27 07:55")
    tracker.snoozeBreak(minutes: 5, now: at("2026-10-27 07:55"), engine: engine)
    let moments = run(&tracker, engine, from: "2026-10-27 07:56", to: "2026-10-27 08:00")
    #expect(moments.contains(Moment(time: at("2026-10-27 07:59"), event: .warn(canSnooze: false))))
    #expect(tracker.today.breaks.isActive)
    #expect(!tracker.today.breaks.canSnooze)
    tracker.snoozeBreak(minutes: 5, now: at("2026-10-27 08:00"), engine: engine)
    #expect(tracker.today.breaks.isActive)
  }

  @Test func `a break snoozed into the last minutes before lunch disappears uncounted`() throws {
    let engine = try makeEngine(schedule: morning)
    var tracker = tracker()
    tracker.today.breaks.lastRestAt = at("2026-10-27 10:30")
    run(&tracker, engine, from: "2026-10-27 10:30", to: "2026-10-27 11:20")
    tracker.snoozeBreak(minutes: 15, now: at("2026-10-27 11:20"), engine: engine)
    run(&tracker, engine, from: "2026-10-27 11:21", to: "2026-10-27 11:35")
    tracker.snoozeBreak(minutes: 15, now: at("2026-10-27 11:35"), engine: engine)
    let moments = run(&tracker, engine, from: "2026-10-27 11:36", to: "2026-10-27 12:30")
    #expect(moments.isEmpty)
    #expect(tracker.today.breaks.skipped == 0)
  }

  @Test func `skipping counts and starts the countdown over`() throws {
    let engine = try makeEngine(schedule: morning)
    var tracker = tracker()
    run(&tracker, engine, from: "2026-10-27 07:00", to: "2026-10-27 07:53")
    tracker.skipBreak(now: at("2026-10-27 07:53"))
    #expect(!tracker.today.breaks.isActive)
    #expect(tracker.today.breaks.skipped == 1)
    let moments = run(&tracker, engine, from: "2026-10-27 07:54", to: "2026-10-27 08:45")
    #expect(starts(moments) == [at("2026-10-27 08:43")])
  }

  @Test func `a break can start early`() throws {
    let engine = try makeEngine(schedule: morning)
    var tracker = tracker()
    run(&tracker, engine, from: "2026-10-27 07:00", to: "2026-10-27 07:20")
    tracker.startBreakNow(now: at("2026-10-27 07:20"), engine: engine)
    let moments = run(&tracker, engine, from: "2026-10-27 07:21", to: "2026-10-27 08:20")
    #expect(moments.first == Moment(time: at("2026-10-27 07:30"), event: .finished))
    #expect(starts(moments) == [at("2026-10-27 08:20")])
  }

  @Test func `switching breaks off takes the break on screen away`() throws {
    var engine = try makeEngine(schedule: morning)
    var tracker = tracker()
    run(&tracker, engine, from: "2026-10-27 07:00", to: "2026-10-27 07:50")
    engine.settings.breaks.enabled = false
    #expect(tracker.tickBreaks(now: at("2026-10-27 07:51"), idleSeconds: 0, inCall: false, engine: engine) == [.cancelled])
    #expect(tracker.today.breaks.taken == 0)
  }

  @Test func `a break on screen carries over a restart`() throws {
    let engine = try makeEngine(schedule: morning)
    var tracker = tracker()
    run(&tracker, engine, from: "2026-10-27 07:00", to: "2026-10-27 07:50")
    tracker.skipBreak(now: at("2026-10-27 07:50"))
    run(&tracker, engine, from: "2026-10-27 07:51", to: "2026-10-27 08:40")
    let stored = try JSONDecoder().decode(DayRecord.self, from: JSONEncoder().encode(tracker.today))
    var (restored, _) = DayTracker.restore(records: [stored], now: at("2026-10-27 08:42"), latestFX: nil, engine: engine)
    #expect(restored.today.breaks.skipped == 1)
    #expect(restored.today.breaks.isActive)
    let moments = run(&restored, engine, from: "2026-10-27 08:42", to: "2026-10-27 08:50")
    #expect(moments == [Moment(time: at("2026-10-27 08:50"), event: .finished)])
  }

  // MARK: - Snapshot

  @Test(arguments: [
    (0, "Ты ещё не скипнул ни одного перерыва из 5"),
    (1, "Ты скипнул уже 1 перерыв из 5"),
    (2, "Ты скипнул уже 2 перерыва из 5"),
    (5, "Ты скипнул уже 5 перерывов из 5"),
    (12, "Ты скипнул уже 12 перерывов из 5"),
    (21, "Ты скипнул уже 21 перерыв из 5"),
  ])
  func `skipped breaks are counted in words`(skipped: Int, line: String) {
    #expect(DayTracker.skippedLine(skipped, of: 5) == line)
  }

  @Test func `the menu shows the countdown and the tally`() throws {
    let engine = try makeEngine(schedule: morning)
    var tracker = tracker()
    run(&tracker, engine, from: "2026-10-27 07:00", to: "2026-10-27 07:50")
    tracker.skipBreak(now: at("2026-10-27 07:50"))
    run(&tracker, engine, from: "2026-10-27 07:51", to: "2026-10-27 08:17")
    let breaks = try #require(tracker.snapshot(now: at("2026-10-27 08:17"), engine: engine).breaks)
    #expect(breaks.status == "Перерыв через 23 мин")
    #expect(breaks.tally == "скипнуто 1 из 5")
    #expect(breaks.canStartNow)
  }

  @Test func `the menu tells when the break waits for lunch or the end of the day`() throws {
    let engine = try makeEngine(schedule: morning)
    var tracker = tracker()
    tracker.today.breaks.lastRestAt = at("2026-10-27 11:00")
    run(&tracker, engine, from: "2026-10-27 11:00", to: "2026-10-27 11:30")
    #expect(tracker.snapshot(now: at("2026-10-27 11:30"), engine: engine).breaks?.status == "Следующий перерыв после обеда")
    tracker.today.breaks.lastRestAt = at("2026-10-27 14:00")
    run(&tracker, engine, from: "2026-10-27 14:00", to: "2026-10-27 14:30")
    #expect(tracker.snapshot(now: at("2026-10-27 14:30"), engine: engine).breaks?.status == "До конца графика перерывов нет")
  }

  @Test func `at lunch, before the start and after finishing the row explains the pause`() throws {
    let engine = try makeEngine(schedule: morning)
    var day = tracker()
    run(&day, engine, from: "2026-10-27 12:10", to: "2026-10-27 12:30")
    let lunch = try #require(day.snapshot(now: at("2026-10-27 12:30"), engine: engine).breaks)
    #expect(lunch.status == "Обед, перерывы с 13:00")
    #expect(lunch.tally == "скипнуто 0 из 5")
    #expect(!lunch.canStartNow)
    #expect(day.snapshot(now: at("2026-10-27 06:30"), engine: engine).breaks?.status == "Перерывы с 07:00")
    _ = day.tick(now: at("2026-10-27 15:05"), idleSeconds: 0, latestFX: nil, engine: engine)
    day.finish(now: at("2026-10-27 15:05"), engine: engine)
    #expect(day.snapshot(now: at("2026-10-27 15:06"), engine: engine).breaks?.status == "Перерывов больше нет")
  }

  @Test func `no break row on a day off or with breaks switched off`() throws {
    let engine = try makeEngine(schedule: morning)
    let holiday = tracker("2026-11-04")
    #expect(holiday.snapshot(now: at("2026-11-04 10:00"), engine: engine).breaks == nil)
    var off = engine
    off.settings.breaks.enabled = false
    var working = tracker()
    run(&working, off, from: "2026-10-27 07:00", to: "2026-10-27 08:00")
    #expect(working.snapshot(now: at("2026-10-27 08:00"), engine: off).breaks == nil)
  }

  @Test func `the break screen shows the countdown, the money and the tally`() throws {
    let engine = try makeEngine(schedule: morning)
    var tracker = tracker()
    run(&tracker, engine, from: "2026-10-27 07:00", to: "2026-10-27 07:50")
    tracker.today.breaks.skipped = 2
    let snapshot = tracker.snapshot(now: at("2026-10-27 07:50").addingTimeInterval(18), engine: engine)
    let screen = try #require(snapshot.breakScreen)
    #expect(screen.remaining == "09:42")
    #expect(screen.prompt == "Встань и отойди от компа на 10 мин")
    #expect(screen.earnings == "За перерыв капнет ≈ 283 ₽")
    #expect(screen.skipped == "Ты скипнул уже 2 перерыва из 5")
    #expect(screen.canSnooze)
    #expect(snapshot.breaks?.status == "Перерыв")
    #expect(snapshot.breaks?.canStartNow == false)
  }

  @Test func `with amounts hidden the break screen drops the money line`() throws {
    var engine = try makeEngine(schedule: morning)
    engine.settings.hidesAmounts = true
    var tracker = tracker()
    run(&tracker, engine, from: "2026-10-27 07:00", to: "2026-10-27 07:50")
    tracker.today.breaks.skipped = 2
    let screen = try #require(tracker.snapshot(now: at("2026-10-27 07:51"), engine: engine).breakScreen)
    #expect(screen.earnings == nil)
    #expect(screen.prompt == "Встань и отойди от компа на 10 мин")
    #expect(screen.skipped == "Ты скипнул уже 2 перерыва из 5")
  }

  @Test func `in overtime the break screen says the time is free anyway`() throws {
    let engine = try makeEngine(schedule: morning)
    var tracker = tracker()
    tracker.today.breaks.lastRestAt = at("2026-10-27 14:20")
    run(&tracker, engine, from: "2026-10-27 14:20", to: "2026-10-27 15:10")
    let snapshot = tracker.snapshot(now: at("2026-10-27 15:11"), engine: engine)
    #expect(snapshot.breakScreen?.earnings == "Ты и так работаешь бесплатно")
    #expect(snapshot.breaks?.tally == "скипнуто 0 из 6")
  }
}
