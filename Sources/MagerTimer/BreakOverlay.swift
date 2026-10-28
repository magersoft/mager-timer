import AppKit
import TimerCore
import SwiftUI

/// Covers every screen, on every Space and over full-screen apps, while a break is on.
final class BreakOverlayController {
  private unowned let model: AppModel
  private var panels: [NSPanel] = []
  private var screensObserver: (any NSObjectProtocol)?
  private var savedOptions: NSApplication.PresentationOptions = []

  init(model: AppModel) {
    self.model = model
  }

  func update(_ screen: DaySnapshot.BreakScreen?) {
    if screen != nil, panels.isEmpty { show() }
    if screen == nil, !panels.isEmpty { hide() }
  }

  private func show() {
    savedOptions = NSApp.presentationOptions
    buildPanels()
    NSSound(named: "Hero")?.play()
    NSApp.activate()
    // Keeps ⌘Tab and ⌘H from leaving the break; Force Quit stays as the way out.
    NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching, .disableHideApplication]
    screensObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.closePanels()
        self?.buildPanels()
      }
    }
  }

  private func hide() {
    closePanels()
    NSApp.presentationOptions = savedOptions
    if let screensObserver { NotificationCenter.default.removeObserver(screensObserver) }
    screensObserver = nil
  }

  private func buildPanels() {
    let main = NSScreen.main ?? NSScreen.screens.first
    panels = NSScreen.screens.map { screen in
      let panel = BreakPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
      panel.level = .screenSaver
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = false
      panel.hidesOnDeactivate = false
      panel.isMovable = false
      panel.isReleasedWhenClosed = false
      panel.contentView = NSHostingView(rootView: BreakView(model: model, showsControls: screen == main))
      panel.setFrame(screen.frame, display: true)
      panel.orderFrontRegardless()
      if screen == main { panel.makeKey() }
      return panel
    }
  }

  private func closePanels() {
    for panel in panels { panel.orderOut(nil) }
    panels = []
  }
}

/// A break panel takes the keyboard and swallows the keys that would close or leave it.
private final class BreakPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  override func cancelOperation(_ sender: Any?) {}

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    // ⌘Q, ⌘W, ⌘H, ⌘M and the rest: only the buttons end a break.
    if event.modifierFlags.contains(.command) { return true }
    return super.performKeyEquivalent(with: event)
  }
}

struct BreakView: View {
  let model: AppModel
  /// Buttons and text go on the main screen; the others show just the timer.
  let showsControls: Bool
  @State private var snoozeMinutes = 5

  var body: some View {
    ZStack {
      Color.black.opacity(0.9).ignoresSafeArea()
      if let screen = model.snapshot.breakScreen {
        VStack(spacing: 16) {
          Image(systemName: "cup.and.saucer.fill").font(.system(size: 96))
          Text(screen.remaining).font(.system(size: 48, weight: .semibold, design: .rounded)).monospacedDigit()
          ProgressView(value: screen.fraction).frame(width: 280).tint(.white)
          if showsControls { details(screen) }
        }
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
      }
    }
    .environment(\.colorScheme, .dark)
  }

  @ViewBuilder private func details(_ screen: DaySnapshot.BreakScreen) -> some View {
    VStack(spacing: 8) {
      Text("Перерыв").font(.title.bold())
      Text(screen.prompt).font(.title3)
      if let earnings = screen.earnings { Text(earnings).font(.title3).foregroundStyle(.green) }
    }
    .padding(.top, 8)
    Text(screen.skipped).font(.headline).foregroundStyle(.orange)
    VStack(spacing: 10) {
      HStack(spacing: 8) {
        Picker("Перенести на", selection: $snoozeMinutes) {
          ForEach([5, 10, 15], id: \.self) { Text("\($0) мин").tag($0) }
        }
        .labelsHidden()
        .frame(width: 110)
        Button { model.snoozeBreak(minutes: snoozeMinutes) } label: {
          Text("Перенести").frame(maxWidth: .infinity)
        }
      }
      .disabled(!screen.canSnooze)
      if !screen.canSnooze {
        Text("Этот перерыв уже переносили дважды").font(.caption).foregroundStyle(.secondary)
      }
      Button { model.skipBreak() } label: { Text("Скипнуть").frame(maxWidth: .infinity) }
    }
    .controlSize(.large)
    .frame(width: 280)
    .padding(.top, 12)
  }
}
