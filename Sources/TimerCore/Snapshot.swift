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
    case pause
    case resume
    /// "Lunch"; `DaySnapshot.Today.lunchButton` names it.
    case lunch
    /// "Back" from lunch.
    case endLunch
    /// "Finish the day" before its end; `DaySnapshot.Today.finishPrompt` asks to confirm.
    case finishEarly
    /// "Back to work" on a closed day, or after "finish" on a day off.
    case resumeWork
    /// "Work on a day off", with the choice of pay (`WeekendPay`).
    case weekendWork
    /// "Pay": change how the weekend session is paid.
    case weekendPay
    case cancelWeekendWork
    /// "Finish" the weekend session.
    case finishWeekend
  }

  /// The day off being worked.
  public struct Weekend: Hashable, Sendable {
    /// `Работа в выходной · ×2 ставки`
    public var title: String
    public var pay: WeekendPay
    /// `отработано 1 ч 30 мин`
    public var worked: String
    /// `5 100 ₽`, or `+1:30` paid as overtime.
    public var amount: String
    /// `3 400 ₽/ч`, the rate with its multiplier; `1 700 ₽/ч · в переработку` as overtime.
    public var rate: String
    /// `на паузе 0:20` while paused.
    public var pause: String?
    /// `Обед · осталось 38 мин` while out for lunch.
    public var lunch: String?
    /// `Обед`, or `Обед (осталось 40 мин)` once part of the hour is taken.
    public var lunchButton: String?
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
    /// The slot is mostly paused.
    public var isPaused: Bool
    /// `пауза 14:00–15:00` for each pause that began in this slot.
    public var pauses: [String]
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
    /// `на паузе 0:42 · конец в 18:42` while the day is on pause.
    public var pause: String?
    /// `Обед · осталось 38 мин` while out for lunch.
    public var lunch: String?
    /// `Обед`, or `Обед (осталось 40 мин)` once part of the hour is taken.
    public var lunchButton: String?
    /// `Недоработано 1 ч 5 мин. Закончить?` — what finishing the day now would leave.
    public var finishPrompt: String?
  }

  public struct Month: Hashable, Sendable {
    public var title: String
    public var earned: String
    public var expected: String
    public var fraction: Double
    public var overtime: String?
    /// `Недоработано: 1 ч`
    public var undertime: String?
    /// `Баланс: +2 ч` — overtime less undertime.
    public var balance: String?
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
    /// `За перерыв капнет ≈ 816 ₽`, or a reminder that overtime is free; nil while amounts are hidden.
    public var earnings: String?
    /// `Ты скипнул уже 2 перерыва из 5`
    public var skipped: String
    public var canSnooze: Bool
    /// The break fell in the lunch hour: "Out for lunch" is offered.
    public var offersLunch: Bool
  }

  public var title: String
  /// The title is shown in red (overtime).
  public var isAlert: Bool
  public var phase: DayPhase
  public var today: Today?
  public var weekend: Weekend?
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
    let status = status(engine: engine, now: now)
    let phase = phase(engine: engine, now: now)
    let rate = engine.rate(year: today.date.year, month: today.date.month, fx: fx)

    var warnings: [String] = []
    if engine.settings.incomes.isEmpty { warnings.append("Добавьте доход в настройках") }
    for income in rate.excluded {
      warnings.append("«\(income.name)» не учтён: нет курса \(income.currency.rawValue)")
    }
    if engine.isCalendarApproximate(for: today.date) {
      warnings.append("Календарь приблизительный: праздники не учтены")
    }
    if engine.lacksOneOffHolidays(for: today.date) {
      warnings.append("Праздники на \(today.date.year) год не внесены: Пасха и другие подвижные — в настройках")
    }
    if fx == nil, needsFX(engine: engine) {
      warnings.append("Курс ЦБ ещё не загружен: суммы в ₽, доходы в $ и € не учтены")
    } else if let fx, fx.date < today.date, needsFX(engine: engine) {
      warnings.append("Курс ЦБ от \(fx.date.shortDisplay)")
    }

    let overtime = today.overtimeSeconds
    let work = weekendWork(engine: engine)
    // A weekend session paid as overtime shows its time; paid in money, the money.
    let weekendValue = work?.pay == .overtime ? "+\(DurationFormatter.hoursMinutes(overtime))" : money(today.earnedRUB)
    var title: String
    var isAlert = false
    switch phase {
    case .nonWorking: title = "🌴"
    case .paidLeave: title = "🌴 \(money(today.earnedRUB))"
    case .beforeStart: title = "☕ \(engine.settings.schedule.start)"
    case .working: title = "💰 \(money(today.earnedRUB))"
    case .lunch: title = "🍜 \(money(today.earnedRUB))"
    case .paused: title = "⏸ \(money(today.earnedRUB))"
    case .afterHours where overtime >= 60:
      title = "🔥 +\(DurationFormatter.hoursMinutes(overtime))"
      isAlert = true
    case .afterHours: title = "⏳ \(money(today.earnedRUB))"
    case .closed: title = "✓ \(money(today.earnedRUB))"
    case .weekend(.working) where work?.pay == .overtime:
      title = "🔥 \(weekendValue)"
      isAlert = true
    case .weekend(.working): title = "💼 \(weekendValue)"
    case .weekend(.lunch): title = "🍜 \(weekendValue)"
    case .weekend(.paused): title = "⏸ \(weekendValue)"
    case .weekend(.finished): title = "✓ \(weekendValue)"
    }
    // Everything after the icon is a value: money, the start time or the overtime.
    if engine.settings.hidesAmounts, let icon = title.split(separator: " ").first, icon != Substring(title) {
      title = "\(icon) •••"
      isAlert = false
    }

    var todaySection: DaySnapshot.Today?
    var weekendSection: DaySnapshot.Weekend?
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
        let lunch = plan.lunches.reduce(0) { $0 + max(0, min(slot.end, $1.end).timeIntervalSince(max(slot.start, $1.start))) }
        let paused = length - plan.activeTime(from: slot.start, to: slot.end)
        let pauses = plan.pauses.filter { (slot.start..<slot.end).contains($0.start) }
          .map { "пауза \(clock($0.start))–\(clock($0.end))" }
        return DaySnapshot.Hour(
          label: "\(clock(slot.start))–\(clock(slot.end))",
          startLabel: String(clock(slot.start).prefix(2)),
          amount: money(slot.earnedRUB),
          state: slot.state,
          fraction: length > 0 && plan.isStarted ? min(max(now.timeIntervalSince(slot.start) / length, 0), 1) : 0,
          isLunch: length > 0 && lunch >= length / 2,
          isPaused: length > 0 && paused >= length / 2,
          pauses: pauses)
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
        remaining: [.working, .lunch].contains(phase) ? DurationFormatter.hoursMinutes(plan.end.timeIntervalSince(now)) : nil,
        hours: hours,
        endLabel: String(clock(plan.end).prefix(2)),
        endTime: clock(plan.end),
        nowFraction: plan.isStarted && now >= plan.start && now < plan.end && phase != .closed
          ? now.timeIntervalSince(plan.start) / plan.end.timeIntervalSince(plan.start) : nil,
        overtimeHours: overtime / 3600,
        rate: "\(money(rate.perHourRUB))/ч",
        realRate: realRate,
        overtime: overtime >= 60 ? DurationFormatter.human(overtime) : nil,
        pause: plan.pausedSince.map { "на паузе \(DurationFormatter.hoursMinutes(now.timeIntervalSince($0))) · конец в \(clock(plan.end))" },
        lunch: plan.lunchSince.map { _ in "Обед · осталось \(lunchMinutesLeft(plan: plan)) мин" },
        lunchButton: canStartLunch(now: now, engine: engine)
          ? (today.closedLunchTime > 0 ? "Обед (осталось \(lunchMinutesLeft(plan: plan)) мин)" : "Обед") : nil,
        // An open pause pushes the end along with now, so the norm left is end − now either way.
        finishPrompt: [.working, .lunch, .paused].contains(phase)
          ? "Недоработано \(DurationFormatter.human(plan.end.timeIntervalSince(now))). Закончить?" : nil)
    case .paidLeave(let plan, let reason):
      let label = reason == .vacation ? "Отпуск" : "Оплачиваемый выходной"
      nonWorkingLabel = "\(label) · \(money(today.earnedRUB)) из \(money(plan.dayPay(rate: rate.perHourRUB)))"
    case .nonWorking where work != nil:
      let work = work!
      let rateLine = work.pay == .overtime
        ? "\(money(rate.perHourRUB))/ч · в переработку" : "\(money(rate.perHourRUB * work.pay.multiplier))/ч"
      var pause: String?
      if case .paused(let since) = work.state { pause = "на паузе \(DurationFormatter.hoursMinutes(now.timeIntervalSince(since)))" }
      let lunchLeft = weekendLunchMinutesLeft(now: now, engine: engine)
      weekendSection = DaySnapshot.Weekend(
        title: "Работа в выходной · \(work.pay.title)",
        pay: work.pay,
        worked: "отработано \(DurationFormatter.human(work.worked(at: now)))",
        amount: weekendValue,
        rate: rateLine,
        pause: pause,
        lunch: phase == .weekend(.lunch) ? "Обед · осталось \(lunchLeft) мин" : nil,
        lunchButton: canStartLunch(now: now, engine: engine)
          ? (today.closedLunchTime > 0 ? "Обед (осталось \(lunchLeft) мин)" : "Обед") : nil)
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
        ? "Переработано: \(DurationFormatter.human(summary.overtimeSeconds)) ≈ \(money(summary.giftedRUB)) подарено" : nil,
      undertime: summary.undertimeSeconds >= 60 ? "Недоработано: \(DurationFormatter.human(summary.undertimeSeconds))" : nil,
      balance: Self.balanceLine(summary.overtimeSeconds - summary.undertimeSeconds))

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
    case .working:
      if canStartLunch(now: now, engine: engine) { actions.append(.lunch) }
      actions += [.pause, .finishEarly, .resetStart, .dayOff]
    case .lunch:
      actions += [.endLunch, .finishEarly, .resetStart, .dayOff]
    case .paused:
      actions += [.resume, .finishEarly, .resetStart, .dayOff]
    case .closed:
      actions.append(.resumeWork)
    case .nonWorking(.unpaidDayOff), .paidLeave(.paidDayOff):
      actions.append(.undoDayOff)
    case .nonWorking(.holiday):
      if canStartWeekendWork(engine: engine) { actions.append(.weekendWork) }
    case .weekend(.working):
      if canStartLunch(now: now, engine: engine) { actions.append(.lunch) }
      actions += [.pause, .finishWeekend, .weekendPay, .cancelWeekendWork]
    case .weekend(.lunch):
      actions += [.endLunch, .finishWeekend, .weekendPay, .cancelWeekendWork]
    case .weekend(.paused):
      actions += [.resume, .finishWeekend, .weekendPay, .cancelWeekendWork]
    case .weekend(.finished):
      actions += [.resumeWork, .weekendPay, .cancelWeekendWork]
    case .nonWorking, .paidLeave:
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
    if let plan = breakPlan(now: now, engine: engine), engine.settings.breaks.enabled {
      let state = today.breaks
      let settings = engine.settings.breaks
      // A weekend session has no schedule to plan breaks by: it counts the ones that came.
      let planned = work != nil ? state.taken + state.skipped + (state.isActive ? 1 : 0)
        : engine.plannedBreaks(plan) + state.overtimeBreaks
      if let since = state.activeSince {
        let end = since.addingTimeInterval(settings.length)
        let left = max(0, end.timeIntervalSince(now))
        let earned = work.map { settings.length / 3600 * rate.perHourRUB * $0.pay.multiplier }
          ?? plan.earned(rate: rate.perHourRUB, at: end) - plan.earned(rate: rate.perHourRUB, at: since)
        breakScreen = DaySnapshot.BreakScreen(
          remaining: String(format: "%02d:%02d", Int(left.rounded(.up)) / 60, Int(left.rounded(.up)) % 60),
          fraction: 1 - left / settings.length,
          prompt: "Встань и отойди от компа на \(settings.lengthMinutes) мин",
          earnings: engine.settings.hidesAmounts ? nil
            : earned >= 1 ? "За перерыв капнет ≈ \(money(earned))" : "Ты и так работаешь бесплатно",
          skipped: Self.skippedLine(state.skipped, of: planned),
          canSnooze: state.canSnooze,
          offersLunch: breakOffersLunch(now: now, engine: engine))
      }
      let running = breaksRunning(phase: phase, engine: engine)
      breaks = DaySnapshot.Breaks(
        status: running || state.isActive ? breakStatus(plan: plan, now: now, engine: engine) : pausedStatus(phase: phase, plan: plan, engine: engine),
        tally: "скипнуто \(state.skipped) из \(planned)",
        skipped: state.skipped, planned: planned, canStartNow: running && !state.isActive)
    }

    return DaySnapshot(
      title: title, isAlert: isAlert, phase: phase, today: todaySection, weekend: weekendSection, nonWorkingLabel: nonWorkingLabel,
      month: month, payday: payday, goals: goals, canAddGoal: engine.settings.goals.isEmpty, warnings: warnings, actions: actions,
      breaks: breaks, breakScreen: breakScreen)
  }

  private func breakStatus(plan: DayPlan, now: Date, engine: Engine) -> String {
    let state = today.breaks
    if state.isActive { return "Перерыв" }
    if state.waitingForCall { return "Перерыв после звонка" }
    guard let due = breakDue(now: now, engine: engine) else { return "" }
    if engine.breakAllowed(at: due, plan: plan) {
      let minutes = Int((due.timeIntervalSince(now) / 60).rounded(.up))
      return minutes > 0 ? "Перерыв через \(minutes) мин" : "Перерыв сейчас"
    }
    return "До конца графика перерывов нет"
  }

  /// Why there is no countdown right now, on a worked day.
  private func pausedStatus(phase: DayPhase, plan: DayPlan, engine: Engine) -> String {
    let clock = { (date: Date) -> String in
      let c = engine.calendar.dateComponents([.hour, .minute], from: date)
      return TimeOfDay(hour: c.hour!, minute: c.minute!).description
    }
    return switch phase {
    case .beforeStart: "Перерывы с \(clock(plan.start))"
    case .lunch: "Обед, перерывы после него"
    case .paused, .weekend(.paused): "Пауза, перерывы после неё"
    case .weekend(.lunch): "Обед, перерывы после него"
    default: "Перерывов больше нет"
    }
  }

  private func weekendLunchMinutesLeft(now: Date, engine: Engine) -> Int {
    let taken = today.resolvedLunches(at: now, dayEnd: midnight(engine: engine)).reduce(0) { $0 + $1.duration }
    return max(0, Int(((Lunch.dailyLimit - taken) / 60).rounded(.up)))
  }

  /// Minutes of the day's lunch hour still free, an open lunch counted up to now.
  private func lunchMinutesLeft(plan: DayPlan) -> Int {
    let taken = plan.lunches.reduce(0) { $0 + $1.duration }
    return max(0, Int(((Lunch.dailyLimit - taken) / 60).rounded(.up)))
  }

  /// `Баланс: +2 ч` or `Баланс: −1 ч 30 мин`; nil when it is under a minute.
  static func balanceLine(_ seconds: TimeInterval) -> String? {
    guard abs(seconds) >= 60 else { return nil }
    return "Баланс: \(seconds > 0 ? "+" : "−")\(DurationFormatter.human(abs(seconds)))"
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
