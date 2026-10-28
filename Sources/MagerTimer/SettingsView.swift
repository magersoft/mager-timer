import TimerCore
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
  case incomes, schedule, vacations, goal, breaks, general
  static let storageKey = "settingsTab"

  var id: Self { self }

  var title: String {
    switch self {
    case .incomes: "Доходы"
    case .schedule: "График"
    case .vacations: "Отпуска"
    case .goal: "Цели"
    case .breaks: "Перерывы"
    case .general: "Общее"
    }
  }

  var icon: String {
    switch self {
    case .incomes: "banknote"
    case .schedule: "clock"
    case .vacations: "beach.umbrella"
    case .goal: "target"
    case .breaks: "cup.and.saucer"
    case .general: "gearshape"
    }
  }
}

struct SettingsView: View {
  static let windowID = "settings"

  let model: AppModel
  @AppStorage(SettingsTab.storageKey) private var tab = SettingsTab.incomes.rawValue
  @State private var draft = TimerCore.Settings()
  @State private var error: String?
  @State private var loaded = false

  var body: some View {
    NavigationSplitView {
      List(SettingsTab.allCases, selection: selection) { tab in
        Label(tab.title, systemImage: tab.icon).tag(tab)
      }
      .navigationSplitViewColumnWidth(170)
      .toolbar(removing: .sidebarToggle)
    } detail: {
      VStack(spacing: 0) {
        content(for: SettingsTab(rawValue: tab) ?? .incomes)
        if let error {
          Text(error).foregroundStyle(.red).font(.callout).padding(8).frame(maxWidth: .infinity)
        }
      }
      .navigationTitle((SettingsTab(rawValue: tab) ?? .incomes).title)
    }
    .frame(width: 720, height: 540)
    .onAppear {
      draft = model.settings
      loaded = true
    }
    .onChange(of: model.settings) { _, new in
      // Keep the form in sync with changes made elsewhere (e.g. a goal marked achieved).
      if error == nil { draft = new }
    }
    .onChange(of: draft) { _, new in
      guard loaded, new != model.settings else { return }
      error = model.apply(new)?.message
    }
  }

  private var selection: Binding<SettingsTab?> {
    Binding(get: { SettingsTab(rawValue: tab) ?? .incomes }, set: { if let new = $0 { tab = new.rawValue } })
  }

  @ViewBuilder private func content(for tab: SettingsTab) -> some View {
    switch tab {
    case .incomes: IncomesTab(settings: $draft, fx: model.fx)
    case .schedule: ScheduleTab(schedule: $draft.schedule)
    case .vacations: VacationsTab(vacations: $draft.vacations, today: model.today)
    case .goal: GoalsTab(goals: $draft.goals, today: model.today)
    case .breaks: BreaksTab(breaks: $draft.breaks, planned: model.plannedBreaks(with: draft))
    case .general: GeneralTab(settings: $draft, dataDirectory: model.dataDirectory)
    }
  }
}

// MARK: - Bindings between model values and pickers

private extension Binding where Value == TimeOfDay {
  var date: Binding<Date> {
    Binding<Date>(
      get: { LocalDate(year: 2000, month: 1, day: 1).date(at: wrappedValue, calendar: .current) },
      set: {
        let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
        wrappedValue = TimeOfDay(hour: c.hour ?? 0, minute: c.minute ?? 0)
      })
  }
}

private extension Binding where Value == LocalDate {
  var date: Binding<Date> {
    Binding<Date>(
      get: { wrappedValue.date(at: TimeOfDay(hour: 12, minute: 0), calendar: .current) },
      set: { wrappedValue = LocalDate($0, calendar: .current) })
  }
}

/// A binding to one element of a list, found by id. Unlike `ForEach($array)`, it survives the
/// element being removed: SwiftUI may read a row's binding once more after deletion, and an
/// index-based binding then reads past the end of the array and traps.
private func binding<E: Identifiable>(_ array: Binding<[E]>, for element: E) -> Binding<E> {
  Binding(
    get: { array.wrappedValue.first { $0.id == element.id } ?? element },
    set: { new in
      if let i = array.wrappedValue.firstIndex(where: { $0.id == element.id }) { array.wrappedValue[i] = new }
    })
}

// MARK: - Tabs

private struct BreaksTab: View {
  @Binding var breaks: BreakSettings
  let planned: Int

  var body: some View {
    Form {
      Section {
        Toggle("Включены", isOn: $breaks.enabled)
        Stepper(value: $breaks.workMinutes, in: BreakSettings.workRange, step: 5) {
          LabeledContent("Работать подряд", value: "\(breaks.workMinutes) мин")
        }
        .disabled(!breaks.enabled)
        Stepper(value: $breaks.lengthMinutes, in: BreakSettings.lengthRange) {
          LabeledContent("Перерыв", value: "\(breaks.lengthMinutes) мин")
        }
        .disabled(!breaks.enabled)
        if breaks.enabled {
          Text("→ \(planned) \(Self.word(planned)) в день по графику").foregroundStyle(.secondary)
        }
      }
      Section {
        Text("Экран перерыва перекрывает все мониторы. Его можно перенести на 5–15 минут, но не больше двух раз, или скипнуть — скипы считаются за день. Если ты сам отошёл от компа на время перерыва, он засчитывается. Во время созвона перерыв ждёт конца звонка. В обед, в выходные, в отпуск и после «Закончил» перерывов нет.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  static func word(_ n: Int) -> String {
    switch (n % 10, n % 100) {
    case (1, let h) where h != 11: "перерыв"
    case (2...4, let h) where !(12...14).contains(h): "перерыва"
    default: "перерывов"
    }
  }
}

private struct IncomesTab: View {
  @Binding var settings: TimerCore.Settings
  let fx: FXRates?

  var body: some View {
    Form {
      Section("Оклады в месяц, на руки") {
        if settings.incomes.isEmpty {
          Text("Добавь хотя бы один доход").foregroundStyle(.secondary)
        }
        ForEach(settings.incomes) { element in
          let income = binding($settings.incomes, for: element)
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              TextField("Название", text: income.name)
              Button(role: .destructive) {
                settings.incomes.removeAll { $0.id == element.id }
              } label: { Image(systemName: "trash") }
              .buttonStyle(.borderless)
              .help("Удалить доход")
            }
            HStack {
              TextField("Сумма", value: income.amount, format: .number)
                .multilineTextAlignment(.trailing)
              Picker("Валюта", selection: income.currency) {
                ForEach(Currency.allCases) { Text($0.symbol).tag($0) }
              }
              .pickerStyle(.segmented)
              .labelsHidden()
              .frame(width: 110)
            }
            if let converted = converted(element.amount, from: element.currency) {
              Text(converted).font(.caption).foregroundStyle(.secondary)
            }
            PayoutsEditor(payouts: income.payouts)
          }
          .padding(.vertical, 2)
        }
        Button("Добавить доход") {
          settings.incomes.append(Income(name: "Доход \(settings.incomes.count + 1)", amount: 100_000, currency: .rub))
        }
      }
      Section {
        Text("Выплаты: в какие дни и какая доля оклада приходит, например аванс 40% 25-го и остаток 60% 10-го. Если день выпадает на выходной или праздник, деньги приходят в предыдущий рабочий день.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Отображение") {
        Picker("Показывать в", selection: $settings.displayCurrency) {
          ForEach(Currency.allCases) { Text("\($0.symbol) \($0.rawValue)").tag($0) }
        }
        .pickerStyle(.segmented)
        if let total {
          LabeledContent("Итого в месяц", value: total)
        }
        Text(fx.map { "Курс ЦБ РФ от \($0.date.shortDisplay): $ = \(rub($0.rubPer(.usd))), € = \(rub($0.rubPer(.eur))). На рабочий день курс фиксируется утром." }
          ?? "Курс ЦБ ещё не загружен — доходы в $ и € пока не учитываются.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private func rub(_ value: Double?) -> String {
    value.map { String(format: "%.2f ₽", $0) } ?? "—"
  }

  /// `≈ €4,432.10 в месяц` when the income is in another currency than the display one.
  private func converted(_ amount: Double, from currency: Currency) -> String? {
    guard currency != settings.displayCurrency, let rub = fx?.toRUB(amount, from: currency),
          let text = MoneyFormatter.format(rub: rub, in: settings.displayCurrency, fx: fx) else { return nil }
    return "≈ \(text) в месяц"
  }

  private var total: String? {
    var rub = 0.0
    for income in settings.incomes {
      guard let value = income.currency == .rub ? income.amount : fx?.toRUB(income.amount, from: income.currency) else { return nil }
      rub += value
    }
    return settings.incomes.isEmpty ? nil : MoneyFormatter.format(rub: rub, in: settings.displayCurrency, fx: fx)
  }
}

/// Paydays of one income with the share of the monthly amount each brings.
private struct PayoutsEditor: View {
  @Binding var payouts: [Payout]

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(payouts) { element in
        let payout = binding($payouts, for: element)
        HStack {
          Stepper("Выплата \(element.day)-го числа", value: payout.day, in: 1...31)
          Spacer()
          TextField("Доля", value: payout.percent, format: .number)
            .multilineTextAlignment(.trailing)
            .frame(width: 44)
            .labelsHidden()
          Text("%")
          Button(role: .destructive) {
            payouts.removeAll { $0.id == element.id }
          } label: { Image(systemName: "minus.circle") }
          .buttonStyle(.borderless)
          .help("Удалить выплату")
        }
        .font(.callout)
      }
      Button(payouts.isEmpty ? "Указать день выплаты" : "Добавить выплату") { add() }
        .buttonStyle(.link)
        .font(.callout)
    }
  }

  /// The new payout takes what is left of 100%, or half of the last one when nothing is left.
  private func add() {
    let left = 100 - payouts.reduce(0) { $0 + $1.percent }
    if payouts.isEmpty {
      payouts.append(Payout(day: 10, percent: 100))
    } else if left > 0 {
      payouts.append(Payout(day: 25, percent: left))
    } else {
      let half = payouts[payouts.count - 1].percent / 2
      payouts[payouts.count - 1].percent -= half
      payouts.append(Payout(day: 25, percent: max(half, 1)))
    }
  }
}

private struct ScheduleTab: View {
  @Binding var schedule: Schedule

  var body: some View {
    Form {
      Section("Рабочий день") {
        DatePicker("Начало", selection: $schedule.start.date, displayedComponents: .hourAndMinute)
        DatePicker("Конец", selection: $schedule.end.date, displayedComponents: .hourAndMinute)
        DatePicker("Обед (1 час) с", selection: $schedule.lunchStart.date, displayedComponents: .hourAndMinute)
      }
      Section {
        Text("Обед входит в рабочий день, деньги идут и в обед. Дневная сумма (ставка × 8 ч) распределяется по графику равномерно. В предпраздничные дни конец наступает на час раньше.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}

private struct VacationsTab: View {
  @Binding var vacations: [VacationRange]
  let today: LocalDate

  var body: some View {
    Form {
      Section("Отпуска") {
        if vacations.isEmpty {
          Text("Отпусков нет").foregroundStyle(.secondary)
        }
        ForEach(vacations) { element in
          let range = binding($vacations, for: element)
          HStack {
            DatePicker("С", selection: range.from.date, displayedComponents: .date)
            DatePicker("по", selection: range.to.date, displayedComponents: .date)
            Button(role: .destructive) {
              vacations.removeAll { $0.id == element.id }
            } label: { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless)
          }
        }
        Button("Добавить отпуск") {
          vacations.append(VacationRange(from: today, to: today.adding(days: 13, calendar: .current)))
        }
      }
      Section {
        Text("Для внезапного отгула или больничного есть кнопка «Сегодня не работаю» в меню.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }
}

private struct GoalsTab: View {
  @Binding var goals: [Goal]
  let today: LocalDate

  var body: some View {
    Form {
      if goals.isEmpty {
        Section("Накопительные цели") {
          Text("Цель наполняется долей заработка с сегодняшнего дня и не сбрасывается в начале месяца. Если на неё уже что-то отложено, укажи это в «Уже накоплено».")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      ForEach(goals) { element in
        let goal = binding($goals, for: element)
        Section("С \(element.createdOn.shortDisplay)\(element.achievedOn != nil ? " · 🎉 достигнута" : "")") {
          HStack {
            TextField("Название", text: goal.name)
            Button(role: .destructive) {
              goals.removeAll { $0.id == element.id }
            } label: { Image(systemName: "trash") }
            .buttonStyle(.borderless)
            .help("Удалить цель")
          }
          HStack {
            TextField("Сумма", value: goal.amount, format: .number)
              .multilineTextAlignment(.trailing)
            Picker("Валюта", selection: goal.currency) {
              ForEach(Currency.allCases) { Text($0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 110)
          }
          TextField("Уже накоплено, \(element.currency.symbol)", value: goal.initialSaved, format: .number)
            .multilineTextAlignment(.trailing)
          Stepper("Откладываю \(element.percent)% заработка", value: goal.percent, in: 1...100, step: 5)
        }
      }
      Section {
        Button("Добавить цель") {
          goals.append(Goal(name: "Мечта", amount: 100_000, currency: .rub, percent: max(1, min(100, 100 - allocated)), createdOn: today))
        }
        if goals.count > 1 {
          Text("На цели уходит \(allocated)% заработка").font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
  }

  private var allocated: Int { goals.filter { $0.achievedOn == nil }.reduce(0) { $0 + $1.percent } }
}

private struct GeneralTab: View {
  @Binding var settings: TimerCore.Settings
  let dataDirectory: URL

  var body: some View {
    Form {
      Section {
        Toggle("Запускать при входе в систему", isOn: $settings.launchAtLogin)
      }
      Section("Данные") {
        LabeledContent("Папка", value: dataDirectory.path(percentEncoded: false))
        Button("Открыть в Finder") { NSWorkspace.shared.open(dataDirectory) }
      }
    }
    .formStyle(.grouped)
  }
}
