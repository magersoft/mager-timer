import Foundation
import Testing
@testable import MotivateCore

struct GoalTests {
  func goal(percent: Int = 100, amount: Double = 150_000, saved: Double = 0, created: String = "2026-10-01") -> Goal {
    Goal(name: "Грузия", amount: amount, currency: .rub, percent: percent, initialSaved: saved, createdOn: day(created))
  }

  func records(_ pairs: [(String, Double)]) -> [DayRecord] {
    pairs.map { DayRecord(date: day($0.0), earnedRUB: $0.1, rateRUB: 1700, normHours: 8) }
  }

  @Test func `progress accumulates across months from the creation date`() throws {
    let engine = try makeEngine(goals: [goal(percent: 20, created: "2026-10-02")])
    let history = records([("2026-10-01", 50_000), ("2026-10-02", 100_000), ("2026-10-30", 100_000)])
    let tracker = DayTracker(today: started("2026-11-01"), history: history)
    let p = try #require(tracker.goalProgress(engine.settings.goals[0], engine: engine, now: at("2026-11-01 12:00")))
    #expect(p.savedRUB == 40_000)
  }

  @Test func `changing the percent recalculates the whole period`() throws {
    var engine = try makeEngine(goals: [goal(percent: 20)])
    let tracker = DayTracker(today: started("2026-10-31"), history: records([("2026-10-10", 100_000)]))
    #expect(tracker.goalProgress(engine.settings.goals[0], engine: engine, now: at("2026-10-31 12:00"))?.savedRUB == 20_000)
    engine.settings.goals[0].percent = 50
    #expect(tracker.goalProgress(engine.settings.goals[0], engine: engine, now: at("2026-10-31 12:00"))?.savedRUB == 50_000)
  }

  @Test func `forecast walks working days forward`() throws {
    // Saturday 31 Oct; 34 000 left at 13 600/day: Mon 2 Nov (13 600), Tue 3 Nov short (11 900), Thu 5 Nov.
    let engine = try makeEngine(goals: [goal(amount: 34_000, created: "2026-10-31")])
    let tracker = DayTracker(today: started("2026-10-31"), history: [])
    let p = try #require(tracker.goalProgress(engine.settings.goals[0], engine: engine, now: at("2026-10-31 12:00")))
    #expect(p.forecast == day("2026-11-05"))
    #expect(!p.achieved)
  }

  @Test func `reaching the goal fires one event`() throws {
    let engine = try makeEngine(goals: [goal(amount: 20_000, created: "2026-10-26")])
    var tracker = DayTracker(today: started("2026-10-27"), history: records([("2026-10-26", 13_600)]))
    var events: [DayTracker.Event] = []
    var now = at("2026-10-27 09:00")
    while now <= at("2026-10-27 17:00") {
      events += tracker.tick(now: now, idleSeconds: 1, latestFX: nil, engine: engine)
      now.addTimeInterval(600)
    }
    #expect(events.filter { $0 == .goalAchieved(id: engine.settings.goals[0].id, name: "Грузия") }.count == 1)
    let p = try #require(tracker.goalProgress(engine.settings.goals[0], engine: engine, now: now))
    #expect(p.achieved && p.fraction == 1 && p.savedRUB == 20_000)
  }

  @Test func `a goal in a currency without a rate has no progress`() throws {
    var g = goal()
    g.currency = .usd
    let tracker = DayTracker(today: started("2026-10-27"), history: [])
    #expect(tracker.goalProgress(g, engine: try makeEngine(goals: [g]), now: at("2026-10-27 12:00")) == nil)
  }

  @Test func `already saved money counts towards the goal`() throws {
    let engine = try makeEngine(goals: [goal(percent: 20, saved: 30_000, created: "2026-10-02")])
    let tracker = DayTracker(today: started("2026-10-31"), history: records([("2026-10-10", 100_000)]))
    #expect(tracker.goalProgress(engine.settings.goals[0], engine: engine, now: at("2026-10-31 12:00"))?.savedRUB == 50_000)
  }

  @Test func `each goal fills from its own share`() throws {
    var second = goal(percent: 30, amount: 1_000_000)
    second.name = "Машина"
    let engine = try makeEngine(goals: [goal(percent: 20, saved: 10_000), second])
    let tracker = DayTracker(today: started("2026-10-31"), history: records([("2026-10-10", 100_000)]))
    let saved = engine.settings.goals.map { tracker.goalProgress($0, engine: engine, now: at("2026-10-31 12:00"))?.savedRUB }
    #expect(saved == [30_000, 30_000])
  }

  @Test func `a goal already covered by savings fires on the first tick`() throws {
    let engine = try makeEngine(goals: [goal(amount: 10_000, saved: 10_000, created: "2026-10-27"), goal(amount: 1_000_000)])
    var tracker = DayTracker(today: started("2026-10-27"), history: [])
    let events = tracker.tick(now: at("2026-10-27 08:00"), idleSeconds: 1, latestFX: nil, engine: engine)
    #expect(events == [.goalAchieved(id: engine.settings.goals[0].id, name: "Грузия")])
    #expect(tracker.tick(now: at("2026-10-27 08:01"), idleSeconds: 1, latestFX: nil, engine: engine).isEmpty)
  }

  @Test func `editing a reached goal's terms checks it again`() throws {
    var reached = goal(amount: 1)
    reached.achievedOn = day("2026-10-27")
    let old = Settings(goals: [reached])
    var renamed = old
    renamed.goals[0].name = "Ипотека"
    #expect(renamed.resettingAchievements(comparedTo: old).goals[0].achievedOn == day("2026-10-27"))
    var raised = old
    raised.goals[0].amount = 100_000
    #expect(raised.resettingAchievements(comparedTo: old).goals[0].achievedOn == nil)
  }

  @Test func `goals are not checked while being edited`() throws {
    let engine = try makeEngine(goals: [goal(amount: 1, created: "2026-10-27")])
    var tracker = DayTracker(today: started("2026-10-27"), history: [])
    #expect(tracker.tick(now: at("2026-10-27 10:00"), idleSeconds: 1, latestFX: nil, engine: engine, checkGoals: false) == [.dayStarted(expectedRUB: 13_600)])
    #expect(tracker.tick(now: at("2026-10-27 10:01"), idleSeconds: 1, latestFX: nil, engine: engine)
      == [.goalAchieved(id: engine.settings.goals[0].id, name: "Грузия")])
  }
}
