import AppKit
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

public struct RecordingOptions: Codable, Equatable, Sendable {
  public static let defaultIntervalSeconds = 900
  public static let minimumDailyIntervalSeconds = 60
  /// The lower bound accepted by the recorder actor; the app exposes this only
  /// through a bounded, temporary `RecordingBurstPlan`.
  public static let minimumIntervalSeconds = 1

  public var intervalSeconds: Int
  public var scale: Double
  public var quality: Double
  public var format: String
  public var mode: RecordingCaptureMode

  public init(
    intervalSeconds: Int = Self.defaultIntervalSeconds,
    scale: Double = 1,
    quality: Double = 0.3,
    format: String = "webp",
    mode: RecordingCaptureMode = .skipUnchanged
  ) {
    self.intervalSeconds = intervalSeconds
    self.scale = scale
    self.quality = quality
    self.format = format
    self.mode = mode
  }

  private enum CodingKeys: String, CodingKey {
    case intervalSeconds, scale, quality, format, mode
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    intervalSeconds =
      try values.decodeIfPresent(Int.self, forKey: .intervalSeconds)
      ?? Self.defaultIntervalSeconds
    scale = try values.decodeIfPresent(Double.self, forKey: .scale) ?? 1
    quality = try values.decodeIfPresent(Double.self, forKey: .quality) ?? 0.3
    format = try values.decodeIfPresent(String.self, forKey: .format) ?? "webp"
    // Existing preferences used every interval before this option existed.
    mode = try values.decodeIfPresent(RecordingCaptureMode.self, forKey: .mode) ?? .everyInterval
  }

  public func validate() throws {
    guard (Self.minimumIntervalSeconds...86_400).contains(intervalSeconds) else {
      throw CaptureRecorderError.invalidOptions("擷取間隔必須介於 1 秒與 24 小時之間。")
    }
    guard scale.isFinite, (0.1...1).contains(scale) else {
      throw CaptureRecorderError.invalidOptions("影像比例必須介於 0.1 與 1 之間。")
    }
    guard quality.isFinite, (0...1).contains(quality) else {
      throw CaptureRecorderError.invalidOptions("影像品質必須介於 0 與 1 之間。")
    }
    guard ["webp", "heic", "jpeg", "png"].contains(normalizedFormat) else {
      throw CaptureRecorderError.invalidOptions("影像格式必須是 WebP、HEIC、JPEG 或 PNG。")
    }
  }

  var normalizedFormat: String {
    format.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}

public struct RecordingDisplay: Identifiable, Codable, Sendable {
  /// The CoreGraphics display UUID is persistent across display-ID changes and filename-safe.
  public let id: String
  public let name: String
  public let width: Int
  public let height: Int
  public let originX: Int?
  public let originY: Int?

  public init(
    id: String, name: String, width: Int, height: Int, originX: Int? = nil, originY: Int? = nil
  ) {
    self.id = id
    self.name = name
    self.width = width
    self.height = height
    self.originX = originX
    self.originY = originY
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, width, height, originX, originY
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    name = try values.decode(String.self, forKey: .name)
    width = try values.decode(Int.self, forKey: .width)
    height = try values.decode(Int.self, forKey: .height)
    originX = try values.decodeIfPresent(Int.self, forKey: .originX)
    originY = try values.decodeIfPresent(Int.self, forKey: .originY)
  }
}

public struct RecordingStatus: Sendable {
  public let isRecording: Bool
  public let framesWritten: Int
  public let cyclesSkipped: Int
  public let lastCapture: Date?
  public let error: String?

  public init(
    isRecording: Bool, framesWritten: Int, cyclesSkipped: Int = 0, lastCapture: Date?,
    error: String?
  ) {
    self.isRecording = isRecording
    self.framesWritten = framesWritten
    self.cyclesSkipped = cyclesSkipped
    self.lastCapture = lastCapture
    self.error = error
  }
}

public enum CaptureRecorderError: LocalizedError, Equatable, Sendable {
  case invalidOptions(String)
  case screenRecordingPermissionRequired
  case noDisplaysAvailable
  case invalidOutputRoot
  case invalidDisplayMetadata
  case insufficientStorage
  case destinationAlreadyExists
  case imageEncodingFailed
  case imagePublishFailed
  case captureFailed

  var stopsRecording: Bool {
    switch self {
    case .noDisplaysAvailable, .captureFailed:
      false
    case .invalidOptions, .screenRecordingPermissionRequired, .invalidOutputRoot,
      .invalidDisplayMetadata, .insufficientStorage, .destinationAlreadyExists,
      .imageEncodingFailed, .imagePublishFailed:
      true
    }
  }

  public var errorDescription: String? {
    switch self {
    case .invalidOptions(let message): message
    case .screenRecordingPermissionRequired:
      "需要螢幕錄製權限。請在設定中允許後再開始。"
    case .noDisplaysAvailable: "目前沒有可擷取的顯示器。"
    case .invalidOutputRoot: "無法安全建立截圖資料夾。"
    case .invalidDisplayMetadata: "顯示器資料無法讀取，為保護既有資料而未覆寫。"
    case .insufficientStorage: "儲存空間不足，記錄已停止。"
    case .destinationAlreadyExists: "同一時間的截圖已存在，為保護原始檔而未覆寫。"
    case .imageEncodingFailed: "無法編碼截圖。"
    case .imagePublishFailed: "無法安全發佈截圖。"
    case .captureFailed: "無法擷取螢幕。"
    }
  }
}

/// A serial, opt-in screen recorder. `start` only checks preflight access; it never asks TCC
/// for permission. The caller must invoke `requestPermission` from an explicit user action.
public actor CaptureRecorder {
  private var options = RecordingOptions()
  private var outputRoot: URL?
  private var activeRunID: UUID?
  private var loop: Task<Void, Never>?
  private var captureInProgress = false
  private var lastMeasurement: RecordingMeasurement?
  public func measurement() -> RecordingMeasurement? { lastMeasurement }

  private var lastSignatures: [String: UInt64] = [:]
  private var currentStatus = RecordingStatus(
    isRecording: false, framesWritten: 0, lastCapture: nil, error: nil)

  private struct CaptureCycleResult {
    let skipped: Bool
  }

  public init() {}

  public func start(at root: URL, options: RecordingOptions) async throws {
    try options.validate()
    guard Self.hasPermission() else { throw CaptureRecorderError.screenRecordingPermissionRequired }

    let previous = loop
    previous?.cancel()
    activeRunID = nil
    await previous?.value
    let safeRoot = try CapturePersistence.prepareRoot(root)
    let runID = UUID()
    self.options = options
    outputRoot = safeRoot
    activeRunID = runID
    lastSignatures = [:]
    currentStatus = RecordingStatus(
      isRecording: true,
      framesWritten: currentStatus.framesWritten,
      cyclesSkipped: currentStatus.cyclesSkipped,
      lastCapture: currentStatus.lastCapture,
      error: nil)
    loop = Task { [weak self] in
      await self?.recordingLoop(runID: runID)
    }
  }

  public func stop() async {
    let previous = loop
    previous?.cancel()
    activeRunID = nil
    currentStatus = RecordingStatus(
      isRecording: false,
      framesWritten: currentStatus.framesWritten,
      cyclesSkipped: currentStatus.cyclesSkipped,
      lastCapture: currentStatus.lastCapture,
      error: currentStatus.error)
    await previous?.value
    loop = nil
  }

  public func status() -> RecordingStatus { currentStatus }

  public func update(options: RecordingOptions) async throws {
    try options.validate()
    self.options = options
    guard let outputRoot, activeRunID != nil else { return }
    try await start(at: outputRoot, options: options)
  }

  /// Persists exactly one complete multi-display cycle using the production capture path.
  /// It does not change the daily cadence or recording intent.
  public func captureNow(at root: URL, options: RecordingOptions) async throws -> [URL] {
    try options.validate()
    guard Self.hasPermission() else { throw CaptureRecorderError.screenRecordingPermissionRequired }
    let safeRoot = try CapturePersistence.prepareRoot(root)
    try CapturePersistence.ensureAvailableStorage(at: safeRoot)
    let frames = try await captureImages(options: options)
    let timestamp = Date()
    try CapturePersistence.mergeDisplays(frames.map(\.0), under: safeRoot)
    let destinations = try frames.map { display, _ in
      try CapturePersistence.destination(
        under: safeRoot, at: timestamp, display: display, format: options.normalizedFormat)
    }
    try CapturePersistence.writeCycle(
      images: frames.map(\.1), destinations: destinations,
      format: options.normalizedFormat, quality: options.quality)
    var sizes: [String: Int64] = [:]
    for (index, frame) in frames.enumerated() {
      sizes[frame.0.id] = Int64(
        try destinations[index].resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }
    currentStatus = RecordingStatus(
      isRecording: currentStatus.isRecording,
      framesWritten: currentStatus.framesWritten + frames.count,
      cyclesSkipped: currentStatus.cyclesSkipped,
      lastCapture: timestamp,
      error: nil)
    lastMeasurement = RecordingMeasurement(
      options: options, displays: frames.map(\.0), bytesByDisplay: sizes, date: timestamp)
    return destinations
  }

  public nonisolated static func hasPermission() -> Bool {
    CGPreflightScreenCaptureAccess()
  }

  /// Call only from a button or another explicit user request. This is the sole TCC prompt path.
  @MainActor public static func requestPermission() -> Bool {
    CGRequestScreenCaptureAccess()
  }

  @MainActor public static func openPermissionSettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    else { return }
    NSWorkspace.shared.open(url)
  }

  @MainActor public static func displays() -> [RecordingDisplay] {
    activeDisplayRecords().values.sorted { lhs, rhs in
      lhs.name == rhs.name
        ? lhs.id < rhs.id : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
  }

  @MainActor public static func hasAwakeDisplay() -> Bool {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return false }
    return ids.prefix(Int(count)).contains { CGDisplayIsAsleep($0) == 0 }
  }

  private func recordingLoop(runID: UUID) async {
    let clock = ContinuousClock()
    while activeRunID == runID, !Task.isCancelled {
      guard Self.hasPermission() else {
        end(runID: runID, error: CaptureRecorderError.screenRecordingPermissionRequired)
        return
      }

      let interval = options.intervalSeconds
      let cycleStarted = clock.now
      var retryableFailure = false
      do {
        let result = try await captureCycle(runID: runID)
        guard activeRunID == runID else { return }
        currentStatus = RecordingStatus(
          isRecording: true,
          framesWritten: currentStatus.framesWritten,
          cyclesSkipped: currentStatus.cyclesSkipped + (result.skipped ? 1 : 0),
          lastCapture: currentStatus.lastCapture,
          error: nil)
      } catch is CancellationError {
        return
      } catch {
        guard activeRunID == runID else { return }
        if let recorderError = error as? CaptureRecorderError, recorderError.stopsRecording {
          end(runID: runID, error: recorderError)
          return
        }
        if !Self.hasPermission() {
          end(runID: runID, error: CaptureRecorderError.screenRecordingPermissionRequired)
          return
        }
        retryableFailure = true
        currentStatus = RecordingStatus(
          isRecording: true,
          framesWritten: currentStatus.framesWritten,
          cyclesSkipped: currentStatus.cyclesSkipped,
          lastCapture: currentStatus.lastCapture,
          error: (error as? LocalizedError)?.errorDescription
            ?? CaptureRecorderError.captureFailed.errorDescription)
      }

      do {
        let elapsed = cycleStarted.duration(to: clock.now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        try await Task.sleep(
          for: .seconds(
            retryableFailure
              ? RecordingCadence.retryDelay(intervalSeconds: interval, elapsedSeconds: seconds)
              : RecordingCadence.delay(intervalSeconds: interval, elapsedSeconds: seconds)))
      } catch {
        return
      }
    }
  }

  private func end(runID: UUID, error: Error) {
    guard activeRunID == runID else { return }
    loop = nil
    activeRunID = nil
    currentStatus = RecordingStatus(
      isRecording: false,
      framesWritten: currentStatus.framesWritten,
      cyclesSkipped: currentStatus.cyclesSkipped,
      lastCapture: currentStatus.lastCapture,
      error: (error as? LocalizedError)?.errorDescription
        ?? CaptureRecorderError.captureFailed.errorDescription)
  }

  /// Queries SCShareableContent every cycle, so a connected or disconnected monitor does not
  /// require restarting recording. Captures and ImageIO encodes deliberately remain serial.
  private func captureCycle(runID: UUID) async throws -> CaptureCycleResult {
    guard let outputRoot, activeRunID == runID else { throw CancellationError() }
    let cycleOptions = options
    let timestamp = Date()
    try CapturePersistence.ensureAvailableStorage(at: outputRoot)
    let captured = try await captureImages(options: cycleOptions)
    guard activeRunID == runID else { throw CancellationError() }
    // Keep display names and physical origins current even when the image cycle is skipped.
    try CapturePersistence.mergeDisplays(captured.map(\.0), under: outputRoot)
    let signatures =
      cycleOptions.mode == .skipUnchanged
      ? Dictionary(uniqueKeysWithValues: captured.map { ($0.0.id, Self.signature(for: $0.1)) })
      : [:]
    guard
      RecordingCyclePolicy.shouldPersist(
        mode: cycleOptions.mode, signatures: signatures, previousSignatures: lastSignatures)
    else { return CaptureCycleResult(skipped: true) }

    let destinations = try captured.map { record, _ in
      try CapturePersistence.destination(
        under: outputRoot, at: timestamp, display: record, format: cycleOptions.normalizedFormat)
    }
    try CapturePersistence.writeCycle(
      images: captured.map(\.1), destinations: destinations,
      format: cycleOptions.normalizedFormat, quality: cycleOptions.quality)
    var sizes: [String: Int64] = [:]
    for (index, frame) in captured.enumerated() {
      sizes[frame.0.id] = Int64(
        try destinations[index].resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }
    currentStatus = RecordingStatus(
      isRecording: true, framesWritten: currentStatus.framesWritten + captured.count,
      cyclesSkipped: currentStatus.cyclesSkipped, lastCapture: timestamp, error: nil)
    lastMeasurement = RecordingMeasurement(
      options: cycleOptions, displays: captured.map(\.0), bytesByDisplay: sizes, date: timestamp)
    lastSignatures = signatures
    return CaptureCycleResult(skipped: false)
  }

  private func captureImages(options cycleOptions: RecordingOptions) async throws -> [(
    RecordingDisplay, CGImage
  )] {
    guard !captureInProgress else { throw CaptureRecorderError.captureFailed }
    captureInProgress = true
    defer { captureInProgress = false }
    let content: SCShareableContent
    do {
      content = try await SCShareableContent.current
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw CaptureRecorderError.captureFailed
    }
    try Task.checkCancellation()

    let records = await MainActor.run { Self.activeDisplayRecords() }
    let displays = content.displays.compactMap { display -> (SCDisplay, RecordingDisplay)? in
      guard let record = records[display.displayID] else { return nil }
      return (display, record)
    }
    guard !displays.isEmpty else { throw CaptureRecorderError.noDisplaysAvailable }
    let ownApplications = content.applications.filter {
      $0.processID == getpid()
        || (Bundle.main.bundleIdentifier != nil
          && $0.bundleIdentifier == Bundle.main.bundleIdentifier)
    }
    var captured: [(RecordingDisplay, CGImage)] = []
    for (display, record) in displays {
      try Task.checkCancellation()
      let filter = SCContentFilter(
        display: display, excludingApplications: ownApplications, exceptingWindows: [])
      let configuration = SCStreamConfiguration()
      configuration.width = scaled(record.width, by: cycleOptions.scale)
      configuration.height = scaled(record.height, by: cycleOptions.scale)
      configuration.showsCursor = true
      configuration.capturesAudio = false
      configuration.scalesToFit = false

      let image: CGImage
      do {
        image = try await SCScreenshotManager.captureImage(
          contentFilter: filter, configuration: configuration)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw CaptureRecorderError.captureFailed
      }
      try Task.checkCancellation()
      captured.append((record, image))
    }

    return captured
  }

  /// Uses the same live capture and encoder as recording, but writes only to a
  /// caller-owned preview directory. A preview never creates a timeline moment.
  public func sample(at root: URL, options: RecordingOptions) async throws -> RecordingPreview {
    try options.validate()
    guard Self.hasPermission() else { throw CaptureRecorderError.screenRecordingPermissionRequired }
    let destination = try CapturePersistence.prepareRoot(root)
    let frames = try await captureImages(options: options)
    var sizes: [String: Int64] = [:]
    var urls: [URL] = []
    let date = Date()
    for (display, image) in frames {
      try Task.checkCancellation()
      let url = try CapturePersistence.destination(
        under: destination, at: date,
        display: display, format: options.normalizedFormat)
      try CapturePersistence.write(
        image: image, to: url, format: options.normalizedFormat, quality: options.quality)
      sizes[display.id] = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
      urls.append(url)
    }
    return RecordingPreview(
      measurement: RecordingMeasurement(
        options: options,
        displays: frames.map(\.0), bytesByDisplay: sizes), urls: urls)
  }

  private static func signature(for image: CGImage) -> UInt64 {
    var hash: UInt64 = 1_469_598_103_934_665_603
    for value in [image.width, image.height, image.bytesPerRow, image.bitsPerPixel] {
      hash ^= UInt64(value)
      hash &*= 1_099_511_628_211
    }
    guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data)
    else { return hash }
    for index in 0..<CFDataGetLength(data) {
      hash ^= UInt64(bytes[index])
      hash &*= 1_099_511_628_211
    }
    return hash
  }

  private func scaled(_ pixels: Int, by scale: Double) -> Int {
    max(1, Int((Double(pixels) * scale).rounded(.toNearestOrAwayFromZero)))
  }

  @MainActor private static func activeDisplayRecords() -> [CGDirectDisplayID: RecordingDisplay] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [:] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [:] }
    let screensByID = Dictionary(
      uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
        guard
          let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber
        else { return nil as (CGDirectDisplayID, NSScreen)? }
        return (number.uint32Value, screen)
      })
    let records: [(CGDirectDisplayID, RecordingDisplay)] = ids.prefix(Int(count)).compactMap {
      id -> (CGDirectDisplayID, RecordingDisplay)? in
      guard let uuid = CGDisplayCreateUUIDFromDisplayID(id), let mode = CGDisplayCopyDisplayMode(id)
      else {
        return nil
      }
      let name = screensByID[id]?.localizedName ?? "Display \(id)"
      return (
        id,
        RecordingDisplay(
          id: CFUUIDCreateString(kCFAllocatorDefault, uuid.takeRetainedValue()) as String,
          name: name,
          width: mode.pixelWidth,
          height: mode.pixelHeight,
          originX: Int(CGDisplayBounds(id).origin.x),
          originY: Int(CGDisplayBounds(id).origin.y))
      )
    }
    return Dictionary(uniqueKeysWithValues: records)
  }
}

/// File-only persistence kept separate from live capture so it can be fixture-tested without TCC.
enum CapturePersistence {
  static func prepareRoot(_ root: URL) throws -> URL {
    let root = root.standardizedFileURL
    var isDirectory = ObjCBool(false)
    if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) {
      let values = try root.resourceValues(forKeys: [.isSymbolicLinkKey])
      guard isDirectory.boolValue, values.isSymbolicLink != true else {
        throw CaptureRecorderError.invalidOutputRoot
      }
    } else {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    let screenshots = root.appending(path: "screenshots", directoryHint: .isDirectory)
    try privateDirectory(screenshots)
    return root
  }

  static func destination(
    under root: URL, at date: Date, display: RecordingDisplay, format: String
  ) throws -> URL {
    guard let fileExtension = fileExtension(for: format) else {
      throw CaptureRecorderError.imageEncodingFailed
    }
    guard !display.id.isEmpty,
      display.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
    else {
      throw CaptureRecorderError.invalidDisplayMetadata
    }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Taipei") ?? .current
    let fields = calendar.dateComponents([.year, .month, .day, .hour], from: date)
    guard let year = fields.year, let month = fields.month, let day = fields.day,
      let hour = fields.hour
    else {
      throw CaptureRecorderError.invalidOutputRoot
    }
    var folder = root.appending(path: "screenshots", directoryHint: .isDirectory)
    try privateDirectory(folder)
    for component in [
      String(format: "%04d", year),
      String(format: "%02d", month),
      String(format: "%02d", day),
      String(format: "%02d", hour),
    ] {
      folder = folder.appending(path: component, directoryHint: .isDirectory)
      try privateDirectory(folder)
    }
    let timestamp = String(
      format: "%.3f",
      locale: Locale(identifier: "en_US_POSIX"),
      arguments: [date.timeIntervalSince1970])
    return folder.appending(path: "\(timestamp)_\(display.id).\(fileExtension)")
  }

  /// Encode every display before publishing; roll back only files created by this cycle.
  static func writeCycle(
    images: [CGImage], destinations: [URL], format: String, quality: Double
  ) throws {
    guard images.count == destinations.count else {
      throw CaptureRecorderError.imagePublishFailed
    }
    var staged: [URL] = []
    var published: [URL] = []
    var complete = false
    defer {
      for url in staged { try? FileManager.default.removeItem(at: url) }
      if !complete {
        for url in published { try? FileManager.default.removeItem(at: url) }
      }
    }
    for (image, destination) in zip(images, destinations) {
      let temporary = destination.deletingLastPathComponent().appending(
        path: ".cycle-\(UUID().uuidString).tmp")
      staged.append(temporary)
      try write(image: image, to: temporary, format: format, quality: quality)
    }
    for (temporary, destination) in zip(staged, destinations) {
      let result = temporary.path.withCString { source in
        destination.path.withCString { target in link(source, target) }
      }
      guard result == 0 else {
        if errno == EEXIST { throw CaptureRecorderError.destinationAlreadyExists }
        if errno == ENOSPC { throw CaptureRecorderError.insufficientStorage }
        throw CaptureRecorderError.imagePublishFailed
      }
      published.append(destination)
    }
    complete = true
  }

  @discardableResult static func write(
    image: CGImage, to destination: URL, format: String, quality: Double
  ) throws -> URL {
    guard let type = imageType(for: format), quality.isFinite, (0...1).contains(quality) else {
      throw CaptureRecorderError.imageEncodingFailed
    }
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw CaptureRecorderError.destinationAlreadyExists
    }
    let temporary = destination.deletingLastPathComponent().appending(
      path: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
    defer { try? FileManager.default.removeItem(at: temporary) }
    if format == "webp" {
      try WebPEncoding.data(image: image, quality: quality).write(to: temporary)
    } else {
      guard
        let writer = CGImageDestinationCreateWithURL(
          temporary as CFURL, type.identifier as CFString, 1, nil)
      else { throw CaptureRecorderError.imageEncodingFailed }
      CGImageDestinationAddImage(
        writer, image,
        [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
      guard CGImageDestinationFinalize(writer) else {
        throw CaptureRecorderError.imageEncodingFailed
      }
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
    let handle = try FileHandle(forWritingTo: temporary)
    try handle.synchronize()
    try handle.close()

    // `link` publishes on the same volume without replacing an existing original.
    let published = temporary.path.withCString { temporaryPath in
      destination.path.withCString { destinationPath in link(temporaryPath, destinationPath) }
    }
    guard published == 0 else {
      if errno == EEXIST { throw CaptureRecorderError.destinationAlreadyExists }
      if errno == ENOSPC { throw CaptureRecorderError.insufficientStorage }
      throw CaptureRecorderError.imagePublishFailed
    }
    try? FileManager.default.removeItem(at: temporary)
    return destination
  }

  static func ensureAvailableStorage(at root: URL) throws {
    let values = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    try requireAvailableStorage(values.volumeAvailableCapacityForImportantUsage)
  }

  static func requireAvailableStorage(_ available: Int64?) throws {
    guard let available else { return }
    guard available > 0 else { throw CaptureRecorderError.insufficientStorage }
  }

  static func mergeDisplays(_ displays: [RecordingDisplay], under root: URL) throws {
    let metadata = root.appending(path: "screenshots/displays.json")
    var known: [String: RecordingDisplay] = [:]
    if FileManager.default.fileExists(atPath: metadata.path) {
      let values = try metadata.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else {
        throw CaptureRecorderError.invalidDisplayMetadata
      }
      do {
        known = try JSONDecoder().decode(
          [String: RecordingDisplay].self, from: Data(contentsOf: metadata))
      } catch {
        throw CaptureRecorderError.invalidDisplayMetadata
      }
    }
    for display in displays { known[display.id] = display }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try privateAtomicWrite(try encoder.encode(known), to: metadata)
  }

  private static func privateDirectory(_ directory: URL) throws {
    var isDirectory = ObjCBool(false)
    if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
      let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey])
      guard isDirectory.boolValue, values.isSymbolicLink != true else {
        throw CaptureRecorderError.invalidOutputRoot
      }
    } else {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  }

  private static func privateAtomicWrite(_ data: Data, to destination: URL) throws {
    let temporary = destination.deletingLastPathComponent().appending(
      path: ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try data.write(to: temporary, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
    if FileManager.default.fileExists(atPath: destination.path) {
      _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
    } else {
      try FileManager.default.moveItem(at: temporary, to: destination)
    }
  }

  private static func fileExtension(for format: String) -> String? {
    switch format.lowercased() {
    case "webp": "webp"
    case "png": "png"
    case "heic": "heic"
    case "jpeg": "jpeg"
    default: nil
    }
  }

  private static func imageType(for format: String) -> UTType? {
    switch format.lowercased() {
    case "webp": .webP
    case "png": .png
    case "heic": .heic
    case "jpeg": .jpeg
    default: nil
    }
  }
}
