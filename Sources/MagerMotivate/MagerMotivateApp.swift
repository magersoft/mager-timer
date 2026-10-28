import SwiftUI

@main
struct MagerMotivateApp: App {
  @State private var model = AppModel()

  var body: some Scene {
    MenuBarExtra {
      MenuContentView(model: model)
    } label: {
      Text(model.snapshot.title)
        .monospacedDigit()
        .foregroundStyle(model.snapshot.isAlert ? .red : .primary)
    }
    .menuBarExtraStyle(.window)

    Window("Настройки MagerMotivate", id: SettingsView.windowID) {
      SettingsView(model: model)
    }
    .windowResizability(.contentSize)
    .defaultLaunchBehavior(.suppressed)
  }
}
