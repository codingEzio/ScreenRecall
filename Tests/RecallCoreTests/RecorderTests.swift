import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import RecallCore

@Test func recordingOptionsAcceptOnlySafeCaptureValues() throws {
  try RecordingOptions().validate()
  try RecordingOptions(intervalSeconds: 3, scale: 0.1, quality: 0, format: "JPEG").validate()
  #expect(RecordingOptions().intervalSeconds == 900)
  #expect(throws: (any Error).self) {
    try RecordingOptions(intervalSeconds: -1).validate()
  }
  #expect(throws: (any Error).self) {
    try RecordingOptions(intervalSeconds: 0).validate()
  }
  #expect(throws: (any Error).self) {
    try RecordingOptions(scale: 1.01).validate()
  }
  #expect(throws: (any Error).self) {
    try RecordingOptions(quality: .nan).validate()
  }
  #expect(throws: (any Error).self) {
    try RecordingOptions(format: "invalid").validate()
  }
}

@Test func oldRecordingPreferencesKeepEveryIntervalMode() throws {
  let data = Data(#"{"intervalSeconds":120,"scale":0.5,"quality":0.7,"format":"jpeg"}"#.utf8)
  let options = try JSONDecoder().decode(RecordingOptions.self, from: data)
  #expect(options.intervalSeconds == 120)
  #expect(options.scale == 0.5)
  #expect(options.quality == 0.7)
  #expect(options.format == "jpeg")
  #expect(options.mode == .everyInterval)
}

@Test func unchangedCyclePolicyPreservesCompleteMultiDisplayMoments() {
  let same = ["main": UInt64(10), "side": UInt64(20)]
  #expect(
    RecordingCyclePolicy.shouldPersist(
      mode: .skipUnchanged, signatures: same, previousSignatures: same) == false)
  #expect(
    RecordingCyclePolicy.shouldPersist(
      mode: .skipUnchanged, signatures: ["main": 11, "side": 20], previousSignatures: same))
  #expect(
    RecordingCyclePolicy.shouldPersist(
      mode: .skipUnchanged, signatures: ["main": 10], previousSignatures: same))
  #expect(
    RecordingCyclePolicy.shouldPersist(
      mode: .everyInterval, signatures: same, previousSignatures: same))
}

@Test func burstPlansAreBoundedAndDoNotChangeTheDailyCaptureProfile() throws {
  let plan = try #require(RecordingBurstPlan(intervalSeconds: 3, durationMinutes: 10))
  #expect(plan.cycleCount == 200)
  let base = RecordingOptions(intervalSeconds: 900, scale: 0.5, quality: 0.6, format: "heic")
  let burst = plan.options(from: base)
  #expect(burst.intervalSeconds == 3)
  #expect(burst.scale == base.scale)
  #expect(burst.quality == base.quality)
  #expect(burst.format == base.format)
  #expect(burst.mode == .everyInterval)
  #expect(RecordingBurstPlan(intervalSeconds: 2, durationMinutes: 10) == nil)
  #expect(RecordingBurstPlan(intervalSeconds: 60, durationMinutes: 10) == nil)
}

@Test func recordingStatusReportsSkippedCycles() {
  let status = RecordingStatus(
    isRecording: true, framesWritten: 4, cyclesSkipped: 3, lastCapture: nil, error: nil)
  #expect(status.cyclesSkipped == 3)
}

@Test func storageErrorIsVisibleAndDescriptive() {
  #expect(CaptureRecorderError.insufficientStorage.errorDescription == "儲存空間不足，記錄已停止。")
}

@Test func storagePreflightStopsOnlyWhenCapacityIsExhausted() throws {
  #expect(throws: CaptureRecorderError.insufficientStorage) {
    try CapturePersistence.requireAvailableStorage(0)
  }
  try CapturePersistence.requireAvailableStorage(1)
  try CapturePersistence.requireAvailableStorage(nil)
}

@Test func recorderStopsOnPermanentPersistenceErrorsButWaitsForTransientCaptureState() {
  #expect(CaptureRecorderError.imagePublishFailed.stopsRecording)
  #expect(CaptureRecorderError.invalidDisplayMetadata.stopsRecording)
  #expect(!CaptureRecorderError.noDisplaysAvailable.stopsRecording)
  #expect(!CaptureRecorderError.captureFailed.stopsRecording)
}

@Test func recordingDisplayReadsLegacyMetadataWithoutOrigins() throws {
  let data = Data(
    #"{"id":"display-1","name":"Fixture","width":1600,"height":1000}"#.utf8)
  let display = try JSONDecoder().decode(RecordingDisplay.self, from: data)
  #expect(display.id == "display-1")
  #expect(display.originX == nil)
  #expect(display.originY == nil)
}

@Test func persistenceKeepsSourcePixelsAndRefusesCollisions() throws {
  let root = FileManager.default.temporaryDirectory.appending(
    path: UUID().uuidString, directoryHint: .isDirectory)
  defer { try? FileManager.default.removeItem(at: root) }
  let prepared = try CapturePersistence.prepareRoot(root)
  let display = RecordingDisplay(id: "A0B1-C2D3", name: "Fixture", width: 80, height: 40)
  let date = Date(timeIntervalSince1970: 1_788_678_901.234)
  let destination = try CapturePersistence.destination(
    under: prepared, at: date, display: display, format: "jpeg")
  let context = try #require(
    CGContext(
      data: nil,
      width: 80,
      height: 40,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
  context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
  let image = try #require(context.makeImage())

  try CapturePersistence.write(image: image, to: destination, format: "jpeg", quality: 0.7)
  let source = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
  let properties = try #require(
    CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
  #expect(properties[kCGImagePropertyPixelWidth] as? Int == 80)
  #expect(properties[kCGImagePropertyPixelHeight] as? Int == 40)
  let original = try Data(contentsOf: destination)

  #expect(throws: CaptureRecorderError.self) {
    try CapturePersistence.write(image: image, to: destination, format: "jpeg", quality: 0.1)
  }
  #expect(try Data(contentsOf: destination) == original)
  let temporaryFiles = try FileManager.default.contentsOfDirectory(
    atPath: destination.deletingLastPathComponent().path
  )
  .filter { $0.hasPrefix(".") }
  #expect(temporaryFiles.isEmpty)
}

@Test func persistenceRejectsLinkedRootsAndUnsafeDisplayNames() throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let actual = root.appending(path: "actual")
  try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
  let link = root.appending(path: "linked")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
  #expect(throws: CaptureRecorderError.self) { try CapturePersistence.prepareRoot(link) }
  let safe = try CapturePersistence.prepareRoot(actual)
  #expect(throws: CaptureRecorderError.self) {
    try CapturePersistence.destination(
      under: safe, at: Date(),
      display: RecordingDisplay(id: "../escape", name: "Fixture", width: 80, height: 40),
      format: "heic")
  }
}

@Test func dailyDefaultsUseReviewedWebPQualityAndAllowOneSecondBursts() throws {
  let options = RecordingOptions()
  #expect(options.format == "webp")
  #expect(options.quality == 0.3)
  #expect(options.intervalSeconds == 900)
  try RecordingOptions(intervalSeconds: 1).validate()
  #expect(RecordingBurstPlan(intervalSeconds: 1, durationMinutes: 5)?.cycleCount == 300)
  #expect(RecordingBurstPlan(intervalSeconds: 15, durationMinutes: 5)?.cycleCount == 20)
}

@Test func webPCapturesRoundTripAsOneMultiDisplayMoment() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let prepared = try CapturePersistence.prepareRoot(root)
  let context = try #require(
    CGContext(
      data: nil, width: 80, height: 40, bitsPerComponent: 8,
      bytesPerRow: 320, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
  context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
  let image = try #require(context.makeImage())
  for id in ["screen-A", "screen-B"] {
    let url = try CapturePersistence.destination(
      under: prepared,
      at: Date(timeIntervalSince1970: 1_788_678_901.234),
      display: RecordingDisplay(id: id, name: id, width: 80, height: 40), format: "webp")
    try CapturePersistence.write(image: image, to: url, format: "webp", quality: 0.3)
    let data = try Data(contentsOf: url)
    #expect(String(decoding: data[8..<12], as: UTF8.self) == "WEBP")
    let decoded = try await ImageStore().image(at: url, maxPixels: 0)
    #expect(decoded.originalWidth == 80 && decoded.originalHeight == 40)
    #expect(throws: CaptureRecorderError.self) {
      try CapturePersistence.write(image: image, to: url, format: "webp", quality: 0.3)
    }
  }
  let library = try CaptureLibrary(root: root)
  let day = try #require(await library.days().first)
  let frames = try await library.captures(on: day)
  #expect(frames.count == 2)
  #expect(Timeline.groups(frames).count == 1)
}

@Test func cyclePublishFailureRollsBackOnlyNewFiles() throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let context = try #require(
    CGContext(
      data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
  let image = try #require(context.makeImage())
  let first = root.appending(path: "first.webp")
  let second = root.appending(path: "second.webp")
  let original = Data("existing original".utf8)
  try original.write(to: second)
  #expect(throws: CaptureRecorderError.destinationAlreadyExists) {
    try CapturePersistence.writeCycle(
      images: [image, image], destinations: [first, second], format: "webp", quality: 0.3)
  }
  #expect(!FileManager.default.fileExists(atPath: first.path))
  #expect(try Data(contentsOf: second) == original)
  #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["second.webp"])
}
