import Foundation
import Testing

@testable import RecallCore

@Test func nearestCaptureHonorsGapsAndBounds() {
  let captures = [10.0, 20, 100].map {
    Capture(url: URL(fileURLWithPath: "/\($0).jpeg"), timestamp: $0)
  }
  #expect(Timeline.nearest(to: 0, in: captures) == 0)
  #expect(Timeline.nearest(to: 21, in: captures) == 1)
  #expect(Timeline.nearest(to: 90, in: captures) == 2)
  #expect(Timeline.nearest(to: 999, in: captures) == 2)
  #expect(Timeline.nearest(to: 30, in: []) == nil)
}

@Test func timelineStepCrossesGapsWithoutSnappingToTheNearestCapture() {
  let captures = [10.0, 20, 100].map {
    Capture(url: URL(fileURLWithPath: "/\($0).jpeg"), timestamp: $0)
  }
  #expect(Timeline.step(from: 10, direction: 1, in: captures) == 1)
  #expect(Timeline.step(from: 10, direction: -1, in: captures) == nil)
  #expect(Timeline.step(from: 55, direction: 1, in: captures) == 2)
  #expect(Timeline.step(from: 55, direction: -1, in: captures) == 1)
  #expect(Timeline.step(from: 100, direction: 1, in: captures) == nil)
  #expect(Timeline.step(from: 100, direction: -1, in: captures) == 1)
  #expect(Timeline.step(from: 20, direction: 1, in: captures) == 2)
  #expect(Timeline.nearest(to: 55, in: captures) == 1)
}

@Test func libraryUsesImagesWithoutOCRAndRejectsEscapingLinks() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let folder = root.appending(path: "ScreenMemoryData/screenshots/2026/09/06/17")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  for name in [
    "1788685930.jpeg", "1788685210.png", "1788685210.123_monitor-a.heic", "invalid.jpeg",
    "1788685211.txt",
  ] {
    try Data().write(to: folder.appending(path: name))
  }
  try FileManager.default.createSymbolicLink(
    at: folder.appending(path: "1788685212.jpeg"),
    withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
  let library = try CaptureLibrary(root: root)
  let days = try await library.days()
  #expect(days.map(\.id) == ["2026/09/06"])
  let captures = try await library.captures(on: #require(days.first))
  #expect(captures.map(\.timestamp) == [1_788_685_210, 1_788_685_210.123, 1_788_685_930])
  #expect(!FileManager.default.fileExists(atPath: root.appending(path: "text.sqlite").path))
}

@Test func invalidSourceIsAnError() {
  #expect(throws: (any Error).self) {
    try CaptureLibrary(root: URL(fileURLWithPath: "/nonexistent-screenrecall-library"))
  }
}

@Test func simultaneousDisplaysShareOneMomentAndKeepLegacyFrames() {
  let frames = [
    Capture(url: URL(fileURLWithPath: "/old/10.jpeg"), timestamp: 10),
    Capture(url: URL(fileURLWithPath: "/new/20_a.heic"), timestamp: 20, displayID: "a"),
    Capture(url: URL(fileURLWithPath: "/new/20_b.heic"), timestamp: 20, displayID: "b"),
    Capture(url: URL(fileURLWithPath: "/new/30_a.heic"), timestamp: 30, displayID: "a"),
  ]
  #expect(Timeline.groups(frames).map(\.count) == [1, 2, 1])
  #expect(Timeline.groups(frames, displayID: "b").map(\.count) == [1])
  #expect(Timeline.groups(frames, displayID: "legacy").first?.first?.timestamp == 10)
}

@Test func archiveCombinesSameDayAcrossReadOnlyRoots() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let roots = [root.appending(path: "old"), root.appending(path: "new")]
  for (index, folder) in roots.enumerated() {
    let day = folder.appending(path: "screenshots/2026/09/06/14")
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    try Data().write(to: day.appending(path: "\(1_788_674_400 + index).jpeg"))
  }
  let archive = try CaptureArchive(roots: roots + [roots[0]])
  let days = try await archive.days()
  #expect(days.count == 1)
  #expect(try await archive.captures(on: #require(days.first)).count == 2)
}

@Test func timelineRulerMarksAFullTaipeiDayEveryThreeHours() {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
  let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 8))!
  let day = CaptureDay(id: "2026/09/08", date: start, url: URL(fileURLWithPath: "/tmp/2026/09/08"))
  let range = Timeline.dayBounds(for: day, calendar: calendar)
  let marks = Timeline.rulerMarks(in: range, calendar: calendar)
  #expect(range.upperBound - range.lowerBound == 86_400)
  #expect(marks.map(\.major) == Array(repeating: true, count: 9))
  #expect(
    marks.map { Timeline.rulerLabel($0.timestamp, range: range, calendar: calendar) } == [
      "0", "3", "6", "9", "12", "15", "18", "21", "24",
    ])
}

@Test func timelineRulerMarksATwoHourWindowOnTheQuarterHour() {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
  let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 8, hour: 14))!
  let end = calendar.date(from: DateComponents(year: 2026, month: 9, day: 8, hour: 16))!
  let range = start.timeIntervalSince1970...end.timeIntervalSince1970
  let marks = Timeline.rulerMarks(in: range, calendar: calendar)
  #expect(
    marks.map { Timeline.rulerLabel($0.timestamp, range: range, calendar: calendar) } == [
      "14", "14:15", "14:30", "14:45", "15", "15:15", "15:30", "15:45", "16",
    ])
  #expect(marks.map(\.major) == [true, false, false, false, true, false, false, false, true])
}

@Test func navigationPreservesToleranceAndDuplicateTimeBoundaries() {
  for count in [1, 10_000] {
    let captures = (0..<count).map { index in
      Capture(url: URL(fileURLWithPath: "/fixture/\(index).png"), timestamp: Double(index / 2))
    }
    for time in [-1.0, 0, 0.049, 0.05, 0.051, 1, 2500, 4998.949, 4999, 10000] {
      #expect(
        Timeline.step(from: time, direction: 1, in: captures)
          == captures.firstIndex { $0.timestamp > time + 0.05 })
      #expect(
        Timeline.step(from: time, direction: -1, in: captures)
          == captures.lastIndex { $0.timestamp < time - 0.05 })
    }
  }
}
