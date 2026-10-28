import Foundation

extension Engine {
  /// No break is shown this close to lunch or to the scheduled end.
  public static let breakQuietWindow: TimeInterval = 15 * 60

  /// Whether a break due at `moment` may be shown: never in lunch or in the last minutes before
  /// lunch or the end; after the end — always.
  public func breakAllowed(at moment: Date, plan: DayPlan) -> Bool {
    if moment >= plan.end { return true }
    let hasLunch = plan.lunchEnd > plan.lunchStart
    if hasLunch, (plan.lunchStart..<plan.lunchEnd).contains(moment) { return false }
    let boundary = hasLunch && moment < plan.lunchStart ? plan.lunchStart : plan.end
    return boundary.timeIntervalSince(moment) >= Self.breakQuietWindow
  }

  /// Breaks a day brings when worked without pauses: counted from the start and from the end of lunch.
  public func plannedBreaks(_ plan: DayPlan) -> Int {
    let breaks = settings.breaks
    guard breaks.enabled else { return 0 }
    var segments = [(plan.start, plan.end)]
    if plan.lunchEnd > plan.lunchStart { segments = [(plan.start, plan.lunchStart), (plan.lunchEnd, plan.end)] }
    var count = 0
    for (start, end) in segments {
      var due = start.addingTimeInterval(breaks.work)
      while due < end, breakAllowed(at: due, plan: plan) {
        count += 1
        due.addTimeInterval(breaks.work + breaks.length)
      }
    }
    return count
  }
}

extension DayTracker {
  public enum BreakEvent: Hashable, Sendable {
    /// A minute before the break.
    case warn(canSnooze: Bool)
    case started
    /// The countdown ran out: the break was taken.
    case finished
    /// The break on screen went away without being taken (breaks were switched off).
    case cancelled
  }

  public static let breakWarningLead: TimeInterval = 60

  /// Breaks run on a worked day, from the start until the day is closed, outside lunch.
  public func breaksRunning(phase: DayPhase, engine: Engine) -> Bool {
    engine.settings.breaks.enabled && status(engine: engine).plan != nil && (phase == .working || phase == .afterHours)
  }

  /// When the next break is due, before the lunch and end-of-day rules apply.
  public func breakDue(engine: Engine) -> Date? {
    guard let plan = status(engine: engine).plan else { return nil }
    let state = today.breaks
    return state.snoozedUntil ?? max(state.lastRestAt ?? plan.start, plan.start).addingTimeInterval(engine.settings.breaks.work)
  }

  /// Advances today's breaks. `idleSeconds` is nil while the screen is locked or the Mac sleeps;
  /// `inCall` holds breaks back while the microphone or a camera is in use.
  public mutating func tickBreaks(now: Date, idleSeconds: TimeInterval?, inCall: Bool, engine: Engine) -> [BreakEvent] {
    let settings = engine.settings.breaks
    var state = today.breaks
    defer { today.breaks = state }
    let gap = state.lastTick.map { now.timeIntervalSince($0) } ?? 0
    state.lastTick = now

    guard settings.enabled, let plan = status(engine: engine).plan else {
      state.waitingForCall = false
      guard state.isActive else { return [] }
      state.activeSince = nil
      return [.cancelled]
    }
    if let since = state.activeSince {
      let end = since.addingTimeInterval(settings.length)
      guard now >= end else { return [] }
      state.activeSince = nil
      state.taken += 1
      state.restart(at: end)
      return [.finished]
    }

    let phase = engine.phase(at: now, status: .working(plan), overtime: today.overtime)
    guard [.working, .lunch, .afterHours].contains(phase) else {
      state.waitingForCall = false
      return []
    }
    var rest = max(state.lastRestAt ?? plan.start, plan.start)
    if now >= plan.lunchEnd, rest < plan.lunchEnd, plan.lunchEnd > plan.lunchStart {
      rest = plan.lunchEnd
      state.restart(at: rest)
    }
    // Being away at least as long as a break is a break.
    if idleSeconds.map({ $0 >= settings.length }) ?? true || gap >= settings.length {
      rest = max(rest, now)
      state.restart(at: rest)
    }
    state.lastRestAt = rest

    guard phase != .lunch, let due = state.snoozedUntil ?? state.lastRestAt.map({ $0.addingTimeInterval(settings.work) }) else {
      state.waitingForCall = false
      return []
    }
    guard engine.breakAllowed(at: due, plan: plan) else {
      // Too close to lunch or the end: this break silently does not happen.
      if now >= due { state.restart(at: due) }
      state.waitingForCall = false
      return []
    }
    state.waitingForCall = inCall && now >= due
    guard !inCall else { return [] }
    var events: [BreakEvent] = []
    if !state.warned, now < due, now >= due.addingTimeInterval(-Self.breakWarningLead) {
      state.warned = true
      events.append(.warn(canSnooze: state.canSnooze))
    }
    if now >= due {
      state.start(at: now, overtime: phase == .afterHours)
      events.append(.started)
    }
    return events
  }

  // MARK: - User actions

  /// Moves the current break, on screen or coming, by `minutes`; at most twice per break.
  public mutating func snoozeBreak(minutes: Int, now: Date, engine: Engine) {
    guard today.breaks.canSnooze, let due = breakDue(engine: engine) else { return }
    today.breaks.snoozedUntil = max(now, due).addingTimeInterval(TimeInterval(minutes * 60))
    today.breaks.snoozes += 1
    today.breaks.activeSince = nil
    today.breaks.warned = false
    today.breaks.waitingForCall = false
  }

  /// Skips the current break: it counts as skipped, and the countdown starts over.
  public mutating func skipBreak(now: Date) {
    today.breaks.activeSince = nil
    today.breaks.skipped += 1
    today.breaks.restart(at: now)
  }

  /// Starts a break right away.
  public mutating func startBreakNow(now: Date, engine: Engine) {
    guard !today.breaks.isActive, status(engine: engine).plan?.isStarted == true else { return }
    let phase = engine.phase(at: now, status: status(engine: engine), overtime: today.overtime)
    today.breaks.start(at: now, overtime: phase == .afterHours)
  }
}

extension BreakState {
  /// The countdown runs from `moment`; whatever was pending for the old break is dropped.
  mutating func restart(at moment: Date) {
    lastRestAt = moment
    snoozedUntil = nil
    snoozes = 0
    warned = false
    waitingForCall = false
  }

  mutating func start(at moment: Date, overtime: Bool) {
    activeSince = moment
    snoozedUntil = nil
    warned = false
    waitingForCall = false
    if overtime { overtimeBreaks += 1 }
  }
}
