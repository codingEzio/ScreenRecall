import AppKit
import OSLog
import Observation
import RecallCore
import ServiceManagement

struct Preferences: Codable, Equatable {
  var source: String
  var previewPixels = 2560
  var appearance = "system"
  var typography = RecallTypography.system
  var visualTheme = RecallVisualTheme.monochrome
  var language = AppLanguage.system
  var displayArrangement = DisplayArrangement.automatic
  var recording = RecordingOptions()
  var recordingIntent = RecordingIntent.paused
  var showInDock = false
  var dockPresentationVersion = 1
  var launchAtLogin = false

  init(source: String) { self.source = source }

  private enum CodingKeys: String, CodingKey {
    case source, previewPixels, appearance, typography, visualTheme, language, displayArrangement, recording,
      recordingIntent,
      showInDock, dockPresentationVersion, launchAtLogin
  }
  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    source = try values.decode(String.self, forKey: .source)
    previewPixels = try values.decodeIfPresent(Int.self, forKey: .previewPixels) ?? 2560
    appearance = try values.decodeIfPresent(String.self, forKey: .appearance) ?? "system"
    typography =
      RecallTypography(
        rawValue:
          try values.decodeIfPresent(String.self, forKey: .typography) ?? "system") ?? .system
    visualTheme = RecallVisualTheme(
      rawValue: try values.decodeIfPresent(String.self, forKey: .visualTheme) ?? "monochrome"
    ) ?? .monochrome
    language = try values.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
    displayArrangement =
      try values.decodeIfPresent(DisplayArrangement.self, forKey: .displayArrangement) ?? .automatic
    recording =
      try values.decodeIfPresent(RecordingOptions.self, forKey: .recording) ?? RecordingOptions()
    recordingIntent =
      try values.decodeIfPresent(RecordingIntent.self, forKey: .recordingIntent) ?? .paused
    // Version 1 changes existing installs to the new menu-bar-first default once,
    // while preserving an explicit Dock opt-in saved by this or a later version.
    let storedDockPresentationVersion =
      try values.decodeIfPresent(Int.self, forKey: .dockPresentationVersion) ?? 0
    showInDock =
      storedDockPresentationVersion >= 1
      ? try values.decodeIfPresent(Bool.self, forKey: .showInDock) ?? false
      : false
    dockPresentationVersion = 1
    launchAtLogin = try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
    // A sub-minute interval is now reserved for the temporary burst mode. Older
    // preferences are migrated to the normal 15-minute profile instead of
    // silently keeping an expensive always-on loop.
    if recording.intervalSeconds < RecordingOptions.minimumDailyIntervalSeconds {
      recording.intervalSeconds = RecordingOptions.defaultIntervalSeconds
    }
  }

  func validate() throws {
    try recording.validate()
    guard recording.intervalSeconds >= RecordingOptions.minimumDailyIntervalSeconds,
      previewPixels == 0 || (640...8192).contains(previewPixels),
      ["system", "light", "dark"].contains(appearance)
    else {
      throw CocoaError(.coderReadCorrupt)
    }
  }
}

enum RecordingIntent: String, Codable, Sendable {
  case paused
  case active
}

@MainActor @Observable
final class RecallModel {
  var days: [CaptureDay] = []
  var selectedDay: CaptureDay?
  var captures: [Capture] = []
  var captureGroups: [[Capture]] = []
  var dayImages: [Capture] = [] {
    didSet { recordedDisplayIDs = Set(dayImages.map { $0.displayID ?? "legacy" }).sorted() }
  }
  private(set) var recordedDisplayIDs: [String] = []
  var displayNames: [String: String] = [:]
  var monitorFilter: String?
  var connectedDisplays: [RecordingDisplay] = []
  var isRecording = false
  var isBurstRecording = false
  var burstIntervalSeconds = 5
  var burstDurationMinutes = 10
  var burstRemainingSeconds: Int?
  var recordingBusy = false
  var recordingError: String?
  var launchAtLoginEnabled = false
  var recordedFrames = 0
  var skippedRecordingCycles = 0
  var recordingSizeStats: CaptureSizeStats?
  var recordingRecentSizeStats: RecentCaptureFileSizeStats?
  var recordingStatsBusy = false
  var recordingStatsUpdatedAt: Date?
  var recordingMeasurements: [RecordingMeasurement] = []
  var recordingPreview: RecordingPreview?
  var recordingPreviewBusy = false
  var showRecordingPreview = false
  private var recordingPreviewTask: Task<Void, Never>?

  var permissionGranted = false
  var needsPermission = false
  private var requestedPermission = false
  private let recorder = CaptureRecorder()
  private var recordingPoll: Task<Void, Never>?
  private var burstStopTask: Task<Void, Never>?
  private var sleepStopTask: Task<Void, Never>?
  private var wakeRetryTask: Task<Void, Never>?
  private var burstReturnToDaily = false
  private var sleepSuspendedRecording = false
  private var wakePending = false
  private var recordingOptionsTask: Task<Void, Never>?
  private var recordingStatsTask: Task<Void, Never>?
  @ObservationIgnored var showMainWindow: (() -> Void)?
  var selection = 0
  var decoded: DecodedImage?
  var decodedScreens: [URL: DecodedImage] = [:]
  var displayedURL: URL?
  var error: String?
  var notice: String?
  var imageError: String?
  var loading = false
  var preferences: Preferences
  var zoomed = false
  var scrubbing = false
  var playheadTime: Double = 0
  var catalogMilliseconds = 0.0
  var dayMilliseconds = 0.0
  var previewMilliseconds = 0.0
  var firstPreviewMilliseconds: Double?
  var previewSamples: [Double] = []
  var searchQuery = ""
  var searchResults: [CatalogSearchResult] = []
  var searchBusy = false
  var catalogBusy = false
  var catalogError: String?
  var catalogIndexedCaptures = 0
  var isPlaying = false
  var playbackRate: PlaybackRate = .one
  var playbackLoop = false
  var currentAnnotation = CaptureAnnotation(marked: false, note: "", updatedAt: 0)
  var annotationDraft = ""
  var annotationMarked = false
  var showAnnotationEditor = false
  var annotationBusy = false
  var annotationError: String?
  var annotations: [CatalogAnnotationResult] = []
  var annotationFilter: AnnotationFilter = .all
  var annotationsBusy = false
  var timelineZoom = 1.0
  var imageScale: CGFloat = 1
  @ObservationIgnored private var timelineZoomGestureBase = 1.0
  let images: ImageStore
  let faults: FaultJournal
  let displayProbe = DisplayProbe()
  private var library: CaptureArchive?
  private var catalog: CaptureCatalog?
  private var loadTask: Task<Void, Never>?
  private var imageTask: Task<Void, Never>?
  private var catalogTask: Task<Void, Never>?
  private var catalogSyncGeneration = 0
  private var catalogRefreshTask: Task<Void, Never>?
  private var presentRefreshTask: Task<Void, Never>?
  private var searchTask: Task<Void, Never>?
  private var playbackTask: Task<Void, Never>?
  private var viewStateTask: Task<Void, Never>?
  private var annotationTask: Task<Void, Never>?
  private var annotationsTask: Task<Void, Never>?
  private var generation = 0
  private let logger = Logger(subsystem: "com.alex.ScreenRecall", category: "Performance")
  private let config: URL
  private let runtimeDirectory: URL
  @ObservationIgnored private var loadedConfigData: Data?
  @ObservationIgnored private var lifecycleObservers: [(NotificationCenter, NSObjectProtocol)] = []
  @ObservationIgnored private var bootstrapped = false
  @ObservationIgnored private var refreshingPresent = false
  private let demo: Bool
  private let persistMaintenanceSnapshots: Bool
  private let ownedLibrary: URL
  var isDemo: Bool { demo }
  private let started = ContinuousClock.now

  var current: Capture? { captures.indices.contains(selection) ? captures[selection] : nil }
  var currentGroup: [Capture] {
    captureGroups.indices.contains(selection) ? captureGroups[selection] : []
  }
  var connectedDisplayOrigins: [String: DisplayOrigin] {
    Dictionary(
      uniqueKeysWithValues: connectedDisplays.compactMap { display in
        guard let originX = display.originX, let originY = display.originY else { return nil }
        return (display.id, DisplayOrigin(x: Double(originX), y: Double(originY)))
      })
  }
  var ownLibrary: URL { ownedLibrary }
  var matchingRecordingMeasurements: [RecordingMeasurement] {
    recordingMeasurements.filter {
      $0.matches(options: preferences.recording, displays: connectedDisplays)
    }
  }
  var recordingCycleStats: CaptureSizeStats? {
    CaptureSizeStats(sizes: matchingRecordingMeasurements.map(\.totalBytes))
  }
  var recordingCapacityEstimate: RecordingCapacityEstimate? {
    guard let stats = recordingCycleStats else { return nil }
    return RecordingCapacityEstimate(
      cycleStats: stats,
      intervalSeconds: preferences.recording.intervalSeconds, displayCount: connectedDisplays.count)
  }
  var burstPlan: RecordingBurstPlan? {
    RecordingBurstPlan(intervalSeconds: burstIntervalSeconds, durationMinutes: burstDurationMinutes)
  }
  var burstEstimatedBytes: Double? {
    guard let stats = recordingCycleStats, let burstPlan else { return nil }
    return stats.averageBytes * Double(burstPlan.cycleCount)
  }
  func averageBytes(for displayID: String) -> Double? {
    let values = matchingRecordingMeasurements.compactMap { $0.bytesByDisplay[displayID] }
    guard !values.isEmpty else { return nil }
    return values.reduce(0) { $0 + Double($1) } / Double(values.count)
  }

  func text(_ key: String) -> String { preferences.language.text(key) }
  var isWaitingForScreen: Bool {
    sleepSuspendedRecording && preferences.recordingIntent == .active
  }
  var recordingRequested: Bool { isRecording || isWaitingForScreen }
  var menuBarSymbol: String {
    if isWaitingForScreen { return "display" }
    if recordingError != nil { return "exclamationmark.circle" }
    if isRecording { return isBurstRecording ? "bolt.circle.fill" : "record.circle.fill" }
    return "record.circle"
  }
  var menuBarStatusText: String {
    if isWaitingForScreen { return text("等待顯示器亮起") }
    if recordingError != nil { return text("記錄錯誤") }
    if isBurstRecording, let remaining = burstRemainingSeconds {
      return "\(text("短時記錄中")) · \(remaining / 60):\(String(format: "%02d", remaining % 60))"
    }
    if isRecording { return text("記錄中") }
    return text("已暫停")
  }
  func displayName(_ id: String) -> String {
    if id == "legacy" { return text("舊歷史") }
    return displayNames[id] ?? "\(text("螢幕")) \((recordedDisplayIDs.firstIndex(of: id) ?? 0) + 1)"
  }
  var timeRange: ClosedRange<Double> {
    if let selectedDay {
      return Timeline.dayBounds(for: selectedDay)
    }
    let start = captures.first?.timestamp ?? 0
    return start...max(start + 1, captures.last?.timestamp ?? 1)
  }
  var visibleTimeRange: ClosedRange<Double> {
    let full = timeRange
    let span = full.upperBound - full.lowerBound
    guard span > 1, timelineZoom < 0.999 else { return full }
    let center = min(
      max(current?.timestamp ?? (full.lowerBound + span / 2), full.lowerBound), full.upperBound)
    let visibleSpan = max(1, span * timelineZoom)
    var lower = center - visibleSpan / 2
    var upper = center + visibleSpan / 2
    if lower < full.lowerBound {
      upper += full.lowerBound - lower
      lower = full.lowerBound
    }
    if upper > full.upperBound {
      lower -= upper - full.upperBound
      upper = full.upperBound
    }
    return max(full.lowerBound, lower)...min(full.upperBound, max(lower + 1, upper))
  }
  func connectedDisplayTitle(_ display: RecordingDisplay) -> String {
    guard let index = connectedDisplays.firstIndex(where: { $0.id == display.id }) else {
      return display.name
    }
    return "\(text("螢幕")) \(index + 1)"
  }

  func clockStyle(seconds: Bool) -> Date.FormatStyle {
    var style = Date.FormatStyle(date: .omitted, time: .omitted)
      .hour(.twoDigits(amPM: .omitted))
      .minute(.twoDigits)
      .locale(preferences.language.timelineLocale)
    if seconds { style = style.second(.twoDigits) }
    return style
  }

  func canNavigate(_ direction: Int) -> Bool {
    guard direction != 0 else { return false }
    if Timeline.step(from: playheadTime, direction: direction, in: captures) != nil {
      return true
    }
    guard let selectedDay, let dayIndex = days.firstIndex(where: { $0.id == selectedDay.id }) else {
      return false
    }
    return days.indices.contains(dayIndex + (direction < 0 ? -1 : 1))
  }

  init(
    configURL: URL? = nil, sourceOverride: String? = nil, demoOverride: Bool? = nil,
    arguments: [String]? = nil
  ) {
    let args = arguments ?? ProcessInfo.processInfo.arguments
    let demoIndex = args.firstIndex(of: "--library")
    demo = demoOverride ?? (demoIndex != nil)
    let demoSource =
      sourceOverride
      ?? demoIndex.flatMap { index in
        args.indices.contains(index + 1) ? args[index + 1] : nil
      }
    let support = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/Application Support/ScreenRecall", directoryHint: .isDirectory)
    let runtimePath =
      Bundle.main.object(forInfoDictionaryKey: "RecallLocalDirectory") as? String ?? support.path
    let demoState = demoSource.map {
      URL(fileURLWithPath: $0).deletingLastPathComponent()
        .appending(path: ".screenrecall-demo-state", directoryHint: .isDirectory)
    }
    runtimeDirectory = configURL?.deletingLastPathComponent()
      ?? (demo ? demoState ?? support.appending(path: "Demo", directoryHint: .isDirectory)
        : URL(fileURLWithPath: runtimePath))
    config = configURL ?? (demo ? runtimeDirectory : support).appending(path: "preferences.json")
    ownedLibrary =
      demo
      ? URL(fileURLWithPath: demoSource ?? runtimePath).deletingLastPathComponent()
        .appending(path: ".screenrecall-demo-captures")
      : runtimeDirectory.appending(path: "CaptureLibrary")
    let defaultSource = ownedLibrary.path
    let storedData = demo ? nil : try? Data(contentsOf: config)
    loadedConfigData = storedData
    if let sourceOverride {
      preferences = Preferences(source: sourceOverride)
    } else if let demoIndex, args.indices.contains(demoIndex + 1) {
      preferences = Preferences(source: args[demoIndex + 1])
    } else if let data = storedData,
      let stored = try? JSONDecoder().decode(Preferences.self, from: data),
      (try? stored.validate()) != nil
    {
      preferences = stored
    } else {
      preferences = Preferences(source: defaultSource)
      if FileManager.default.fileExists(atPath: config.path) {
        notice = "設定檔無法讀取，已暫用預設值。可在設定還原上一次設定；原檔仍保留。"
      }
    }
    launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    persistMaintenanceSnapshots = !demo && configURL == nil
    faults = FaultJournal(
      fileURL: runtimeDirectory.appending(path: "diagnostics/faults.jsonl"))
    images = ImageStore(
      cacheMegabytes: ImageStore.defaultCacheMegabytes,
      diskRoot: runtimeDirectory.appending(path: "Thumbnails"))
    installLifecycleObservers()
  }

  isolated deinit {
    for (center, observer) in lifecycleObservers {
      center.removeObserver(observer)
    }
  }

  private func installLifecycleObservers() {
    let applicationCenter = NotificationCenter.default
    lifecycleObservers.append(
      (
        applicationCenter,
        applicationCenter.addObserver(
          forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
        ) { [weak self] _ in
          Task { @MainActor [weak self] in self?.bootstrap() }
        }
      ))
    lifecycleObservers.append(
      (
        applicationCenter,
        applicationCenter.addObserver(
          forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
          Task { @MainActor [weak self] in
            guard let self else { return }
            let alreadyBootstrapped = self.bootstrapped
            self.bootstrap()
            if alreadyBootstrapped { self.goToNow() }
            self.refreshDevicesAndPermission()
            self.resumeAfterWake()
          }
        }
      ))
    lifecycleObservers.append(
      (
        applicationCenter,
        applicationCenter.addObserver(
          forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
          Task { @MainActor [weak self] in
            self?.refreshDevicesAndPermission()
            self?.resumeAfterWake()
          }
        }
      ))

    let catalogURL = catalogDatabaseURL
    let maintenanceRoot = runtimeDirectory.appending(path: "maintenance")
    let skipSnapshot = !persistMaintenanceSnapshots
    let journal = faults
    lifecycleObservers.append(
      (
        applicationCenter,
        applicationCenter.addObserver(
          forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
          guard !skipSnapshot else { return }
          do {
            try CatalogMaintenance.snapshotIfDue(from: catalogURL, into: maintenanceRoot)
          } catch {
            journal.record(code: "catalog.snapshot.failed", detail: error.localizedDescription)
          }
        }
      ))

    let workspaceCenter = NSWorkspace.shared.notificationCenter
    lifecycleObservers.append(
      (
        workspaceCenter,
        workspaceCenter.addObserver(
          forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
          Task { @MainActor [weak self] in self?.prepareForSleep() }
        }
      ))
    lifecycleObservers.append(
      (
        workspaceCenter,
        workspaceCenter.addObserver(
          forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
          Task { @MainActor [weak self] in self?.resumeAfterWake() }
        }
      ))
    lifecycleObservers.append(
      (
        workspaceCenter,
        workspaceCenter.addObserver(
          forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
          Task { @MainActor [weak self] in self?.prepareForSleep() }
        }
      ))
    lifecycleObservers.append(
      (
        workspaceCenter,
        workspaceCenter.addObserver(
          forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
          Task { @MainActor [weak self] in self?.resumeAfterWake() }
        }
      ))
  }

  /// Initializes history and recording intent without requiring the main window
  /// to exist. Scene tasks call this too as an idempotent fallback.
  func bootstrap() {
    guard !bootstrapped else { return }
    bootstrapped = true
    refreshSystemState()
    openSource(restoringViewState: false)
    resumeRecordingIfNeeded()
  }

  func openSource(restoringViewState: Bool = true, now: Date = .now) {
    stopPlayback()
    loadTask?.cancel()
    imageTask?.cancel()
    catalogTask?.cancel()
    catalogSyncGeneration += 1
    catalogRefreshTask?.cancel()
    presentRefreshTask?.cancel()
    refreshingPresent = false
    searchTask?.cancel()
    annotationTask?.cancel()
    annotationsTask?.cancel()
    viewStateTask?.cancel()
    recordingStatsTask?.cancel()
    generation += 1
    let version = generation
    captures = []
    captureGroups = []
    dayImages = []
    days = []
    decoded = nil
    displayedURL = nil
    selectedDay = nil
    searchResults = []
    searchBusy = false
    currentAnnotation = CaptureAnnotation(marked: false, note: "", updatedAt: 0)
    annotationDraft = ""
    annotationMarked = false
    showAnnotationEditor = false
    annotationError = nil
    annotations = []
    annotationsBusy = false
    catalogBusy = false
    catalogError = nil
    loading = true
    error = nil
    loadTask = Task {
      let start = ContinuousClock.now
      do {
        let roots = try sourceRoots()
        let library = try CaptureArchive(roots: roots)
        if catalog == nil {
          do {
            catalog = try CaptureCatalog(databaseURL: catalogDatabaseURL)
          } catch {
            catalogError = error.localizedDescription
            recordFault("catalog.open.failed", error: error)
          }
        }
        scheduleCatalogSnapshot()
        let catalogDays = (try? await catalog?.presentDays(roots: roots)) ?? []
        let fileDays = try await library.days()
        let days =
          restoringViewState && !catalogDays.isEmpty
          ? catalogDays : fileDays
        let names = await library.displayNames()
        guard !Task.isCancelled, generation == version else { return }
        self.library = library
        self.days = days
        displayNames = names
        catalogMilliseconds = elapsed(start)
        logger.info(
          "Catalog days=\(days.count) elapsed=\(String(describing: start.duration(to: .now)), privacy: .public)"
        )
        loading = false
        let savedState: CatalogViewState?
        if restoringViewState, let catalog {
          savedState = try? await catalog.viewState()
        } else {
          savedState = nil
        }
        let restoredDay = savedState.flatMap { state in
          days.first(where: { $0.id == state.dayKey || $0.catalogDayKey == state.dayKey })
        }
        if restoringViewState, let restoredDay {
          monitorFilter = savedState?.displayID
          selectDay(restoredDay, at: savedState?.timestamp)
        } else if let present = presentDay(in: days, now: now) {
          monitorFilter = nil
          selectDay(present)
        }
        startCatalogSync(roots: roots, version: generation, importLegacy: false)
      } catch {
        guard !Task.isCancelled, generation == version else { return }
        loading = false
        self.error = error.localizedDescription
        recordFault("library.open.failed", error: error)
      }
    }
  }

  func refreshRecordingSizeStats() {
    if recordingMeasurements.isEmpty, !demo,
      let data = try? Data(contentsOf: measurementFile),
      let stored = try? JSONDecoder().decode([RecordingMeasurement].self, from: data)
    {
      recordingMeasurements = Array(stored.suffix(32))
    }
    recordingStatsTask?.cancel()
    recordingStatsBusy = true
    let root = ownLibrary
    recordingStatsTask = Task { [weak self] in
      do {
        let library = try CaptureLibrary(root: root)
        let stats = try await library.fileSizeSummary()
        guard !Task.isCancelled, let self else { return }
        self.recordingSizeStats = stats.allFiles
        self.recordingRecentSizeStats = stats.recent
        self.recordingStatsUpdatedAt = stats.readAt
        self.recordingStatsBusy = false
      } catch is CancellationError {
      } catch {
        guard !Task.isCancelled, let self else { return }
        self.recordingSizeStats = nil
        self.recordingRecentSizeStats = nil
        self.recordingStatsUpdatedAt = nil
        self.recordingStatsBusy = false
      }
    }
  }

  private var measurementFile: URL {
    runtimeDirectory.appending(path: "recording-measurements.json")
  }

  func rememberRecordingMeasurement(_ measurement: RecordingMeasurement) {
    guard !demo, !recordingMeasurements.contains(where: { $0.date == measurement.date }) else {
      return
    }
    recordingMeasurements = Array((recordingMeasurements + [measurement]).suffix(32))
    // This is a rebuildable estimate cache, never authoritative recording data.
    if let data = try? JSONEncoder().encode(recordingMeasurements) {
      try? data.write(to: measurementFile, options: .atomic)
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: measurementFile.path)
    }
  }

  func sampleRecording() {
    guard !demo, !recordingPreviewBusy, !isBurstRecording else { return }
    refreshDevicesAndPermission()
    if !permissionGranted && !requestedPermission {
      requestedPermission = true
      permissionGranted = CaptureRecorder.requestPermission()
    }
    guard permissionGranted else {
      needsPermission = true
      return
    }
    recordingPreviewBusy = true
    recordingError = nil
    let options = preferences.recording
    let root = runtimeDirectory.appending(
      path: "CapturePreview/" + UUID().uuidString)
    recordingPreviewTask = Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await recorder.sample(at: root, options: options)
        guard !Task.isCancelled else {
          try? FileManager.default.removeItem(at: root)
          return
        }
        // Only UUID directories owned by this preview feature are disposable.
        let previewParent = root.deletingLastPathComponent()
        if let previous = try? FileManager.default.contentsOfDirectory(
          at: previewParent,
          includingPropertiesForKeys: nil)
        {
          for directory in previous
          where directory.standardizedFileURL.path != root.standardizedFileURL.path
            && UUID(uuidString: directory.lastPathComponent) != nil
          {
            try? FileManager.default.removeItem(at: directory)
          }
        }
        recordingPreview = result
        rememberRecordingMeasurement(result.measurement)
        recordingPreviewBusy = false
        showRecordingPreview = true
      } catch {
        try? FileManager.default.removeItem(at: root)
        recordingPreviewBusy = false
        recordingError = error.localizedDescription
        recordFault("recording.preview.failed", error: error)
      }
    }
  }

  func captureNow() {
    guard !demo, !recordingBusy, !isBurstRecording else { return }
    refreshDevicesAndPermission()
    if !permissionGranted && !requestedPermission {
      requestedPermission = true
      permissionGranted = CaptureRecorder.requestPermission()
    }
    guard permissionGranted else {
      needsPermission = true
      return
    }
    recordingBusy = true
    recordingError = nil
    Task { [weak self] in
      guard let self else { return }
      do {
        var options = preferences.recording
        options.mode = .everyInterval
        let destinations = try await recorder.captureNow(at: ownLibrary, options: options)
        guard !Task.isCancelled else { return }
        recordingBusy = false
        recordingError = destinations.isEmpty ? "沒有完成任何螢幕擷取。" : nil
        await refreshRecordingHistory()
        refreshRecordingSizeStats()
      } catch {
        guard !Task.isCancelled else { return }
        recordingBusy = false
        recordingError = error.localizedDescription
        recordFault("recording.capture.failed", error: error)
      }
    }
  }

  func refreshDevicesAndPermission() {
    connectedDisplays = CaptureRecorder.displays()
    permissionGranted = CaptureRecorder.hasPermission()
    if isRecording && !permissionGranted { pauseRecording() }
  }

  /// Stop capture when the system or screens sleep. Keep only an active daily
  /// intent; a bounded burst ends rather than extending into time with no screen.
  func prepareForSleep() {
    guard !demo, isRecording, !sleepSuspendedRecording else { return }
    if isBurstRecording {
      burstStopTask?.cancel()
      burstStopTask = nil
      isBurstRecording = false
      burstRemainingSeconds = nil
      burstReturnToDaily = false
    }
    sleepSuspendedRecording = preferences.recordingIntent == .active
    if recordingError == CaptureRecorderError.noDisplaysAvailable.errorDescription {
      recordingError = nil
    }
    wakePending = false
    recordingPoll?.cancel()
    recordingPoll = nil
    recordingBusy = true
    sleepStopTask?.cancel()
    sleepStopTask = Task { [weak self] in
      guard let self else { return }
      await recorder.stop()
      guard !Task.isCancelled else { return }
      isRecording = false
      recordingBusy = false
      refreshRecordingSizeStats()
      if wakePending {
        wakePending = false
        resumeAfterWake()
      }
    }
  }

  /// A system wake can precede screen wake; wait until a drawable display exists.
  func resumeAfterWake(displaysAwake: Bool? = nil) {
    refreshDevicesAndPermission()
    guard sleepSuspendedRecording else { return }
    guard !demo, preferences.recordingIntent == .active else {
      sleepSuspendedRecording = false
      wakePending = false
      return
    }
    guard displaysAwake ?? CaptureRecorder.hasAwakeDisplay() else {
      scheduleWakeRetry()
      return
    }
    guard !recordingBusy else {
      wakePending = true
      return
    }
    wakeRetryTask?.cancel()
    wakeRetryTask = nil
    sleepSuspendedRecording = false
    wakePending = false
    resumeActiveRecordingIfPermitted()
  }

  private func scheduleWakeRetry() {
    guard wakeRetryTask == nil else { return }
    wakeRetryTask = Task { [weak self] in
      guard let self else { return }
      while isWaitingForScreen, !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(RecordingOptions.minimumDailyIntervalSeconds))
        } catch { return }
        guard !Task.isCancelled else { return }
        if CaptureRecorder.hasAwakeDisplay() {
          wakeRetryTask = nil
          resumeAfterWake()
          return
        }
      }
      wakeRetryTask = nil
    }
  }

  func refreshSystemState() {
    launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    applyDockVisibility()
    refreshDevicesAndPermission()
  }

  func applyDockVisibility() {
    NSApp?.setActivationPolicy(preferences.showInDock ? .regular : .accessory)
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
      preferences.launchAtLogin = launchAtLoginEnabled
      savePreferences()
    } catch {
      launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
      notice = "無法更新登入時啟動：\(error.localizedDescription)"
    }
  }

  func toggleRecording() {
    if recordingRequested { pauseRecording() } else { startRecording() }
  }

  func toggleZoom() {
    setImageScale(imageScale > 1.01 ? 1 : 2)
  }

  func setImageScale(_ scale: CGFloat) {
    imageScale = min(4, max(1, scale))
    zoomed = imageScale > 1.01
  }

  func beginTimelineZoom() {
    timelineZoomGestureBase = timelineZoom
  }

  func adjustTimelineZoom(by magnification: CGFloat) {
    guard magnification.isFinite, magnification > 0 else { return }
    timelineZoom = min(1, max(0.01, timelineZoomGestureBase / Double(magnification)))
  }

  func resetTimelineZoom() {
    timelineZoom = 1
  }

  func navigateBySwipe(_ direction: Int) {
    guard canNavigate(direction) else { return }
    if let next = Timeline.step(from: playheadTime, direction: direction, in: captures) {
      choose(next)
      return
    }
    guard let selectedDay, let dayIndex = days.firstIndex(where: { $0.id == selectedDay.id }) else {
      return
    }
    let targetIndex = dayIndex + (direction < 0 ? -1 : 1)
    guard days.indices.contains(targetIndex) else { return }
    let target = days[targetIndex]
    let time =
      direction < 0
      ? target.date.timeIntervalSince1970 + 86_399
      : target.date.timeIntervalSince1970
    selectDay(target, at: time)
  }

  private func scheduleViewStateSave() {
    guard !demo, let catalog, let selectedDay, let current else { return }
    let dayKey = selectedDay.id
    let timestamp = current.timestamp
    let displayID = monitorFilter
    viewStateTask?.cancel()
    viewStateTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(250))
        try await catalog.saveViewState(
          dayKey: dayKey, timestamp: timestamp, displayID: displayID)
      } catch is CancellationError {
      } catch {
        guard let self, !Task.isCancelled else { return }
        self.catalogError = error.localizedDescription
        self.recordFault("catalog.viewstate.failed", error: error)
      }
    }
  }

  func goToNow() {
    guard !refreshingPresent else { return }
    stopPlayback()
    loadTask?.cancel()
    imageTask?.cancel()
    generation += 1
    refreshingPresent = true
    presentRefreshTask = Task {
      await refreshRecordingHistory(forcePresent: true)
      refreshingPresent = false
    }
  }

  private func presentDay(in days: [CaptureDay], now: Date) -> CaptureDay? {
    days.last(where: { Calendar.current.isDate($0.date, inSameDayAs: now) }) ?? days.last
  }

  func startRecording() {
    guard !demo, !recordingBusy, !isRecording else { return }
    beginRecording(options: preferences.recording, burstPlan: nil, returnToDaily: false)
  }

  func startBurstRecording() {
    guard !demo, !recordingBusy, !isBurstRecording, let burstPlan else { return }
    let returnToDaily = isRecording
    beginRecording(
      options: burstPlan.options(from: preferences.recording), burstPlan: burstPlan,
      returnToDaily: returnToDaily)
  }

  func startBurstRecording(intervalSeconds: Int, durationMinutes: Int) {
    burstIntervalSeconds = intervalSeconds
    burstDurationMinutes = durationMinutes
    startBurstRecording()
  }

  private func beginRecording(
    options: RecordingOptions, burstPlan: RecordingBurstPlan?, returnToDaily: Bool
  ) {
    permissionGranted = CaptureRecorder.hasPermission()
    if !permissionGranted && !requestedPermission {
      requestedPermission = true
      permissionGranted = CaptureRecorder.requestPermission()
    }
    guard permissionGranted else {
      needsPermission = true
      return
    }
    guard CaptureRecorder.hasAwakeDisplay() else {
      if burstPlan == nil {
        preferences.recordingIntent = .active
        savePreferences()
        sleepSuspendedRecording = true
        recordingError = nil
        scheduleWakeRetry()
      } else {
        recordingError = CaptureRecorderError.noDisplaysAvailable.errorDescription
      }
      return
    }
    needsPermission = false
    recordingBusy = true
    recordingError = nil
    recordingPoll?.cancel()
    recordingPoll = nil
    Task {
      do {
        try await recorder.start(at: ownLibrary, options: options)
        isRecording = true
        isBurstRecording = burstPlan != nil
        burstReturnToDaily = returnToDaily
        burstRemainingSeconds = burstPlan.map { $0.durationMinutes * 60 }
        if burstPlan == nil {
          preferences.recordingIntent = .active
          savePreferences()
        }
        recordingBusy = false
        if !CaptureRecorder.hasAwakeDisplay() {
          prepareForSleep()
          return
        }
        startRecordingPoll()
        if let burstPlan { scheduleBurstStop(after: burstPlan.durationMinutes * 60) }
      } catch {
        recordingBusy = false
        isRecording = (await recorder.status()).isRecording
        if !isRecording {
          isBurstRecording = false
          burstRemainingSeconds = nil
          burstReturnToDaily = false
        }
        recordingError = error.localizedDescription
        recordFault("recording.start.failed", error: error)
      }
    }
  }

  private func startRecordingPoll() {
    recordingPoll?.cancel()
    recordingPoll = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        let status = await recorder.status()
        guard !Task.isCancelled else { break }
        isRecording = status.isRecording
        recordingError = status.error
        if let runtimeError = status.error {
          recordFault("recording.runtime.failed", detail: runtimeError)
        }
        if let measurement = await recorder.measurement() {
          rememberRecordingMeasurement(measurement)
        }
        skippedRecordingCycles = status.cyclesSkipped
        if status.framesWritten != recordedFrames {
          recordedFrames = status.framesWritten
          await refreshRecordingHistory()
        }
        if !status.isRecording {
          if isBurstRecording {
            burstStopTask?.cancel()
            burstStopTask = nil
            isBurstRecording = false
            burstRemainingSeconds = nil
            burstReturnToDaily = false
          }
          break
        }
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  private func scheduleBurstStop(after seconds: Int) {
    burstStopTask?.cancel()
    burstStopTask = Task { [weak self] in
      guard let self else { return }
      let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
      while ContinuousClock.now < deadline {
        guard !Task.isCancelled, isBurstRecording else { return }
        let remaining = ContinuousClock.now.duration(to: deadline).components
        burstRemainingSeconds = max(1, Int(remaining.seconds) + (remaining.attoseconds > 0 ? 1 : 0))
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
      }
      guard !Task.isCancelled, isBurstRecording else { return }
      finishBurstAutomatically()
    }
  }

  private func finishBurstAutomatically() {
    guard isBurstRecording, !recordingBusy else { return }
    let returnToDaily = burstReturnToDaily
    burstStopTask = nil
    recordingBusy = true
    Task {
      await recorder.stop()
      recordingPoll?.cancel()
      isBurstRecording = false
      burstRemainingSeconds = nil
      burstReturnToDaily = false
      isRecording = false
      recordingBusy = false
      refreshRecordingSizeStats()
      if returnToDaily {
        startRecording()
      } else {
        preferences.recordingIntent = .paused
        savePreferences()
      }
    }
  }

  private func sourceRoots() throws -> [URL] {
    var roots: [URL] = []
    let source = preferences.source
    if !source.isEmpty, (try? CaptureLibrary(root: URL(fileURLWithPath: source))) != nil {
      roots.append(URL(fileURLWithPath: source))
    }
    if !demo, FileManager.default.fileExists(atPath: ownLibrary.appending(path: "screenshots").path)
    {
      roots.append(ownLibrary)
    }
    guard !roots.isEmpty else { throw LibraryError.invalidRoot }
    return roots
  }

  private func archiveForCurrentSources() throws -> CaptureArchive {
    try CaptureArchive(roots: sourceRoots())
  }

  private var catalogDatabaseURL: URL {
    if demo {
      // Keep demo state under the app-owned private directory. A demo source
      // can live in a system temporary directory whose parent we do not own.
      return ownLibrary.appending(path: "catalog.sqlite")
    }
    return runtimeDirectory.appending(path: "catalog.sqlite")
  }

  private func capturesForDay(_ day: CaptureDay) async throws -> [Capture] {
    if let library {
      let frames = try await library.captures(on: day)
      if !frames.isEmpty { return frames }
    }
    var catalogCaptures: [Capture] = []
    if let catalog {
      for root in (try? sourceRoots()) ?? [] {
        catalogCaptures += (try? await catalog.presentCaptures(on: day, root: root)) ?? []
      }
    }
    return catalogCaptures.sorted {
      $0.timestamp == $1.timestamp ? $0.url.path < $1.url.path : $0.timestamp < $1.timestamp
    }
  }

  private func startCatalogSync(
    roots: [URL], version: Int, importLegacy: Bool = true, mode: CatalogSyncMode = .incremental
  ) {
    catalogTask?.cancel()
    catalogSyncGeneration += 1
    let syncVersion = catalogSyncGeneration
    do {
      if catalog == nil { catalog = try CaptureCatalog(databaseURL: catalogDatabaseURL) }
    } catch {
      catalogBusy = false
      catalogError = error.localizedDescription
      recordFault("catalog.open.failed", error: error)
      return
    }
    guard let catalog else { return }
    catalogBusy = true
    catalogError = nil
    catalogTask = Task { [weak self] in
      do {
        let summary = try await catalog.synchronize(
          roots: roots, importLegacy: importLegacy, mode: mode)
        guard !Task.isCancelled, let self, self.generation == version,
          self.catalogSyncGeneration == syncVersion
        else { return }
        self.catalogIndexedCaptures = summary.indexedCaptures
        self.catalogBusy = false
        if let updated = try? await catalog.presentDays(roots: roots), !updated.isEmpty {
          let selectedID = self.selectedDay?.id
          self.days = updated
          if mode == .full,
            let selectedID, updated.contains(where: { $0.id == selectedID }),
            let selectedDay
          {
            self.selectDay(selectedDay, at: self.current?.timestamp)
          } else if let selectedID, !updated.contains(where: { $0.id == selectedID }),
            let latest = updated.last
          {
            self.selectDay(latest)
          }
        }
        self.refreshAnnotation()
        self.refreshAnnotations()
        if !self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          self.updateSearchResults()
        }
      } catch is CancellationError {
        guard let self, self.generation == version,
          self.catalogSyncGeneration == syncVersion
        else { return }
        self.catalogBusy = false
      } catch {
        guard !Task.isCancelled, let self, self.generation == version,
          self.catalogSyncGeneration == syncVersion
        else { return }
        self.catalogBusy = false
        self.catalogError = error.localizedDescription
        self.recordFault("catalog.sync.failed", error: error)
      }
    }
  }

  func rebuildLocalIndex() {
    guard let roots = try? sourceRoots() else { return }
    startCatalogSync(
      roots: roots, version: generation, importLegacy: false, mode: .full)
  }

  func updateSearchResults() {
    searchTask?.cancel()
    let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      searchResults = []
      searchBusy = false
      return
    }
    guard let catalog else {
      searchResults = []
      searchBusy = false
      return
    }
    let catalogQuery = catalogQuery(for: query)
    searchBusy = true
    searchTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(100))
        let results = try await catalog.search(catalogQuery)
        guard !Task.isCancelled, let self,
          self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query
        else {
          return
        }
        self.searchResults = results
        self.searchBusy = false
      } catch is CancellationError {
      } catch {
        guard !Task.isCancelled, let self else { return }
        self.searchBusy = false
        self.catalogError = error.localizedDescription
        self.recordFault("catalog.search.failed", error: error)
      }
    }
  }

  private func catalogQuery(for query: String) -> String {
    for (id, name) in displayNames.sorted(by: { $0.value.count > $1.value.count }) {
      let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty, query.range(of: name, options: .caseInsensitive) != nil else {
        continue
      }
      return query.replacingOccurrences(of: name, with: id, options: .caseInsensitive)
    }
    return query
  }

  func chooseSearchResult(_ result: CatalogSearchResult) {
    guard
      let day = days.min(by: {
        abs($0.date.timeIntervalSince(result.capture.date))
          < abs($1.date.timeIntervalSince(result.capture.date))
      })
    else { return }
    searchQuery = ""
    searchResults = []
    showAnnotationEditor = false
    selectDay(day, at: result.capture.timestamp)
  }

  func chooseAnnotation(_ result: CatalogAnnotationResult) {
    searchQuery = ""
    searchResults = []
    showAnnotationEditor = false
    monitorFilter = result.capture.displayID
    guard
      let day = days.min(by: {
        abs($0.date.timeIntervalSince(result.capture.date))
          < abs($1.date.timeIntervalSince(result.capture.date))
      })
    else { return }
    selectDay(day, at: result.capture.timestamp)
  }

  func refreshAnnotations() {
    annotationsTask?.cancel()
    guard let catalog else {
      annotations = []
      annotationsBusy = false
      return
    }
    annotationsBusy = true
    let filter = annotationFilter
    annotationsTask = Task { [weak self] in
      do {
        let results = try await catalog.annotations(
          markedOnly: filter == .marked, notesOnly: filter == .notes)
        guard !Task.isCancelled, let self, self.annotationFilter == filter else { return }
        self.annotations = results
        self.annotationsBusy = false
      } catch is CancellationError {
      } catch {
        guard !Task.isCancelled, let self else { return }
        self.annotationsBusy = false
        self.catalogError = error.localizedDescription
        self.recordFault("catalog.annotations.failed", error: error)
      }
    }
  }

  /// Refresh metadata without clearing the visible image or moving a historical selection.
  func refreshRecordingHistory(forcePresent: Bool = false, now: Date = .now) async {
    let version = generation
    do {
      let archive = try archiveForCurrentSources()
      let updatedDays = try await archive.days()
      let names = await archive.displayNames()
      guard !Task.isCancelled, generation == version else { return }
      let followsLatest =
        current == nil
        || (!scrubbing && selectedDay?.id == days.last?.id && selection == captures.count - 1)
      let targetDay: CaptureDay?
      if forcePresent {
        targetDay = presentDay(in: updatedDays, now: now)
      } else if followsLatest {
        targetDay = updatedDays.last
      } else {
        targetDay = updatedDays.first(where: { $0.id == selectedDay?.id })
      }
      guard let day = targetDay else { return }
      let frames = try await archive.captures(on: day)
      guard !Task.isCancelled, generation == version else { return }
      // Selection can change while the filesystem actor is reading. Respect its latest value.
      let stillFollowsLatest =
        forcePresent || current == nil
        || (!scrubbing && selectedDay?.id == days.last?.id && selection == captures.count - 1)
      let previous = current
      let previousGroup = currentGroup
      self.library = archive
      days = updatedDays
      displayNames = names
      if day.id != selectedDay?.id && !stillFollowsLatest { return }
      if forcePresent { monitorFilter = nil }
      dayImages = frames
      captureGroups = Timeline.groups(frames, displayID: monitorFilter)
      captures = captureGroups.compactMap(\.first)
      selectedDay = day
      if stillFollowsLatest {
        selection = max(0, captures.count - 1)
        if captures.indices.contains(selection) {
          playheadTime = captures[selection].timestamp
        }
      } else {
        selection =
          captures.firstIndex(where: { $0.id == previous?.id })
          ?? previous.flatMap { Timeline.nearest(to: $0.timestamp, in: captures) } ?? 0
      }
      error = nil
      loading = false
      if current?.id != previous?.id || currentGroup != previousGroup || decoded == nil {
        requestImage()
      }
      // A one-shot capture also changes the app-owned catalog. Keep this
      // debounced so a burst of refreshes cannot serialize a sync per frame.
      scheduleCatalogSync()
    } catch is CancellationError {
    } catch {
      // A transient refresh failure must not discard a readable historical selection.
      recordingError = error.localizedDescription
      recordFault("recording.refresh.failed", error: error)
    }
  }

  func pauseRecording() {
    guard !recordingBusy else { return }
    burstStopTask?.cancel()
    burstStopTask = nil
    burstReturnToDaily = false
    isBurstRecording = false
    burstRemainingSeconds = nil
    sleepSuspendedRecording = false
    wakeRetryTask?.cancel()
    wakeRetryTask = nil
    wakePending = false
    sleepStopTask?.cancel()
    sleepStopTask = nil
    preferences.recordingIntent = .paused
    savePreferences()
    recordingBusy = true
    Task {
      await recorder.stop()
      recordingPoll?.cancel()
      isRecording = false
      recordingBusy = false
      refreshRecordingSizeStats()
    }
  }

  func updateRecordingOptions() {
    recordingOptionsTask?.cancel()
    recordingOptionsTask = Task {
      do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
      savePreferences()
      guard !isBurstRecording else { return }
      do { try await recorder.update(options: preferences.recording) } catch {
        recordingError = error.localizedDescription
        recordFault("recording.options.failed", error: error)
      }
    }
  }

  func resumeRecordingIfNeeded() {
    guard !demo, preferences.recordingIntent == .active, !isRecording else { return }
    resumeActiveRecordingIfPermitted()
  }

  /// Relaunch and wake may continue an active intent, but neither path may
  /// present the TCC prompt. Permission requests remain explicit user actions.
  private func resumeActiveRecordingIfPermitted() {
    permissionGranted = CaptureRecorder.hasPermission()
    guard permissionGranted else {
      recordingError = CaptureRecorderError.screenRecordingPermissionRequired.errorDescription
      return
    }
    guard CaptureRecorder.hasAwakeDisplay() else {
      sleepSuspendedRecording = true
      recordingError = nil
      scheduleWakeRetry()
      return
    }
    startRecording()
  }

  func selectDay(_ day: CaptureDay, at time: Double? = nil) {
    guard library != nil else { return }
    stopPlayback()
    showAnnotationEditor = false
    annotationTask?.cancel()
    annotationBusy = false
    annotationError = nil
    loadTask?.cancel()
    imageTask?.cancel()
    presentRefreshTask?.cancel()
    refreshingPresent = false
    generation += 1
    let version = generation
    selectedDay = day
    captures = []
    captureGroups = []
    dayImages = []
    decoded = nil
    displayedURL = nil
    imageError = nil
    loading = true
    error = nil
    zoomed = false
    imageScale = 1
    timelineZoom = 1
    loadTask = Task {
      let start = ContinuousClock.now
      do {
        let captures = try await capturesForDay(day)
        guard !Task.isCancelled, generation == version else { return }
        dayImages = captures
        if let monitorFilter,
          !captures.contains(where: { ($0.displayID ?? "legacy") == monitorFilter })
        {
          self.monitorFilter = nil
        }
        captureGroups = Timeline.groups(captures, displayID: monitorFilter)
        self.captures = captureGroups.compactMap(\.first)
        dayMilliseconds = elapsed(start)
        selection =
          time.flatMap { Timeline.nearest(to: $0, in: self.captures) }
          ?? max(0, self.captures.count - 1)
        if let time {
          playheadTime = time
        } else if self.captures.indices.contains(selection) {
          playheadTime = self.captures[selection].timestamp
        }
        loading = false
        logger.info(
          "Day frames=\(captures.count) elapsed=\(String(describing: start.duration(to: .now)), privacy: .public)"
        )
        requestImage()
        refreshAnnotation()
        scheduleViewStateSave()
      } catch {
        guard !Task.isCancelled, generation == version else { return }
        loading = false
        self.error = error.localizedDescription
        recordFault("library.day.failed", error: error)
      }
    }
  }

  func jump(to date: Date) {
    guard
      let day = days.min(by: {
        abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
      })
    else { return }
    selectDay(day)
  }

  func moveDay(_ offset: Int) {
    guard let selectedDay, let index = days.firstIndex(where: { $0.id == selectedDay.id }),
      days.indices.contains(index + offset)
    else { return }
    selectDay(days[index + offset])
  }

  func choose(_ capture: Capture) {
    guard let index = captures.firstIndex(of: capture) else { return }
    choose(index)
  }

  func filterDisplay(_ id: String?) {
    stopPlayback()
    showAnnotationEditor = false
    annotationTask?.cancel()
    annotationBusy = false
    annotationError = nil
    let time = current?.timestamp
    monitorFilter = id
    captureGroups = Timeline.groups(dayImages, displayID: id)
    captures = captureGroups.compactMap(\.first)
    selection =
      time.flatMap { Timeline.nearest(to: $0, in: captures) } ?? max(0, captures.count - 1)
    if captures.indices.contains(selection) {
      playheadTime = captures[selection].timestamp
    }
    setImageScale(1)
    timelineZoom = 1
    decoded = nil
    decodedScreens = [:]
    displayedURL = nil
    requestImage()
    refreshAnnotation()
    scheduleViewStateSave()
  }

  func choose(_ index: Int) {
    guard captures.indices.contains(index) else { return }
    if !scrubbing { playheadTime = captures[index].timestamp }
    guard selection != index else { return }
    selection = index
    showCachedPreview(for: captures[index])
    requestImage()
    if !isPlaying { refreshAnnotation() }
    scheduleViewStateSave()
  }

  func scrub(to time: Double) {
    let range = visibleTimeRange
    playheadTime = min(max(time, range.lowerBound), range.upperBound)
    guard let index = Timeline.nearest(to: playheadTime, in: captures) else { return }
    guard selection != index else { return }
    selection = index
    showCachedPreview(for: captures[index])
    requestImage()
    if !isPlaying { refreshAnnotation() }
    scheduleViewStateSave()
  }

  func editingTimeline(_ editing: Bool) {
    scrubbing = editing
    if !editing { requestImage() }
  }

  func togglePlayback() {
    if isPlaying { stopPlayback() } else { startPlayback() }
  }

  func startPlayback() {
    guard captures.count > 1 else { return }
    playbackTask?.cancel()
    annotationTask?.cancel()
    annotationBusy = false
    if selection >= captures.count - 1 {
      selection = 0
      if captures.indices.contains(0) { playheadTime = captures[0].timestamp }
      requestImage()
    }
    isPlaying = true
    playbackTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled && isPlaying {
        do {
          try await Task.sleep(
            for: .milliseconds(PlaybackSchedule.delayMilliseconds(for: playbackRate)))
        } catch {
          return
        }
        guard !Task.isCancelled, isPlaying else { return }
        guard
          let next = PlaybackSchedule.nextIndex(
            current: selection, count: captures.count, looping: playbackLoop)
        else {
          isPlaying = false
          refreshAnnotation()
          return
        }
        choose(next)
      }
    }
  }

  func stopPlayback() {
    playbackTask?.cancel()
    playbackTask = nil
    if isPlaying {
      isPlaying = false
      refreshAnnotation()
    }
  }

  func openAnnotationEditor() {
    annotationDraft = currentAnnotation.note
    annotationMarked = currentAnnotation.marked
    showAnnotationEditor = true
  }

  func cancelAnnotationEdit() {
    annotationDraft = currentAnnotation.note
    annotationMarked = currentAnnotation.marked
    showAnnotationEditor = false
  }

  func toggleMark() {
    guard current != nil else { return }
    annotationMarked.toggle()
    saveAnnotation()
  }

  func saveAnnotation() {
    guard let catalog, let capture = current else {
      annotationError = "本機索引尚未完成，稍後再試。"
      return
    }
    annotationTask?.cancel()
    annotationBusy = true
    annotationError = nil
    let marked = annotationMarked
    let note = annotationDraft
    annotationTask = Task { [weak self] in
      do {
        try await catalog.saveAnnotation(for: capture, marked: marked, note: note)
        let saved = try await catalog.annotation(for: capture)
        guard !Task.isCancelled, let self, self.current?.id == capture.id else { return }
        self.currentAnnotation =
          saved ?? CaptureAnnotation(marked: false, note: "", updatedAt: 0)
        self.annotationMarked = saved?.marked ?? false
        self.annotationDraft = saved?.note ?? ""
        self.annotationBusy = false
        self.showAnnotationEditor = false
        self.refreshAnnotations()
      } catch is CancellationError {
      } catch {
        guard !Task.isCancelled, let self else { return }
        self.annotationBusy = false
        self.annotationError = error.localizedDescription
        self.recordFault("annotation.save.failed", error: error)
      }
    }
  }

  private func refreshAnnotation() {
    annotationTask?.cancel()
    guard let catalog, let capture = current else {
      currentAnnotation = CaptureAnnotation(marked: false, note: "", updatedAt: 0)
      annotationDraft = ""
      annotationMarked = false
      annotationBusy = false
      return
    }
    annotationBusy = true
    annotationError = nil
    annotationTask = Task { [weak self] in
      do {
        let annotation = try await catalog.annotation(for: capture)
        guard !Task.isCancelled, let self, self.current?.id == capture.id else { return }
        self.currentAnnotation =
          annotation ?? CaptureAnnotation(marked: false, note: "", updatedAt: 0)
        self.annotationDraft = annotation?.note ?? ""
        self.annotationMarked = annotation?.marked ?? false
        self.annotationBusy = false
      } catch is CancellationError {
      } catch {
        guard !Task.isCancelled, let self else { return }
        self.annotationBusy = false
        self.annotationError = error.localizedDescription
        self.recordFault("annotation.read.failed", error: error)
      }
    }
  }

  func requestImage() {
    imageTask?.cancel()
    imageError = nil
    guard let capture = current else { return }
    showCachedPreview(for: capture)
    let version = generation
    let pixels = preferences.previewPixels
    let isScrubbing = scrubbing
    let group = currentGroup
    let neighborURLs = [-1, 1].compactMap { offset -> URL? in
      let index = selection + offset
      return captures.indices.contains(index) ? captures[index].url : nil
    }
    imageTask = Task(priority: .userInitiated) {
      let start = ContinuousClock.now
      do {
        let previewPixels = isScrubbing ? 640 : 1280
        let preview = try await images.image(at: capture.url, maxPixels: previewPixels)
        guard !Task.isCancelled, generation == version, current?.id == capture.id else { return }
        decoded = preview
        decodedScreens[capture.url] = preview
        displayedURL = capture.url
        previewMilliseconds = elapsed(start)
        previewSamples.append(previewMilliseconds)
        if previewSamples.count > 120 { previewSamples.removeFirst() }
        if firstPreviewMilliseconds == nil { firstPreviewMilliseconds = elapsed(started) }
        logger.debug(
          "Preview elapsed=\(String(describing: start.duration(to: .now)), privacy: .public)")
        for screen in group.dropFirst() {
          let screenPreview = try await images.image(at: screen.url, maxPixels: previewPixels)
          guard !Task.isCancelled, generation == version, current?.id == capture.id else { return }
          decodedScreens[screen.url] = screenPreview
        }
        guard !isScrubbing else { return }
        if pixels != previewPixels {
          let full = try await images.image(at: capture.url, maxPixels: pixels)
          guard !Task.isCancelled, generation == version, current?.id == capture.id else { return }
          decoded = full
          decodedScreens[capture.url] = full
          for screen in group.dropFirst() {
            let full = try await images.image(at: screen.url, maxPixels: pixels)
            guard !Task.isCancelled, generation == version, current?.id == capture.id else {
              return
            }
            decodedScreens[screen.url] = full
          }
        }
        for url in neighborURLs {
          try Task.checkCancellation()
          _ = try? await images.image(at: url, maxPixels: 1280)
        }
      } catch is CancellationError {
      } catch {
        guard !Task.isCancelled, generation == version, current?.id == capture.id else { return }
        decoded = nil
        displayedURL = nil
        imageError = error.localizedDescription
        recordFault("image.decode.failed", error: error)
      }
    }
  }

  private func showCachedPreview(for capture: Capture) {
    // The view owns only the visible group. Retaining every visited image here
    // would bypass ImageStore's bounded cache and grow for the entire session.
    let visibleURLs = Set(currentGroup.map(\.url))
    decodedScreens = decodedScreens.filter { visibleURLs.contains($0.key) }
    if let preview = images.cachedPreview(at: capture.url) {
      decoded = preview
      decodedScreens[capture.url] = preview
      displayedURL = capture.url
      imageError = nil
    }
    for screen in currentGroup.dropFirst() {
      if let preview = images.cachedPreview(at: screen.url) {
        decodedScreens[screen.url] = preview
      }
    }
  }

  func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = text("開啟歷史")
    panel.message = text("選擇 ScreenRecall 圖片資料夾或 screenshots 資料夾。")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do { _ = try CaptureLibrary(root: url) } catch {
      notice = error.localizedDescription
      return
    }
    preferences.source = url.path
    savePreferences()
    openSource()
  }

  func savePreferences() {
    guard !demo else { return }
    do {
      try preferences.validate()
      try FileManager.default.createDirectory(
        at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
      let previous = try? Data(contentsOf: config)
      if previous != loadedConfigData {
        notice = "設定檔已在其他地方變更，尚未覆寫；請重新開啟 App 後再試。"
        recordFault("preferences.conflict")
        return
      }
      let encoded = try JSONEncoder().encode(preferences)
      var values =
        (try? JSONSerialization.jsonObject(with: previous ?? Data())) as? [String: Any] ?? [:]
      if let typed = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] {
        for (key, value) in typed { values[key] = value }
      }
      let merged = try JSONSerialization.data(
        withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
      guard previous != merged else {
        loadedConfigData = previous
        return
      }
      if let previous {
        try previous.write(to: previousConfig, options: .atomic)
        try FileManager.default.setAttributes(
          [.posixPermissions: 0o600], ofItemAtPath: previousConfig.path)
      }
      try merged.write(to: config, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
      loadedConfigData = merged
    } catch {
      notice = "無法儲存設定：\(error.localizedDescription)"
      recordFault("preferences.save.failed", error: error)
    }
  }

  private var previousConfig: URL {
    config.deletingLastPathComponent().appending(path: "preferences.previous.json")
  }

  private func scheduleCatalogSync() {
    catalogRefreshTask?.cancel()
    catalogRefreshTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
      guard let self, !Task.isCancelled, !self.demo,
        FileManager.default.fileExists(atPath: self.ownLibrary.appending(path: "screenshots").path)
      else { return }
      self.startCatalogSync(
        roots: [self.ownLibrary], version: self.generation, importLegacy: false)
    }
  }

  func restorePreferences() {
    do {
      let restored = try JSONDecoder().decode(
        Preferences.self, from: Data(contentsOf: previousConfig))
      try restored.validate()
      preferences = restored
      savePreferences()
      openSource()
    } catch { notice = "沒有可還原的設定。" }
  }

  private func elapsed(_ start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now).components
    return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
  }

  /// Deliberate allow-list: no URLs, filenames, capture times, images, or preferences.source.
  func diagnosticReport() -> String {
    let samples = previewSamples.sorted()
    let report: [String: Any] = [
      "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        as? String ?? "development",
      "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
      "screen_max_hz": NSScreen.screens.map(\.maximumFramesPerSecond),
      "catalog_days": days.count,
      "day_frames": captures.count,
      "indexed_captures": catalogIndexedCaptures,
      "index_busy": catalogBusy,
      "search_result_count": searchResults.count,
      "selected_index": selection,
      "display_matches_selection": displayedURL != nil && displayedURL == current?.url,
      "catalog_ms": catalogMilliseconds,
      "day_metadata_ms": dayMilliseconds,
      "latest_preview_ms": previewMilliseconds,
      "first_preview_from_model_init_ms": firstPreviewMilliseconds as Any? ?? NSNull(),
      "preview_sample_count": samples.count,
      "preview_p95_ms": samples.isEmpty ? 0 : samples[Int(Double(samples.count - 1) * 0.95)],
      "preview_pixels": preferences.previewPixels,
      "cache_budget_mb": images.cacheBudgetMegabytes,
      "max_decode_workers": ImageStore.maximumDecodeWorkers,
      "synthetic_mode": demo,
      "source_access":
        "owned image pool; app-owned SQLite index, annotations and view state",
      "recording_active": isRecording,
      "recording_waiting_for_screen": isWaitingForScreen,
      "recording_burst_active": isBurstRecording,
      "burst_remaining_seconds": burstRemainingSeconds as Any? ?? NSNull(),
      "recorded_frames": recordedFrames,
      "skipped_recording_cycles": skippedRecordingCycles,
      "connected_displays": connectedDisplays.count,
      "screen_permission": permissionGranted,
      "display_callback_sample": displayProbe.report,
      "recent_fault_codes": faults.recentCodes(),
      "fault_journal_disabled": faults.disabled,
    ]
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    else { return "{}" }
    return String(decoding: data, as: UTF8.self)
  }

  private func scheduleCatalogSnapshot() {
    guard persistMaintenanceSnapshots else { return }
    let catalogURL = catalogDatabaseURL
    let maintenance = runtimeDirectory.appending(path: "maintenance")
    let journal = faults
    Task.detached {
      do {
        try CatalogMaintenance.snapshotIfDue(from: catalogURL, into: maintenance)
      } catch {
        journal.record(code: "catalog.snapshot.failed", detail: error.localizedDescription)
      }
    }
  }

  private func recordFault(_ code: String, detail: String = "") {
    faults.record(code: code, detail: detail)
  }

  private func recordFault(_ code: String, error: Error) {
    faults.record(code: code, detail: error.localizedDescription)
  }
}
