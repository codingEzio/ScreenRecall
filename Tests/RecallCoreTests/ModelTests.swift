import CoreGraphics
import Foundation
import ImageIO
import RecallCore
import Testing
import UniformTypeIdentifiers

@testable import ScreenRecall

@MainActor
func eventually(_ condition: () -> Bool) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(4))
  while !condition() && ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(condition())
}

@MainActor
func eventuallyAsync(_ condition: () async throws -> Bool) async throws {
  let deadline = ContinuousClock.now.advanced(by: .seconds(4))
  while !(try await condition()) && ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(try await condition())
}

@MainActor @Test func reopeningSourceClearsCancelledCatalogBusyState() {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let model = RecallModel(
    configURL: root.appending(path: "preferences.json"), sourceOverride: "/synthetic/screenshots")
  model.catalogBusy = true
  model.openSource()
  #expect(!model.catalogBusy)
}

@MainActor @Test func rapidSelectionNeverSettlesOnAnOlderFrame() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let directory = root.appending(path: "screenshots/2026/09/06/14")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let context = try #require(
    CGContext(
      data: nil, width: 64, height: 32, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
  for time in [1_788_674_400, 1_788_674_460, 1_788_674_520] {
    let destination = try #require(
      CGImageDestinationCreateWithURL(
        directory.appending(path: "\(time).png") as CFURL, UTType.png.identifier as CFString, 1, nil
      ))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
  }
  let model = RecallModel(
    configURL: root.appending(path: "preferences.json"), sourceOverride: root.path)
  model.openSource()
  try await eventually { model.captures.count == 3 && model.decoded != nil }
  model.editingTimeline(true)
  for index in [0, 2, 1, 0, 2, 0, 1] { model.choose(index) }
  model.editingTimeline(false)
  try await eventually { model.displayedURL == model.current?.url && model.decoded != nil }
  #expect(model.selection == 1)
  #expect(model.displayedURL?.lastPathComponent == "1788674460.png")
  #expect(model.imageError == nil)
}

@MainActor @Test func scrubbingThroughAGapKeepsThePlayheadAndArrowsFindTheNextCapture()
  async throws
{
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let morning = 1_788_674_400.0
  let evening = morning + 8 * 3600
  try writeHistoryFixture(root.appending(path: "screenshots/2026/09/06/14/\(Int(morning)).png"))
  try writeHistoryFixture(root.appending(path: "screenshots/2026/09/06/22/\(Int(evening)).png"))
  let model = RecallModel(
    configURL: root.appending(path: "preferences.json"), sourceOverride: root.path)
  model.openSource()
  try await eventually { model.captures.count == 2 && model.decoded != nil }
  model.editingTimeline(true)
  let gap = morning + 3600
  model.scrub(to: gap)
  #expect(abs(model.playheadTime - gap) < 1)
  #expect(model.current?.timestamp == morning)
  model.editingTimeline(false)
  #expect(abs(model.playheadTime - gap) < 1)
  model.navigateBySwipe(1)
  #expect(model.current?.timestamp == evening)
  #expect(abs(model.playheadTime - evening) < 1)
}

@Test func screenshotZoomKeepsThePinchFocusStationary() {
  let size = CGSize(width: 200, height: 100)
  let offset = ScreenshotZoom.offset(
    keepingFocus: CGPoint(x: 50, y: 25), in: size, baseOffset: .zero, baseScale: 1, newScale: 2)
  #expect(abs(offset.width - 50) < 0.001)
  #expect(abs(offset.height - 25) < 0.001)
  let clamped = ScreenshotZoom.clamped(
    CGSize(width: 400, height: 400), scale: 1, fitted: CGSize(width: 200, height: 100),
    view: size)
  #expect(clamped == .zero)
  let zoomed = ScreenshotZoom.clamped(
    CGSize(width: 400, height: 400), scale: 2, fitted: CGSize(width: 200, height: 100),
    view: size)
  #expect(zoomed.width == 100)
  #expect(zoomed.height == 50)
}

@MainActor @Test func timelineCoversEmptyHoursOfTheSelectedDay() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = .current
  let dayStart = calendar.date(from: DateComponents(year: 2026, month: 9, day: 6))!
  let afternoon = calendar.date(bySettingHour: 15, minute: 0, second: 0, of: dayStart)!
  try writeHistoryFixture(
    root.appending(
      path: "screenshots/2026/09/06/15/\(Int(afternoon.timeIntervalSince1970)).png"))
  let model = RecallModel(
    configURL: root.appending(path: "preferences.json"), sourceOverride: root.path)
  model.openSource()
  try await eventually { model.captures.count == 1 && model.selectedDay != nil }
  let bounds = Timeline.dayBounds(for: try #require(model.selectedDay), calendar: calendar)
  #expect(model.timeRange == bounds)
  #expect(model.captures[0].timestamp > model.timeRange.lowerBound + 8 * 3600)
}

@MainActor @Test func reviewPlaybackMovesFramesAndStopsAtTheEnd() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  for time in [1_788_674_400, 1_788_674_460, 1_788_674_520] {
    try writeHistoryFixture(root.appending(path: "screenshots/2026/09/06/14/\(time).png"))
  }
  let model = RecallModel(
    configURL: root.appending(path: "preferences.json"), sourceOverride: root.path)
  model.openSource()
  try await eventually { model.captures.count == 3 && model.decoded != nil }
  model.playbackRate = .four
  model.startPlayback()
  try await eventually { model.isPlaying && model.selection == 1 }
  model.stopPlayback()
  #expect(!model.isPlaying)

  model.choose(2)
  model.startPlayback()
  #expect(model.selection == 0)
  model.stopPlayback()
}

@MainActor @Test func reviewAnnotationSurvivesReload() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let image = root.appending(path: "screenshots/2026/09/06/14/1788674400.png")
  try writeHistoryFixture(image)
  let config = root.appending(path: "preferences.json")
  let model = RecallModel(configURL: config, sourceOverride: root.path)
  model.openSource()
  try await eventually { model.captures.count == 1 && model.decoded != nil && !model.catalogBusy }
  model.annotationMarked = true
  model.annotationDraft = "Review this moment"
  model.saveAnnotation()
  try await eventually {
    model.currentAnnotation.marked && model.currentAnnotation.note == "Review this moment"
      && model.annotations.count == 1
  }

  let reloaded = RecallModel(configURL: config, sourceOverride: root.path)
  reloaded.openSource()
  try await eventually {
    reloaded.captures.count == 1 && reloaded.currentAnnotation.marked
      && reloaded.currentAnnotation.note == "Review this moment"
      && reloaded.annotations.count == 1
  }
}

@Test func displayWallUsesKnownHorizontalArrangement() {
  #expect(
    DisplayWallLayout.resolve(
      mode: .automatic,
      aspectRatios: [16.0 / 9.0, 16.0 / 9.0],
      displayOrigins: [DisplayOrigin(x: 0, y: 0), DisplayOrigin(x: 2_992, y: 0)],
      width: 1_200,
      height: 700)
      == .sideBySide)
  #expect(
    DisplayWallLayout.resolve(
      mode: .automatic, aspectRatios: [16.0 / 9.0, 9.0 / 16.0], width: 420, height: 760)
      == .stacked)
}

@Test func displayWallAutomaticFollowsPhysicalDisplayArrangement() {
  let vertical = [DisplayOrigin(x: 0, y: 0), DisplayOrigin(x: 0, y: 1_934)]
  let horizontal = [DisplayOrigin(x: 0, y: 0), DisplayOrigin(x: 2_992, y: 0)]
  let ratios = [16.0 / 9.0, 16.0 / 9.0]

  #expect(
    DisplayWallLayout.resolve(
      mode: .automatic, aspectRatios: ratios, displayOrigins: vertical, width: 1_200, height: 700)
      == .stacked)
  #expect(
    DisplayWallLayout.resolve(
      mode: .automatic, aspectRatios: ratios, displayOrigins: vertical, width: 700, height: 1_200)
      == .stacked)
  #expect(
    DisplayWallLayout.resolve(
      mode: .automatic, aspectRatios: ratios, displayOrigins: horizontal, width: 700, height: 1_200)
      == .sideBySide)
  #expect(
    DisplayWallLayout.resolve(
      mode: .automatic, aspectRatios: ratios, width: 1_200, height: 700)
      == .stacked)
}

@Test func displayWallHonorsAnExplicitArrangement() {
  #expect(
    DisplayWallLayout.resolve(
      mode: .stacked, aspectRatios: [16.0 / 9.0, 16.0 / 9.0], width: 1_200, height: 700)
      == .stacked)
  #expect(
    DisplayWallLayout.resolve(
      mode: .sideBySide, aspectRatios: [9.0 / 16.0, 9.0 / 16.0], width: 420, height: 760)
      == .sideBySide)
}

@MainActor @Test func savingSettingsKeepsARecoverablePreviousVersion() throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let config = root.appending(path: "preferences.json")
  let model = RecallModel(configURL: config, sourceOverride: "/synthetic/screenshots")
  model.savePreferences()
  model.preferences.appearance = "light"
  model.savePreferences()
  let backup = root.appending(path: "preferences.previous.json")
  #expect(FileManager.default.fileExists(atPath: backup.path))
  let restored = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: backup))
  #expect(restored.appearance == "system")
  model.savePreferences()
  #expect(
    try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: backup)).appearance
      == "system")
  let permissions =
    try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? Int
  #expect(permissions == 0o600)
}

@MainActor @Test func preferencesPreserveUnknownKeysAndRejectExternalChanges() throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let config = root.appending(path: "preferences.json")
  let initial = Data(#"{"source":"/fixture","futureOption":{"enabled":true}}"#.utf8)
  try initial.write(to: config)

  let model = RecallModel(configURL: config, sourceOverride: "/fixture")
  model.preferences.appearance = "dark"
  model.savePreferences()
  let saved = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
  #expect(saved["futureOption"] as? [String: Bool] == ["enabled": true])
  #expect(saved["appearance"] as? String == "dark")

  let external = Data(#"{"source":"/other","futureOption":{"enabled":false}}"#.utf8)
  try external.write(to: config, options: .atomic)
  model.preferences.appearance = "light"
  model.savePreferences()
  #expect(try Data(contentsOf: config) == external)
  #expect(model.notice?.contains("其他地方變更") == true)
  #expect(model.faults.recentCodes().contains("preferences.conflict"))
}

@Test func recordingIntentRoundTripsAsAnExplicitPreference() throws {
  let data = Data(
    #"{"source":"/fixture","recordingIntent":"active","recording":{"intervalSeconds":900}}"#.utf8)
  let preferences = try JSONDecoder().decode(Preferences.self, from: data)
  try preferences.validate()
  #expect(preferences.recordingIntent == .active)
  let encoded = try JSONEncoder().encode(preferences)
  #expect(String(decoding: encoded, as: UTF8.self).contains("active"))
}

@MainActor @Test func diagnosticReportNeverIncludesSourceOrCapturePaths() throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let model = RecallModel(
    configURL: root.appending(path: "preferences.json"),
    sourceOverride: "/sensitive-personal-folder/screenshots")
  model.displayedURL = URL(fileURLWithPath: "/sensitive-personal-folder/example.jpeg")
  let report = model.diagnosticReport()
  #expect(!report.contains("sensitive-personal-folder"))
  #expect(!report.contains("example.jpeg"))
  let parsed = try JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any]
  #expect(parsed?["recent_fault_codes"] is [Any])
  #expect(parsed?["fault_journal_disabled"] is Bool)
  #expect(
    parsed?["source_access"] as? String
      == "owned image pool; app-owned SQLite index, annotations and view state")
}

@MainActor @Test func legacyDatabasesAreNotRequiredForImageHistory() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try writeHistoryFixture(root.appending(path: "screenshots/2026/09/06/14/1788674400.png"))
  try Data("not a sqlite database".utf8).write(to: root.appending(path: "usage.sqlite"))
  try Data("not a sqlite database".utf8).write(to: root.appending(path: "text.sqlite"))

  let model = RecallModel(
    configURL: root.appending(path: "preferences.json"), sourceOverride: root.path)
  model.openSource()
  try await eventually {
    model.captures.count == 1 && !model.catalogBusy && model.decoded != nil
  }

  #expect(model.catalogError == nil)
  #expect(model.catalogIndexedCaptures == 1)
}

@MainActor @Test func bootstrapLoadsHistoryWithoutAWindowTask() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try writeHistoryFixture(root.appending(path: "screenshots/2026/09/06/14/1788674400.png"))

  let model = RecallModel(
    configURL: root.appending(path: "preferences.json"), sourceOverride: root.path)
  model.bootstrap()
  model.bootstrap()
  try await eventually {
    model.captures.count == 1 && !model.catalogBusy && model.decoded != nil
  }

  #expect(model.error == nil)
  #expect(model.catalogError == nil)
}

@MainActor @Test func bootstrapPrefersTodayAndItsLatestCaptureOverSavedHistory() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let calendar = Calendar.current
  let today = calendar.startOfDay(for: .now)
  let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: today))
  let historicalTime = yesterday.addingTimeInterval(12 * 3600).timeIntervalSince1970
  let newestTime = today.addingTimeInterval(60).timeIntervalSince1970
  try writeHistoryFixture(historyFixtureURL(root: root, timestamp: historicalTime))
  try writeHistoryFixture(historyFixtureURL(root: root, timestamp: newestTime - 30))
  try writeHistoryFixture(historyFixtureURL(root: root, timestamp: newestTime))

  let catalog = try CaptureCatalog(databaseURL: root.appending(path: "catalog.sqlite"))
  try await catalog.saveViewState(
    dayKey: historyDayKey(yesterday, calendar: calendar), timestamp: historicalTime)
  let model = RecallModel(
    configURL: root.appending(path: "preferences.json"), sourceOverride: root.path)
  model.bootstrap()
  try await eventually {
    model.selectedDay?.id == historyDayKey(today, calendar: calendar)
      && model.current?.timestamp == newestTime && model.decoded != nil
  }
}

@MainActor @Test func goToNowDiscoversANewTodayAndSelectsItsLatestCapture() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let calendar = Calendar.current
  let today = calendar.startOfDay(for: .now)
  let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: today))
  let historicalTime = yesterday.addingTimeInterval(12 * 3600).timeIntervalSince1970
  try writeHistoryFixture(historyFixtureURL(root: root, timestamp: historicalTime))

  let model = RecallModel(
    configURL: root.appending(path: "preferences.json"), sourceOverride: root.path)
  model.openSource()
  try await eventually { model.current?.timestamp == historicalTime && model.decoded != nil }

  let newestTime = today.addingTimeInterval(60).timeIntervalSince1970
  try writeHistoryFixture(historyFixtureURL(root: root, timestamp: newestTime - 30))
  try writeHistoryFixture(historyFixtureURL(root: root, timestamp: newestTime))
  model.goToNow()
  try await eventually {
    model.selectedDay?.id == historyDayKey(today, calendar: calendar)
      && model.current?.timestamp == newestTime && model.decoded != nil
  }
}

@Test func previousPreferencesKeepSourceAndGainSafeDefaults() throws {
  let data = Data(#"{"source":"/fixture","previewPixels":1280,"appearance":"dark"}"#.utf8)
  let preferences = try JSONDecoder().decode(Preferences.self, from: data)
  try preferences.validate()
  #expect(preferences.source == "/fixture")
  #expect(preferences.previewPixels == 1280)
  #expect(preferences.appearance == "dark")
  #expect(preferences.language == .system)
  #expect(preferences.recording.intervalSeconds == 900)
  #expect(!preferences.showInDock)
}

@Test func previousDockChoiceMigratesOnceToTheMenuBarOnlyDefault() throws {
  let oldData = Data(#"{"source":"/fixture","showInDock":true}"#.utf8)
  let migrated = try JSONDecoder().decode(Preferences.self, from: oldData)
  #expect(!migrated.showInDock)

  let currentData = Data(
    #"{"source":"/fixture","showInDock":true,"dockPresentationVersion":1}"#.utf8)
  let current = try JSONDecoder().decode(Preferences.self, from: currentData)
  #expect(current.showInDock)
}

@Test func subMinuteDailyPreferencesMigrateToTheNormalProfile() throws {
  let data = Data(
    #"{"source":"/fixture","recording":{"intervalSeconds":3,"scale":1,"quality":0.8,"format":"heic","mode":"everyInterval"}}"#
      .utf8)
  let preferences = try JSONDecoder().decode(Preferences.self, from: data)
  try preferences.validate()
  #expect(preferences.recording.intervalSeconds == RecordingOptions.defaultIntervalSeconds)
}

func writeHistoryFixture(_ url: URL) throws {
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  let context = try #require(
    CGContext(
      data: nil, width: 64, height: 32, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
  let output = try #require(
    CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
  CGImageDestinationAddImage(output, try #require(context.makeImage()), nil)
  #expect(CGImageDestinationFinalize(output))
}

private func historyFixtureURL(root: URL, timestamp: TimeInterval) -> URL {
  let date = Date(timeIntervalSince1970: timestamp)
  let components = Calendar.current.dateComponents([.year, .month, .day, .hour], from: date)
  return root.appending(
    path: String(
      format: "screenshots/%04d/%02d/%02d/%02d/%d.png", components.year ?? 0,
      components.month ?? 0, components.day ?? 0, components.hour ?? 0, Int(timestamp)))
}

private func historyDayKey(_ date: Date, calendar: Calendar) -> String {
  let components = calendar.dateComponents([.year, .month, .day], from: date)
  return String(
    format: "%04d/%02d/%02d", components.year ?? 0, components.month ?? 0,
    components.day ?? 0)
}

@MainActor @Test func demoModeDoesNotReadTheRealCaptureLibrary() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let fixture = root.appending(path: "Demo")
  try writeHistoryFixture(fixture.appending(path: "screenshots/2026/09/06/14/1788674400.png"))
  let realCapture = root.appending(path: "CaptureLibrary")
  try writeHistoryFixture(
    realCapture.appending(path: "screenshots/2026/09/07/14/1788760800.png"))

  let model = RecallModel(
    configURL: root.appending(path: "preferences.json"),
    sourceOverride: fixture.path,
    demoOverride: true)
  model.openSource()
  try await eventually {
    model.captures.count == 1 && model.decoded != nil && !model.catalogBusy
      && model.catalogError == nil
  }

  #expect(model.days.map(\.id) == ["2026/09/06"])
  #expect(model.captures.first?.date == Date(timeIntervalSince1970: 1_788_674_400))
  #expect(model.ownLibrary.path != realCapture.path)
  #expect(
    FileManager.default.fileExists(atPath: model.ownLibrary.appending(path: "catalog.sqlite").path))
}

@MainActor @Test func commandLineDemoKeepsCatalogBesideSyntheticFixture() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let fixture = root.appending(path: "Demo")
  try writeHistoryFixture(fixture.appending(path: "screenshots/2026/09/06/14/1788674400.png"))
  let model = RecallModel(arguments: ["ScreenRecall", "--library", fixture.path])
  model.openSource()
  try await eventually {
    model.captures.count == 1 && !model.catalogBusy && model.catalogError == nil
  }
  #expect(model.ownLibrary == root.appending(path: ".screenrecall-demo-captures"))
  #expect(model.preferences.source == fixture.path)
  #expect(model.preferences.recordingIntent == .paused)
  #expect(FileManager.default.fileExists(atPath: model.ownLibrary.appending(path: "catalog.sqlite").path))
  #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".screenrecall-demo-state/preferences.json").path))
}

@MainActor @Test func searchLocatesIndexedCaptureWithoutOCR() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try writeHistoryFixture(
    root.appending(path: "screenshots/2026/09/06/14/1788674400_monitor-a.png"))
  try writeHistoryFixture(
    root.appending(path: "screenshots/2026/09/06/15/1788678000_monitor-b.png"))

  let model = RecallModel(
    configURL: root.appending(path: "preferences.json"), sourceOverride: root.path)
  model.openSource()
  try await eventually { model.captures.count == 2 && model.decoded != nil }
  model.searchQuery = "monitor-b"
  model.updateSearchResults()
  try await eventually { model.searchResults.count == 1 }

  let result = try #require(model.searchResults.first)
  #expect(result.capture.displayID == "monitor-b")
  model.chooseSearchResult(result)
  try await eventually {
    model.current?.timestamp == result.capture.timestamp && model.decoded != nil
  }
}

@MainActor @Test func searchMatchesRecordedDisplayName() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let capture = root.appending(path: "screenshots/2026/09/06/14/1788674400_monitor-b.png")
  try writeHistoryFixture(capture)
  let displays = [
    "monitor-b": RecordingDisplay(id: "monitor-b", name: "Portrait", width: 1_000, height: 1_600)
  ]
  try JSONEncoder().encode(displays).write(to: root.appending(path: "screenshots/displays.json"))

  let model = RecallModel(
    configURL: root.appending(path: "preferences.json"), sourceOverride: root.path)
  model.openSource()
  try await eventually { model.captures.count == 1 }
  #expect(model.error == nil)
  model.searchQuery = "Portrait"
  model.updateSearchResults()
  try await eventually { model.searchResults.count == 1 }
  #expect(model.searchResults.first?.capture.displayID == "monitor-b")
}

@MainActor @Test func newRecordingsFollowLatestButPreserveHistoricalSelection() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let old = root.appending(path: "legacy/screenshots/2026/09/06/14")
  try writeHistoryFixture(old.appending(path: "1788674400.png"))
  try writeHistoryFixture(old.appending(path: "1788674460.png"))
  let model = RecallModel(
    configURL: root.appending(path: "preferences.json"),
    sourceOverride: root.appending(path: "legacy").path)
  model.openSource()
  try await eventually { model.captures.count == 2 && model.decoded != nil }
  let own = model.ownLibrary.appending(path: "screenshots/2026/09/06/14")
  try writeHistoryFixture(own.appending(path: "1788674520_a.png"))
  try writeHistoryFixture(own.appending(path: "1788674520_b.png"))
  await model.refreshRecordingHistory()
  #expect(model.captures.count == 3)
  #expect(model.current?.timestamp == 1_788_674_520)
  #expect(model.currentGroup.count == 2)
  model.choose(0)
  let selected = model.current?.id
  try writeHistoryFixture(own.appending(path: "1788674580_a.png"))
  await model.refreshRecordingHistory()
  #expect(model.captures.count == 4)
  #expect(model.current?.id == selected)
  model.choose(model.captures.count - 1)
  model.editingTimeline(true)
  let dragging = model.current?.id
  try writeHistoryFixture(own.appending(path: "1788674640_a.png"))
  await model.refreshRecordingHistory()
  #expect(model.current?.id == dragging)
  #expect(model.captures.count == 5)
  model.editingTimeline(false)
}

@MainActor @Test func refreshedOneShotCaptureReachesTheOwnedCatalog() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let legacy = root.appending(path: "legacy")
  try writeHistoryFixture(legacy.appending(path: "screenshots/2026/09/06/14/1788674400.png"))
  let model = RecallModel(
    configURL: root.appending(path: "preferences.json"), sourceOverride: legacy.path)
  model.openSource()
  try await eventually { model.captures.count == 1 && !model.catalogBusy && model.decoded != nil }

  try writeHistoryFixture(
    model.ownLibrary.appending(path: "screenshots/2026/09/06/14/1788674460.webp"))
  await model.refreshRecordingHistory()

  let catalog = try CaptureCatalog(databaseURL: root.appending(path: "catalog.sqlite"))
  try await eventuallyAsync { try await catalog.currentCaptureCount() == 2 }
  #expect(model.captures.count == 2)
}

@MainActor @Test func recordingRefreshCrossesMidnightWithoutMovingAnOlderDay() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let legacy = root.appending(path: "legacy")
  try writeHistoryFixture(legacy.appending(path: "screenshots/2026/09/06/23/1788710340.png"))
  let model = RecallModel(
    configURL: root.appending(path: "preferences.json"), sourceOverride: legacy.path)
  model.openSource()
  // Finish the initial index before simulating later recorded days.
  try await eventually { model.decoded != nil && !model.catalogBusy }
  try writeHistoryFixture(
    model.ownLibrary.appending(path: "screenshots/2026/09/07/00/1788710400_a.png"))
  await model.refreshRecordingHistory()
  #expect(model.selectedDay?.id == "2026/09/07")
  #expect(model.days.count == 2)
  model.moveDay(-1)
  // Day selection publishes before its asynchronous frames/preview arrive.
  // Wait for the historical frame itself; a non-nil previous preview is insufficient.
  try await eventually {
    model.selectedDay?.id == "2026/09/06"
      && model.current?.timestamp == 1_788_710_340
      && model.displayedURL == model.current?.url && model.decoded != nil
  }
  let historical = model.current?.id
  try writeHistoryFixture(
    model.ownLibrary.appending(path: "screenshots/2026/09/07/00/1788710460_a.png"))
  await model.refreshRecordingHistory()
  #expect(model.selectedDay?.id == "2026/09/06")
  #expect(model.current?.id == historical)
}

@MainActor @Test func frameNavigationCrossesAdjacentRecordedDays() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let legacy = root.appending(path: "legacy")
  try writeHistoryFixture(legacy.appending(path: "screenshots/2026/09/06/23/1788710340.png"))
  try writeHistoryFixture(legacy.appending(path: "screenshots/2026/09/07/00/1788710400.png"))
  let model = RecallModel(
    configURL: root.appending(path: "preferences.json"), sourceOverride: legacy.path)
  model.openSource()
  try await eventually { model.selectedDay?.id == "2026/09/07" && model.decoded != nil }

  #expect(model.canNavigate(-1))
  model.navigateBySwipe(-1)
  try await eventually { model.selectedDay?.id == "2026/09/06" && model.decoded != nil }
  #expect(model.current?.timestamp == 1_788_710_340)

  #expect(model.canNavigate(1))
  model.navigateBySwipe(1)
  try await eventually { model.selectedDay?.id == "2026/09/07" && model.decoded != nil }
  #expect(model.current?.timestamp == 1_788_710_400)

  try await Task.sleep(for: .milliseconds(400))
  let restored = RecallModel(
    configURL: root.appending(path: "preferences.json"), sourceOverride: legacy.path)
  restored.openSource()
  try await eventually {
    restored.selectedDay?.id == "2026/09/07"
      && restored.current?.timestamp == 1_788_710_400
      && restored.decoded != nil
  }
}

@MainActor @Test func forecastUsesWholeCyclesAndInvalidatesOnQualityChanges() throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let model = RecallModel(
    configURL: root.appending(path: "preferences.json"), sourceOverride: root.path)
  model.connectedDisplays = [
    RecordingDisplay(id: "a", name: "A", width: 4096, height: 2304),
    RecordingDisplay(id: "b", name: "B", width: 2992, height: 1934),
  ]
  model.preferences.recording.intervalSeconds = 600
  model.rememberRecordingMeasurement(
    RecordingMeasurement(
      options: model.preferences.recording,
      displays: model.connectedDisplays, bytesByDisplay: ["a": 309_314, "b": 194_302]))
  #expect(model.recordingCapacityEstimate?.averageBytesPerDay == 72_520_704)
  #expect(model.averageBytes(for: "a") == 309_314)
  model.burstIntervalSeconds = 1
  model.burstDurationMinutes = 5
  #expect(model.burstEstimatedBytes == 151_084_800)
  model.preferences.recording.quality = 0.2
  #expect(model.recordingCapacityEstimate == nil)
  #expect(model.burstEstimatedBytes == nil)
  model.preferences.recording.quality = 0.3
  model.preferences.recording.intervalSeconds = 900
  #expect(model.recordingCapacityEstimate?.averageBytesPerDay == 48_347_136)
}

@MainActor @Test func sleepSuspensionStopsTheLoopButKeepsActiveIntent() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let model = RecallModel(
    configURL: root.appending(path: "preferences.json"), sourceOverride: "/synthetic/screenshots")
  model.preferences.recordingIntent = .active
  model.isRecording = true

  model.prepareForSleep()
  try await eventually { !model.isRecording && !model.recordingBusy }

  #expect(model.preferences.recordingIntent == .active)
  model.preferences.recordingIntent = .paused
  model.resumeAfterWake()
  #expect(!model.isRecording)
}

@MainActor @Test func displaySleepWaitsForAnAwakeDisplayWithoutLosingRecordingIntent()
  async throws
{
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let model = RecallModel(
    configURL: root.appending(path: "preferences.json"), sourceOverride: "/synthetic/screenshots")
  model.preferences.recordingIntent = .active
  model.isRecording = true

  model.prepareForSleep()
  try await eventually { !model.isRecording && !model.recordingBusy }
  #expect(model.isWaitingForScreen)
  #expect(model.preferences.recordingIntent == .active)

  model.resumeAfterWake(displaysAwake: false)
  #expect(model.isWaitingForScreen)
  model.pauseRecording()
  try await eventually { !model.recordingBusy }
  model.resumeAfterWake(displaysAwake: true)
  #expect(!model.isWaitingForScreen)
  #expect(model.preferences.recordingIntent == .paused)
}

@MainActor @Test func displaySleepEndsPausedBurstWithoutCreatingDailyIntent() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let model = RecallModel(
    configURL: root.appending(path: "preferences.json"), sourceOverride: "/synthetic/screenshots")
  model.preferences.recordingIntent = .paused
  model.isRecording = true
  model.isBurstRecording = true

  model.prepareForSleep()
  try await eventually { !model.isRecording && !model.recordingBusy }
  #expect(!model.isBurstRecording)
  #expect(!model.isWaitingForScreen)
  #expect(model.preferences.recordingIntent == .paused)
}

@MainActor @Test func displaySleepEndsBurstAndKeepsPriorDailyIntent() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let model = RecallModel(
    configURL: root.appending(path: "preferences.json"), sourceOverride: "/synthetic/screenshots")
  model.preferences.recordingIntent = .active
  model.isRecording = true
  model.isBurstRecording = true

  model.prepareForSleep()
  try await eventually { !model.isRecording && !model.recordingBusy }
  #expect(!model.isBurstRecording)
  #expect(model.isWaitingForScreen)
  #expect(model.preferences.recordingIntent == .active)
}

@Test func missingVisualThemeUsesMonochromeWithoutChangingTypographyOrAppearance() throws {
  let data = Data(#"{"source":"/synthetic","typography":"compact","appearance":"dark"}"#.utf8)
  let preferences = try JSONDecoder().decode(Preferences.self, from: data)
  #expect(preferences.visualTheme == .monochrome)
  #expect(preferences.typography == .compact)
  #expect(preferences.appearance == "dark")
}

@Test func classicVisualThemeSurvivesPreferenceRoundtrip() throws {
  var preferences = Preferences(source: "/synthetic")
  preferences.visualTheme = .classic
  let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
  #expect(decoded.visualTheme == .classic)
}

@Test func unknownVisualThemeFallsBackToMonochrome() throws {
  let data = Data(#"{"source":"/synthetic","visualTheme":"future"}"#.utf8)
  #expect(try JSONDecoder().decode(Preferences.self, from: data).visualTheme == .monochrome)
}
