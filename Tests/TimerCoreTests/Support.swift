import Foundation
import Testing
@testable import TimerCore

let moscow: Calendar = {
  var c = Calendar(identifier: .gregorian)
  c.timeZone = TimeZone(identifier: "Europe/Moscow")!
  return c
}()

/// `"2026-10-27 13:30"` in Moscow time.
func at(_ s: String) -> Date {
  let parts = s.split(separator: " ")
  let d = LocalDate(string: String(parts[0]))!
  let t = parts[1].split(separator: ":").map { Int($0)! }
  return d.date(at: TimeOfDay(hour: t[0], minute: t[1]), calendar: moscow)
}

func day(_ s: String) -> LocalDate { LocalDate(string: s)! }

func fixture(_ name: String) throws -> Data {
  let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
  return try Data(contentsOf: url)
}

func calendar2026() throws -> WorkCalendar {
  let raw = try WorkCalendar.validate(String(decoding: fixture("isdayoff-2026.txt"), as: UTF8.self), year: 2026, calendar: moscow)
  return WorkCalendar(years: [2026: raw])
}

/// October 2026 has 176 norm hours, so 299 200 ₽ gives exactly 1 700 ₽/h.
let october1700 = Income(name: "Работа", amount: 1700 * 176, currency: .rub)

func makeEngine(_ incomes: [Income] = [october1700], schedule: Schedule = Schedule(), goals: [Goal] = [],
                vacations: [VacationRange] = [], display: Currency = .rub) throws -> Engine {
  Engine(
    settings: Settings(incomes: incomes, displayCurrency: display, schedule: schedule, vacations: vacations, goals: goals),
    workCalendar: try calendar2026(), calendar: moscow)
}

let usdFX = FXRates(date: LocalDate(year: 2026, month: 10, day: 27), rubPerUnit: ["USD": 87.4, "EUR": 95])

func t(_ h: Int, _ m: Int) -> TimeOfDay { TimeOfDay(hour: h, minute: m) }

/// A day already started at `time`, the default schedule's start; most tests are about what follows.
func started(_ s: String, at time: String = "09:00") -> DayRecord {
  DayRecord(date: day(s), startedAt: at("\(s) \(time)"))
}
