import Foundation
import Testing
@testable import TimerCore

struct StorageTests {
  let storage = Storage(root: URL.temporaryDirectory.appending(path: "timer-tests-\(UUID().uuidString)"))

  @Test func `settings persist`() throws {
    #expect(try storage.loadSettings() == nil)
    let settings = Settings(incomes: [october1700], displayCurrency: .eur)
    try storage.save(settings)
    #expect(try storage.loadSettings() == settings)
  }

  @Test func `records are upserted into month files`() throws {
    let a = DayRecord(date: day("2026-10-27"), earnedRUB: 1)
    let b = DayRecord(date: day("2026-11-02"), earnedRUB: 2)
    try storage.save([a, b])
    var a2 = a
    a2.earnedRUB = 13_600
    try storage.save([a2])
    #expect(try storage.loadAllRecords() == [a2, b])
  }

  @Test func `caches persist`() throws {
    let raw = try calendar2026().years[2026]!
    try storage.saveCalendar(year: 2026, raw: raw)
    #expect(storage.loadCalendar(years: [2026, 2027]).years == [2026: raw])
    try storage.saveLatestFX(usdFX)
    #expect(storage.loadLatestFX() == usdFX)
  }

  @Test func `restoring after two missed days writes them to disk`() throws {
    let engine = try makeEngine()
    let monday = DayRecord(date: day("2026-10-26"), earnedRUB: 13_600, rateRUB: 1700, normHours: 8,
                           overtime: OvertimeState(closedAt: at("2026-10-26 17:15"), finalOvertime: 0))
    try storage.save([monday])
    let (_, changed) = DayTracker.restore(records: try storage.loadAllRecords(), now: at("2026-10-29 10:00"), latestFX: nil, engine: engine)
    try storage.save(changed)
    let stored = try storage.loadAllRecords()
    #expect(stored.map(\.date) == [day("2026-10-26"), day("2026-10-27"), day("2026-10-28")])
    #expect(stored.dropFirst().allSatisfy { $0.earnedRUB == 13_600 && $0.overtimeSeconds == 0 })
  }

  @Test func `data from the old folder moves to the new one once`() throws {
    let base = URL.temporaryDirectory.appending(path: "timer-migrate-\(UUID().uuidString)")
    let legacy = Storage(root: base.appending(path: "MagerMotivate"))
    let settings = Settings(incomes: [october1700])
    try legacy.save(settings)
    let root = base.appending(path: "MagerTimer")
    try Storage.migrate(from: legacy.root, to: root)
    #expect(try Storage(root: root).loadSettings() == settings)
    #expect(!FileManager.default.fileExists(atPath: legacy.root.path(percentEncoded: false)))
  }

  @Test func `migration leaves an existing new folder alone`() throws {
    let base = URL.temporaryDirectory.appending(path: "timer-migrate-\(UUID().uuidString)")
    let legacy = Storage(root: base.appending(path: "MagerMotivate"))
    try legacy.save(Settings(incomes: [october1700]))
    let current = Storage(root: base.appending(path: "MagerTimer"))
    try current.save(Settings())
    try Storage.migrate(from: legacy.root, to: current.root)
    #expect(try current.loadSettings() == Settings())
    #expect(try legacy.loadSettings() != nil)
  }
}
