import Foundation

/// A production calendar. From isdayoff.ru it is one character per day of the year: `0` working,
/// `1` non-working, `2` shortened pre-holiday day. With the user's own holidays it is Saturday and
/// Sunday off plus those holidays, for any year, without shortened days.
public struct WorkCalendar: Hashable, Sendable {
  public enum Kind: Sendable, Equatable {
    case working
    case short
    case nonWorking
  }

  public enum ParseError: Error, Equatable, Sendable { case wrongLength(Int), badCharacter(Character) }

  /// Raw isdayoff strings keyed by year.
  public private(set) var years: [Int: String]

  /// Set for the user's own calendar; `years` is then ignored.
  public private(set) var holidays: [Holiday]?

  public init(years: [Int: String] = [:]) {
    self.years = years
  }

  public init(holidays: [Holiday]) {
    self.years = [:]
    self.holidays = holidays
  }

  public static func validate(_ raw: String, year: Int, calendar: Calendar) throws(ParseError) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let start = LocalDate(year: year, month: 1, day: 1).startOfDay(calendar: calendar)
    let days = calendar.range(of: .day, in: .year, for: start)!.count
    guard trimmed.count == days else { throw .wrongLength(trimmed.count) }
    if let bad = trimmed.first(where: { !"012".contains($0) }) { throw .badCharacter(bad) }
    return trimmed
  }

  public mutating func set(year: Int, raw: String) { years[year] = raw }

  public func hasData(for year: Int) -> Bool { holidays != nil || years[year] != nil }

  /// The user's own list has one-off dates (movable holidays such as Easter are entered that way)
  /// but none for this year: they were probably not carried over, and the days count as working.
  public func lacksOneOffHolidays(for year: Int) -> Bool {
    guard let holidays, holidays.contains(where: { $0.year != nil }) else { return false }
    return !holidays.contains { $0.year == year }
  }

  public func kind(of date: LocalDate, calendar: Calendar) -> Kind {
    let day = date.date(at: TimeOfDay(hour: 12, minute: 0), calendar: calendar)
    if let holidays, holidays.contains(where: { $0.matches(date) }) { return .nonWorking }
    if holidays == nil, let raw = years[date.year], let index = calendar.ordinality(of: .day, in: .year, for: day) {
      let ch = raw[raw.index(raw.startIndex, offsetBy: index - 1)]
      switch ch {
      case "0": return .working
      case "2": return .short
      default: return .nonWorking
      }
    }
    let weekday = calendar.component(.weekday, from: day)
    return weekday == 1 || weekday == 7 ? .nonWorking : .working
  }

  public func days(inMonth year: Int, _ month: Int, calendar: Calendar) -> [LocalDate] {
    let first = LocalDate(year: year, month: month, day: 1)
    let count = calendar.range(of: .day, in: .month, for: first.startOfDay(calendar: calendar))!.count
    return (1...count).map { LocalDate(year: year, month: month, day: $0) }
  }

  /// Norm hours of a month: 8 per working day, 7 per shortened day.
  public func normHours(year: Int, month: Int, calendar: Calendar) -> Double {
    days(inMonth: year, month, calendar: calendar).reduce(0) { sum, day in
      sum + Self.normHours(of: kind(of: day, calendar: calendar))
    }
  }

  public static func normHours(of kind: Kind) -> Double {
    switch kind {
    case .working: 8
    case .short: 7
    case .nonWorking: 0
    }
  }
}
