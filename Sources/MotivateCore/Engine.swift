import Foundation

/// The schedule of one working day, resolved to concrete instants.
public struct DayPlan: Hashable, Sendable {
  public var date: LocalDate
  public var isShort: Bool
  public var start: Date
  public var end: Date
  public var lunchStart: Date
  public var lunchEnd: Date
  /// 8, or 7 on a shortened day.
  public var normHours: Double
  /// False until the day is started; the times are then the schedule's, as a forecast.
  public var isStarted: Bool

  public var duration: TimeInterval { end.timeIntervalSince(start) }
  public var scheduleHours: Double { duration / 3600 }

  public func dayPay(rate: Double) -> Double { rate * normHours }

  /// Earnings grow evenly from start to end, lunch included, up to the day's pay.
  public func earned(rate: Double, at now: Date) -> Double {
    guard isStarted, duration > 0 else { return 0 }
    let fraction = min(max(now.timeIntervalSince(start) / duration, 0), 1)
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
      let counted = min(max(now.timeIntervalSince(slotStart), 0), slotEnd.timeIntervalSince(slotStart))
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
  /// After the scheduled end; overtime may be accruing.
  case afterHours
  case closed
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

  /// Paid leave runs by the schedule; only a worked day follows `start`.
  public func status(on date: LocalDate, dayOffs: [LocalDate: DayOff] = [:], start: DayStart = .scheduled) -> DayStatus {
    let kind = workCalendar.kind(of: date, calendar: calendar)
    if kind == .nonWorking { return .nonWorking(.holiday) }
    let isShort = kind == .short
    if settings.vacations.contains(where: { $0.contains(date) }) { return .paidLeave(plan(for: date, isShort: isShort), .vacation) }
    switch dayOffs[date] {
    case .paid: return .paidLeave(plan(for: date, isShort: isShort), .paidDayOff)
    case .unpaid: return .nonWorking(.unpaidDayOff)
    case nil: return .working(plan(for: date, isShort: isShort, start: start))
    }
  }

  /// The whole day moves with its actual start and keeps its length; lunch stays on the clock.
  public func plan(for date: LocalDate, isShort: Bool, start: DayStart = .scheduled) -> DayPlan {
    let s = settings.schedule
    let scheduled = date.date(at: s.start, calendar: calendar)
    let begin = if case .at(let moment) = start { moment } else { scheduled }
    var end = date.date(at: s.end, calendar: calendar).addingTimeInterval(begin.timeIntervalSince(scheduled))
    if isShort { end = max(begin, end.addingTimeInterval(-3600)) }
    let clamp = { (moment: Date) in min(max(moment, begin), end) }
    return DayPlan(
      date: date, isShort: isShort, start: begin, end: end,
      lunchStart: clamp(date.date(at: s.lunchStart, calendar: calendar)),
      lunchEnd: clamp(date.date(at: s.lunchEnd, calendar: calendar)),
      normHours: isShort ? 7 : 8, isStarted: start != .notStarted)
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
    if now < plan.end {
      return (plan.lunchStart..<plan.lunchEnd).contains(now) ? .lunch : .working
    }
    return overtime.isClosed ? .closed : .afterHours
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
  /// Overtime so far, given the scheduled end.
  public func overtime(end: Date, now: Date) -> TimeInterval {
    if let finalOvertime { return finalOvertime }
    guard now > end else { return 0 }
    switch mode {
    case .manual: return now.timeIntervalSince(end)
    case .auto: return max(0, (lastActivityAt ?? end).timeIntervalSince(end))
    }
  }

  /// Advances automatic tracking. `idleSeconds` is nil while the screen is locked or the Mac sleeps.
  public mutating func advance(end: Date, now: Date, idleSeconds: TimeInterval?) {
    guard !isClosed, now > end else { return }
    let previous = max(end, lastActivityAt ?? end)
    if let idleSeconds {
      let activity = now.addingTimeInterval(-idleSeconds)
      if activity > previous {
        if mode == .auto, activity.timeIntervalSince(previous) >= Self.idleLimit {
          close(at: previous.addingTimeInterval(Self.idleLimit), overtime: previous.timeIntervalSince(end))
          return
        }
        lastActivityAt = activity
      }
    }
    guard mode == .auto else { return }
    let last = max(end, lastActivityAt ?? end)
    if now.timeIntervalSince(last) >= Self.idleLimit {
      close(at: last.addingTimeInterval(Self.idleLimit), overtime: last.timeIntervalSince(end))
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

  /// Closes a day that was left open (app quit, or the day rolled over).
  public mutating func finalize(end: Date, at moment: Date) {
    guard !isClosed else { return }
    let value: TimeInterval
    switch mode {
    case .manual: value = max(0, min(moment, lastActivityAt ?? end).timeIntervalSince(end))
    case .auto: value = max(0, (lastActivityAt ?? end).timeIntervalSince(end))
    }
    close(at: moment, overtime: value)
  }

  private mutating func close(at moment: Date, overtime: TimeInterval) {
    closedAt = moment
    finalOvertime = max(0, overtime)
  }
}
