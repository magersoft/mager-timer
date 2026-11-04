import Foundation

/// The schedule of one working day, resolved to concrete instants.
public struct DayPlan: Hashable, Sendable {
  public var date: LocalDate
  public var isShort: Bool
  public var start: Date
  public var end: Date
  /// 8, or 7 on a shortened day.
  public var normHours: Double
  /// False until the day is started; the times are then the schedule's, as a forecast.
  public var isStarted: Bool
  /// Pauses of the day; an open one runs up to the moment the plan was made for.
  public var pauses: [DateInterval] = []
  /// The day is on pause since this moment.
  public var pausedSince: Date?
  /// Lunches of the day; they change neither the money nor the end.
  public var lunches: [DateInterval] = []
  /// The user is out for lunch since this moment.
  public var lunchSince: Date?

  /// The length of the schedule: from start to end, pauses left out.
  public var duration: TimeInterval { end.timeIntervalSince(start) - pauses.reduce(0) { $0 + $1.duration } }
  public var scheduleHours: Double { duration / 3600 }

  public func dayPay(rate: Double) -> Double { rate * normHours }

  /// Time between `from` and `to` that is not paused.
  public func activeTime(from: Date, to: Date) -> TimeInterval {
    guard to > from else { return 0 }
    let paused = pauses.reduce(0) { $0 + max(0, min($1.end, to).timeIntervalSince(max($1.start, from))) }
    return to.timeIntervalSince(from) - paused
  }

  /// Earnings grow evenly over the active time from start to end, lunch included, up to the day's pay.
  public func earned(rate: Double, at now: Date) -> Double {
    guard isStarted, duration > 0 else { return 0 }
    let fraction = min(max(activeTime(from: start, to: min(now, end)) / duration, 0), 1)
    return dayPay(rate: rate) * fraction
  }

  public struct HourSlot: Hashable, Sendable {
    public enum State: Sendable { case done, inProgress, upcoming }
    public var start: Date
    public var end: Date
    public var earnedRUB: Double
    public var state: State
  }

  /// One slot per hour counted from the start of the schedule.
  public func hourSlots(rate: Double, at now: Date) -> [HourSlot] {
    guard duration > 0 else { return [] }
    let now = isStarted ? now : .distantPast
    let perSecond = dayPay(rate: rate) / duration
    var slots: [HourSlot] = []
    var slotStart = start
    while slotStart < end {
      let slotEnd = min(slotStart.addingTimeInterval(3600), end)
      let counted = activeTime(from: slotStart, to: min(now, slotEnd))
      let state: HourSlot.State = now >= slotEnd ? .done : (now >= slotStart ? .inProgress : .upcoming)
      slots.append(HourSlot(start: slotStart, end: slotEnd, earnedRUB: counted * perSecond, state: state))
      slotStart = slotEnd
    }
    return slots
  }
}

/// When a working day began.
public enum DayStart: Hashable, Sendable {
  /// At the scheduled time: forecasts, and days that were never started by hand.
  case scheduled
  case at(Date)
  case notStarted
}

/// A working day the user marked as not working.
public enum DayOff: String, Codable, Hashable, Sendable {
  /// Sick leave or a day off that keeps the pay.
  case paid
  /// A day off at one's own expense.
  case unpaid
}

public enum NonWorkingReason: Hashable, Sendable {
  case holiday
  case unpaidDayOff
}

/// Days that are paid as usual without working.
public enum LeaveReason: Hashable, Sendable {
  case vacation
  case paidDayOff
}

public enum DayStatus: Hashable, Sendable {
  case working(DayPlan)
  case paidLeave(DayPlan, LeaveReason)
  case nonWorking(NonWorkingReason)

  /// The plan of a day that is actually worked.
  public var plan: DayPlan? {
    if case .working(let plan) = self { plan } else { nil }
  }

  /// The plan of any paid day, worked or on leave.
  public var paidPlan: DayPlan? {
    switch self {
    case .working(let plan), .paidLeave(let plan, _): plan
    case .nonWorking: nil
    }
  }
}

public enum DayPhase: Hashable, Sendable {
  case nonWorking(NonWorkingReason)
  case paidLeave(LeaveReason)
  case beforeStart
  case working
  case lunch
  /// The user stepped away: money stands still and the end moves on.
  case paused
  /// After the scheduled end; overtime may be accruing.
  case afterHours
  case closed
  /// Work on a day off by the calendar (`WeekendWork`).
  case weekend(WeekendPhase)
}

public enum WeekendPhase: Hashable, Sendable {
  case working
  case lunch
  case paused
  case finished
}

/// Money arriving on one day, possibly from several incomes.
public struct UpcomingPayout: Hashable, Sendable {
  public struct Share: Hashable, Sendable {
    public var income: Income
    public var percent: Int

    /// In the income's currency.
    public var amount: Double { income.amount * Double(percent) / 100 }
  }

  public var date: LocalDate
  public var shares: [Share]
}

public struct HourlyRate: Hashable, Sendable {
  public var perHourRUB: Double
  /// Incomes left out because no exchange rate is known for their currency.
  public var excluded: [Income]
}

/// Pure calculations over the user's settings and the production calendar.
public struct Engine: Sendable {
  public var settings: Settings
  public var workCalendar: WorkCalendar
  public var calendar: Calendar

  public init(settings: Settings, workCalendar: WorkCalendar, calendar: Calendar) {
    self.settings = settings
    self.workCalendar = workCalendar
    self.calendar = calendar
  }

  public func isCalendarApproximate(for date: LocalDate) -> Bool { !workCalendar.hasData(for: date.year) }

  public func lacksOneOffHolidays(for date: LocalDate) -> Bool { workCalendar.lacksOneOffHolidays(for: date.year) }

  /// Paid leave runs by the schedule; only a worked day follows `start` and its pauses.
  public func status(
    on date: LocalDate, dayOffs: [LocalDate: DayOff] = [:], start: DayStart = .scheduled,
    pauses: [DateInterval] = [], pausedSince: Date? = nil
  ) -> DayStatus {
    let kind = workCalendar.kind(of: date, calendar: calendar)
    if kind == .nonWorking { return .nonWorking(.holiday) }
    let isShort = kind == .short
    if settings.vacations.contains(where: { $0.contains(date) }) { return .paidLeave(plan(for: date, isShort: isShort), .vacation) }
    switch dayOffs[date] {
    case .paid: return .paidLeave(plan(for: date, isShort: isShort), .paidDayOff)
    case .unpaid: return .nonWorking(.unpaidDayOff)
    case nil: return .working(plan(for: date, isShort: isShort, start: start, pauses: pauses, pausedSince: pausedSince))
    }
  }

  /// The whole day moves with its actual start and keeps its length; pauses push the end further.
  public func plan(
    for date: LocalDate, isShort: Bool, start: DayStart = .scheduled, pauses: [DateInterval] = [], pausedSince: Date? = nil
  ) -> DayPlan {
    let s = settings.schedule
    let scheduled = date.date(at: s.start, calendar: calendar)
    let begin = if case .at(let moment) = start { moment } else { scheduled }
    let paused = pauses.reduce(0) { $0 + $1.duration }
    var end = date.date(at: s.end, calendar: calendar).addingTimeInterval(begin.timeIntervalSince(scheduled) + paused)
    if isShort { end = max(begin, end.addingTimeInterval(-3600)) }
    return DayPlan(
      date: date, isShort: isShort, start: begin, end: end,
      normHours: isShort ? 7 : 8, isStarted: start != .notStarted, pauses: pauses, pausedSince: pausedSince)
  }

  /// The hour after the lunch reminder, on the clock whatever time the day started. It only
  /// prompts lunch; time in it is lunch only when the user took it.
  public func lunchWindow(on date: LocalDate) -> DateInterval {
    DateInterval(start: date.date(at: settings.schedule.lunchStart, calendar: calendar), duration: Lunch.dailyLimit)
  }

  /// Σ incomes in RUB ÷ the month's norm hours.
  public func rate(year: Int, month: Int, fx: FXRates?) -> HourlyRate {
    var totalRUB = 0.0
    var excluded: [Income] = []
    for income in settings.incomes {
      let rub = income.currency == .rub ? income.amount : fx?.toRUB(income.amount, from: income.currency)
      if let rub { totalRUB += rub } else { excluded.append(income) }
    }
    let norm = workCalendar.normHours(year: year, month: month, calendar: calendar)
    return HourlyRate(perHourRUB: norm > 0 ? totalRUB / norm : 0, excluded: excluded)
  }

  public func phase(at now: Date, status: DayStatus, overtime: OvertimeState) -> DayPhase {
    let plan: DayPlan
    switch status {
    case .working(let p): plan = p
    case .paidLeave(_, let reason): return .paidLeave(reason)
    case .nonWorking(let reason): return .nonWorking(reason)
    }
    if !plan.isStarted || now < plan.start { return .beforeStart }
    // A day finished early is closed before its end.
    if overtime.isClosed { return .closed }
    if plan.pausedSince != nil { return .paused }
    if now < plan.end {
      return plan.lunchSince != nil ? .lunch : .working
    }
    return .afterHours
  }

  /// Paid days strictly after `date`, in order, within a horizon.
  public func paidDays(after date: LocalDate, dayOffs: [LocalDate: DayOff] = [:], limit: Int = 800) -> some Sequence<DayPlan> {
    (1...limit).lazy.compactMap { offset in
      status(on: date.adding(days: offset, calendar: calendar), dayOffs: dayOffs).paidPlan
    }
  }

  /// The nearest payday on or after `date`, with every income share paid that day. A payday
  /// that falls on a weekend or holiday moves to the preceding working day (Labour Code art. 136).
  public func nextPayout(onOrAfter date: LocalDate) -> UpcomingPayout? {
    var candidates: [(date: LocalDate, share: UpcomingPayout.Share)] = []
    for offset in 0...2 {
      let anchor = calendar.date(byAdding: .month, value: offset, to: LocalDate(year: date.year, month: date.month, day: 1).startOfDay(calendar: calendar))!
      let month = LocalDate(anchor, calendar: calendar)
      let length = calendar.range(of: .day, in: .month, for: anchor)!.count
      for income in settings.incomes {
        for payout in income.payouts where (1...31).contains(payout.day) {
          var payday = LocalDate(year: month.year, month: month.month, day: min(payout.day, length))
          for _ in 0..<15 where workCalendar.kind(of: payday, calendar: calendar) == .nonWorking {
            payday = payday.adding(days: -1, calendar: calendar)
          }
          if payday >= date { candidates.append((payday, .init(income: income, percent: payout.percent))) }
        }
      }
    }
    guard let first = candidates.map(\.date).min() else { return nil }
    return UpcomingPayout(date: first, shares: candidates.filter { $0.date == first }.map(\.share))
  }
}

extension OvertimeState {
  /// The current session counts from the scheduled end, or from "back to work" if later.
  func sessionStart(end: Date) -> Date { max(end, resumedAt ?? end) }

  /// Overtime so far, given the scheduled end.
  public func overtime(end: Date, now: Date) -> TimeInterval {
    if let finalOvertime { return finalOvertime }
    let from = sessionStart(end: end)
    guard now > from else { return banked }
    switch mode {
    case .manual: return banked + now.timeIntervalSince(from)
    case .auto: return banked + max(0, (lastActivityAt ?? from).timeIntervalSince(from))
    }
  }

  /// Advances automatic tracking. `idleSeconds` is nil while the screen is locked or the Mac sleeps.
  public mutating func advance(end: Date, now: Date, idleSeconds: TimeInterval?) {
    let from = sessionStart(end: end)
    guard !isClosed, now > from else { return }
    let previous = max(from, lastActivityAt ?? from)
    if let idleSeconds {
      let activity = now.addingTimeInterval(-idleSeconds)
      if activity > previous {
        if mode == .auto, activity.timeIntervalSince(previous) >= Self.idleLimit {
          close(at: previous.addingTimeInterval(Self.idleLimit), overtime: banked + previous.timeIntervalSince(from))
          return
        }
        lastActivityAt = activity
      }
    }
    guard mode == .auto else { return }
    let last = max(from, lastActivityAt ?? from)
    if now.timeIntervalSince(last) >= Self.idleLimit {
      close(at: last.addingTimeInterval(Self.idleLimit), overtime: banked + last.timeIntervalSince(from))
    }
  }

  /// "Still working": overtime counts continuously from the scheduled end.
  public mutating func startManual() {
    guard !isClosed else { return }
    mode = .manual
  }

  /// "Done for today".
  public mutating func finish(end: Date, now: Date) {
    guard !isClosed else { return }
    close(at: now, overtime: overtime(end: end, now: now))
  }

  /// "Back to work" on a day closed after its end: a new session that counts on top of the
  /// earlier ones, continuously, as "still working" does — the user said they are working.
  public mutating func reopen(at moment: Date) {
    guard isClosed else { return }
    banked = finalOvertime ?? 0
    closedAt = nil
    finalOvertime = nil
    mode = .manual
    resumedAt = moment
    lastActivityAt = moment
  }

  /// Closes a day that was left open (app quit, or the day rolled over).
  public mutating func finalize(end: Date, at moment: Date) {
    guard !isClosed else { return }
    let from = sessionStart(end: end)
    let value: TimeInterval
    switch mode {
    case .manual: value = max(0, min(moment, lastActivityAt ?? from).timeIntervalSince(from))
    case .auto: value = max(0, (lastActivityAt ?? from).timeIntervalSince(from))
    }
    close(at: moment, overtime: banked + value)
  }

  private mutating func close(at moment: Date, overtime: TimeInterval) {
    closedAt = moment
    finalOvertime = max(0, overtime)
  }
}
