import Foundation

/// A calendar day in the user's local time zone, stored as `yyyy-MM-dd`.
public struct LocalDate: Hashable, Comparable, Sendable, CustomStringConvertible {
  public var year: Int
  public var month: Int
  public var day: Int

  public init(year: Int, month: Int, day: Int) {
    self.year = year
    self.month = month
    self.day = day
  }

  public init(_ date: Date, calendar: Calendar) {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    self.init(year: c.year!, month: c.month!, day: c.day!)
  }

  public init?(string: String) {
    let parts = string.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    self.init(year: parts[0], month: parts[1], day: parts[2])
  }

  public var description: String {
    String(format: "%04d-%02d-%02d", year, month, day)
  }

  /// `dd.MM` for compact display.
  public var shortDisplay: String { String(format: "%02d.%02d", day, month) }

  public static func < (a: LocalDate, b: LocalDate) -> Bool {
    (a.year, a.month, a.day) < (b.year, b.month, b.day)
  }

  public func date(at time: TimeOfDay, calendar: Calendar) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: time.hour, minute: time.minute))!
  }

  public func startOfDay(calendar: Calendar) -> Date { date(at: TimeOfDay(hour: 0, minute: 0), calendar: calendar) }

  public func adding(days: Int, calendar: Calendar) -> LocalDate {
    LocalDate(calendar.date(byAdding: .day, value: days, to: date(at: TimeOfDay(hour: 12, minute: 0), calendar: calendar))!, calendar: calendar)
  }

  public func isSameMonth(as other: LocalDate) -> Bool { year == other.year && month == other.month }
}

extension LocalDate: Codable {
  public init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    guard let value = LocalDate(string: raw) else {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(raw)"))
    }
    self = value
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer()
    try c.encode(description)
  }
}

/// Wall-clock time within a day, stored as `HH:mm`.
public struct TimeOfDay: Hashable, Comparable, Sendable, CustomStringConvertible {
  public var hour: Int
  public var minute: Int

  public init(hour: Int, minute: Int) {
    self.hour = hour
    self.minute = minute
  }

  public var minutes: Int { hour * 60 + minute }

  public init(minutes: Int) { self.init(hour: minutes / 60, minute: minutes % 60) }

  public var description: String { String(format: "%02d:%02d", hour, minute) }

  public static func < (a: TimeOfDay, b: TimeOfDay) -> Bool { a.minutes < b.minutes }
}

extension TimeOfDay: Codable {
  public init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    let parts = raw.split(separator: ":").compactMap { Int($0) }
    guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad time \(raw)"))
    }
    self.init(hour: parts[0], minute: parts[1])
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer()
    try c.encode(description)
  }
}

public enum SettingsError: Error, Equatable, Sendable {
  case endNotAfterStart
  case lunchOutsideDay
  case nonPositiveAmount
  case percentOutOfRange
  case emptyName
  case paydayOutOfRange
  /// Payout shares of one income do not add up to 100%.
  case payoutsNotWhole(income: String, percent: Int)
  case negativeSaved
  /// Active goals take more than all of the earnings.
  case goalsOverAllocated(percent: Int)
  case breakWorkOutOfRange
  case breakLengthOutOfRange

  public var message: String {
    switch self {
    case .endNotAfterStart: "Конец рабочего дня должен быть позже начала"
    case .lunchOutsideDay: "Обед должен целиком попадать в рабочий день"
    case .nonPositiveAmount: "Сумма должна быть больше нуля"
    case .percentOutOfRange: "Процент должен быть от 1 до 100"
    case .emptyName: "Название не может быть пустым"
    case .paydayOutOfRange: "День выплаты должен быть от 1 до 31"
    case .payoutsNotWhole(let income, let percent): "Выплаты по «\(income)» в сумме \(percent)%, а нужно 100%"
    case .negativeSaved: "Уже накоплено не может быть меньше нуля"
    case .goalsOverAllocated(let percent): "На цели уходит \(percent)% заработка, больше 100% нельзя"
    case .breakWorkOutOfRange:
      "Работать подряд можно от \(BreakSettings.workRange.lowerBound) до \(BreakSettings.workRange.upperBound) мин"
    case .breakLengthOutOfRange:
      "Перерыв может длиться от \(BreakSettings.lengthRange.lowerBound) до \(BreakSettings.lengthRange.upperBound) мин"
    }
  }
}

/// Fixed daily schedule; the one-hour lunch sits inside the working day.
public struct Schedule: Codable, Hashable, Sendable {
  public static let lunchMinutes = 60

  public var start: TimeOfDay
  public var end: TimeOfDay
  public var lunchStart: TimeOfDay

  public init(
    start: TimeOfDay = TimeOfDay(hour: 9, minute: 0),
    end: TimeOfDay = TimeOfDay(hour: 17, minute: 0),
    lunchStart: TimeOfDay = TimeOfDay(hour: 13, minute: 0)
  ) {
    self.start = start
    self.end = end
    self.lunchStart = lunchStart
  }

  public var lunchEnd: TimeOfDay { TimeOfDay(minutes: lunchStart.minutes + Self.lunchMinutes) }

  public func validate() throws(SettingsError) {
    guard end > start else { throw .endNotAfterStart }
    guard lunchStart >= start, lunchEnd <= end else { throw .lunchOutsideDay }
  }
}

public enum Currency: String, Codable, CaseIterable, Sendable, Identifiable {
  case rub = "RUB"
  case usd = "USD"
  case eur = "EUR"

  public var id: String { rawValue }

  public var symbol: String {
    switch self {
    case .rub: "₽"
    case .usd: "$"
    case .eur: "€"
    }
  }
}

/// One payment of an income in a month: on `day`, `percent` of the monthly amount.
public struct Payout: Codable, Hashable, Sendable, Identifiable {
  public var id: UUID
  /// Day of the month, 1...31; clamped to the month's length.
  public var day: Int
  public var percent: Int

  public init(id: UUID = UUID(), day: Int, percent: Int) {
    self.id = id
    self.day = day
    self.percent = percent
  }
}

public struct Income: Codable, Hashable, Sendable, Identifiable {
  public var id: UUID
  public var name: String
  /// Monthly take-home amount.
  public var amount: Double
  public var currency: Currency
  /// When the money arrives, e.g. an advance of 40% on the 25th and the rest on the 10th.
  public var payouts: [Payout]

  public init(id: UUID = UUID(), name: String, amount: Double, currency: Currency, payouts: [Payout] = []) {
    self.id = id
    self.name = name
    self.amount = amount
    self.currency = currency
    self.payouts = payouts
  }

  public func validate() throws(SettingsError) {
    guard amount > 0 else { throw .nonPositiveAmount }
    guard payouts.allSatisfy({ (1...31).contains($0.day) }) else { throw .paydayOutOfRange }
    guard payouts.allSatisfy({ (1...100).contains($0.percent) }) else { throw .percentOutOfRange }
    let total = payouts.reduce(0) { $0 + $1.percent }
    guard payouts.isEmpty || total == 100 else { throw .payoutsNotWhole(income: name, percent: total) }
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    name = try c.decode(String.self, forKey: .name)
    amount = try c.decode(Double.self, forKey: .amount)
    currency = try c.decode(Currency.self, forKey: .currency)
    payouts = try c.decodeIfPresent([Payout].self, forKey: .payouts) ?? []
  }
}

/// Inclusive range of vacation days.
public struct VacationRange: Codable, Hashable, Sendable, Identifiable {
  public var id: UUID
  public var from: LocalDate
  public var to: LocalDate

  public init(id: UUID = UUID(), from: LocalDate, to: LocalDate) {
    self.id = id
    self.from = min(from, to)
    self.to = max(from, to)
  }

  public func contains(_ date: LocalDate) -> Bool { from <= date && date <= to }
}

public struct Goal: Codable, Hashable, Sendable, Identifiable {
  public var id: UUID
  public var name: String
  public var amount: Double
  public var currency: Currency
  /// Share of earnings put towards the goal, 1...100.
  public var percent: Int
  /// Already put aside before the goal was set, in the goal's currency.
  public var initialSaved: Double
  public var createdOn: LocalDate
  public var achievedOn: LocalDate?

  public init(
    id: UUID = UUID(), name: String, amount: Double, currency: Currency, percent: Int = 100,
    initialSaved: Double = 0, createdOn: LocalDate, achievedOn: LocalDate? = nil
  ) {
    self.id = id
    self.name = name
    self.amount = amount
    self.currency = currency
    self.percent = percent
    self.initialSaved = initialSaved
    self.createdOn = createdOn
    self.achievedOn = achievedOn
  }

  public func validate() throws(SettingsError) {
    guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw .emptyName }
    guard amount > 0 else { throw .nonPositiveAmount }
    guard (1...100).contains(percent) else { throw .percentOutOfRange }
    guard initialSaved >= 0 else { throw .negativeSaved }
  }

  /// Whether `other` counts progress the same way; the name and dates do not matter.
  public func hasSameTerms(as other: Goal) -> Bool {
    amount == other.amount && currency == other.currency && percent == other.percent && initialSaved == other.initialSaved
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    name = try c.decode(String.self, forKey: .name)
    amount = try c.decode(Double.self, forKey: .amount)
    currency = try c.decode(Currency.self, forKey: .currency)
    percent = try c.decodeIfPresent(Int.self, forKey: .percent) ?? 100
    initialSaved = try c.decodeIfPresent(Double.self, forKey: .initialSaved) ?? 0
    createdOn = try c.decode(LocalDate.self, forKey: .createdOn)
    achievedOn = try c.decodeIfPresent(LocalDate.self, forKey: .achievedOn)
  }
}

public struct Settings: Codable, Hashable, Sendable {
  public var incomes: [Income]
  public var displayCurrency: Currency
  public var schedule: Schedule
  public var vacations: [VacationRange]
  public var goals: [Goal]
  public var launchAtLogin: Bool
  public var breaks: BreakSettings

  public init(
    incomes: [Income] = [],
    displayCurrency: Currency = .rub,
    schedule: Schedule = Schedule(),
    vacations: [VacationRange] = [],
    goals: [Goal] = [],
    launchAtLogin: Bool = true,
    breaks: BreakSettings = BreakSettings()
  ) {
    self.incomes = incomes
    self.displayCurrency = displayCurrency
    self.schedule = schedule
    self.vacations = vacations
    self.goals = goals
    self.launchAtLogin = launchAtLogin
    self.breaks = breaks
  }

  public func validate() throws(SettingsError) {
    try schedule.validate()
    try breaks.validate()
    for income in incomes { try income.validate() }
    for goal in goals { try goal.validate() }
    let allocated = goals.filter { $0.achievedOn == nil }.reduce(0) { $0 + $1.percent }
    guard allocated <= 100 else { throw .goalsOverAllocated(percent: allocated) }
  }

  /// A goal whose terms were edited is no longer known to be achieved: it is checked afresh.
  public func resettingAchievements(comparedTo old: Settings) -> Settings {
    var result = self
    for i in result.goals.indices where result.goals[i].achievedOn != nil {
      if let previous = old.goals.first(where: { $0.id == result.goals[i].id }), !previous.hasSameTerms(as: result.goals[i]) {
        result.goals[i].achievedOn = nil
      }
    }
    return result
  }

  /// Keys of earlier file versions: a single `goal`, and `paydays` shared by all incomes.
  private enum LegacyKeys: String, CodingKey {
    case goal, paydays
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let legacy = try decoder.container(keyedBy: LegacyKeys.self)
    let d = Settings()
    incomes = try c.decodeIfPresent([Income].self, forKey: .incomes) ?? d.incomes
    displayCurrency = try c.decodeIfPresent(Currency.self, forKey: .displayCurrency) ?? d.displayCurrency
    schedule = try c.decodeIfPresent(Schedule.self, forKey: .schedule) ?? d.schedule
    vacations = try c.decodeIfPresent([VacationRange].self, forKey: .vacations) ?? d.vacations
    goals = try c.decodeIfPresent([Goal].self, forKey: .goals)
      ?? (try legacy.decodeIfPresent(Goal.self, forKey: .goal)).map { [$0] } ?? []
    launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
    breaks = try c.decodeIfPresent(BreakSettings.self, forKey: .breaks) ?? d.breaks
    // Shared paydays become equal shares of every income that has none of its own.
    let days = (try legacy.decodeIfPresent([Int].self, forKey: .paydays) ?? []).filter { (1...31).contains($0) }
    if !days.isEmpty {
      for i in incomes.indices where incomes[i].payouts.isEmpty {
        incomes[i].payouts = days.enumerated().map { n, day in
          Payout(day: day, percent: n == days.count - 1 ? 100 - 100 / days.count * (days.count - 1) : 100 / days.count)
        }
      }
    }
  }
}

/// Breaks from the screen: after `workMinutes` of work in a row, a break of `lengthMinutes`.
public struct BreakSettings: Codable, Hashable, Sendable {
  public static let workRange = 20...120
  public static let lengthRange = 1...30

  public var enabled: Bool
  public var workMinutes: Int
  public var lengthMinutes: Int

  public init(enabled: Bool = true, workMinutes: Int = 50, lengthMinutes: Int = 10) {
    self.enabled = enabled
    self.workMinutes = workMinutes
    self.lengthMinutes = lengthMinutes
  }

  public var work: TimeInterval { TimeInterval(workMinutes * 60) }
  public var length: TimeInterval { TimeInterval(lengthMinutes * 60) }

  public func validate() throws(SettingsError) {
    guard Self.workRange.contains(workMinutes) else { throw .breakWorkOutOfRange }
    guard Self.lengthRange.contains(lengthMinutes) else { throw .breakLengthOutOfRange }
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = BreakSettings()
    enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
    workMinutes = try c.decodeIfPresent(Int.self, forKey: .workMinutes) ?? d.workMinutes
    lengthMinutes = try c.decodeIfPresent(Int.self, forKey: .lengthMinutes) ?? d.lengthMinutes
  }
}

/// Today's breaks: what the countdown runs from, the break on screen, and the day's tally.
public struct BreakState: Codable, Hashable, Sendable {
  public static let snoozeLimit = 2

  /// The countdown to the next break runs from here.
  public var lastRestAt: Date?
  /// The current break was moved to this moment.
  public var snoozedUntil: Date?
  /// Times the current break was moved.
  public var snoozes: Int
  /// The break on screen started here.
  public var activeSince: Date?
  /// The break is due but waits for a call to end.
  public var waitingForCall: Bool
  /// The one-minute warning for the current break went out.
  public var warned: Bool
  public var taken: Int
  public var skipped: Int
  /// Breaks that came up after the scheduled end; they add to the day's plan.
  public var overtimeBreaks: Int
  /// The previous tick; a longer gap (sleep, app not running) counts as rest.
  public var lastTick: Date?

  public init() {
    snoozes = 0
    waitingForCall = false
    warned = false
    taken = 0
    skipped = 0
    overtimeBreaks = 0
  }

  public var isActive: Bool { activeSince != nil }
  public var canSnooze: Bool { snoozes < Self.snoozeLimit }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init()
    lastRestAt = try c.decodeIfPresent(Date.self, forKey: .lastRestAt)
    snoozedUntil = try c.decodeIfPresent(Date.self, forKey: .snoozedUntil)
    snoozes = try c.decodeIfPresent(Int.self, forKey: .snoozes) ?? 0
    activeSince = try c.decodeIfPresent(Date.self, forKey: .activeSince)
    waitingForCall = try c.decodeIfPresent(Bool.self, forKey: .waitingForCall) ?? false
    warned = try c.decodeIfPresent(Bool.self, forKey: .warned) ?? false
    taken = try c.decodeIfPresent(Int.self, forKey: .taken) ?? 0
    skipped = try c.decodeIfPresent(Int.self, forKey: .skipped) ?? 0
    overtimeBreaks = try c.decodeIfPresent(Int.self, forKey: .overtimeBreaks) ?? 0
    lastTick = try c.decodeIfPresent(Date.self, forKey: .lastTick)
  }
}

/// Overtime after the scheduled end of a working day.
public struct OvertimeState: Codable, Hashable, Sendable {
  public enum Mode: String, Codable, Sendable {
    /// Counted from user activity; 15 idle minutes close the day.
    case auto
    /// "Still working": counted continuously until the user finishes.
    case manual
  }

  public static let idleLimit: TimeInterval = 15 * 60

  public var mode: Mode
  public var lastActivityAt: Date?
  public var closedAt: Date?
  public var finalOvertime: TimeInterval?

  public init(mode: Mode = .auto, lastActivityAt: Date? = nil, closedAt: Date? = nil, finalOvertime: TimeInterval? = nil) {
    self.mode = mode
    self.lastActivityAt = lastActivityAt
    self.closedAt = closedAt
    self.finalOvertime = finalOvertime
  }

  public var isClosed: Bool { closedAt != nil }
}

/// Everything recorded about one calendar day.
public struct DayRecord: Codable, Hashable, Sendable, Identifiable {
  public var date: LocalDate
  public var earnedRUB: Double
  public var rateRUB: Double
  /// Exchange rates fixed for this day on its first calculation.
  public var fx: FXRates?
  /// Norm hours of the day (8, or 7 on a shortened day); 0 when not a working day.
  public var normHours: Double
  /// Length of the scheduled day in hours.
  public var scheduleHours: Double
  public var overtime: OvertimeState
  public var overtimeSeconds: Double
  public var dayOff: DayOff?
  /// Keys of notifications already delivered for this day.
  public var notified: Set<String>
  public var breaks: BreakState
  /// When the working day actually began: the "start the day" button or the first activity.
  public var startedAt: Date?
  /// The start was reset: today starts only by the button.
  public var manualStartOnly: Bool

  public var id: LocalDate { date }

  public init(
    date: LocalDate,
    earnedRUB: Double = 0,
    rateRUB: Double = 0,
    fx: FXRates? = nil,
    normHours: Double = 0,
    scheduleHours: Double = 0,
    overtime: OvertimeState = OvertimeState(),
    overtimeSeconds: Double = 0,
    dayOff: DayOff? = nil,
    notified: Set<String> = [],
    breaks: BreakState = BreakState(),
    startedAt: Date? = nil,
    manualStartOnly: Bool = false
  ) {
    self.date = date
    self.earnedRUB = earnedRUB
    self.rateRUB = rateRUB
    self.fx = fx
    self.normHours = normHours
    self.scheduleHours = scheduleHours
    self.overtime = overtime
    self.overtimeSeconds = overtimeSeconds
    self.dayOff = dayOff
    self.notified = notified
    self.breaks = breaks
    self.startedAt = startedAt
    self.manualStartOnly = manualStartOnly
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    date = try c.decode(LocalDate.self, forKey: .date)
    earnedRUB = try c.decodeIfPresent(Double.self, forKey: .earnedRUB) ?? 0
    rateRUB = try c.decodeIfPresent(Double.self, forKey: .rateRUB) ?? 0
    fx = try c.decodeIfPresent(FXRates.self, forKey: .fx)
    normHours = try c.decodeIfPresent(Double.self, forKey: .normHours) ?? 0
    scheduleHours = try c.decodeIfPresent(Double.self, forKey: .scheduleHours) ?? 0
    overtime = try c.decodeIfPresent(OvertimeState.self, forKey: .overtime) ?? OvertimeState()
    overtimeSeconds = try c.decodeIfPresent(Double.self, forKey: .overtimeSeconds) ?? 0
    // Early files stored `dayOff` as a Bool meaning an unpaid day off.
    if let legacy = try? c.decodeIfPresent(Bool.self, forKey: .dayOff) {
      dayOff = legacy ? .unpaid : nil
    } else {
      dayOff = try c.decodeIfPresent(DayOff.self, forKey: .dayOff)
    }
    notified = try c.decodeIfPresent(Set<String>.self, forKey: .notified) ?? []
    breaks = try c.decodeIfPresent(BreakState.self, forKey: .breaks) ?? BreakState()
    startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
    manualStartOnly = try c.decodeIfPresent(Bool.self, forKey: .manualStartOnly) ?? false
  }
}
