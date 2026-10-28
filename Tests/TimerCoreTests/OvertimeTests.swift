import Foundation
import Testing
@testable import TimerCore

/// Overtime scenarios use an 18:00 end, as in the spec.
struct OvertimeTests {
  let end = at("2026-10-27 18:00")

  /// Simulates ticks every minute; `active` says whether the user touched the Mac during that minute.
  func run(_ state: inout OvertimeState, from: String, to: String, active: (Date) -> Bool, locked: (Date) -> Bool = { _ in false }) {
    var lastInput = end.addingTimeInterval(-60)
    var now = at(from)
    while now <= at(to) {
      if active(now) { lastInput = now }
      state.advance(end: end, now: now, idleSeconds: locked(now) ? nil : now.timeIntervalSince(lastInput))
      now.addTimeInterval(60)
    }
  }

  @Test func `stayed to work then left`() {
    var s = OvertimeState()
    run(&s, from: "2026-10-27 18:00", to: "2026-10-27 20:00") { $0 <= at("2026-10-27 19:10") }
    #expect(s.closedAt == at("2026-10-27 19:25"))
    #expect(s.overtime(end: end, now: at("2026-10-27 20:00")) == 70 * 60)
  }

  @Test func `left on time`() {
    var s = OvertimeState()
    run(&s, from: "2026-10-27 18:00", to: "2026-10-27 19:00") { _ in false }
    #expect(s.closedAt == at("2026-10-27 18:15"))
    #expect(s.overtime(end: end, now: at("2026-10-27 19:00")) == 0)
  }

  @Test func `a short pause counts as overtime`() {
    var s = OvertimeState()
    let away = at("2026-10-27 18:30")...at("2026-10-27 18:40")
    run(&s, from: "2026-10-27 18:00", to: "2026-10-27 19:00") { !away.contains($0) }
    #expect(!s.isClosed)
    #expect(s.overtime(end: end, now: at("2026-10-27 19:00")) == 60 * 60)
  }

  @Test func `a locked screen is idle time`() {
    var s = OvertimeState()
    run(&s, from: "2026-10-27 18:00", to: "2026-10-27 18:40", active: { _ in true }, locked: { $0 > at("2026-10-27 18:10") })
    #expect(s.closedAt == at("2026-10-27 18:25"))
    #expect(s.overtime(end: end, now: at("2026-10-27 18:40")) == 10 * 60)
  }

  @Test func `evening use after closing does not reopen the day`() {
    var s = OvertimeState()
    run(&s, from: "2026-10-27 18:00", to: "2026-10-27 22:30") { $0 <= at("2026-10-27 18:05") || $0 >= at("2026-10-27 22:00") }
    #expect(s.closedAt == at("2026-10-27 18:20"))
    #expect(s.overtime(end: end, now: at("2026-10-27 22:30")) == 5 * 60)
  }

  @Test func `returning after a long gap closes at the gap`() {
    // App was not ticking: last seen active at 18:20, next tick at 21:00 with fresh input.
    var s = OvertimeState(lastActivityAt: at("2026-10-27 18:20"))
    s.advance(end: end, now: at("2026-10-27 21:00"), idleSeconds: 5)
    #expect(s.closedAt == at("2026-10-27 18:35"))
    #expect(s.overtime(end: end, now: at("2026-10-27 21:00")) == 20 * 60)
  }

  @Test func `still working counts continuously regardless of activity`() {
    var s = OvertimeState()
    run(&s, from: "2026-10-27 18:00", to: "2026-10-27 18:05") { _ in true }
    s.startManual()
    run(&s, from: "2026-10-27 18:06", to: "2026-10-27 18:45") { _ in false }
    #expect(!s.isClosed)
    #expect(s.overtime(end: end, now: at("2026-10-27 18:45")) == 45 * 60)
  }

  @Test func `finishing freezes overtime`() {
    var s = OvertimeState()
    run(&s, from: "2026-10-27 18:00", to: "2026-10-27 19:30") { _ in true }
    s.finish(end: end, now: at("2026-10-27 19:30"))
    #expect(s.isClosed)
    #expect(s.overtime(end: end, now: at("2026-10-27 23:00")) == 90 * 60)
    s.startManual()
    #expect(s.mode == .auto)
  }

  @Test func `nothing happens before the end of the day`() {
    var s = OvertimeState()
    s.advance(end: end, now: at("2026-10-27 17:00"), idleSeconds: 3600)
    #expect(s == OvertimeState())
  }
}
