import Foundation

/// Observed encoded sizes for the app-owned recording library.
public struct CaptureSizeStats: Equatable, Sendable {
  public let sampleCount: Int
  public let averageBytes: Double
  public let p50Bytes: Double
  public let p95Bytes: Double

  public init?(sizes: [Int64]) {
    let values = sizes.filter { $0 > 0 }.sorted()
    guard !values.isEmpty else { return nil }

    sampleCount = values.count
    averageBytes = values.reduce(0.0) { $0 + Double($1) } / Double(values.count)
    p50Bytes = Self.percentile(values, at: 0.50)
    p95Bytes = Self.percentile(values, at: 0.95)
  }

  private static func percentile(_ values: [Int64], at fraction: Double) -> Double {
    guard values.count > 1 else { return Double(values[0]) }
    let position = Double(values.count - 1) * fraction
    let lower = Int(position.rounded(.down))
    let upper = Int(position.rounded(.up))
    guard lower != upper else { return Double(values[lower]) }
    let weight = position - Double(lower)
    return Double(values[lower]) + Double(values[upper] - values[lower]) * weight
  }
}

public struct CaptureFileSizeWindow: Equatable, Sendable {
  public let fileCount: Int
  public let byteCount: Int64
}

public struct RecentCaptureFileSizeStats: Equatable, Sendable {
  public let last24Hours: CaptureFileSizeWindow
  public let last7Days: CaptureFileSizeWindow
  public let last30Days: CaptureFileSizeWindow
}

public struct CaptureLibraryFileSizeSummary: Equatable, Sendable {
  public let allFiles: CaptureSizeStats?
  public let recent: RecentCaptureFileSizeStats
  public let readAt: Date
}

/// A deliberately approximate forecast based on observed encoded frame sizes.
/// It is a planning aid, not a quota or a fixed-size guarantee.
public struct RecordingCapacityEstimate: Equatable, Sendable {
  public let displayCount: Int
  public let intervalSeconds: Int
  public let averageBytesPerDay: Double
  public let p50BytesPerDay: Double
  public let p95BytesPerDay: Double

  public init?(
    stats: CaptureSizeStats, intervalSeconds: Int, displayCount: Int
  ) {
    guard intervalSeconds > 0, displayCount > 0 else { return nil }
    let framesPerDay = 86_400.0 / Double(intervalSeconds) * Double(displayCount)
    self.displayCount = displayCount
    self.intervalSeconds = intervalSeconds
    averageBytesPerDay = stats.averageBytes * framesPerDay
    p50BytesPerDay = stats.p50Bytes * framesPerDay
    p95BytesPerDay = stats.p95Bytes * framesPerDay
  }

  public init?(cycleStats: CaptureSizeStats, intervalSeconds: Int, displayCount: Int) {
    guard intervalSeconds > 0, displayCount > 0 else { return nil }
    self.displayCount = displayCount
    self.intervalSeconds = intervalSeconds
    let cyclesPerDay = 86_400.0 / Double(intervalSeconds)
    averageBytesPerDay = cycleStats.averageBytes * cyclesPerDay
    p50BytesPerDay = cycleStats.p50Bytes * cyclesPerDay
    p95BytesPerDay = cycleStats.p95Bytes * cyclesPerDay
  }

  public func bytesPerDay(multiplier: Double = 1) -> Double {
    averageBytesPerDay * multiplier
  }

  public func p50BytesPerDay(multiplier: Double = 1) -> Double {
    p50BytesPerDay * multiplier
  }

  public func p95BytesPerDay(multiplier: Double = 1) -> Double {
    p95BytesPerDay * multiplier
  }
}

/// One complete cycle. Encoding settings and physical display dimensions travel with
/// its byte counts, so a new quality or monitor never reuses unrelated file averages.
public struct RecordingMeasurement: Codable, Equatable, Sendable {
  public let date: Date
  public let format: String
  public let quality: Double
  public let scale: Double
  public let dimensions: [String: [Int]]
  public let bytesByDisplay: [String: Int64]

  public init(
    options: RecordingOptions, displays: [RecordingDisplay],
    bytesByDisplay: [String: Int64], date: Date = Date()
  ) {
    self.date = date
    format = options.format.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    quality = options.quality
    scale = options.scale
    dimensions = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, [$0.width, $0.height]) })
    self.bytesByDisplay = bytesByDisplay
  }

  public var totalBytes: Int64 { bytesByDisplay.values.reduce(0, +) }

  public func matches(options: RecordingOptions, displays: [RecordingDisplay]) -> Bool {
    let current = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, [$0.width, $0.height]) })
    return !dimensions.isEmpty && dimensions == current
      && Set(bytesByDisplay.keys) == Set(dimensions.keys)
      && bytesByDisplay.values.allSatisfy { $0 > 0 }
      && format == options.format.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      && abs(scale - options.scale) < 1e-9
      && (format == "png" || abs(quality - options.quality) < 1e-9)
  }
}

public struct RecordingPreview: Sendable {
  public let measurement: RecordingMeasurement
  public let urls: [URL]
}
