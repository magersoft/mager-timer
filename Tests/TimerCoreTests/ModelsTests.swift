import Foundation
import Testing
@testable import TimerCore

struct ModelsTests {
  func roundTrip<T: Codable & Equatable>(_ value: T) throws {
    let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
    let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
    #expect(try d.decode(T.self, from: e.encode(value)) == value)
  }

  @Test func `settings, records and goals survive a JSON round trip`() throws {
    let goal = Goal(name: "Грузия", amount: 150_000, currency: .rub, percent: 20, initialSaved: 30_000, createdOn: day("2026-10-01"))
    try roundTrip(Settings(
      incomes: [october1700, Income(name: "US", amount: 1000, currency: .usd, payouts: [Payout(day: 5, percent: 100)])], displayCurrency: .usd,
      schedule: Schedule(start: t(10, 0), end: t(18, 0), lunchStart: t(14, 0)),
      vacations: [VacationRange(from: day("2026-11-10"), to: day("2026-11-24"))], goals: [goal], launchAtLogin: false, hidesAmounts: true))
    try roundTrip(DayRecord(
      date: day("2026-10-27"), earnedRUB: 13_600, rateRUB: 1700, fx: usdFX, normHours: 8, scheduleHours: 8,
      overtime: OvertimeState(mode: .manual, lastActivityAt: at("2026-10-27 18:10"), closedAt: at("2026-10-27 18:30"), finalOvertime: 1800),
      overtimeSeconds: 1800, dayOff: .paid, notified: ["start", "end"]))
    try roundTrip(goal)
  }

  @Test func `pauses and resumed overtime survive a JSON round trip`() throws {
    try roundTrip(DayRecord(
      date: day("2026-10-27"), startedAt: at("2026-10-27 09:00"),
      pauses: [Pause(start: at("2026-10-27 11:00"), end: at("2026-10-27 11:20")), Pause(start: at("2026-10-27 14:00"))],
      undertimeSeconds: 3600))
    try roundTrip(OvertimeState(mode: .manual, lastActivityAt: at("2026-10-27 21:00"), banked: 1800, resumedAt: at("2026-10-27 21:00")))
  }

  @Test func `records without pauses still load`() throws {
    let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
    let r = try d.decode(DayRecord.self, from: Data(#"{"date":"2026-10-27","overtime":{"mode":"auto"}}"#.utf8))
    #expect(r.pauses.isEmpty)
    #expect(r.undertimeSeconds == 0)
    #expect(r.overtime.banked == 0)
    #expect(r.overtime.resumedAt == nil)
  }

  @Test func `an open pause runs up to now`() {
    let r = DayRecord(
      date: day("2026-10-27"),
      pauses: [Pause(start: at("2026-10-27 11:00"), end: at("2026-10-27 11:20")), Pause(start: at("2026-10-27 14:00"))])
    #expect(r.openPause?.start == at("2026-10-27 14:00"))
    let lengths: [TimeInterval] = r.resolvedPauses(at: at("2026-10-27 14:42")).map(\.duration)
    #expect(lengths == [1200, 2520])
  }

  @Test func `settings missing keys fall back to defaults`() throws {
    let s = try JSONDecoder().decode(Settings.self, from: Data(#"{"displayCurrency":"EUR"}"#.utf8))
    #expect(s.displayCurrency == .eur)
    #expect(s.schedule == Schedule())
    #expect(s.launchAtLogin)
    #expect(!s.hidesAmounts)
  }

  @Test func `early records with a Bool day off still load`() throws {
    let json = #"[{"date":"2026-10-27","dayOff":true},{"date":"2026-10-28","dayOff":false},{"date":"2026-10-29","dayOff":"paid"}]"#
    let records = try JSONDecoder().decode([DayRecord].self, from: Data(json.utf8))
    #expect(records.map(\.dayOff) == [.unpaid, nil, .paid])
  }

  @Test func `payouts are days of a month that add up to the whole income`() {
    let income = { (payouts: [Payout]) in Income(name: "ЗП", amount: 100, currency: .rub, payouts: payouts) }
    #expect(throws: SettingsError.paydayOutOfRange) { try income([Payout(day: 32, percent: 100)]).validate() }
    #expect(throws: SettingsError.payoutsNotWhole(income: "ЗП", percent: 90)) {
      try income([Payout(day: 10, percent: 50), Payout(day: 25, percent: 40)]).validate()
    }
    #expect(throws: Never.self) { try income([Payout(day: 10, percent: 60), Payout(day: 25, percent: 40)]).validate() }
    #expect(throws: Never.self) { try income([]).validate() }
  }

  @Test func `earlier settings with one goal and shared paydays still load`() throws {
    let id = october1700.id
    let json = #"""
      {"incomes":[{"id":"\#(id)","name":"Работа","amount":1000,"currency":"RUB"}],"paydays":[10,25,5],
       "goal":{"name":"Грузия","amount":100,"currency":"RUB","percent":20,"createdOn":"2026-10-01"}}
      """#
    let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(s.goals.map(\.name) == ["Грузия"] && s.goals[0].initialSaved == 0)
    #expect(s.incomes[0].payouts.map(\.day) == [10, 25, 5])
    #expect(s.incomes[0].payouts.map(\.percent) == [33, 33, 34])
    #expect(throws: Never.self) { try s.validate() }
  }

  @Test func `goals cannot take more than all of the earnings`() {
    let goal = { (percent: Int) in Goal(name: "Цель", amount: 100, currency: .rub, percent: percent, createdOn: day("2026-10-01")) }
    var s = Settings(goals: [goal(60), goal(50)])
    #expect(throws: SettingsError.goalsOverAllocated(percent: 110)) { try s.validate() }
    s.goals[0].achievedOn = day("2026-10-20")
    #expect(throws: Never.self) { try s.validate() }
  }

  @Test func `default schedule is 8 hours including lunch`() {
    let s = Schedule()
    #expect(s.start == t(9, 0) && s.end == t(17, 0) && s.lunchStart == t(13, 0))
  }

  @Test(arguments: [
    (Schedule(start: t(9, 0), end: t(17, 0), lunchStart: t(13, 0)), nil),
    (Schedule(start: t(9, 0), end: t(9, 0), lunchStart: t(9, 0)), SettingsError.endNotAfterStart),
    (Schedule(start: t(18, 0), end: t(10, 0), lunchStart: t(13, 0)), .endNotAfterStart),
    (Schedule(start: t(9, 0), end: t(17, 0), lunchStart: t(16, 30)), nil),
    (Schedule(start: t(9, 0), end: t(17, 0), lunchStart: t(17, 0)), .lunchReminderOutsideDay),
    (Schedule(start: t(9, 0), end: t(17, 0), lunchStart: t(8, 0)), .lunchReminderOutsideDay),
  ] as [(Schedule, SettingsError?)])
  func `schedule validation`(schedule: Schedule, error: SettingsError?) {
    if let error {
      #expect(throws: error) { try schedule.validate() }
    } else {
      #expect(throws: Never.self) { try schedule.validate() }
    }
  }

  @Test func `income amount must be positive`() {
    #expect(throws: SettingsError.nonPositiveAmount) { try Income(name: "x", amount: 0, currency: .rub).validate() }
    #expect(throws: SettingsError.nonPositiveAmount) { try Income(name: "x", amount: -5, currency: .rub).validate() }
    #expect(throws: Never.self) { try Income(name: "x", amount: 1, currency: .usd).validate() }
  }

  @Test func `settings validation covers schedule, incomes and goal`() {
    var s = Settings(incomes: [october1700])
    #expect(throws: Never.self) { try s.validate() }
    s.incomes.append(Income(name: "x", amount: 0, currency: .usd))
    #expect(throws: SettingsError.nonPositiveAmount) { try s.validate() }
    s = Settings(schedule: Schedule(start: t(18, 0), end: t(10, 0), lunchStart: t(13, 0)))
    #expect(throws: SettingsError.endNotAfterStart) { try s.validate() }
  }

  @Test func `goal validation`() {
    let base = Goal(name: "Цель", amount: 100, currency: .rub, createdOn: day("2026-10-01"))
    #expect(throws: Never.self) { try base.validate() }
    var g = base; g.percent = 0
    #expect(throws: SettingsError.percentOutOfRange) { try g.validate() }
    g = base; g.name = "  "
    #expect(throws: SettingsError.emptyName) { try g.validate() }
    g = base; g.initialSaved = -1
    #expect(throws: SettingsError.negativeSaved) { try g.validate() }
  }

  // MARK: - Lunch

  @Test func `old day files read without lunches, and an open lunch survives a round trip`() throws {
    let old = #"{"date":"2026-10-27","earnedRUB":0,"rateRUB":0,"normHours":8,"scheduleHours":8,"overtime":{"mode":"auto"},"overtimeSeconds":0,"notified":[]}"#
    #expect(try JSONDecoder().decode(DayRecord.self, from: Data(old.utf8)).lunches == [])

    var record = DayRecord(date: day("2026-10-27"))
    record.lunches = [Lunch(start: at("2026-10-27 11:30"), end: at("2026-10-27 11:50")), Lunch(start: at("2026-10-27 13:00"))]
    #expect(try JSONDecoder().decode(DayRecord.self, from: JSONEncoder().encode(record)) == record)
  }

  @Test func `an open lunch runs up to now but stops at what is left of the hour`() {
    var record = DayRecord(date: day("2026-10-27"))
    record.lunches = [Lunch(start: at("2026-10-27 11:30"), end: at("2026-10-27 11:50")), Lunch(start: at("2026-10-27 13:00"))]
    let end = at("2026-10-27 15:00")
    #expect(record.resolvedLunches(at: at("2026-10-27 13:10"), dayEnd: end).last?.end == at("2026-10-27 13:10"))
    #expect(record.resolvedLunches(at: at("2026-10-27 13:50"), dayEnd: end).last?.end == at("2026-10-27 13:40"))
    #expect(record.closedLunchTime == 20 * 60)
  }

  @Test func `an open lunch stops at the end of the day`() {
    var record = DayRecord(date: day("2026-10-27"))
    record.lunches = [Lunch(start: at("2026-10-27 14:40"))]
    #expect(record.resolvedLunches(at: at("2026-10-27 15:10"), dayEnd: at("2026-10-27 15:00")).last?.end == at("2026-10-27 15:00"))
  }

  @Test func `old schedules keep their lunch time as the reminder, which is on`() throws {
    let json = #"{"start":"09:00","end":"17:00","lunchStart":"12:00"}"#
    let schedule = try JSONDecoder().decode(Schedule.self, from: Data(json.utf8))
    #expect(schedule.lunchStart == t(12, 0) && schedule.lunchReminder)
    let off = Schedule(lunchReminder: false)
    #expect(try JSONDecoder().decode(Schedule.self, from: JSONEncoder().encode(off)) == off)
  }

  @Test func `settings without a calendar choice read as Russia without holidays`() throws {
    let settings = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
    #expect(settings.calendar == .country(.ru))
    #expect(settings.holidays.isEmpty)
  }

  @Test func `the own calendar and a yearly holiday survive a JSON round trip`() throws {
    try roundTrip(Settings(calendar: .custom, holidays: [Holiday(name: "Благовещение", month: 3, day: 25)]))
    try roundTrip(Settings(calendar: .country(.by), holidays: [Holiday(name: "Разовый", month: 4, day: 13, year: 2026)]))
    let yearly = try JSONDecoder().decode(Holiday.self, from: JSONEncoder().encode(Holiday(name: "a", month: 1, day: 1)))
    #expect(yearly.year == nil)
  }

  @Test func `a holiday needs a name and a real date`() {
    #expect(throws: SettingsError.emptyName) { try Holiday(name: " ", month: 3, day: 25).validate() }
    #expect(throws: SettingsError.invalidDate) { try Holiday(name: "a", month: 4, day: 31).validate() }
    #expect(throws: SettingsError.invalidDate) { try Holiday(name: "a", month: 2, day: 29, year: 2027).validate() }
    #expect(throws: Never.self) { try Holiday(name: "a", month: 2, day: 29).validate() }
    #expect(throws: SettingsError.emptyName) { try Settings(holidays: [Holiday(name: "", month: 1, day: 1)]).validate() }
  }
}
