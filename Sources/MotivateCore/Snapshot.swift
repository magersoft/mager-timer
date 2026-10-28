import Foundation

/// Everything the menu bar and its window show at one moment, already formatted.
public struct DaySnapshot: Hashable, Sendable {
  public enum Action: Hashable, Sendable {
    case startDay
    case resetStart
    case stillWorking
    case finish
    case dayOff
    case undoDayOff
  }

  public struct Hour: Hashable, Sendable {
    /// `10:00–11:00`
    public var label: String
    /// `10` — hour of the slot start, for axis ticks.
    public var startLabel: String
    public var amount: String
    public var state: DayPlan.HourSlot.State
    /// How much of the slot has passed, 0...1.
    public var fraction: Double
    /// The slot is mostly lunch.
    public var isLunch: Bool
  }

  public struct Today: Hashable, Sendable {
    public var dateLabel: String
    /// `07:20` — when the day actually started; nil until it does.
    public var startTime: String?
    public var earned: String
    public var dayPay: String
    public var fraction: Double
    /// Time left until the scheduled end, when the day is still running.
    public var remaining: String?
    public var hours: [Hour]
    /// `15` — hour of the scheduled end, closing the axis.
    public var endLabel: String
    /// `15:00` — the scheduled end.
    public var endTime: String
    /// Position of "now" across the scheduled day, 0...1; nil outside it.
    public var nowFraction: Double?
    public var overtimeHours: Double
    public var rate: String
    /// Real rate after overtime, e.g. `1 360 ₽/ч (−20%)`.
    public var realRate: String?
    public var overtime: String?
  }

  public struct Month: Hashable, Sendable {
    public var title: String
    public var earned: String
    public var expected: String
    public var fraction: Double
    public var overtime: String?
  }

  public struct Payday: Hashable, Sendable {
    /// `Выплата 10 нояб. · через 14 дн.`
    public var title: String
    /// `≈ 120 000 ₽`, or the parts in their own currencies when a rate is missing.
    public var amount: String
    /// `Работа 60% · Фриланс` — whose money arrives.
    public var sources: String
  }

  public struct Goal: Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var saved: String
    public var target: String
    public var fraction: Double
    public var achieved: Bool
    public var forecast: String?
  }

  public struct Breaks: Hashable, Sendable {
    /// `Перерыв через 23 мин`, `Перерыв после звонка`.
    public var status: String
    /// `скипнуто 2 из 5`
    public var tally: String
    public var skipped: Int
    public var planned: Int
    public var canStartNow: Bool
  }

  /// The break on screen.
  public struct BreakScreen: Hashable, Sendable {
    /// `09:42`
    public var remaining: String
    /// How much of the break has passed, 0...1.
    public var fraction: Double
    /// `Встань и отойди от компа на 10 мин`
    public var prompt: String
    /// `За перерыв капнет ≈ 816 ₽`, or a reminder that overtime is free.
    public var earnings: String
    /// `Ты скипнул уже 2 перерыва из 5`
    public var skipped: String
    public var canSnooze: Bool
  }

  public var title: String
  /// The title is shown in red (overtime).
  public var isAlert: Bool
  public var phase: DayPhase
  public var today: Today?
  public var nonWorkingLabel: String?
  public var month: Month
  /// The nearest payday, when incomes have payouts set.
  public var payday: Payday?
  public var goals: [Goal]
  /// No goals are set, so the menu offers to add one.
  public var canAddGoal: Bool
  public var warnings: [String]
  public var actions: [Action]
  /// Breaks today, while they run.
  public var breaks: Breaks?
  public var breakScreen: BreakScreen?
}

extension DayTracker {
  public func snapshot(now: Date, engine: Engine) -> DaySnapshot {
    let currency = engine.settings.displayCurrency
    let fx = today.fx
    let money: (Double) -> String = { MoneyFormatter.format(rub: $0, in: currency, fx: fx) ?? MoneyFormatter.format($0, .rub) }
    let status = status(engine: engine)
    let phase = engine.phase(at: now, status: status, overtime: today.overtime)
    let rate = engine.rate(year: today.date.year, month: today.date.month, fx: fx)

    var warnings: [String] = []
    if engine.settings.incomes.isEmpty { warnings.append("Добавьте доход в настройках") }
    for income in rate.excluded {
      warnings.append("«\(income.name)» не учтён: нет курса \(income.currency.rawValue)")
    }
    if engine.isCalendarApproximate(for: today.date) {
      warnings.append("Календарь приблизительный: праздники не учтены")
    }
    if fx == nil, needsFX(engine: engine) {
      warnings.append("Курс ЦБ ещё не загружен: суммы в ₽, доходы в $ и € не учтены")
    } else if let fx, fx.date < today.date, needsFX(engine: engine) {
      warnings.append("Курс ЦБ от \(fx.date.shortDisplay)")
    }

    let overtime = today.overtimeSeconds
    var title: String
    var isAlert = false
    switch phase {
    case .nonWorking: title = "🌴"
    case .paidLeave: title = "🌴 \(money(today.earnedRUB))"
    case .beforeStart: title = "☕ \(engine.settings.schedule.start)"
    case .working: title = "💰 \(money(today.earnedRUB))"
    case .lunch: title = "🍜 \(money(today.earnedRUB))"
    case .afterHours where overtime >= 60:
      title = "🔥 +\(DurationFormatter.hoursMinutes(overtime))"
      isAlert = true
    case .afterHours: title = "⏳ \(money(today.earnedRUB))"
    case .closed: title = "✓ \(money(today.earnedRUB))"
    }

    var todaySection: DaySnapshot.Today?
    var nonWorkingLabel: String?
    switch status {
    case .working(let plan):
      let dayPay = plan.dayPay(rate: rate.perHourRUB)
      let clock: (Date) -> String = {
        let c = engine.calendar.dateComponents([.hour, .minute], from: $0)
        return TimeOfDay(hour: c.hour!, minute: c.minute!).description
      }
      let hours = plan.hourSlots(rate: rate.perHourRUB, at: now).map { slot in
        let length = slot.end.timeIntervalSince(slot.start)
        let lunch = min(slot.end, plan.lunchEnd).timeIntervalSince(max(slot.start, plan.lunchStart))
        return DaySnapshot.Hour(
          label: "\(clock(slot.start))–\(clock(slot.end))",
          startLabel: String(clock(slot.start).prefix(2)),
          amount: money(slot.earnedRUB),
          state: slot.state,
          fraction: length > 0 && plan.isStarted ? min(max(now.timeIntervalSince(slot.start) / length, 0), 1) : 0,
          isLunch: length > 0 && lunch >= length / 2)
      }
      var realRate: String?
      if overtime >= 60, plan.scheduleHours > 0 {
        let real = today.earnedRUB / (plan.scheduleHours + overtime / 3600)
        let base = dayPay / plan.scheduleHours
        let drop = base > 0 ? Int(((1 - real / base) * 100).rounded()) : 0
        realRate = "\(money(real))/ч (−\(drop)%)"
      }
      todaySection = DaySnapshot.Today(
        dateLabel: dateLabel(today.date, engine: engine),
        startTime: plan.isStarted ? clock(plan.start) : nil,
        earned: money(today.earnedRUB),
        dayPay: money(dayPay),
        fraction: dayPay > 0 ? today.earnedRUB / dayPay : 0,
        remaining: plan.isStarted && now < plan.end && now >= plan.start ? DurationFormatter.hoursMinutes(plan.end.timeIntervalSince(now)) : nil,
        hours: hours,
        endLabel: String(clock(plan.end).prefix(2)),
        endTime: clock(plan.end),
        nowFraction: plan.isStarted && now >= plan.start && now < plan.end ? now.timeIntervalSince(plan.start) / plan.duration : nil,
        overtimeHours: overtime / 3600,
        rate: "\(money(rate.perHourRUB))/ч",
        realRate: realRate,
        overtime: overtime >= 60 ? DurationFormatter.human(overtime) : nil)
    case .paidLeave(let plan, let reason):
      let label = reason == .vacation ? "Отпуск" : "Оплачиваемый выходной"
      nonWorkingLabel = "\(label) · \(money(today.earnedRUB)) из \(money(plan.dayPay(rate: rate.perHourRUB)))"
    case .nonWorking(let reason):
      nonWorkingLabel = switch reason {
      case .holiday: "Выходной"
      case .unpaidDayOff: "Выходной за свой счёт"
      }
    }

    let summary = monthSummary(engine: engine)
    let monthTitle = today.date.date(at: TimeOfDay(hour: 12, minute: 0), calendar: engine.calendar)
      .formatted(Date.FormatStyle().month(.wide).locale(Locale(identifier: "ru_RU")))
    let month = DaySnapshot.Month(
      title: monthTitle.prefix(1).uppercased() + monthTitle.dropFirst(),
      earned: money(summary.earnedRUB),
      expected: money(summary.expectedRUB),
      fraction: summary.expectedRUB > 0 ? min(summary.earnedRUB / summary.expectedRUB, 1) : 0,
      overtime: summary.overtimeSeconds >= 60
        ? "Переработано: \(DurationFormatter.human(summary.overtimeSeconds)) ≈ \(money(summary.giftedRUB)) подарено" : nil)

    var goals: [DaySnapshot.Goal] = []
    for g in engine.settings.goals {
      if let p = goalProgress(g, engine: engine, now: now) {
        goals.append(DaySnapshot.Goal(
          id: g.id, name: g.name, saved: money(p.savedRUB), target: money(p.targetRUB), fraction: p.fraction,
          achieved: p.achieved, forecast: p.forecast.map { "~ \(dateLabel($0, engine: engine, weekday: false))" }))
      } else {
        warnings.append("Цель «\(g.name)»: нет курса \(g.currency.rawValue)")
      }
    }

    var actions: [DaySnapshot.Action] = []
    switch phase {
    case .afterHours:
      if today.overtime.mode == .auto { actions.append(.stillWorking) }
      actions += [.finish, .resetStart]
    case .beforeStart:
      if today.startedAt == nil { actions.append(.startDay) }
      actions.append(.dayOff)
    case .working, .lunch:
      actions += [.resetStart, .dayOff]
    case .nonWorking(.unpaidDayOff), .paidLeave(.paidDayOff):
      actions.append(.undoDayOff)
    case .nonWorking, .paidLeave, .closed:
      break
    }

    var payday: DaySnapshot.Payday?
    if let next = engine.nextPayout(onOrAfter: today.date) {
      let days = engine.calendar.dateComponents(
        [.day], from: today.date.startOfDay(calendar: engine.calendar), to: next.date.startOfDay(calendar: engine.calendar)).day ?? 0
      let title = switch days {
      case 0: "Выплата сегодня 🎉"
      case 1: "Выплата завтра"
      default: "Выплата \(dateLabel(next.date, engine: engine, weekday: false)) · через \(days) дн."
      }
      payday = DaySnapshot.Payday(
        title: title, amount: payoutAmount(next, currency: currency, fx: fx),
        sources: next.shares.map { $0.percent == 100 ? $0.income.name : "\($0.income.name) \($0.percent)%" }.joined(separator: " · "))
    }

    var breaks: DaySnapshot.Breaks?
    var breakScreen: DaySnapshot.BreakScreen?
    if let plan = status.plan, engine.settings.breaks.enabled {
      let state = today.breaks
      let settings = engine.settings.breaks
      let planned = engine.plannedBreaks(plan) + state.overtimeBreaks
      if let since = state.activeSince {
        let end = since.addingTimeInterval(settings.length)
        let left = max(0, end.timeIntervalSince(now))
        let earned = plan.earned(rate: rate.perHourRUB, at: end) - plan.earned(rate: rate.perHourRUB, at: since)
        breakScreen = DaySnapshot.BreakScreen(
          remaining: String(format: "%02d:%02d", Int(left.rounded(.up)) / 60, Int(left.rounded(.up)) % 60),
          fraction: 1 - left / settings.length,
          prompt: "Встань и отойди от компа на \(settings.lengthMinutes) мин",
          earnings: earned >= 1 ? "За перерыв капнет ≈ \(money(earned))" : "Ты и так работаешь бесплатно",
          skipped: Self.skippedLine(state.skipped, of: planned),
          canSnooze: state.canSnooze)
      }
      let running = breaksRunning(phase: phase, engine: engine)
      breaks = DaySnapshot.Breaks(
        status: running || state.isActive ? breakStatus(plan: plan, now: now, engine: engine) : pausedStatus(phase: phase, plan: plan, engine: engine),
        tally: "скипнуто \(state.skipped) из \(planned)",
        skipped: state.skipped, planned: planned, canStartNow: running && !state.isActive)
    }

    return DaySnapshot(
      title: title, isAlert: isAlert, phase: phase, today: todaySection, nonWorkingLabel: nonWorkingLabel,
      month: month, payday: payday, goals: goals, canAddGoal: engine.settings.goals.isEmpty, warnings: warnings, actions: actions,
      breaks: breaks, breakScreen: breakScreen)
  }

  private func breakStatus(plan: DayPlan, now: Date, engine: Engine) -> String {
    let state = today.breaks
    if state.isActive { return "Перерыв" }
    if state.waitingForCall { return "Перерыв после звонка" }
    guard let due = breakDue(engine: engine) else { return "" }
    if engine.breakAllowed(at: due, plan: plan) {
      let minutes = Int((due.timeIntervalSince(now) / 60).rounded(.up))
      return minutes > 0 ? "Перерыв через \(minutes) мин" : "Перерыв сейчас"
    }
    let beforeLunch = plan.lunchEnd > plan.lunchStart && due < plan.lunchStart
    return beforeLunch ? "Следующий перерыв после обеда" : "До конца графика перерывов нет"
  }

  /// Why there is no countdown right now, on a worked day.
  private func pausedStatus(phase: DayPhase, plan: DayPlan, engine: Engine) -> String {
    let clock = { (date: Date) -> String in
      let c = engine.calendar.dateComponents([.hour, .minute], from: date)
      return TimeOfDay(hour: c.hour!, minute: c.minute!).description
    }
    return switch phase {
    case .beforeStart: "Перерывы с \(clock(plan.start))"
    case .lunch: "Обед, перерывы с \(clock(plan.lunchEnd))"
    default: "Перерывов больше нет"
    }
  }

  /// `Ты скипнул уже 2 перерыва из 5`, in the right grammatical number.
  static func skippedLine(_ skipped: Int, of planned: Int) -> String {
    guard skipped > 0 else { return "Ты ещё не скипнул ни одного перерыва из \(planned)" }
    let word = switch (skipped % 10, skipped % 100) {
    case (1, let h) where h != 11: "перерыв"
    case (2...4, let h) where !(12...14).contains(h): "перерыва"
    default: "перерывов"
    }
    return "Ты скипнул уже \(skipped) \(word) из \(planned)"
  }

  /// The payout in the display currency, `≈` when converted; without a rate, the parts as they are.
  private func payoutAmount(_ payout: UpcomingPayout, currency: Currency, fx: FXRates?) -> String {
    let rub = payout.shares.map { $0.income.currency == .rub ? $0.amount : fx?.toRUB($0.amount, from: $0.income.currency) }
    let converted = payout.shares.contains { $0.income.currency != currency }
    if rub.allSatisfy({ $0 != nil }), let text = MoneyFormatter.format(rub: rub.reduce(0) { $0 + $1! }, in: currency, fx: fx) {
      return converted ? "≈ \(text)" : text
    }
    var byCurrency: [Currency: Double] = [:]
    for share in payout.shares { byCurrency[share.income.currency, default: 0] += share.amount }
    return Currency.allCases.compactMap { c in byCurrency[c].map { MoneyFormatter.format($0, c) } }.joined(separator: " + ")
  }

  private func needsFX(engine: Engine) -> Bool {
    engine.settings.displayCurrency != .rub
      || engine.settings.incomes.contains { $0.currency != .rub }
      || engine.settings.goals.contains { $0.currency != .rub }
  }

  private func dateLabel(_ date: LocalDate, engine: Engine, weekday: Bool = true) -> String {
    var style = Date.FormatStyle().day().month(.abbreviated).locale(Locale(identifier: "ru_RU"))
    if weekday { style = style.weekday(.abbreviated) }
    style.timeZone = engine.calendar.timeZone
    return date.date(at: TimeOfDay(hour: 12, minute: 0), calendar: engine.calendar).formatted(style)
  }
}
