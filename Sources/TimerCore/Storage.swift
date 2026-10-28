import Foundation

/// JSON files under one directory (by default `~/Library/Application Support/MagerTimer`).
public struct Storage: Sendable {
  public let root: URL

  public init(root: URL) {
    self.root = root
  }

  public static var defaultRoot: URL {
    URL.applicationSupportDirectory.appending(path: "MagerTimer", directoryHint: .isDirectory)
  }

  /// Where the app kept its data before it was renamed from MagerMotivate.
  public static var legacyRoot: URL {
    URL.applicationSupportDirectory.appending(path: "MagerMotivate", directoryHint: .isDirectory)
  }

  /// Moves the whole folder once, so history and settings survive the rename. Does nothing if the new folder already exists.
  public static func migrate(from legacy: URL, to root: URL) throws {
    let fm = FileManager.default
    guard fm.fileExists(atPath: legacy.path(percentEncoded: false)),
          !fm.fileExists(atPath: root.path(percentEncoded: false)) else { return }
    try fm.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.moveItem(at: legacy, to: root)
  }

  private var historyDir: URL { root.appending(path: "history", directoryHint: .isDirectory) }
  private var settingsURL: URL { root.appending(path: "settings.json") }
  private var fxURL: URL { root.appending(path: "fx-latest.json") }
  private func calendarURL(_ year: Int) -> URL { root.appending(path: "calendar-\(year).txt") }
  private func monthURL(_ year: Int, _ month: Int) -> URL {
    historyDir.appending(path: String(format: "%04d-%02d.json", year, month))
  }

  private static let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    e.dateEncodingStrategy = .iso8601
    return e
  }()

  private static let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
  }()

  private func write(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
  }

  private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
    guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
    return try Self.decoder.decode(T.self, from: Data(contentsOf: url))
  }

  // MARK: Settings

  public func loadSettings() throws -> Settings? { try read(Settings.self, from: settingsURL) }

  public func save(_ settings: Settings) throws { try write(Self.encoder.encode(settings), to: settingsURL) }

  // MARK: History

  public func loadAllRecords() throws -> [DayRecord] {
    let files = (try? FileManager.default.contentsOfDirectory(at: historyDir, includingPropertiesForKeys: nil)) ?? []
    return try files.filter { $0.pathExtension == "json" }
      .flatMap { try read([DayRecord].self, from: $0) ?? [] }
      .sorted { $0.date < $1.date }
  }

  /// Inserts or replaces records, grouped into their month files.
  public func save(_ records: [DayRecord]) throws {
    let byMonth = Dictionary(grouping: records) { [$0.date.year, $0.date.month] }
    for (key, updates) in byMonth {
      let url = monthURL(key[0], key[1])
      var existing = Dictionary(uniqueKeysWithValues: (try read([DayRecord].self, from: url) ?? []).map { ($0.date, $0) })
      for record in updates { existing[record.date] = record }
      try write(Self.encoder.encode(existing.values.sorted { $0.date < $1.date }), to: url)
    }
  }

  // MARK: Caches

  public func loadCalendar(years: [Int]) -> WorkCalendar {
    var calendar = WorkCalendar()
    for year in years {
      if let raw = try? String(contentsOf: calendarURL(year), encoding: .utf8) { calendar.set(year: year, raw: raw) }
    }
    return calendar
  }

  public func saveCalendar(year: Int, raw: String) throws { try write(Data(raw.utf8), to: calendarURL(year)) }

  public func loadLatestFX() -> FXRates? { try? read(FXRates.self, from: fxURL) }

  public func saveLatestFX(_ fx: FXRates) throws { try write(Self.encoder.encode(fx), to: fxURL) }
}
