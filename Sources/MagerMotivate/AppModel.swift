import AppKit
import Foundation
import MotivateCore
import Observation

@Observable
final class AppModel {
  private(set) var snapshot: DaySnapshot
  private(set) var settings: Settings
  private(set) var notificationsAuthorized = true
  let dataDirectory: URL

  @ObservationIgnored private var tracker: DayTracker
  @ObservationIgnored private var workCalendar: WorkCalendar
  @ObservationIgnored private var latestFX: FXRates?
  @ObservationIgnored private let storage: Storage
  @ObservationIgnored private let calendar = Calendar.autoupdatingCurrent
  /// Shift applied to the wall clock by `--fake-now`, for trying out the day.
  @ObservationIgnored private let clockOffset: TimeInterval
  @ObservationIgnored private let activity = ActivityMonitor()
  @ObservationIgnored private let notifier = Notifier()
  @ObservationIgnored private var lastSavedPhase: DayPhase?
  @ObservationIgnored private var lastSave = Date.distantPast
  @ObservationIgnored private var lastFetch = Date.distantPast
  @ObservationIgnored private var loop: Task<Void, Never>?
  @ObservationIgnored private var needsRestore: Bool
  /// Real time of the last goal edit; achievements wait until editing settles.
  @ObservationIgnored private var lastGoalEdit = Date.distantPast
  @ObservationIgnored private var wasInCall = false
  @ObservationIgnored private lazy var overlay = BreakOverlayController(model: self)

  init(arguments: [String] = CommandLine.arguments) {
    func value(_ flag: String) -> String? {
      arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }
    var offset: TimeInterval = 0
    if let fake = value("--fake-now") {
      let parser = DateFormatter()
      parser.dateFormat = "yyyy-MM-dd'T'HH:mm"
      if let date = parser.date(from: fake) { offset = date.timeIntervalSinceNow }
    }
    clockOffset = offset
    dataDirectory = value("--data-dir").map { URL(filePath: $0, directoryHint: .isDirectory) } ?? Storage.defaultRoot
    storage = Storage(root: dataDirectory)

    let now = Date().addingTimeInterval(offset)
    let year = calendar.component(.year, from: now)
    let loaded = (try? storage.loadSettings()) ?? nil
    let settings = loaded ?? Settings()
    self.settings = settings
    workCalendar = storage.loadCalendar(years: [year - 1, year, year + 1])
    latestFX = storage.loadLatestFX()
    let engine = Engine(settings: settings, workCalendar: workCalendar, calendar: calendar)
    let records = (try? storage.loadAllRecords()) ?? []
    let todayDate = LocalDate(now, calendar: calendar)
    // Filling in past days needs the rate and the calendar; without them, wait for the first fetch.
    needsRestore = latestFX == nil || !workCalendar.hasData(for: todayDate.year)
    var changed: [DayRecord] = []
    if needsRestore {
      tracker = DayTracker(
        today: records.first { $0.date == todayDate } ?? DayRecord(date: todayDate),
        history: records.filter { $0.date < todayDate })
    } else {
      (tracker, changed) = DayTracker.restore(records: records, now: now, latestFX: latestFX, engine: engine)
    }
    snapshot = tracker.snapshot(now: now, engine: engine)

    if loaded == nil { persist(settings) }
    save(changed)
    LoginItem.apply(settings.launchAtLogin)
    start()
  }

  var now: Date { Date().addingTimeInterval(clockOffset) }

  private var engine: Engine { Engine(settings: settings, workCalendar: workCalendar, calendar: calendar) }

  private func start() {
    activity.onWake = { [weak self] in self?.tick() }
    notifier.onAction = { [weak self] action in
      switch action {
      case Notifier.finishAction: self?.finish()
      case Notifier.stillWorkingAction: self?.stillWorking()
      case Notifier.snoozeBreakAction: self?.snoozeBreak(minutes: 5)
      default: break
      }
    }
    loop = Task { [weak self] in
      // Without a cached rate the first events would be formatted in roubles, so fetch first.
      if let self, self.needsRestore {
        let ok = await self.refreshRemoteData()
        self.lastFetch = ok ? self.now : self.now.addingTimeInterval(-6 * 3600 + 300)
        self.restore()
      }
      await self?.notifier.setUp()
      self?.notificationsAuthorized = self?.notifier.isAuthorized ?? false || !isBundled
      while !Task.isCancelled {
        self?.tick()
        if let self, self.now.timeIntervalSince(self.lastFetch) > 6 * 3600 {
          // On failure retry in five minutes instead of six hours.
          let ok = await self.refreshRemoteData()
          self.lastFetch = ok ? self.now : self.now.addingTimeInterval(-6 * 3600 + 300)
        }
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  // MARK: - Ticking

  func tick() {
    let now = now
    let engine = engine
    save(tracker.rollOver(now: now, latestFX: latestFX, engine: engine))
    let phase = engine.phase(at: now, status: tracker.status(engine: engine), overtime: tracker.today.overtime)
    let breaksRunning = tracker.breaksRunning(phase: phase, engine: engine)
    let awaitsStart = tracker.awaitsStart(now: now, engine: engine)
    // Activity matters for starting a forgotten day, for overtime once the day is over,
    // and for breaks while they run.
    let idle: TimeInterval? = phase == .afterHours || breaksRunning || awaitsStart ? activity.idleSeconds() : 0
    let events = tracker.tick(
      now: now, idleSeconds: phase == .afterHours || awaitsStart ? idle : 0, latestFX: latestFX, engine: engine,
      checkGoals: Date().timeIntervalSince(lastGoalEdit) > 30)
    for event in events { deliver(event) }
    let inCall = breaksRunning && CallDetector.isInCall()
    if inCall != wasInCall {
      log.info("Call \(inCall ? "started" : "ended", privacy: .public)")
      wasInCall = inCall
    }
    let breakEvents = tracker.tickBreaks(now: now, idleSeconds: idle, inCall: inCall, engine: engine)
    for event in breakEvents { deliver(event) }
    snapshot = tracker.snapshot(now: now, engine: engine)
    overlay.update(snapshot.breakScreen)
    if !breakEvents.isEmpty { saveToday(now: now) }
    if !events.isEmpty || snapshot.phase != lastSavedPhase || now.timeIntervalSince(lastSave) >= 60 {
      saveToday(now: now)
    }
  }

  private func deliver(_ event: DayTracker.Event) {
    let money = { (rub: Double) in
      MoneyFormatter.format(rub: rub, in: self.settings.displayCurrency, fx: self.fx) ?? MoneyFormatter.format(rub, .rub)
    }
    switch event {
    case .dayStarted(let expected):
      notifier.post(title: "Рабочий день начался", body: "Сегодня \(money(expected))")
    case .dayEnded(let total):
      notifier.post(title: "Рабочий день окончен · \(money(total))", body: "Дальше бесплатно", category: Notifier.endOfDayCategory)
    case .overtime(let hours):
      notifier.post(title: "🔥 Переработка \(hours) ч", body: "Ты работаешь бесплатно уже \(hours) ч. Пора закругляться")
    case .goalAchieved(let id, let name):
      notifier.post(title: "🎉 Цель «\(name)» достигнута", body: "Пора тратить")
      var updated = settings
      if let i = updated.goals.firstIndex(where: { $0.id == id }) { updated.goals[i].achievedOn = tracker.today.date }
      apply(updated)
    }
  }

  private func deliver(_ event: DayTracker.BreakEvent) {
    switch event {
    case .warn(let canSnooze):
      notifier.post(
        title: "☕ Перерыв через минуту", body: "Сохранись и приготовься встать",
        category: canSnooze ? Notifier.breakSoonCategory : nil)
    case .finished:
      NSSound(named: "Glass")?.play()
    case .started, .cancelled:
      break
    }
  }

  // MARK: - Actions

  func snoozeBreak(minutes: Int) {
    tracker.snoozeBreak(minutes: minutes, now: now, engine: engine)
    tick()
    saveToday(now: now)
  }

  func skipBreak() {
    tracker.skipBreak(now: now)
    tick()
    saveToday(now: now)
  }

  func startBreakNow() {
    tracker.startBreakNow(now: now, engine: engine)
    tick()
    saveToday(now: now)
  }

  /// Breaks a regular day brings under `settings`, for the settings form.
  func plannedBreaks(with settings: MotivateCore.Settings) -> Int {
    let engine = Engine(settings: settings, workCalendar: workCalendar, calendar: calendar)
    return engine.plannedBreaks(engine.plan(for: today, isShort: false))
  }

  func startDay() {
    tracker.startDay(now: now, engine: engine)
    tick()
    saveToday(now: now)
  }

  func resetStart() {
    tracker.resetStart(engine: engine)
    tick()
    saveToday(now: now)
  }

  func stillWorking() {
    tracker.stillWorking(now: now, engine: engine)
    tick()
    saveToday(now: now)
  }

  func finish() {
    tracker.finish(now: now, engine: engine)
    tick()
    saveToday(now: now)
  }

  func setDayOff(_ dayOff: DayOff?) {
    tracker.setDayOff(dayOff)
    tick()
    saveToday(now: now)
  }

  private func restore() {
    needsRestore = false
    let (rebuilt, changed) = DayTracker.restore(records: tracker.allRecords, now: now, latestFX: latestFX, engine: engine)
    tracker = rebuilt
    save(changed)
    tick()
  }

  /// Validates and stores new settings; returns the error to show if they are invalid.
  @discardableResult
  func apply(_ edited: Settings) -> SettingsError? {
    let new = edited.resettingAchievements(comparedTo: settings)
    do throws(SettingsError) {
      try new.validate()
    } catch {
      return error
    }
    let launchChanged = new.launchAtLogin != settings.launchAtLogin
    if new.goals.map({ ($0.id, $0.amount, $0.currency, $0.percent, $0.initialSaved) }).elementsEqual(
      settings.goals.map({ ($0.id, $0.amount, $0.currency, $0.percent, $0.initialSaved) }), by: ==) == false {
      lastGoalEdit = Date()
    }
    settings = new
    persist(new)
    if launchChanged { LoginItem.apply(new.launchAtLogin) }
    tick()
    return nil
  }

  var today: LocalDate { tracker.today.date }

  /// Today's fixed rate, or the latest known one.
  var fx: FXRates? { tracker.today.fx ?? latestFX }

  // MARK: - Persistence

  private func persist(_ settings: Settings) {
    do { try storage.save(settings) } catch { log.error("Saving settings failed: \(error.localizedDescription, privacy: .public)") }
  }

  private func save(_ records: [DayRecord]) {
    guard !records.isEmpty else { return }
    do { try storage.save(records) } catch { log.error("Saving history failed: \(error.localizedDescription, privacy: .public)") }
  }

  private func saveToday(now: Date) {
    save([tracker.today])
    lastSave = now
    lastSavedPhase = snapshot.phase
  }

  private func refreshRemoteData() async -> Bool {
    var ok = true
    let year = calendar.component(.year, from: now)
    var years = [year]
    if calendar.component(.month, from: now) == 12 { years.append(year + 1) }
    for y in years where !workCalendar.hasData(for: y) {
      do {
        let raw = try await RemoteData.calendar(year: y, calendar: calendar)
        workCalendar.set(year: y, raw: raw)
        try storage.saveCalendar(year: y, raw: raw)
      } catch {
        ok = false
        log.error("Calendar \(y) fetch failed: \(error.localizedDescription, privacy: .public)")
      }
    }
    do {
      let fx = try await RemoteData.exchangeRates()
      latestFX = fx
      try storage.saveLatestFX(fx)
    } catch {
      ok = false
      log.error("FX fetch failed: \(error.localizedDescription, privacy: .public)")
    }
    tick()
    return ok
  }
}
