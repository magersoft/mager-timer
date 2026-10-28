import Foundation

/// Russian production calendar, one character per day of the year as served by isdayoff.ru:
/// `0` working, `1` non-working, `2` shortened pre-holiday day.
public struct WorkCalendar: Hashable, Sendable {
  public enum Kind: Sendable, Equatable {
    case working
    case short
    case nonWorking
  }

  public enum ParseError: Error, Equatable, Sendable { case wrongLength(Int), badCharacter(Character) }

  /// Raw isdayoff strings keyed by year.
  public private(set) var years: [Int: String]

  public init(years: [Int: String] = [:]) {
    self.years = years
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

  public func hasData(for year: Int) -> Bool { years[year] != nil }

  public func kind(of date: LocalDate, calendar: Calendar) -> Kind {
    let day = date.date(at: TimeOfDay(hour: 12, minute: 0), calendar: calendar)
    if let raw = years[date.year], let index = calendar.ordinality(of: .day, in: .year, for: day) {
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
