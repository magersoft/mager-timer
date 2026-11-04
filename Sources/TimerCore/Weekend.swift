import Foundation

/// Work on a day off by the calendar: started only by the button, paid double, at the usual
/// rate or as overtime. It lives beside the working day's plan and never touches it.
extension DayTracker {
  /// Today's weekend session, while today is off by the calendar. If the calendar changed and
  /// today became a working day, the session is ignored (its data stays in the record).
  public func weekendWork(engine: Engine) -> WeekendWork? {
    guard isCalendarDayOff(engine: engine) else { return nil }
    return today.weekendWork
  }

  func isCalendarDayOff(engine: Engine) -> Bool {
    engine.status(on: today.date, dayOffs: dayOffs) == .nonWorking(.holiday)
  }

  /// The phase of today, a weekend session included.
  public func phase(engine: Engine, now: Date) -> DayPhase {
    guard let work = weekendWork(engine: engine) else {
      return engine.phase(at: now, status: status(engine: engine, now: now), overtime: today.overtime)
    }
    switch work.state {
    case .running: return weekendLunchSince(now: now, engine: engine) != nil ? .weekend(.lunch) : .weekend(.working)
    case .paused: return .weekend(.paused)
    case .finished: return .weekend(.finished)
    }
  }

  /// "Work on a day off" is there on a day off by the calendar until a session starts.
  public func canStartWeekendWork(engine: Engine) -> Bool {
    isCalendarDayOff(engine: engine) && today.weekendWork == nil
  }

  static func midnight(after date: LocalDate, engine: Engine) -> Date {
    date.adding(days: 1, calendar: engine.calendar).startOfDay(calendar: engine.calendar)
  }

  func midnight(engine: Engine) -> Date { Self.midnight(after: today.date, engine: engine) }

  /// Since when the user is out for lunch during a running weekend session.
  func weekendLunchSince(now: Date, engine: Engine) -> Date? {
    guard let open = today.openLunch, let limit = today.openLunchLimit(dayEnd: midnight(engine: engine)), now < limit else { return nil }
    return open.start
  }

  // MARK: - Actions

  /// Starts the session from now with the chosen pay; once a day, until cancelled.
  public mutating func startWeekendWork(pay: WeekendPay, now: Date, engine: Engine) {
    guard canStartWeekendWork(engine: engine) else { return }
    today.weekendWork = WeekendWork(pay: pay, start: now)
    today.breaks = BreakState()
    today.lunches = []
    updateWeekend(now: now, engine: engine)
  }

  public mutating func setWeekendPay(_ pay: WeekendPay, now: Date, engine: Engine) {
    guard weekendWork(engine: engine) != nil else { return }
    today.weekendWork?.pay = pay
    updateWeekend(now: now, engine: engine)
  }

  /// A start by mistake: the day is an ordinary day off again.
  public mutating func cancelWeekendWork(engine: Engine) {
    guard weekendWork(engine: engine) != nil else { return }
    today.weekendWork = nil
    today.lunches = []
    today.breaks = BreakState()
    today.earnedRUB = 0
    today.overtimeSeconds = 0
    today.rateRUB = 0
  }

  mutating func pauseWeekend(now: Date, engine: Engine) {
    settleLunch(now: now, engine: engine)
    guard weekendWork(engine: engine)?.state == .running, today.openLunch == nil else { return }
    today.weekendWork?.close(at: now)
    today.breaks.activeSince = nil
    updateWeekend(now: now, engine: engine)
  }

  mutating func resumeWeekend(now: Date, engine: Engine) {
    guard case .paused(let since) = weekendWork(engine: engine)?.state else { return }
    today.weekendWork?.open(at: max(now, since))
    rest(since: since, now: now, engine: engine)
    updateWeekend(now: now, engine: engine)
  }

  /// "Finish": the session stops now; from lunch, lunch ends now too.
  public mutating func finishWeekend(now: Date, engine: Engine) {
    settleLunch(now: now, engine: engine)
    guard let work = weekendWork(engine: engine), work.state != .finished else { return }
    if today.openLunch != nil { closeLunch(at: now, engine: engine) }
    today.weekendWork?.close(at: now)
    today.weekendWork?.finished = true
    today.breaks.activeSince = nil
    updateWeekend(now: now, engine: engine)
  }

  /// "Back to work" after "finish": counts on top of what was worked.
  mutating func resumeWeekendWork(now: Date, engine: Engine) {
    guard weekendWork(engine: engine)?.state == .finished, let last = today.weekendWork?.segments.last?.end else { return }
    today.weekendWork?.open(at: max(now, last))
    rest(since: last, now: now, engine: engine)
    updateWeekend(now: now, engine: engine)
  }

  // MARK: - Ticking

  /// Remembers the last activity while the session runs and recounts the day.
  mutating func tickWeekend(now: Date, idleSeconds: TimeInterval?, engine: Engine) {
    if let idleSeconds, let open = today.weekendWork?.openSegment {
      let activity = max(open.start, now.addingTimeInterval(-idleSeconds))
      if activity > (today.weekendWork?.lastActivityAt ?? .distantPast) { today.weekendWork?.lastActivityAt = activity }
    }
    settleLunch(now: now, engine: engine)
    updateWeekend(now: now, engine: engine)
  }

  mutating func updateWeekend(now: Date, engine: Engine) {
    Self.countWeekend(&today, now: now, engine: engine)
  }

  /// Money or overtime of a weekend session, written into the day's usual fields so that the
  /// month, "gifted" and goals pick it up as they are.
  static func countWeekend(_ record: inout DayRecord, now: Date, engine: Engine) {
    guard let work = record.weekendWork else { return }
    let rate = engine.rate(year: record.date.year, month: record.date.month, fx: record.fx).perHourRUB
    let worked = work.worked(at: now)
    record.rateRUB = rate
    record.normHours = 0
    record.scheduleHours = 0
    record.earnedRUB = worked / 3600 * rate * work.pay.multiplier
    record.overtimeSeconds = work.pay == .overtime ? worked : 0
  }

  /// Closes a session left open at midnight: a running one at the last activity (not before
  /// its start or the end of its last lunch), from lunch when the lunch would have run out,
  /// a paused one where the pause began.
  static func closeWeekend(_ record: inout DayRecord, engine: Engine) {
    guard var work = record.weekendWork else { return }
    let midnight = midnight(after: record.date, engine: engine)
    if let open = work.openSegment {
      if record.openLunch != nil, let limit = record.openLunchLimit(dayEnd: midnight) {
        record.lunches[record.lunches.count - 1].end = limit
        work.close(at: limit)
      } else {
        let lastLunch = record.lunches.compactMap(\.end).filter { $0 >= open.start }.max()
        let floor = max(open.start, lastLunch ?? open.start)
        work.close(at: min(max(work.lastActivityAt ?? floor, floor), midnight))
      }
    }
    work.finished = true
    record.weekendWork = work
    countWeekend(&record, now: midnight, engine: engine)
    let start = record.date.startOfDay(calendar: engine.calendar)
    record.overtime.finalize(end: start, at: start)
  }

  // MARK: - Breaks

  /// A plan for the break countdown while a weekend session is on: from its first start to
  /// midnight, the time between segments as pauses.
  func weekendBreakPlan(now: Date, engine: Engine) -> DayPlan? {
    guard let work = weekendWork(engine: engine), let first = work.segments.first else { return nil }
    let end = midnight(engine: engine)
    var pauses: [DateInterval] = []
    for (a, b) in zip(work.segments, work.segments.dropFirst()) {
      if let aEnd = a.end, b.start > aEnd { pauses.append(DateInterval(start: aEnd, end: b.start)) }
    }
    var pausedSince: Date?
    if work.openSegment == nil, let last = work.segments.last?.end {
      pauses.append(DateInterval(start: last, end: max(last, now)))
      pausedSince = last
    }
    var plan = DayPlan(
      date: today.date, isShort: false, start: first.start, end: end, normHours: 0, isStarted: true,
      pauses: pauses, pausedSince: pausedSince)
    plan.lunches = today.resolvedLunches(at: now, dayEnd: end)
    plan.lunchSince = weekendLunchSince(now: now, engine: engine)
    return plan
  }
}
