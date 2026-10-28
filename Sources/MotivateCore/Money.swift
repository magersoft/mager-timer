import Foundation

/// Official CBR exchange rates: how many roubles one unit of a currency costs.
public struct FXRates: Codable, Hashable, Sendable {
  public var date: LocalDate
  public var rubPerUnit: [String: Double]

  public init(date: LocalDate, rubPerUnit: [String: Double]) {
    self.date = date
    self.rubPerUnit = rubPerUnit
  }

  public func rubPer(_ currency: Currency) -> Double? {
    currency == .rub ? 1 : rubPerUnit[currency.rawValue]
  }

  public func toRUB(_ amount: Double, from currency: Currency) -> Double? {
    rubPer(currency).map { amount * $0 }
  }

  public func fromRUB(_ rub: Double, to currency: Currency) -> Double? {
    rubPer(currency).map { rub / $0 }
  }

  public enum ParseError: Error, Sendable { case malformed }

  /// Parses the `cbr-xml-daily.ru/daily_json.js` payload.
  public static func parseCBR(_ data: Data) throws -> FXRates {
    struct Payload: Decodable {
      struct Valute: Decodable {
        let Nominal: Double
        let Value: Double
      }
      let Date: String
      let Valute: [String: Valute]
    }
    let payload = try JSONDecoder().decode(Payload.self, from: data)
    guard let date = LocalDate(string: String(payload.Date.prefix(10))) else { throw ParseError.malformed }
    var rates: [String: Double] = [:]
    for currency in Currency.allCases where currency != .rub {
      if let v = payload.Valute[currency.rawValue], v.Nominal > 0 {
        rates[currency.rawValue] = v.Value / v.Nominal
      }
    }
    guard !rates.isEmpty else { throw ParseError.malformed }
    return FXRates(date: date, rubPerUnit: rates)
  }
}

public enum MoneyFormatter {
  /// RUB in whole units with space grouping (`8 452 ₽`); USD/EUR with two decimals (`$1,234.50`).
  public static func format(_ amount: Double, _ currency: Currency) -> String {
    switch currency {
    case .rub:
      return "\(group(Int(amount.rounded()), separator: " ")) ₽"
    case .usd, .eur:
      let cents = Int((amount * 100).rounded())
      let sign = cents < 0 ? "-" : ""
      let whole = abs(cents) / 100
      let fraction = String(format: "%02d", abs(cents) % 100)
      return "\(sign)\(currency.symbol)\(group(whole, separator: ",")).\(fraction)"
    }
  }

  /// Formats a rouble amount in the display currency, or nil when no rate is known.
  public static func format(rub: Double, in currency: Currency, fx: FXRates?) -> String? {
    if currency == .rub { return format(rub, .rub) }
    guard let value = fx?.fromRUB(rub, to: currency) else { return nil }
    return format(value, currency)
  }

  private static func group(_ value: Int, separator: String) -> String {
    let digits = String(abs(value))
    var out = ""
    for (i, ch) in digits.enumerated() {
      if i > 0, (digits.count - i) % 3 == 0 { out += separator }
      out.append(ch)
    }
    return (value < 0 ? "-" : "") + out
  }
}

public enum DurationFormatter {
  /// `1:05` — hours and zero-padded minutes.
  public static func hoursMinutes(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds) / 60)
    return String(format: "%d:%02d", total / 60, total % 60)
  }

  /// `11 ч` or `2 ч 30 мин`.
  public static func human(_ seconds: TimeInterval) -> String {
    let total = max(0, Int((seconds / 60).rounded()))
    let h = total / 60, m = total % 60
    switch (h, m) {
    case (0, _): return "\(m) мин"
    case (_, 0): return "\(h) ч"
    default: return "\(h) ч \(m) мин"
    }
  }
}
