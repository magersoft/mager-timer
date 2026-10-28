import MotivateCore
import SwiftUI

struct MenuContentView: View {
  let model: AppModel
  @Environment(\.openWindow) private var openWindow

  private var snapshot: DaySnapshot { model.snapshot }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ZStack(alignment: .topTrailing) {
        if let today = snapshot.today {
          VStack(alignment: .leading, spacing: 10) {
            TodaySection(
              today: today, isAlert: snapshot.isAlert,
              resetStart: snapshot.actions.contains(.resetStart) ? { model.resetStart() } : nil)
            if let breaks = snapshot.breaks { breakRow(breaks) }
            if snapshot.actions.contains(.startDay) { startPrompt }
            if snapshot.actions.contains(.finish) { afterHoursPrompt }
          }
        } else if let label = snapshot.nonWorkingLabel {
          Text("🌴 \(label)").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
        }
        HStack(spacing: 8) {
          Button { model.toggleHidesAmounts() } label: {
            Image(systemName: model.settings.hidesAmounts ? "eye.slash" : "eye").font(.body)
          }
          .buttonStyle(.borderless)
          .help(model.settings.hidesAmounts ? "Показать суммы в menubar (⌃⌥⌘M)" : "Скрыть суммы в menubar (⌃⌥⌘M)")
          Button { openSettings(.incomes) } label: {
            Image(systemName: "gearshape").font(.body)
          }
          .buttonStyle(.borderless)
          .help("Настройки")
        }
      }
      Divider()
      MonthSection(month: snapshot.month, payday: snapshot.payday)
      Divider()
      goalSection
      if !snapshot.warnings.isEmpty || !model.notificationsAuthorized {
        Divider()
        warnings
      }
      Divider()
      footer
    }
    .padding(14)
    .frame(width: 320)
  }

  @ViewBuilder private var goalSection: some View {
    if snapshot.canAddGoal {
      Button("Поставить цель…") { openSettings(.goal) }.buttonStyle(.link)
    } else if !snapshot.goals.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        Text(snapshot.goals.count == 1 ? "Цель" : "Цели").font(.subheadline.bold())
        ForEach(snapshot.goals, id: \.id) { GoalRow(goal: $0) }
      }
    }
  }

  private var warnings: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(snapshot.warnings, id: \.self) { Text("⚠︎ \($0)") }
      if !model.notificationsAuthorized {
        Text("⚠︎ Уведомления выключены: Системные настройки → Уведомления → MagerMotivate")
      }
    }
    .font(.caption).foregroundStyle(.orange)
  }

  private func breakRow(_ breaks: DaySnapshot.Breaks) -> some View {
    HStack {
      Text("☕ \(breaks.status) · \(breaks.tally)")
      Spacer()
      if breaks.canStartNow {
        Button("Сейчас") { model.startBreakNow() }
          .buttonStyle(.link)
          .help("Начать перерыв прямо сейчас")
      }
    }
    .font(.caption)
    .monospacedDigit()
  }

  /// The day waits for the user: early or late, it runs from the press.
  private var startPrompt: some View {
    Button { model.startDay() } label: { Text("Начать день").frame(maxWidth: .infinity) }
      .buttonStyle(.borderedProminent)
      .keyboardShortcut(.defaultAction)
      .controlSize(.large)
  }

  /// Time-sensitive choice after the scheduled end, shown right under the day it affects.
  private var afterHoursPrompt: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Рабочий день окончен. Дальше — бесплатно").font(.caption.bold())
      HStack(spacing: 8) {
        Button { model.finish() } label: { Text("Закончил").frame(maxWidth: .infinity) }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
        if snapshot.actions.contains(.stillWorking) {
          Button { model.stillWorking() } label: { Text("Ещё работаю").frame(maxWidth: .infinity) }
            .buttonStyle(.bordered)
        }
      }
      .controlSize(.large)
    }
    .padding(10)
    .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
  }

  /// Rare actions: quiet, one style, the day-off choice on the left and quitting on the right.
  private var footer: some View {
    HStack {
      if snapshot.actions.contains(.dayOff) {
        Menu {
          Button("Оплачиваемый: больничный, отгул") { model.setDayOff(.paid) }
          Button("За свой счёт") { model.setDayOff(.unpaid) }
        } label: {
          Label("Сегодня не работаю", systemImage: "bed.double")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.borderless)
        .fixedSize()
      } else if snapshot.actions.contains(.undoDayOff) {
        Button { model.setDayOff(nil) } label: {
          Label("Всё-таки работаю", systemImage: "arrow.uturn.backward")
        }
        .buttonStyle(.borderless)
      }
      Spacer()
      Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
        .buttonStyle(.borderless)
        .keyboardShortcut("q")
        .help("Выйти из MagerMotivate (⌘Q)")
    }
    .font(.callout)
    .foregroundStyle(.secondary)
  }

  private func openSettings(_ tab: SettingsTab) {
    UserDefaults.standard.set(tab.rawValue, forKey: SettingsTab.storageKey)
    openWindow(id: SettingsView.windowID)
    NSApp.activate()
  }
}

private struct TodaySection: View {
  let today: DaySnapshot.Today
  let isAlert: Bool
  let resetStart: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 4) {
        Text("Сегодня · \(today.dateLabel)").font(.subheadline.bold())
        if let start = today.startTime { startLabel(start) }
      }
      HStack(alignment: .firstTextBaseline) {
        Text(today.earned).font(.title2.bold()).monospacedDigit()
        Text("из \(today.dayPay)").foregroundStyle(.secondary).monospacedDigit()
        Spacer()
        Text("\(Int((today.fraction * 100).rounded(.down)))%").monospacedDigit()
      }
      DayRibbon(today: today)
      HStack {
        Text("Ставка: \(today.rate)")
        if let real = today.realRate {
          Text("→ \(real) 🔥").foregroundStyle(.red)
        }
      }
      .font(.caption).monospacedDigit()
      if let overtime = today.overtime {
        Text("Переработка: \(overtime) — бесплатно").font(.caption.bold()).foregroundStyle(.red)
      }
    }
  }

  /// The start time is plain information; a click on it undoes a start by mistake.
  @ViewBuilder
  private func startLabel(_ start: String) -> some View {
    let label = Text("· с \(start)").font(.subheadline).foregroundStyle(.secondary)
    if let resetStart {
      Menu {
        Button("Сбросить начало дня", systemImage: "arrow.uturn.backward", action: resetStart)
      } label: {
        label
      }
      .menuStyle(.button)
      .menuIndicator(.hidden)
      .buttonStyle(.borderless)
      .fixedSize()
      .help("День начался по ошибке? Сбросьте начало: дальше день начнётся только кнопкой")
    } else {
      label
    }
  }
}

private struct GoalRow: View {
  let goal: DaySnapshot.Goal

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack {
        Text(goal.achieved ? "\(goal.name) 🎉" : goal.name)
        Spacer()
        Text("\(Int((goal.fraction * 100).rounded(.down)))%").monospacedDigit()
      }
      .font(.caption.bold())
      ProgressView(value: goal.fraction).tint(goal.achieved ? .green : .accentColor)
      HStack {
        Text("\(goal.saved) из \(goal.target)")
        Spacer()
        if let forecast = goal.forecast { Text(forecast) }
      }
      .font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }
  }
}

private struct MonthSection: View {
  let month: DaySnapshot.Month
  let payday: DaySnapshot.Payday?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(month.title).font(.subheadline.bold())
      HStack {
        Text("\(month.earned) из \(month.expected)").monospacedDigit()
        Spacer()
        Text("\(Int((month.fraction * 100).rounded(.down)))%").monospacedDigit()
      }
      .font(.caption)
      ProgressView(value: month.fraction)
      if let payday {
        VStack(alignment: .leading, spacing: 1) {
          HStack {
            Text(payday.title)
            Spacer()
            Text(payday.amount).monospacedDigit()
          }
          .font(.caption)
          Text(payday.sources).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.top, 2)
      }
      if let overtime = month.overtime {
        Text(overtime).font(.caption).foregroundStyle(.red)
      }
    }
  }
}
