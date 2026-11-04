import Foundation

/// Today's state plus the history it builds on. Pure: the caller supplies time, activity and rates.
public struct DayTracker: Sendable {
  public enum Event: Hashable, Sendable {
    case dayStarted(expectedRUB: Double)
    case dayEnded(totalRUB: Double)
    case overtime(hours: Int)
    case goalAchieved(id: UUID, name: String)
    /// The lunch reminder: lunch can be taken right now.
    case lunchTime
  }

  public internal(set) var today: DayRecord
  /// Past days, oldest first.
  public private(set) var history: [DayRecord]

  public init(today: DayRecord, history: [DayRecord]) {
    self.today = today
    self.history = history.sorted { $0.date < $1.date }
  }

  /// Rebuilds the tracker from stored records: finalizes past days left open and fills in
  /// paid days the app never saw with a full day's pay — back to the first of the month on
  /// the very first launch, so the month does not start from zero. Returns the records that changed.
  public static func restore(records: [DayRecord], now: Date, latestFX: FXRates?, engine: Engine) -> (DayTracker, changed: [DayRecord]) {
    let todayDate = LocalDate(now, calendar: engine.calendar)
    var past = records.filter { $0.date < todayDate }.sorted { $0.date < $1.date }
    var changed: [DayRecord] = []
    for i in past.indices where !past[i].overtime.isClosed {
      finalize(&past[i], engine: engine, dayOffs: dayOffs(in: past))
      changed.append(past[i])
    }
    let firstMissing = past.last.map { $0.date.adding(days: 1, calendar: engine.calendar) }
      ?? LocalDate(year: todayDate.year, month: todayDate.month, day: 1)
    var day = firstMissing
    while day < todayDate {
      var record = DayRecord(date: day, fx: latestFX)
      finalize(&record, engine: engine, dayOffs: [:])
      if record.normHours > 0 {
        past.append(record)
        changed.append(record)
      }
      day = day.adding(days: 1, calendar: engine.calendar)
    }
    var today = records.first { $0.date == todayDate } ?? DayRecord(date: todayDate)
    // Saved by a version that started the day by the schedule: it is already earning.
    if today.startedAt == nil, today.weekendWork == nil, today.earnedRUB > 0 {
      today.startedAt = todayDate.date(at: engine.settings.schedule.start, calendar: engine.calendar)
    }
    return (DayTracker(today: today, history: past), changed)
  }

  private static func dayOffs(in records: [DayRecord]) -> [LocalDate: DayOff] {
    Dictionary(uniqueKeysWithValues: records.compactMap { r in r.dayOff.map { (r.date, $0) } })
  }

  /// A past day counts in full; open overtime is closed at what was observed. A working day
  /// that was never started was still worked (away from the Mac), as if started by the schedule.
  /// A pause never ended finishes the day early, at the moment it began.
  private static func finalize(_ record: inout DayRecord, engine: Engine, dayOffs: [LocalDate: DayOff]) {
    var offs = dayOffs
    offs[record.date] = record.dayOff
    if record.startedAt == nil, case .working(let plan) = engine.status(on: record.date, dayOffs: offs) {
      record.startedAt = plan.start
    }
    let pausedSince = record.openPause?.start
    let pauses = record.resolvedPauses(at: pausedSince ?? record.date.startOfDay(calendar: engine.calendar))
    let status = engine.status(on: record.date, dayOffs: offs, start: record.start, pauses: pauses)
    if status == .nonWorking(.holiday), record.weekendWork != nil {
      closeWeekend(&record, engine: engine)
      return
    }
    if let pausedSince, !record.overtime.isClosed, let plan = status.plan {
      record.undertimeSeconds = max(0, plan.end.timeIntervalSince(pausedSince))
      record.overtime.finish(end: plan.end, now: pausedSince)
    }
    // A lunch never ended ran out by itself: at the end of the hour or of the day.
    if let open = record.openLunch {
      record.lunches[record.lunches.count - 1].end = status.plan.flatMap { record.openLunchLimit(dayEnd: $0.end) } ?? open.start
    }
    guard let plan = status.paidPlan else {
      record.earnedRUB = 0
      record.normHours = 0
      record.overtime.finalize(end: record.date.startOfDay(calendar: engine.calendar), at: record.date.startOfDay(calendar: engine.calendar))
      return
    }
    let rate = engine.rate(year: record.date.year, month: record.date.month, fx: record.fx).perHourRUB
    let midnight = record.date.adding(days: 1, calendar: engine.calendar).startOfDay(calendar: engine.calendar)
    record.rateRUB = rate
    record.normHours = plan.normHours
    record.scheduleHours = plan.scheduleHours
    record.earnedRUB = plan.dayPay(rate: rate)
    record.overtime.finalize(end: plan.end, at: midnight)
    record.overtimeSeconds = record.overtime.overtime(end: plan.end, now: midnight)
  }

  // MARK: - Ticking

  public var dayOffs: [LocalDate: DayOff] {
    var offs = Self.dayOffs(in: history)
    offs[today.date] = today.dayOff
    return offs
  }

  /// Today's status at `now`: an open pause runs up to it and keeps pushing the end; an open
  /// lunch runs up to it, but not past the hour or the end of the day.
  public func status(engine: Engine, now: Date) -> DayStatus {
    let status = engine.status(
      on: today.date, dayOffs: dayOffs, start: today.start,
      pauses: today.resolvedPauses(at: now), pausedSince: today.openPause?.start)
    guard case .working(var plan) = status else { return status }
    plan.lunches = today.resolvedLunches(at: now, dayEnd: plan.end)
    if let open = today.openLunch, let limit = today.openLunchLimit(dayEnd: plan.end), now < limit {
      plan.lunchSince = open.start
    }
    return .working(plan)
  }

  /// Scheduled hours are on and the day has not started: activity now would start it.
  public func awaitsStart(now: Date, engine: Engine) -> Bool {
    guard case .working(let plan) = status(engine: engine, now: now), !plan.isStarted, !today.manualStartOnly else { return false }
    return (plan.start..<plan.end).contains(now)
  }

  /// Rolls the day over at midnight and returns the record of the day that just ended, if any.
  public mutating func rollOver(now: Date, latestFX: FXRates?, engine: Engine) -> [DayRecord] {
    let date = LocalDate(now, calendar: engine.calendar)
    guard date > today.date else { return [] }
    let (rebuilt, changed) = Self.restore(records: history + [today], now: now, latestFX: latestFX, engine: engine)
    self = rebuilt
    return changed
  }

  /// Recomputes today at `now`. `idleSeconds` is nil while the screen is locked or the Mac sleeps.
  /// `checkGoals` is off while goals are being edited, so a half-typed amount does not count as reached.
  public mutating func tick(now: Date, idleSeconds: TimeInterval?, latestFX: FXRates?, engine: Engine, checkGoals: Bool = true) -> [Event] {
    if today.fx == nil, let latestFX { today.fx = latestFX }
    if weekendWork(engine: engine) != nil {
      tickWeekend(now: now, idleSeconds: idleSeconds, engine: engine)
      return goalEvents(engine: engine, now: now, checkGoals: checkGoals)
    }
    // Forgot to press "start": the first activity within the scheduled hours starts the day.
    if let idleSeconds, awaitsStart(now: now, engine: engine), let scheduled = status(engine: engine, now: now).plan {
      let activity = now.addingTimeInterval(-idleSeconds)
      if (scheduled.start..<scheduled.end).contains(activity) { today.startedAt = activity }
    }
    settleLunch(now: now, engine: engine)
    let status = status(engine: engine, now: now)
    guard let plan = status.paidPlan else {
      today.earnedRUB = 0
      today.normHours = 0
      today.scheduleHours = 0
      today.overtimeSeconds = 0
      return []
    }
    let rate = engine.rate(year: today.date.year, month: today.date.month, fx: today.fx).perHourRUB
    today.rateRUB = rate
    today.normHours = plan.normHours
    today.scheduleHours = plan.scheduleHours
    // A closed day, early or not, is paid in full.
    today.earnedRUB = status.plan != nil && today.overtime.isClosed ? plan.dayPay(rate: rate) : plan.earned(rate: rate, at: now)
    // On paid leave the money flows, but there is nothing to notify and no overtime;
    // a day not yet started has neither.
    guard status.plan != nil, plan.isStarted else {
      today.overtimeSeconds = 0
      return []
    }
    today.overtime.advance(end: plan.end, now: now, idleSeconds: idleSeconds)
    today.overtimeSeconds = today.overtime.overtime(end: plan.end, now: now)

    var events: [Event] = []
    if now >= plan.start, notifyOnce("start", deliver: now < plan.end) {
      events.append(.dayStarted(expectedRUB: plan.dayPay(rate: rate)))
    }
    if now >= plan.end, notifyOnce("end", deliver: now.timeIntervalSince(plan.end) < OvertimeState.idleLimit) {
      events.append(.dayEnded(totalRUB: today.earnedRUB))
    }
    // One reminder a day, at its time; if lunch cannot be taken then, it does not come later.
    let window = engine.lunchWindow(on: today.date)
    if engine.settings.schedule.lunchReminder, now >= window.start,
       notifyOnce("lunch", deliver: now < window.end && canStartLunch(now: now, engine: engine))
    {
      events.append(.lunchTime)
    }
    let hours = Int(today.overtimeSeconds / 3600)
    if hours >= 1, !today.overtime.isClosed, notifyOnce("overtime-\(hours)", deliver: true) {
      events.append(.overtime(hours: hours))
    }
    return events + goalEvents(engine: engine, now: now, checkGoals: checkGoals)
  }

  private mutating func goalEvents(engine: Engine, now: Date, checkGoals: Bool) -> [Event] {
    var events: [Event] = []
    for goal in engine.settings.goals where checkGoals && goal.achievedOn == nil {
      // Keyed by the target too, so a goal raised after being reached can be reached again.
      if let progress = goalProgress(goal, engine: engine, now: now), progress.achieved,
         notifyOnce("goal-\(goal.id)-\(goal.amount)\(goal.currency.rawValue)", deliver: true)
      {
        events.append(.goalAchieved(id: goal.id, name: goal.name))
      }
    }
    return events
  }

  /// Marks a notification key; returns true when it should be delivered now.
  private mutating func notifyOnce(_ key: String, deliver: Bool) -> Bool {
    guard !today.notified.contains(key) else { return false }
    today.notified.insert(key)
    return deliver
  }

  // MARK: - User actions

  /// "Start the day": the day runs from now, early or late; once only.
  public mutating func startDay(now: Date, engine: Engine) {
    guard today.startedAt == nil, status(engine: engine, now: now).plan != nil else { return }
    today.startedAt = now
  }

  /// A start by mistake: the day is back to not started, as if nothing ran, and from now on
  /// starts only by the button. A day already closed keeps its start.
  public mutating func resetStart(now: Date, engine: Engine) {
    guard today.startedAt != nil, !today.overtime.isClosed, status(engine: engine, now: now).plan != nil else { return }
    today.startedAt = nil
    today.manualStartOnly = true
    today.earnedRUB = 0
    today.overtime = OvertimeState()
    today.overtimeSeconds = 0
    today.breaks = BreakState()
    today.pauses = []
    today.undertimeSeconds = 0
    today.lunches = []
    today.notified = today.notified.filter { $0 != "start" && $0 != "end" && $0 != "lunch" && !$0.hasPrefix("overtime-") }
  }

  public mutating func stillWorking(now: Date, engine: Engine) {
    guard let plan = status(engine: engine, now: now).plan, plan.isStarted, now >= plan.end else { return }
    today.overtime.startManual()
  }

  public mutating func finish(now: Date, engine: Engine) {
    guard let plan = status(engine: engine, now: now).plan, plan.isStarted, now >= plan.end else { return }
    today.overtime.finish(end: plan.end, now: now)
    today.overtimeSeconds = today.overtime.overtime(end: plan.end, now: now)
  }

  /// A started day, still running and before its end.
  private func runningPlan(now: Date, engine: Engine) -> DayPlan? {
    guard let plan = status(engine: engine, now: now).plan, plan.isStarted, now >= plan.start,
          !today.overtime.isClosed, now < plan.end else { return nil }
    return plan
  }

  /// "Pause": money stands still, and the end moves on by as long as the pause lasts. Not at
  /// lunch: the user is away already.
  public mutating func pause(now: Date, engine: Engine) {
    if weekendWork(engine: engine) != nil { return pauseWeekend(now: now, engine: engine) }
    settleLunch(now: now, engine: engine)
    guard runningPlan(now: now, engine: engine) != nil, today.openPause == nil, today.openLunch == nil else { return }
    today.pauses.append(Pause(start: now))
    today.breaks.activeSince = nil
  }

  /// "Resume" after a pause.
  public mutating func resume(now: Date, engine: Engine) {
    if weekendWork(engine: engine) != nil { return resumeWeekend(now: now, engine: engine) }
    guard !today.overtime.isClosed, let since = today.openPause?.start else { return }
    today.pauses[today.pauses.count - 1].end = max(now, since)
    rest(since: since, now: now, engine: engine)
  }

  /// "Finish the day" before its end: paid in full, the rest of the norm left as undertime.
  /// From a pause, the day ends where the pause began; the pause stays open, so "back to work" ends it.
  public mutating func finishEarly(now: Date, engine: Engine) {
    settleLunch(now: now, engine: engine)
    guard let plan = runningPlan(now: now, engine: engine) else { return }
    if today.openLunch != nil { closeLunch(at: now, engine: engine) }
    let since = today.openPause?.start ?? now
    if today.openPause == nil { today.pauses.append(Pause(start: now)) }
    // The open pause pushes the end with `now`, so what is left is simply end − now.
    today.undertimeSeconds = max(0, plan.end.timeIntervalSince(now))
    today.overtime.finish(end: plan.end, now: since)
    today.overtimeSeconds = 0
    today.breaks.activeSince = nil
    tickEarned(engine: engine)
  }

  /// "Back to work" on a day closed today. Closed early, the time away was a pause and the day
  /// runs to its new end; closed after the end, a new overtime session starts.
  public mutating func resumeWork(now: Date, engine: Engine) {
    if weekendWork(engine: engine) != nil { return resumeWeekendWork(now: now, engine: engine) }
    guard today.overtime.isClosed, let plan = status(engine: engine, now: now).plan, plan.isStarted else { return }
    if let since = today.openPause?.start {
      today.pauses[today.pauses.count - 1].end = max(now, since)
      today.overtime = OvertimeState(mode: .manual, lastActivityAt: now, resumedAt: now)
      today.undertimeSeconds = 0
      rest(since: since, now: now, engine: engine)
    } else {
      let closedAt = today.overtime.closedAt ?? now
      today.overtime.reopen(at: now)
      rest(since: closedAt, now: now, engine: engine)
    }
  }

  /// "Lunch" is there while the day runs, off pause, and some of the hour is left.
  public func canStartLunch(now: Date, engine: Engine) -> Bool {
    if let work = weekendWork(engine: engine) {
      guard work.state == .running, weekendLunchSince(now: now, engine: engine) == nil else { return false }
      return today.closedLunchTime < Lunch.dailyLimit
    }
    guard let plan = runningPlan(now: now, engine: engine), today.openPause == nil, plan.lunchSince == nil else { return false }
    return today.closedLunchTime < Lunch.dailyLimit
  }

  /// "Lunch": out for lunch from now. Money and the end of the day do not change.
  public mutating func startLunch(now: Date, engine: Engine) {
    settleLunch(now: now, engine: engine)
    guard canStartLunch(now: now, engine: engine) else { return }
    today.lunches.append(Lunch(start: now))
    today.breaks.activeSince = nil
  }

  /// "Back" from lunch.
  public mutating func endLunch(now: Date, engine: Engine) {
    settleLunch(now: now, engine: engine)
    guard today.openLunch != nil else { return }
    closeLunch(at: now, engine: engine)
  }

  /// Ends an open lunch whose hour or day ran out, at that moment.
  mutating func settleLunch(now: Date, engine: Engine) {
    let dayEnd = weekendWork(engine: engine) != nil ? midnight(engine: engine) : status(engine: engine, now: now).plan?.end
    guard today.openLunch != nil, let dayEnd, let limit = today.openLunchLimit(dayEnd: dayEnd), limit <= now else { return }
    closeLunch(at: limit, engine: engine)
  }

  mutating func closeLunch(at moment: Date, engine: Engine) {
    guard let since = today.openLunch?.start else { return }
    today.lunches[today.lunches.count - 1].end = max(moment, since)
    rest(since: since, now: max(moment, since), engine: engine)
  }

  /// Time away at least as long as a break was a break.
  mutating func rest(since: Date, now: Date, engine: Engine) {
    if now.timeIntervalSince(since) >= engine.settings.breaks.length { today.breaks.restart(at: now) }
  }

  /// A closed day is paid in full right away, not on the next tick.
  private mutating func tickEarned(engine: Engine) {
    let rate = engine.rate(year: today.date.year, month: today.date.month, fx: today.fx).perHourRUB
    today.earnedRUB = rate * today.normHours
  }

  public mutating func setDayOff(_ dayOff: DayOff?) {
    today.dayOff = dayOff
  }

  // MARK: - Aggregates

  public var allRecords: [DayRecord] { history + [today] }

  public func month() -> [DayRecord] { allRecords.filter { $0.date.isSameMonth(as: today.date) } }

  public struct MonthSummary: Hashable, Sendable {
    public var earnedRUB: Double
    public var expectedRUB: Double
    public var overtimeSeconds: Double
    /// The norm left unworked by days finished early.
    public var undertimeSeconds: Double
    /// Overtime valued at each day's rate.
    public var giftedRUB: Double
  }

  public func monthSummary(engine: Engine) -> MonthSummary {
    let records = month()
    let rate = engine.rate(year: today.date.year, month: today.date.month, fx: today.fx).perHourRUB
    let offs = dayOffs
    let expected = engine.workCalendar.days(inMonth: today.date.year, today.date.month, calendar: engine.calendar)
      .compactMap { engine.status(on: $0, dayOffs: offs).paidPlan }
      .reduce(0) { $0 + $1.dayPay(rate: rate) }
    // Work on days off is on top of the salary, so the month can still reach 100%.
    let weekend = records.filter { $0.weekendWork != nil && $0.normHours == 0 }.reduce(0) { $0 + $1.earnedRUB }
    return MonthSummary(
      earnedRUB: records.reduce(0) { $0 + $1.earnedRUB },
      expectedRUB: expected + weekend,
      overtimeSeconds: records.reduce(0) { $0 + $1.overtimeSeconds },
      undertimeSeconds: records.reduce(0) { $0 + $1.undertimeSeconds },
      giftedRUB: records.reduce(0) { $0 + $1.overtimeSeconds / 3600 * $1.rateRUB })
  }

  public struct GoalProgress: Hashable, Sendable {
    public var savedRUB: Double
    public var targetRUB: Double
    public var achieved: Bool
    public var forecast: LocalDate?

    public var fraction: Double { targetRUB > 0 ? min(savedRUB / targetRUB, 1) : 0 }
  }

  /// What was already put aside plus the goal's share of earnings since it was set.
  /// Nil when the goal's currency has no known rate.
  public func goalProgress(_ goal: Goal, engine: Engine, now: Date) -> GoalProgress? {
    let fx = today.fx
    let toRUB = { (value: Double) in goal.currency == .rub ? value : fx?.toRUB(value, from: goal.currency) }
    guard let target = toRUB(goal.amount), let initial = toRUB(goal.initialSaved) else { return nil }
    let share = Double(goal.percent) / 100
    let saved = initial + allRecords.filter { $0.date >= goal.createdOn }.reduce(0) { $0 + $1.earnedRUB } * share
    let achieved = goal.achievedOn != nil || saved >= target
    var forecast: LocalDate?
    if !achieved {
      let rate = engine.rate(year: today.date.year, month: today.date.month, fx: fx).perHourRUB
      var remaining = target - saved
      if let plan = status(engine: engine, now: now).paidPlan {
        remaining -= (plan.dayPay(rate: rate) - today.earnedRUB) * share
        if remaining <= 0 { forecast = today.date }
      }
      if forecast == nil, rate > 0 {
        for plan in engine.paidDays(after: today.date, dayOffs: dayOffs) {
          remaining -= plan.dayPay(rate: rate) * share
          if remaining <= 0 {
            forecast = plan.date
            break
          }
        }
      }
    }
    return GoalProgress(savedRUB: min(saved, target), targetRUB: target, achieved: achieved, forecast: forecast)
  }
}

extension DayRecord {
  /// How the day's plan is anchored.
  public var start: DayStart { startedAt.map { .at($0) } ?? .notStarted }
}
