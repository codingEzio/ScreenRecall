import Foundation
import RecallCore
import Testing

@testable import ScreenRecall

@MainActor @Test func displayFilterReadCostForTenThousandFrames() {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let model = RecallModel(
    configURL: root.appending(path: "preferences.json"), sourceOverride: "/fixture")
  model.dayImages = (0..<10_000).map { index in
    Capture(
      url: URL(fileURLWithPath: "/fixture/\(index).png"), timestamp: Double(index),
      displayID: index.isMultiple(of: 2) ? "display-a" : "display-b")
  }
  let start = ContinuousClock.now
  var count = 0
  for _ in 0..<2_000 { count += model.recordedDisplayIDs.count }
  let duration = start.duration(to: .now).components
  let milliseconds = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
  print("display_filter_10000_frames_2000_reads_ms=\(milliseconds)")
  #expect(count == 4_000)
  #expect(model.recordedDisplayIDs == ["display-a", "display-b"])
  model.dayImages = [Capture(url: URL(fileURLWithPath: "/fixture/one.png"), timestamp: 0)]
  #expect(model.recordedDisplayIDs == ["legacy"])
  model.dayImages = []
  #expect(model.recordedDisplayIDs.isEmpty)
}

@MainActor @Test func diagnosticsReportTheActualDecodeBudget() throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let model = RecallModel(
    configURL: root.appending(path: "preferences.json"), sourceOverride: "/fixture")
  let data = try #require(model.diagnosticReport().data(using: .utf8))
  let report = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect(report["cache_budget_mb"] as? Int == 192)
  #expect(report["max_decode_workers"] as? Int == 4)
}

@MainActor @Test func browsingReleasesDecodedFramesOutsideTheCurrentDisplayGroup() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let directory = root.appending(path: "screenshots/2026/09/06/14")
  let base = 1_788_674_400
  for index in 0..<12 {
    for screen in 0..<2 {
      try writeHistoryFixture(
        directory.appending(path: "\(base + index * 60)_display-\(screen).png"))
    }
  }
  let model = RecallModel(
    configURL: root.appending(path: "preferences.json"), sourceOverride: root.path)
  model.preferences.previewPixels = 1280
  model.openSource()
  try await eventually { model.captures.count == 12 && model.decodedScreens.count >= 2 }
  for index in 0..<12 {
    model.choose(index)
    try await eventually {
      model.displayedURL == model.current?.url
        && model.currentGroup.allSatisfy { model.decodedScreens[$0.url] != nil }
    }
    #expect(Set(model.decodedScreens.keys) == Set(model.currentGroup.map(\.url)))
  }
}

@Test func frameNavigationReadCostForTenThousandFrames() {
  let captures = (0..<10_000).map {
    Capture(url: URL(fileURLWithPath: "/fixture/\($0).png"), timestamp: Double($0))
  }
  let start = ContinuousClock.now
  var sum = 0
  for _ in 0..<2_000 {
    sum += Timeline.step(from: 5000, direction: 1, in: captures) ?? 0
    sum += Timeline.step(from: 5000, direction: -1, in: captures) ?? 0
  }
  let duration = start.duration(to: .now).components
  print(
    "navigation_10000_frames_4000_steps_ms=\(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)"
  )
  #expect(sum == 20_000_000)
}
