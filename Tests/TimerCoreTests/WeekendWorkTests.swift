import Foundation
import Testing
@testable import TimerCore

/// 31 October 2026 is a Saturday; October's rate is 1 700 ₽/h.
struct WeekendWorkTests {
  let saturday = day("2026-10-31")

  func tracker(_ record: DayRecord? = nil) -> DayTracker {
    DayTracker(today: record ?? DayRecord(date: saturday), history: [])
  }

  func started(_ pay: WeekendPay, at time: String = "10:00", engine: Engine) -> DayTracker {
    var tracker = tracker()
    tracker.startWeekendWork(pay: pay, now: at("2026-10-31 \(time)"), engine: engine)
    return tracker
  }

  @discardableResult
  func tick(_ tracker: inout DayTracker, _ time: String, idle: TimeInterval? = 0, engine: Engine) -> [DayTracker.Event] {
    tracker.tick(now: at("2026-10-31 \(time)"), idleSeconds: idle, latestFX: nil, engine: engine)
  }

  // MARK: Model

  @Test func `a record saved before weekend work reads without it`() throws {
    let json = #"{"date":"2026-10-31"}"#
    #expect(try JSONDecoder().decode(DayRecord.self, from: Data(json.utf8)).weekendWork == nil)
  }

  @Test func `worked time adds up the segments, the open one up to now`() {
    let work = WeekendWork(pay: .double, segments: [
      WorkSegment(start: at("2026-10-31 10:00"), end: at("2026-10-31 12:00")),
      WorkSegment(start: at("2026-10-31 12:30")),
    ])
    #expect(work.worked(at: at("2026-10-31 13:30")) == 3 * 3600)
    #expect(work.state == .running)
  }

  // MARK: Start

  @Test func `a whole day at the Mac without the button starts nothing`() throws {
    let engine = try makeEngine()
    var tracker = tracker()
    for time in ["10:00", "12:00", "14:00"] { tick(&tracker, time, engine: engine) }
    #expect(tracker.phase(engine: engine, now: at("2026-10-31 14:00")) == .nonWorking(.holiday))
    #expect(tracker.today.earnedRUB == 0)
    #expect(tracker.today.weekendWork == nil)
  }

  @Test func `there is no weekend work on a working day or on vacation`() throws {
    let engine = try makeEngine(vacations: [VacationRange(from: day("2026-10-26"), to: day("2026-10-30"))])
    var vacation = DayTracker(today: DayRecord(date: day("2026-10-27")), history: [])
    vacation.startWeekendWork(pay: .double, now: at("2026-10-27 10:00"), engine: engine)
    #expect(vacation.today.weekendWork == nil)
    var working = DayTracker(today: DayRecord(date: day("2026-11-02")), history: [])
    working.startWeekendWork(pay: .double, now: at("2026-11-02 10:00"), engine: engine)
    #expect(working.today.weekendWork == nil)
  }

  // MARK: Money

  @Test(arguments: [(WeekendPay.double, 10_200.0), (.single, 5_100)])
  func `three hours are paid by the chosen multiplier`(pay: WeekendPay, expected: Double) throws {
    let engine = try makeEngine()
    var tracker = started(pay, engine: engine)
    tick(&tracker, "13:00", engine: engine)
    #expect(abs(tracker.today.earnedRUB - expected) < 0.001)
    #expect(tracker.today.overtimeSeconds == 0)
    #expect(tracker.today.normHours == 0)
    #expect(tracker.today.rateRUB == 1700)
  }

  @Test func `paid as overtime, the time goes to overtime and the money stays zero`() throws {
    let engine = try makeEngine()
    var tracker = started(.overtime, engine: engine)
    tick(&tracker, "12:00", engine: engine)
    #expect(tracker.today.earnedRUB == 0)
    #expect(tracker.today.overtimeSeconds == 7200)
  }

  @Test func `a pause is not counted and the time stands still on it`() throws {
    let engine = try makeEngine()
    var tracker = started(.double, engine: engine)
    tracker.pause(now: at("2026-10-31 12:00"), engine: engine)
    #expect(tracker.phase(engine: engine, now: at("2026-10-31 12:20")) == .weekend(.paused))
    tick(&tracker, "12:20", engine: engine)
    #expect(abs(tracker.today.earnedRUB - 2 * 3400) < 0.001)
    tracker.resume(now: at("2026-10-31 12:30"), engine: engine)
    tick(&tracker, "13:30", engine: engine)
    #expect(tracker.today.weekendWork?.worked(at: at("2026-10-31 13:30")).rounded() == 3.0 * 3600)
  }

  @Test func `finish and back to work add up the evening`() throws {
    let engine = try makeEngine()
    var tracker = started(.single, engine: engine)
    tracker.finishWeekend(now: at("2026-10-31 13:00"), engine: engine)
    #expect(tracker.phase(engine: engine, now: at("2026-10-31 15:00")) == .weekend(.finished))
    tracker.resumeWork(now: at("2026-10-31 20:00"), engine: engine)
    tracker.finishWeekend(now: at("2026-10-31 21:00"), engine: engine)
    #expect(tracker.today.weekendWork?.worked(at: at("2026-10-31 23:00")).rounded() == 4.0 * 3600)
    #expect(abs(tracker.today.earnedRUB - 4 * 1700) < 0.001)
  }

  @Test func `changing the pay recounts the whole session`() throws {
    let engine = try makeEngine()
    var tracker = started(.overtime, engine: engine)
    tick(&tracker, "13:00", engine: engine)
    tracker.setWeekendPay(.double, now: at("2026-10-31 13:00"), engine: engine)
    #expect(abs(tracker.today.earnedRUB - 10_200) < 0.001)
    #expect(tracker.today.overtimeSeconds == 0)
  }

  @Test func `cancelling makes it an ordinary day off`() throws {
    let engine = try makeEngine()
    var tracker = started(.overtime, engine: engine)
    tick(&tracker, "10:05", engine: engine)
    tracker.cancelWeekendWork(engine: engine)
    #expect(tracker.today.weekendWork == nil)
    #expect(tracker.today.earnedRUB == 0 && tracker.today.overtimeSeconds == 0)
    #expect(tracker.snapshot(now: at("2026-10-31 10:05"), engine: engine).actions == [.weekendWork])
  }

  @Test func `idle time without a pause does not stop the count`() throws {
    let engine = try makeEngine()
    var tracker = started(.double, engine: engine)
    tick(&tracker, "11:00", engine: engine)
    tick(&tracker, "11:40", idle: 40 * 60, engine: engine)
    tick(&tracker, "12:00", engine: engine)
    #expect(tracker.phase(engine: engine, now: at("2026-10-31 12:00")) == .weekend(.working))
    #expect(abs(tracker.today.earnedRUB - 2 * 3400) < 0.001)
  }

  // MARK: Lunch

  @Test func `lunch is paid as worked time`() throws {
    let engine = try makeEngine()
    var tracker = started(.double, engine: engine)
    #expect(tracker.canStartLunch(now: at("2026-10-31 12:00"), engine: engine))
    tracker.startLunch(now: at("2026-10-31 12:00"), engine: engine)
    #expect(tracker.phase(engine: engine, now: at("2026-10-31 12:10")) == .weekend(.lunch))
    tracker.endLunch(now: at("2026-10-31 12:30"), engine: engine)
    tick(&tracker, "13:00", engine: engine)
    #expect(abs(tracker.today.earnedRUB - 10_200) < 0.001)
  }

  @Test func `a pause instead of lunch is not paid`() throws {
    let engine = try makeEngine()
    var tracker = started(.double, engine: engine)
    tracker.pause(now: at("2026-10-31 12:00"), engine: engine)
    tracker.resume(now: at("2026-10-31 12:30"), engine: engine)
    #expect(tracker.today.weekendWork?.worked(at: at("2026-10-31 13:00")).rounded() == 2.5 * 3600)
  }

  @Test func `a lunch not ended runs out after the hour`() throws {
    let engine = try makeEngine()
    var tracker = started(.double, engine: engine)
    tracker.startLunch(now: at("2026-10-31 12:00"), engine: engine)
    tick(&tracker, "13:05", engine: engine)
    #expect(tracker.today.lunches == [Lunch(start: at("2026-10-31 12:00"), end: at("2026-10-31 13:00"))])
    #expect(tracker.phase(engine: engine, now: at("2026-10-31 13:05")) == .weekend(.working))
    #expect(!tracker.canStartLunch(now: at("2026-10-31 13:05"), engine: engine))
  }

  @Test func `there is no lunch on pause or without a session`() throws {
    let engine = try makeEngine()
    #expect(!tracker().canStartLunch(now: at("2026-10-31 12:00"), engine: engine))
    var tracker = started(.double, engine: engine)
    tracker.pause(now: at("2026-10-31 11:00"), engine: engine)
    #expect(!tracker.canStartLunch(now: at("2026-10-31 12:00"), engine: engine))
  }

  @Test func `there is no pause at lunch, and finish ends the lunch`() throws {
    let engine = try makeEngine()
    var tracker = started(.double, engine: engine)
    tracker.startLunch(now: at("2026-10-31 12:00"), engine: engine)
    tracker.pause(now: at("2026-10-31 12:10"), engine: engine)
    #expect(tracker.today.weekendWork?.state == .running)
    tracker.finishWeekend(now: at("2026-10-31 12:20"), engine: engine)
    #expect(tracker.today.lunches.last?.end == at("2026-10-31 12:20"))
    #expect(tracker.today.weekendWork?.worked(at: at("2026-10-31 18:00")).rounded() == 2.0 * 3600 + 20 * 60)
  }

  // MARK: Midnight and restart

  func nextDay(_ tracker: DayTracker, engine: Engine) -> DayRecord? {
    let (restored, _) = DayTracker.restore(
      records: tracker.allRecords, now: at("2026-11-01 09:00"), latestFX: nil, engine: engine)
    return restored.history.first { $0.date == saturday }
  }

  @Test func `a session left running closes at the last activity`() throws {
    let engine = try makeEngine()
    var tracker = started(.double, engine: engine)
    tick(&tracker, "15:00", engine: engine)
    tick(&tracker, "18:00", idle: 3 * 3600, engine: engine)
    let record = try #require(nextDay(tracker, engine: engine))
    #expect(record.weekendWork?.worked(at: at("2026-11-01 09:00")).rounded() == 5.0 * 3600)
    #expect(abs(record.earnedRUB - 17_000) < 0.001)
    #expect(record.weekendWork?.finished == true)
  }

  @Test func `a session left on pause closes where the pause began`() throws {
    let engine = try makeEngine()
    var tracker = started(.single, engine: engine)
    tracker.pause(now: at("2026-10-31 13:00"), engine: engine)
    let record = try #require(nextDay(tracker, engine: engine))
    #expect(record.weekendWork?.worked(at: at("2026-11-01 09:00")).rounded() == 3.0 * 3600)
  }

  @Test func `a lunch left open at midnight ends when it would have run out`() throws {
    let engine = try makeEngine()
    var tracker = started(.single, engine: engine)
    tracker.startLunch(now: at("2026-10-31 14:00"), engine: engine)
    let record = try #require(nextDay(tracker, engine: engine))
    #expect(record.lunches.last?.end == at("2026-10-31 15:00"))
    #expect(record.weekendWork?.worked(at: at("2026-11-01 09:00")).rounded() == 5.0 * 3600)
  }

  @Test func `a restart the same day keeps the session`() throws {
    let engine = try makeEngine()
    let tracker = started(.single, engine: engine)
    let (restored, _) = DayTracker.restore(records: tracker.allRecords, now: at("2026-10-31 12:00"), latestFX: nil, engine: engine)
    #expect(restored.today.weekendWork?.segments.first?.start == at("2026-10-31 10:00"))
    #expect(restored.today.weekendWork?.pay == .single)
    #expect(restored.today.startedAt == nil)
  }

  @Test func `missed days are not filled in for days off`() throws {
    let engine = try makeEngine()
    let friday = DayRecord(date: day("2026-10-30"), earnedRUB: 13_600, rateRUB: 1700, normHours: 8,
                           overtime: OvertimeState(closedAt: at("2026-10-30 17:00"), finalOvertime: 0))
    let (restored, _) = DayTracker.restore(records: [friday], now: at("2026-11-02 09:00"), latestFX: nil, engine: engine)
    #expect(restored.history.map(\.date) == [day("2026-10-30")])
  }

  // MARK: Month

  @Test func `weekend earnings add to the expected month`() throws {
    let engine = try makeEngine([Income(name: "a", amount: 272_000, currency: .rub)])
    var tracker = started(.double, engine: engine)
    tracker.finishWeekend(now: at("2026-10-31 13:00"), engine: engine)
    let weekend = tracker.today.earnedRUB
    let summary = tracker.monthSummary(engine: engine)
    let plain = DayTracker(today: DayRecord(date: saturday), history: []).monthSummary(engine: engine)
    #expect(abs(summary.expectedRUB - (plain.expectedRUB + weekend)) < 0.001)
    #expect(summary.earnedRUB == weekend)
  }

  @Test func `weekend overtime adds to the month and to gifted`() throws {
    let engine = try makeEngine()
    let friday = DayRecord(date: day("2026-10-30"), rateRUB: 1700, normHours: 8,
                           overtime: OvertimeState(closedAt: at("2026-10-30 18:00"), finalOvertime: 3600), overtimeSeconds: 3600)
    var tracker = DayTracker(today: DayRecord(date: saturday), history: [friday])
    tracker.startWeekendWork(pay: .overtime, now: at("2026-10-31 10:00"), engine: engine)
    tracker.finishWeekend(now: at("2026-10-31 12:00"), engine: engine)
    var summary = tracker.monthSummary(engine: engine)
    #expect(summary.overtimeSeconds == 3 * 3600)
    #expect(abs(summary.giftedRUB - 5_100) < 0.001)
    tracker.setWeekendPay(.double, now: at("2026-10-31 12:00"), engine: engine)
    summary = tracker.monthSummary(engine: engine)
    #expect(summary.overtimeSeconds == 3600)
  }
}
