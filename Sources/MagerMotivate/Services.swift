import AppKit
import CoreAudio
import CoreMediaIO
import CoreGraphics
import Foundation
import MotivateCore
import os
import ServiceManagement
import UserNotifications

let log = Logger(subsystem: "com.magersoft.MagerMotivate", category: "app")

/// True when running from a real `.app` bundle; notifications and login items need one.
var isBundled: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

/// Reports how long the user has been idle; nil while the screen is locked or the Mac sleeps.
final class ActivityMonitor {
  private var isLocked = false
  private var isAsleep = false
  private var tokens: [any NSObjectProtocol] = []
  var onWake: (() -> Void)?

  init() {
    let workspace = NSWorkspace.shared.notificationCenter
    tokens.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.isAsleep = true }
    })
    tokens.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.isAsleep = false
        self?.onWake?()
      }
    })
    let distributed = DistributedNotificationCenter.default()
    tokens.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.isLocked = true }
    })
    tokens.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.isLocked = false
        self?.onWake?()
      }
    })
  }

  func idleSeconds() -> TimeInterval? {
    guard !isLocked, !isAsleep else { return nil }
    return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
  }
}

/// Production calendar and exchange rates from the network.
enum RemoteData {
  enum Failure: Error { case badStatus(Int) }

  private static func get(_ url: URL) async throws -> Data {
    var request = URLRequest(url: url)
    request.timeoutInterval = 20
    let (data, response) = try await URLSession.shared.data(for: request)
    if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw Failure.badStatus(http.statusCode) }
    return data
  }

  static func calendar(year: Int, calendar: Calendar) async throws -> String {
    let data = try await get(URL(string: "https://isdayoff.ru/api/getdata?year=\(year)&pre=1")!)
    return try WorkCalendar.validate(String(decoding: data, as: UTF8.self), year: year, calendar: calendar)
  }

  static func exchangeRates() async throws -> FXRates {
    try FXRates.parseCBR(try await get(URL(string: "https://www.cbr-xml-daily.ru/daily_json.js")!))
  }
}

enum LoginItem {
  static func apply(_ enabled: Bool) {
    guard isBundled else { return }
    let service = SMAppService.mainApp
    do {
      if enabled, service.status != .enabled { try service.register() }
      if !enabled, service.status == .enabled { try service.unregister() }
    } catch {
      log.error("Login item update failed: \(error.localizedDescription, privacy: .public)")
    }
  }
}

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
  static let endOfDayCategory = "END_OF_DAY"
  static let finishAction = "FINISHED"
  static let stillWorkingAction = "STILL_WORKING"
  static let breakSoonCategory = "BREAK_SOON"
  static let snoozeBreakAction = "SNOOZE_BREAK_5"

  private(set) var isAuthorized = false
  var onAction: ((String) -> Void)?

  func setUp() async {
    guard isBundled else { return }
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.setNotificationCategories([
      UNNotificationCategory(
        identifier: Self.endOfDayCategory,
        actions: [
          UNNotificationAction(identifier: Self.finishAction, title: "Закончил"),
          UNNotificationAction(identifier: Self.stillWorkingAction, title: "Ещё работаю"),
        ],
        intentIdentifiers: []),
      UNNotificationCategory(
        identifier: Self.breakSoonCategory,
        actions: [UNNotificationAction(identifier: Self.snoozeBreakAction, title: "Перенести на 5 мин")],
        intentIdentifiers: []),
    ])
    do {
      isAuthorized = try await center.requestAuthorization(options: [.alert, .sound])
    } catch {
      log.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  func post(title: String, body: String, category: String? = nil) {
    guard isBundled, isAuthorized else { return }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    if let category { content.categoryIdentifier = category }
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
    let action = response.actionIdentifier
    await MainActor.run { onAction?(action) }
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
    [.banner, .sound]
  }
}

/// Tells whether a call is likely on: some app holds a microphone or a camera. Reads only the
/// devices' "in use" flags, so it needs no permission.
enum CallDetector {
  static func isInCall() -> Bool { microphoneInUse() || cameraInUse() }

  private static func microphoneInUse() -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    let system = AudioObjectID(kAudioObjectSystemObject)
    guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return false }
    var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return false }
    return devices.contains { device in
      var streams = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
      var streamsSize: UInt32 = 0
      guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamsSize) == noErr, streamsSize > 0 else { return false }
      var running = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
      var value: UInt32 = 0
      var valueSize = UInt32(MemoryLayout<UInt32>.size)
      return AudioObjectGetPropertyData(device, &running, 0, nil, &valueSize, &value) == noErr && value != 0
    }
  }

  private static func cameraInUse() -> Bool {
    var address = CMIOObjectPropertyAddress(
      mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
      mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    let system = CMIOObjectID(kCMIOObjectSystemObject)
    var size: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return false }
    var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
    var used: UInt32 = 0
    guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == noErr else { return false }
    return devices.contains { device in
      var running = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
      var value: UInt32 = 0
      var valueUsed: UInt32 = 0
      return CMIOObjectGetPropertyData(device, &running, 0, nil, UInt32(MemoryLayout<UInt32>.size), &valueUsed, &value) == noErr
        && value != 0
    }
  }
}
