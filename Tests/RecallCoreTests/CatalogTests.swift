import Foundation
import SQLite3
import Testing

@testable import RecallCore

@Test func catalogSyncIsResumableAndSearchesCaptureMetadata() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let library = root.appending(path: "library")
  try writeCatalogFile(
    library.appending(path: "screenshots/2026/09/06/14/1788674400_monitor-a.heic"))
  try writeCatalogFile(
    library.appending(path: "screenshots/2026/09/06/15/1788678000_monitor-b.heic"))

  let source = try CaptureLibrary(root: library)
  let sourceDays = try await source.days()
  #expect(sourceDays.count == 1)
  #expect(try await source.captures(on: #require(sourceDays.first)).count == 2)

  let catalog = try CaptureCatalog(databaseURL: root.appending(path: "catalog.sqlite"))
  let first = try await catalog.synchronize(roots: [library])
  #expect(first.indexedCaptures == 2)
  #expect(first.preservedNotes == 0)
  #expect(try await catalog.currentCaptureCount() == 2)
  for suffix in ["", "-wal", "-shm"] {
    let path = root.appending(path: "catalog.sqlite\(suffix)").path
    if FileManager.default.fileExists(atPath: path) {
      let permissions =
        try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
      #expect(permissions == 0o600)
    }
  }

  let dateResults = try await catalog.search("2026-09-06")
  #expect(dateResults.count == 2)
  let screenResults = try await catalog.search("monitor-b")
  #expect(screenResults.map { $0.capture.displayID } == ["monitor-b"])

  let second = try await catalog.synchronize(roots: [library])
  #expect(second.indexedCaptures == 2)
  #expect(second.inspectedPaths == 2)
  #expect(second.unchangedPaths == 2)
  #expect(second.changedPaths == 0)
  #expect(second.addedPaths == 0)
  #expect(second.walkMilliseconds >= 0)
  #expect(second.writeMilliseconds >= 0)
  #expect(try await catalog.currentCaptureCount() == 2)
}

@Test func catalogBackupCopiesWalStateWithoutTouchingSource() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let library = root.appending(path: "library")
  try writeCatalogFile(
    library.appending(path: "screenshots/2026/09/06/14/1788674400_monitor-a.webp"))
  let sourceCatalog = root.appending(path: "source.sqlite")
  let catalog = try CaptureCatalog(databaseURL: sourceCatalog)
  _ = try await catalog.synchronize(roots: [library], importLegacy: false)
  try await catalog.saveViewState(dayKey: "2026-09-06", timestamp: 1_788_674_400)
  let sourceCount = try await catalog.currentCaptureCount()

  let copy = root.appending(path: "copy.sqlite")
  try CaptureCatalog.backup(from: sourceCatalog, to: copy)
  #expect(try CaptureCatalog.integrityOK(at: copy))
  #expect(try await catalog.currentCaptureCount() == sourceCount)

  let restored = try CaptureCatalog(databaseURL: copy)
  #expect(try await restored.currentCaptureCount() == sourceCount)
  #expect(try await restored.viewState()?.dayKey == "2026-09-06")
  #expect(try await restored.dayMomentCounts().map(\.count) == [1])
}

@Test func incrementalSyncSkipsUnchangedFilesAndKeepsMissingAnnotations() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let library = root.appending(path: "library")
  let first = library.appending(path: "screenshots/2026/09/06/14/1788674400_monitor-a.webp")
  let second = library.appending(path: "screenshots/2026/09/06/14/1788674460_monitor-b.webp")
  try writeCatalogFile(first)
  try writeCatalogFile(second)

  let catalog = try CaptureCatalog(databaseURL: root.appending(path: "catalog.sqlite"))
  let initial = try await catalog.synchronize(roots: [library], importLegacy: false)
  #expect(initial.addedPaths == 2)
  #expect(initial.unchangedPaths == 0)
  try await catalog.saveAnnotation(
    for: Capture(url: first, timestamp: 1_788_674_400, displayID: "monitor-a"),
    marked: true, note: "keep")

  let noChange = try await catalog.synchronize(roots: [library], importLegacy: false)
  #expect(noChange.inspectedPaths == 2)
  #expect(noChange.unchangedPaths == 2)
  #expect(noChange.addedPaths == 0)
  #expect(noChange.changedPaths == 0)
  #expect(noChange.missingPaths == 0)

  let third = library.appending(path: "screenshots/2026/09/06/14/1788674520_monitor-a.webp")
  try writeCatalogFile(third)
  try FileManager.default.removeItem(at: second)
  let delta = try await catalog.synchronize(roots: [library], importLegacy: false)
  #expect(delta.addedPaths == 1)
  #expect(delta.missingPaths == 1)
  #expect(try await catalog.currentCaptureCount() == 2)
  #expect(try await catalog.presentDays(roots: [library]).map(\.id) == ["2026/09/06"])
  let annotations = try await catalog.annotations()
  #expect(annotations.count == 1)
  #expect(annotations.first?.note == "keep")
  #expect(annotations.first?.capture.url == first)
}

@Test func cancelledCatalogSyncDoesNotBlockANewerScan() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let library = root.appending(path: "library")
  try writeCatalogFile(
    library.appending(path: "screenshots/2026/09/06/14/1788674400_monitor-a.webp"))
  let catalog = try CaptureCatalog(databaseURL: root.appending(path: "catalog.sqlite"))
  let cancelled = Task { try await catalog.synchronize(roots: [library], importLegacy: false) }
  cancelled.cancel()
  _ = try? await cancelled.value
  let finished = try await catalog.synchronize(roots: [library], importLegacy: false)
  #expect(finished.indexedCaptures == 1)
  #expect(try await catalog.currentCaptureCount() == 1)
}

@Test func q50SourceSwitchKeepsSimpleImageRelationships() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let timestamp = 1_788_674_400.0
  let legacy = root.appending(path: "legacy")
  let converted = root.appending(path: "converted")
  let oldImage = legacy.appending(path: "screenshots/2026/09/06/14/1788674400.jpeg")
  let newImage = converted.appending(path: "screenshots/2026/09/06/14/1788674400.webp")
  try writeCatalogFile(oldImage)
  try writeCatalogFile(newImage)
  try Data([0]).write(to: legacy.appending(path: "notes.sqlite"))
  try Data(#"{"quality":50,"version":1}"#.utf8)
    .write(to: converted.appending(path: "q50-config.json"))

  let catalog = try CaptureCatalog(databaseURL: root.appending(path: "catalog.sqlite"))
  _ = try await catalog.synchronize(roots: [legacy], importLegacy: false)
  try await catalog.saveAnnotation(
    for: Capture(url: oldImage, timestamp: timestamp), marked: true, note: "Keep this moment")

  _ = try await catalog.synchronize(roots: [converted], importLegacy: false)
  let ownership = try await catalog.ownershipSummary()
  let annotations = try await catalog.annotations()
  #expect(ownership.sourceCount == 1)
  #expect(ownership.momentCount == 1)
  #expect(ownership.frameCount == 1)
  #expect(ownership.annotationCount == 1)
  #expect(annotations.first?.capture.url == newImage)
  #expect(annotations.first?.note == "Keep this moment")
}

@Test func containingScreenMemoryDBAndQ50UseOneLogicalSource() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let timestamp = 1_788_674_400.0
  let container = root.appending(path: "ScreenMemoryDB")
  let legacy = container.appending(path: "ScreenMemoryData")
  let converted = container.appending(path: "ScreenMemoryData-WebP-Q50")
  let oldImage = legacy.appending(path: "screenshots/2026/09/06/14/1788674400.jpeg")
  let newImage = converted.appending(path: "screenshots/2026/09/06/14/1788674400.webp")
  try writeCatalogFile(oldImage)
  try writeCatalogFile(newImage)
  try makeLegacyDatabase(
    at: legacy.appending(path: "notes.sqlite"),
    sql: "CREATE TABLE notes (id INTEGER PRIMARY KEY, timestamp INTEGER, note TEXT);"
  )
  try Data(#"{"quality":50,"version":1}"#.utf8)
    .write(to: converted.appending(path: "q50-config.json"))

  let catalog = try CaptureCatalog(databaseURL: root.appending(path: "catalog.sqlite"))
  // Simulate the formal catalog written by the older build, which used the
  // discovered key for a containing ScreenMemoryDB directory.
  _ = try await catalog.synchronize(
    sources: [
      CatalogSource(
        key: "image-tree.discovered", root: container, domain: "image-tree", profile: "discovered")
    ], importLegacy: false)
  try await catalog.saveAnnotation(
    for: Capture(url: oldImage, timestamp: timestamp), marked: true, note: "Keep this path")
  _ = try await catalog.synchronize(roots: [converted], importLegacy: false)

  let ownership = try await catalog.ownershipSummary()
  let annotations = try await catalog.annotations()
  #expect(ownership.sourceCount == 1)
  #expect(ownership.momentCount == 1)
  #expect(ownership.frameCount == 1)
  #expect(annotations.first?.capture.url == newImage)
}

@Test func ownedSourceMergeCombinesQ50AndQ30IntoOnePool() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let timestamp = 1_788_674_400.0
  let q50 = root.appending(path: "History/Q50")
  let owned = root.appending(path: "CaptureLibrary")
  let q50Image = q50.appending(path: "screenshots/2026/09/06/14/1788674400.webp")
  let q30Image = owned.appending(path: "screenshots/2026/09/06/14/1788674460_display-a.webp")
  try writeCatalogFile(q50Image)
  try writeCatalogFile(q30Image)

  let catalog = try CaptureCatalog(databaseURL: root.appending(path: "catalog.sqlite"))
  _ = try await catalog.synchronize(roots: [q50, owned], importLegacy: false)
  try await catalog.saveAnnotation(
    for: Capture(url: q50Image, timestamp: timestamp), marked: true, note: "Keep Q50")

  let movedImage = owned.appending(path: "screenshots/2026/09/06/14/1788674400.webp")
  try FileManager.default.moveItem(at: q50Image, to: movedImage)
  let merged = try await catalog.mergeSource(from: q50, into: owned)
  #expect(merged.mergedMoments == 1)
  #expect(merged.mergedFrames == 1)

  let sync = try await catalog.synchronize(roots: [owned], importLegacy: false)
  #expect(sync.conflicts == 0)
  let ownership = try await catalog.ownershipSummary()
  #expect(ownership.sourceCount == 1)
  #expect(ownership.momentCount == 2)
  #expect(ownership.frameCount == 2)
  #expect(ownership.annotationCount == 1)
  let annotations = try await catalog.annotations()
  #expect(annotations.first?.sourceRoot.standardizedFileURL == owned.standardizedFileURL)
  #expect(annotations.first?.capture.url == movedImage)
}

@Test func catalogPreservesNonOCRLegacyDataAndRecordsDeferredOCR() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try writeCatalogFile(
    root.appending(path: "screenshots/2026/09/06/14/1788674400_monitor-a.heic"))
  try makeLegacyDatabase(
    at: root.appending(path: "notes.sqlite"),
    sql:
      "CREATE TABLE notes (id INTEGER PRIMARY KEY, timestamp INTEGER NOT NULL, note TEXT NOT NULL); INSERT INTO notes VALUES (1, 1788674400, 'A note');"
  )
  try makeLegacyDatabase(
    at: root.appending(path: "usage.sqlite"),
    sql:
      "CREATE TABLE usage (id INTEGER PRIMARY KEY, timestamp TEXT NOT NULL, identifier TEXT NOT NULL, name TEXT NOT NULL); INSERT INTO usage VALUES (1, '1788674400', 'com.example.app', 'Example');"
  )
  try makeLegacyDatabase(
    at: root.appending(path: "text.sqlite"),
    sql:
      "CREATE TABLE ocrresults (id INTEGER PRIMARY KEY, imagetimestamp TEXT UNIQUE, imagepath TEXT NOT NULL UNIQUE, imagedate TEXT NOT NULL, imagetext TEXT NOT NULL); INSERT INTO ocrresults VALUES (1, '1788674400', 'private.png', '2026-09-06', 'private text');"
  )

  let catalog = try CaptureCatalog(databaseURL: root.appending(path: "catalog.sqlite"))
  let summary = try await catalog.synchronize(roots: [root])
  #expect(summary.preservedNotes == 1)
  #expect(summary.preservedUsage == 1)
  #expect(summary.deferredOCRRows == 1)
  #expect(try await catalog.legacyArtifactStatus("text.sqlite") == "deferred-ocr")
  let ownership = try await catalog.ownershipSummary()
  #expect(ownership.applicationCount == 1)
  #expect(ownership.appEventCount == 1)
}

@Test func catalogRoundTripsLocalCaptureAnnotationWithoutTouchingTheImage() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let image = root.appending(path: "screenshots/2026/09/06/14/1788674400_monitor-a.heic")
  let noteImage = root.appending(path: "screenshots/2026/09/06/14/1788674460_monitor-b.heic")
  try writeCatalogFile(image)
  try writeCatalogFile(noteImage)
  let catalog = try CaptureCatalog(databaseURL: root.appending(path: "catalog.sqlite"))
  _ = try await catalog.synchronize(roots: [root])
  let capture = Capture(url: image, timestamp: 1_788_674_400, displayID: "monitor-a")
  let noteCapture = Capture(url: noteImage, timestamp: 1_788_674_460, displayID: "monitor-b")

  #expect(try await catalog.annotation(for: capture) == nil)
  try await catalog.saveAnnotation(for: capture, marked: true, note: "Check this moment")
  let saved = try #require(await catalog.annotation(for: capture))
  #expect(saved.marked)
  #expect(saved.note == "Check this moment")
  #expect(try Data(contentsOf: image) == Data([0]))
  try await catalog.saveAnnotation(for: noteCapture, marked: false, note: "Note only")

  let annotated = try await catalog.annotations()
  #expect(annotated.count == 2)
  #expect(annotated.map(\.capture.url).contains(image))
  #expect(try await catalog.annotations(markedOnly: true).count == 1)
  #expect(try await catalog.annotations(notesOnly: true).count == 2)

  try await catalog.saveAnnotation(for: capture, marked: false, note: "")
  #expect(try await catalog.annotation(for: capture) == nil)
  #expect(try await catalog.annotations().count == 1)
}

@Test func catalogBackupRefusesAnExistingDestinationAndLeavesTheSourceIntact() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let library = root.appending(path: "library")
  try writeCatalogFile(
    library.appending(path: "screenshots/2026/09/06/14/1788674400_monitor-a.webp"))
  let sourceCatalog = root.appending(path: "source.sqlite")
  let catalog = try CaptureCatalog(databaseURL: sourceCatalog)
  _ = try await catalog.synchronize(roots: [library], importLegacy: false)
  try await catalog.saveAnnotation(
    for: Capture(
      url: library.appending(path: "screenshots/2026/09/06/14/1788674400_monitor-a.webp"),
      timestamp: 1_788_674_400, displayID: "monitor-a"),
    marked: true, note: "keep")
  let copy = root.appending(path: "copy.sqlite")
  try Data([1]).write(to: copy)
  #expect(throws: (any Error).self) {
    try CaptureCatalog.backup(from: sourceCatalog, to: copy)
  }
  #expect(try Data(contentsOf: copy) == Data([1]))
  #expect(try await catalog.currentCaptureCount() == 1)
  #expect(try await catalog.annotations().first?.note == "keep")
}

@Test func catalogReopenPreservesAnnotationsAndViewState() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let library = root.appending(path: "library")
  let image = library.appending(path: "screenshots/2026/09/06/14/1788674400_monitor-a.webp")
  try writeCatalogFile(image)
  let database = root.appending(path: "catalog.sqlite")
  do {
    let catalog = try CaptureCatalog(databaseURL: database)
    _ = try await catalog.synchronize(roots: [library], importLegacy: false)
    try await catalog.saveAnnotation(
      for: Capture(url: image, timestamp: 1_788_674_400, displayID: "monitor-a"),
      marked: true, note: "durable")
    try await catalog.saveViewState(dayKey: "2026-09-06", timestamp: 1_788_674_400)
    try await catalog.checkpointPassive()
  }
  let reopened = try CaptureCatalog(databaseURL: database)
  #expect(try await reopened.viewState()?.dayKey == "2026-09-06")
  #expect(try await reopened.annotations().first?.note == "durable")
  #expect(try CaptureCatalog.integrityOK(at: database))
}

@Test func repeatedIncrementalSyncDoesNotGrowTheWalWithoutBound() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let library = root.appending(path: "library")
  try writeCatalogFile(
    library.appending(path: "screenshots/2026/09/06/14/1788674400_monitor-a.webp"))
  let catalog = try CaptureCatalog(databaseURL: root.appending(path: "catalog.sqlite"))
  _ = try await catalog.synchronize(roots: [library], importLegacy: false)
  for _ in 0..<4 {
    _ = try await catalog.synchronize(roots: [library], importLegacy: false)
  }
  let bytes = try await catalog.storageBytes()
  #expect(bytes.wal < 1_048_576)
  #expect(try CaptureCatalog.integrityOK(at: catalog.databaseURL))
}

@Test func catalogIntegrityRejectsACorruptFile() throws {
  let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).sqlite")
  defer { try? FileManager.default.removeItem(at: url) }
  try Data("not a sqlite database".utf8).write(to: url)
  let intact = try? CaptureCatalog.integrityOK(at: url)
  #expect(intact != true)
}

@Test func dailyCatalogSnapshotIsIdempotentAndPrunesOnlyAutoFolders() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let library = root.appending(path: "library")
  try writeCatalogFile(
    library.appending(path: "screenshots/2026/09/06/14/1788674400_monitor-a.webp"))
  let catalogURL = root.appending(path: "catalog.sqlite")
  let catalog = try CaptureCatalog(databaseURL: catalogURL)
  _ = try await catalog.synchronize(roots: [library], importLegacy: false)
  try await catalog.saveAnnotation(
    for: Capture(
      url: library.appending(path: "screenshots/2026/09/06/14/1788674400_monitor-a.webp"),
      timestamp: 1_788_674_400, displayID: "monitor-a"),
    marked: true, note: "snapshot")
  try await catalog.saveViewState(dayKey: "2026-09-06", timestamp: 1_788_674_400)

  let maintenance = root.appending(path: "maintenance")
  let manual = maintenance.appending(path: "2026-09-08-before-clear-favorites")
  try FileManager.default.createDirectory(at: manual, withIntermediateDirectories: true)
  try Data("manual".utf8).write(to: manual.appending(path: "keep.txt"))
  for day in ["2026-09-01", "2026-09-02", "2026-09-03", "2026-09-04"] {
    let folder = maintenance.appending(path: "auto-\(day)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(day.utf8).write(to: folder.appending(path: "catalog.sqlite"))
  }

  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
  let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 8, hour: 10))!
  let first = try CatalogMaintenance.snapshotIfDue(
    from: catalogURL, into: maintenance, now: now, calendar: calendar, keepLast: 3)
  #expect(first != nil)
  let second = try CatalogMaintenance.snapshotIfDue(
    from: catalogURL, into: maintenance, now: now, calendar: calendar, keepLast: 3)
  #expect(second == nil)

  let names = try FileManager.default.contentsOfDirectory(atPath: maintenance.path).sorted()
  #expect(names.contains("2026-09-08-before-clear-favorites"))
  #expect(!names.contains("auto-2026-09-01"))
  #expect(!names.contains("auto-2026-09-02"))
  #expect(names.contains("auto-2026-09-03") || names.contains("auto-2026-09-04"))
  #expect(names.contains("auto-2026-09-08"))
  #expect(names.filter { $0.hasPrefix("auto-") }.count == 3)
  #expect(try String(contentsOf: manual.appending(path: "keep.txt"), encoding: .utf8) == "manual")
  #expect(try await catalog.currentCaptureCount() == 1)
  #expect(try await catalog.annotations().first?.note == "snapshot")

  let snapshot = try #require(first)
  #expect(try CaptureCatalog.integrityOK(at: snapshot))
  let restored = try CaptureCatalog(databaseURL: snapshot)
  #expect(try await restored.annotations().first?.note == "snapshot")
  #expect(try await restored.viewState()?.dayKey == "2026-09-06")
}

@Test func missingCatalogDoesNotCreateAFailedSnapshotFolder() throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let maintenance = root.appending(path: "maintenance")
  let missing = root.appending(path: "missing.sqlite")
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
  let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 8))!
  let result = try CatalogMaintenance.snapshotIfDue(
    from: missing, into: maintenance, now: now, calendar: calendar)
  #expect(result == nil)
  #expect(
    !FileManager.default.fileExists(atPath: maintenance.appending(path: "auto-2026-09-08").path))
}

@Test func failedSnapshotRemovesItsFolderAndLeavesTheSourceCatalog() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let catalogURL = root.appending(path: "catalog.sqlite")
  try FileManager.default.createDirectory(at: catalogURL, withIntermediateDirectories: true)
  try Data("source".utf8).write(to: catalogURL.appending(path: "keep.txt"))
  let maintenance = root.appending(path: "maintenance")
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
  let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 8))!
  #expect(throws: (any Error).self) {
    try CatalogMaintenance.snapshotIfDue(
      from: catalogURL, into: maintenance, now: now, calendar: calendar)
  }
  #expect(
    !FileManager.default.fileExists(atPath: maintenance.appending(path: "auto-2026-09-08").path))
  #expect(
    try String(contentsOf: catalogURL.appending(path: "keep.txt"), encoding: .utf8) == "source")
}

private func writeCatalogFile(_ url: URL) throws {
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data([0]).write(to: url)
}

private func makeLegacyDatabase(at url: URL, sql: String) throws {
  var database: OpaquePointer?
  guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
    throw NSError(domain: "CatalogTests", code: 1)
  }
  defer { sqlite3_close(database) }
  guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
    throw NSError(domain: "CatalogTests", code: 2)
  }
}
