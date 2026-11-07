import Foundation

public struct Capture: Identifiable, Hashable, Sendable {
  public var id: URL { url }
  public let url: URL
  public let timestamp: TimeInterval
  public let displayID: String?
  public var date: Date { Date(timeIntervalSince1970: timestamp) }
  public init(url: URL, timestamp: TimeInterval, displayID: String? = nil) {
    self.url = url
    self.timestamp = timestamp
    self.displayID = displayID
  }
}

public enum Timeline {
  public static func groups(_ captures: [Capture], displayID: String? = nil) -> [[Capture]] {
    let filtered = captures.filter { displayID == nil || ($0.displayID ?? "legacy") == displayID }
    let groups = Dictionary(grouping: filtered) {
      $0.displayID == nil ? $0.url.path : "\($0.timestamp)"
    }
    return groups.values.map { $0.sorted { $0.url.path < $1.url.path } }.sorted {
      let a = $0[0]
      let b = $1[0]
      return a.timestamp == b.timestamp ? a.url.path < b.url.path : a.timestamp < b.timestamp
    }
  }

  public static func nearest(to time: TimeInterval, in captures: [Capture]) -> Int? {
    guard !captures.isEmpty, time.isFinite else { return nil }
    var low = 0
    var high = captures.count
    while low < high {
      let middle = (low + high) / 2
      if captures[middle].timestamp < time { low = middle + 1 } else { high = middle }
    }
    if low == 0 { return 0 }
    if low == captures.count { return low - 1 }
    return time - captures[low - 1].timestamp <= captures[low].timestamp - time ? low - 1 : low
  }

  public static func step(
    from time: TimeInterval, direction: Int, in captures: [Capture]
  ) -> Int? {
    guard !captures.isEmpty, direction != 0, time.isFinite else { return nil }
    // Capture metadata is sorted by time. Keep navigation off the linear scan
    // path, since button availability is also queried during every scrub update.
    let threshold = time + (direction > 0 ? 0.05 : -0.05)
    var low = 0
    var high = captures.count
    while low < high {
      let middle = (low + high) / 2
      let beforeBoundary =
        direction > 0
        ? captures[middle].timestamp <= threshold : captures[middle].timestamp < threshold
      if beforeBoundary { low = middle + 1 } else { high = middle }
    }
    if direction > 0 { return low < captures.count ? low : nil }
    return low > 0 ? low - 1 : nil
  }

  public struct RulerMark: Equatable, Sendable, Identifiable {
    public var id: TimeInterval { timestamp }
    public let timestamp: TimeInterval
    public let major: Bool
  }

  public static func dayBounds(
    for day: CaptureDay, calendar: Calendar = .current
  ) -> ClosedRange<TimeInterval> {
    let start = calendar.startOfDay(for: day.date)
    let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    return start.timeIntervalSince1970...end.timeIntervalSince1970
  }

  public static func rulerMarks(
    in range: ClosedRange<TimeInterval>, calendar: Calendar = .current
  ) -> [RulerMark] {
    guard range.upperBound > range.lowerBound, range.lowerBound.isFinite, range.upperBound.isFinite
    else { return [] }
    let span = range.upperBound - range.lowerBound
    let stepMinutes: Int
    let majorMinutes: Int
    if span >= 16 * 3600 {
      stepMinutes = 180
      majorMinutes = 180
    } else if span >= 5 * 3600 {
      stepMinutes = 60
      majorMinutes = 60
    } else if span >= 90 * 60 {
      stepMinutes = 15
      majorMinutes = 60
    } else {
      stepMinutes = 5
      majorMinutes = 15
    }
    let startDate = Date(timeIntervalSince1970: range.lowerBound)
    let endDate = Date(timeIntervalSince1970: range.upperBound)
    guard let first = flooredDate(startDate, stepMinutes: stepMinutes, calendar: calendar) else {
      return []
    }
    var marks: [RulerMark] = []
    var date = first
    var steps = 0
    let last = endDate.addingTimeInterval(0.5)
    while date <= last, steps < 400 {
      let timestamp = date.timeIntervalSince1970
      if timestamp >= range.lowerBound - 0.5, timestamp <= range.upperBound + 0.5 {
        let minuteOfDay =
          calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        let isDayEnd =
          timestamp >= range.upperBound - 0.5
          && calendar.component(.hour, from: date) == 0
          && calendar.component(.minute, from: date) == 0
        marks.append(
          RulerMark(timestamp: timestamp, major: isDayEnd || minuteOfDay % majorMinutes == 0))
      }
      guard let next = calendar.date(byAdding: .minute, value: stepMinutes, to: date) else { break }
      date = next
      steps += 1
    }
    return marks
  }

  public static func rulerLabel(
    _ timestamp: TimeInterval, range: ClosedRange<TimeInterval>, calendar: Calendar = .current
  ) -> String {
    let date = Date(timeIntervalSince1970: timestamp)
    let hour = calendar.component(.hour, from: date)
    let minute = calendar.component(.minute, from: date)
    if hour == 0, minute == 0, timestamp >= range.upperBound - 0.5 {
      return "24"
    }
    if minute == 0 { return String(hour) }
    return String(format: "%d:%02d", hour, minute)
  }

  private static func flooredDate(
    _ date: Date, stepMinutes: Int, calendar: Calendar
  ) -> Date? {
    var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    let minuteOfDay = (components.hour ?? 0) * 60 + (components.minute ?? 0)
    let rounded = minuteOfDay / stepMinutes * stepMinutes
    components.hour = rounded / 60
    components.minute = rounded % 60
    components.second = 0
    components.nanosecond = 0
    return calendar.date(from: components)
  }
}

public struct CaptureDay: Identifiable, Hashable, Sendable {
  public let id: String
  public let date: Date
  public let url: URL

  public var catalogDayKey: String { Self.catalogDayKey(from: id) }

  public static func catalogDayKey(from folderID: String) -> String {
    folderID.replacingOccurrences(of: "/", with: "-")
  }

  public static func folderID(fromCatalogDayKey key: String) -> String {
    key.replacingOccurrences(of: "-", with: "/")
  }

  public static func fromCatalog(dayKey: String, screenshots: URL) -> CaptureDay? {
    let folderID = folderID(fromCatalogDayKey: dayKey)
    let parts = folderID.split(separator: "/").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    var components = DateComponents()
    components.year = parts[0]
    components.month = parts[1]
    components.day = parts[2]
    guard let date = calendar.date(from: components) else { return nil }
    return CaptureDay(id: folderID, date: date, url: screenshots.appending(path: folderID))
  }
}

public enum LibraryError: LocalizedError {
  case invalidRoot
  case unreadableImage
  public var errorDescription: String? {
    switch self {
    case .invalidRoot: "找不到 ScreenRecall 圖片資料夾。請選擇 ScreenRecall 資料夾或 screenshots。"
    case .unreadableImage: "無法讀取這張截圖。檔案可能已移動、尚未寫完或已損壞。"
    }
  }
}

/// Reads the dated image tree only. It never opens or mutates the legacy databases.
public actor CaptureLibrary {
  public nonisolated let screenshots: URL
  public init(root: URL) throws {
    let candidates = [
      root.appending(path: "ScreenMemoryData/screenshots"),
      root.appending(path: "screenshots"), root,
    ]
    guard
      let directory = candidates.first(where: {
        var isDirectory: ObjCBool = false
        return $0.lastPathComponent == "screenshots"
          && FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory)
          && isDirectory.boolValue
      })
    else { throw LibraryError.invalidRoot }
    screenshots = directory.resolvingSymlinksInPath()
  }

  public func days() throws -> [CaptureDay] {
    let calendar = Calendar(identifier: .gregorian)
    var result: [CaptureDay] = []
    for year in try directories(screenshots, digits: 4) {
      for month in try directories(year, digits: 2) {
        for day in try directories(month, digits: 2) {
          try Task.checkCancellation()
          let components = DateComponents(
            year: Int(year.lastPathComponent),
            month: Int(month.lastPathComponent), day: Int(day.lastPathComponent))
          guard let date = calendar.date(from: components),
            calendar.dateComponents([.year, .month, .day], from: date) == components
          else { continue }
          result.append(
            CaptureDay(
              id: "\(year.lastPathComponent)/\(month.lastPathComponent)/\(day.lastPathComponent)",
              date: date, url: day))
        }
      }
    }
    return result.sorted { $0.id < $1.id }
  }

  public func captures(on day: CaptureDay) throws -> [Capture] {
    guard day.url.resolvingSymlinksInPath().path.hasPrefix(screenshots.path + "/") else {
      throw LibraryError.invalidRoot
    }
    var result: [Capture] = []
    for hour in try directories(day.url, digits: 2) {
      try Task.checkCancellation()
      for url in try FileManager.default.contentsOfDirectory(
        at: hour,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles])
      {
        let parts = url.deletingPathExtension().lastPathComponent.split(
          separator: "_", maxSplits: 1)
        guard ["jpg", "jpeg", "png", "heic", "webp"].contains(url.pathExtension.lowercased()),
          let first = parts.first, let timestamp = Double(first),
          timestamp.isFinite, timestamp > 0, timestamp < 253_402_300_800
        else { continue }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
        let displayID = parts.count == 2 ? String(parts[1]) : nil
        result.append(Capture(url: url, timestamp: timestamp, displayID: displayID))
      }
    }
    return result.sorted {
      $0.timestamp == $1.timestamp ? $0.url.path < $1.url.path : $0.timestamp < $1.timestamp
    }
  }

  public func fileSizeStats() throws -> CaptureSizeStats? {
    try fileSizeSummary().allFiles
  }

  /// Reads files in this dated image tree without opening legacy databases or image pixels.
  public func fileSizeSummary(asOf: Date = Date()) throws -> CaptureLibraryFileSizeSummary {
    var sizes: [Int64] = []
    var last24HoursCount = 0
    var last24HoursBytes: Int64 = 0
    var last7DaysCount = 0
    var last7DaysBytes: Int64 = 0
    var last30DaysCount = 0
    var last30DaysBytes: Int64 = 0
    let asOfTimestamp = asOf.timeIntervalSince1970

    for day in try days() {
      for capture in try captures(on: day) {
        try Task.checkCancellation()
        guard let size = try capture.url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
          size > 0
        else { continue }
        let byteCount = Int64(size)
        sizes.append(byteCount)

        let age = asOfTimestamp - capture.timestamp
        guard age >= 0 else { continue }
        if age < 86_400 {
          last24HoursCount += 1
          last24HoursBytes += byteCount
        }
        if age < 7 * 86_400 {
          last7DaysCount += 1
          last7DaysBytes += byteCount
        }
        if age < 30 * 86_400 {
          last30DaysCount += 1
          last30DaysBytes += byteCount
        }
      }
    }
    return CaptureLibraryFileSizeSummary(
      allFiles: CaptureSizeStats(sizes: sizes),
      recent: RecentCaptureFileSizeStats(
        last24Hours: CaptureFileSizeWindow(fileCount: last24HoursCount, byteCount: last24HoursBytes),
        last7Days: CaptureFileSizeWindow(fileCount: last7DaysCount, byteCount: last7DaysBytes),
        last30Days: CaptureFileSizeWindow(fileCount: last30DaysCount, byteCount: last30DaysBytes)),
      readAt: asOf)
  }

  public func displayNames() -> [String: String] {
    guard let data = try? Data(contentsOf: screenshots.appending(path: "displays.json")),
      let values = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]]
    else { return [:] }
    return values.compactMapValues { $0["name"] as? String }
  }

  private func directories(_ parent: URL, digits: Int) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: parent,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    )
    .filter {
      let name = $0.lastPathComponent
      guard name.count == digits, name.allSatisfy({ $0.isASCII && $0.isNumber }) else {
        return false
      }
      let values = try $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      return values.isDirectory == true && values.isSymbolicLink != true
    }
  }
}

/// One read view across legacy history and the app-owned recording library.
public actor CaptureArchive {
  private let libraries: [CaptureLibrary]
  private var sources: [String: [(CaptureLibrary, CaptureDay)]] = [:]
  public init(roots: [URL]) throws {
    var seen = Set<String>()
    libraries = try roots.compactMap {
      let library = try CaptureLibrary(root: $0)
      return seen.insert(library.screenshots.path).inserted ? library : nil
    }
  }

  public func days() async throws -> [CaptureDay] {
    sources = [:]
    for library in libraries {
      for day in try await library.days() { sources[day.id, default: []].append((library, day)) }
    }
    return sources.keys.sorted().compactMap { sources[$0]?.first?.1 }
  }

  public func captures(on day: CaptureDay) async throws -> [Capture] {
    var captures: [Capture] = []
    for (library, sourceDay) in sources[day.id] ?? [] {
      captures += try await library.captures(on: sourceDay)
    }
    return captures.sorted {
      $0.timestamp == $1.timestamp ? $0.url.path < $1.url.path : $0.timestamp < $1.timestamp
    }
  }

  public func displayNames() async -> [String: String] {
    var names: [String: String] = [:]
    for library in libraries { names.merge(await library.displayNames()) { first, _ in first } }
    return names
  }
}
