import Foundation
import Testing

@testable import RecallCore

@Test func captureSizeStatsUseInterpolatedPercentiles() throws {
  let stats = try #require(CaptureSizeStats(sizes: [100, 200, 300, 400]))
  #expect(stats.sampleCount == 4)
  #expect(stats.averageBytes == 250)
  #expect(stats.p50Bytes == 250)
  #expect(stats.p95Bytes == 385)
}

@Test func recordingCapacityEstimateScalesByIntervalAndDisplayCount() throws {
  let stats = try #require(CaptureSizeStats(sizes: [100, 200, 300, 400]))
  let estimate = try #require(
    RecordingCapacityEstimate(stats: stats, intervalSeconds: 60, displayCount: 2))
  #expect(estimate.averageBytesPerDay == 720_000)
  #expect(estimate.p50BytesPerDay == 720_000)
  #expect(estimate.p95BytesPerDay == 1_108_800)
  #expect(estimate.bytesPerDay(multiplier: 7) == 5_040_000)
}

@Test func captureLibraryReadsEncodedFileSizesWithoutDecoding() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let screenshots = root.appending(path: "screenshots/2026/09/06/14")
  try FileManager.default.createDirectory(at: screenshots, withIntermediateDirectories: true)
  for (index, size) in [100, 200, 400].enumerated() {
    let url = screenshots.appending(path: "178867440\(index)_display.heic")
    try Data(repeating: 1, count: size).write(to: url)
  }

  let library = try CaptureLibrary(root: root)
  let stats = try #require(await library.fileSizeStats())
  #expect(stats.sampleCount == 3)
  #expect(stats.averageBytes == 700.0 / 3.0)
  #expect(stats.p50Bytes == 200)
  #expect(stats.p95Bytes == 380)
}

@Test func measuredCyclesSumDisplaysAndRejectStaleEncodingProfiles() throws {
  let displays = [
    RecordingDisplay(id: "a", name: "A", width: 4096, height: 2304),
    RecordingDisplay(id: "b", name: "B", width: 2992, height: 1934),
  ]
  let profile = RecordingOptions(format: "webp")
  let sample = RecordingMeasurement(
    options: profile, displays: displays,
    bytesByDisplay: ["a": 309_314, "b": 194_302])
  #expect(sample.totalBytes == 503_616)
  #expect(sample.matches(options: profile, displays: displays))
  var changed = profile
  changed.intervalSeconds = 600
  #expect(sample.matches(options: changed, displays: displays))
  changed.quality = 0.2
  #expect(!sample.matches(options: changed, displays: displays))
  #expect(!sample.matches(options: profile, displays: Array(displays.prefix(1))))
  let incomplete = RecordingMeasurement(
    options: profile, displays: displays, bytesByDisplay: ["a": 123])
  #expect(!incomplete.matches(options: profile, displays: displays))
}

@Test func cadenceNeverBuildsAnOverdueCaptureBacklog() {
  #expect(RecordingCadence.delay(intervalSeconds: 1, elapsedSeconds: 0.3) == 0.7)
  #expect(RecordingCadence.delay(intervalSeconds: 1, elapsedSeconds: 2.4) == 1)
  #expect(RecordingCadence.retryDelay(intervalSeconds: 600, elapsedSeconds: 0.2) == 59.8)
  #expect(RecordingCadence.retryDelay(intervalSeconds: 5, elapsedSeconds: 0.2) == 4.8)
}
