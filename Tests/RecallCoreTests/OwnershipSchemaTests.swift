import Foundation
import SQLite3
import Testing

@testable import RecallCore

@Test func ownershipSchemaPreservesMomentsAssetsAndAnnotationsAcrossPathMove() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }

  let original = root.appending(path: "original")
  let first = original.appending(path: "screenshots/2026/09/06/14/1788674400_monitor-a.png")
  let second = original.appending(path: "screenshots/2026/09/06/14/1788674460_monitor-a.png")
  try writeFixtureData(Data([1, 2, 3]), to: first)
  try writeFixtureData(Data([1, 2, 3]), to: second)

  let catalog = try CaptureCatalog(databaseURL: root.appending(path: "library.sqlite"))
  let source = CatalogSource(
    key: "test.screenmemory", root: original, domain: "screenmemory", profile: "legacy")
  let firstSync = try await catalog.synchronize(sources: [source], hashAssets: true)
  #expect(firstSync.ownedMoments == 2)
  #expect(firstSync.ownedFrames == 2)
  #expect(firstSync.hashedAssets == 2)

  let status = try await catalog.schemaStatus()
  #expect(status.userVersion >= 3)
  #expect(status.migrationVersions == [1, 2, 3])
  #expect(
    [
      "moments", "frames", "assets", "schema_migrations", "maintenance_runs",
      "maintenance_items", "view_state",
    ]
    .allSatisfy(status.tables.contains))

  #expect(try await catalog.viewState() == nil)
  try await catalog.saveViewState(
    dayKey: "2026/09/06", timestamp: 1_788_674_400, displayID: "monitor-a")
  #expect(
    try await catalog.viewState()
      == CatalogViewState(dayKey: "2026/09/06", timestamp: 1_788_674_400, displayID: "monitor-a"))

  let oldCapture = Capture(url: first, timestamp: 1_788_674_400, displayID: "monitor-a")
  try await catalog.saveAnnotation(for: oldCapture, marked: true, note: "keep this")

  let moved = root.appending(path: "moved")
  try FileManager.default.moveItem(at: original, to: moved)
  let movedFirst = moved.appending(path: "screenshots/2026/09/06/14/1788674400_monitor-a.png")
  let movedSecond = moved.appending(path: "screenshots/2026/09/06/14/1788674460_monitor-a.png")
  let movedSource = CatalogSource(
    key: "test.screenmemory", root: moved, domain: "screenmemory", profile: "legacy")
  let secondSync = try await catalog.synchronize(sources: [movedSource], hashAssets: true)
  #expect(secondSync.ownedMoments == 2)

  let saved = try #require(
    await catalog.annotation(
      for: Capture(url: movedFirst, timestamp: 1_788_674_400, displayID: "monitor-a")))
  #expect(saved.marked)
  #expect(saved.note == "keep this")

  let summary = try await catalog.ownershipSummary()
  #expect(summary.momentCount == 2)
  #expect(summary.frameCount == 2)
  #expect(summary.assetCount == 1)
  #expect(summary.sharedAssetCount == 1)
  #expect(movedSecond.lastPathComponent.contains("1788674460"))
}

@Test func unknownSchemaVersionStopsWithoutResettingDatabase() throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let url = root.appending(path: "unknown.sqlite")
  var database: OpaquePointer?
  #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
  defer { sqlite3_close(database) }
  #expect(sqlite3_exec(database, "PRAGMA user_version = 999;", nil, nil, nil) == SQLITE_OK)
  #expect(throws: CatalogError.self) {
    _ = try CaptureCatalog(databaseURL: url)
  }
}

@Test func knownV1CatalogMigratesToOwnedSchemaWithoutResettingRows() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let databaseURL = root.appending(path: "catalog.sqlite")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  var database: OpaquePointer?
  guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
    throw NSError(domain: "OwnershipSchemaTests", code: 1)
  }
  defer { sqlite3_close(database) }
  let sql = """
    CREATE TABLE sources (id INTEGER PRIMARY KEY, root_path TEXT NOT NULL UNIQUE,
      kind TEXT NOT NULL DEFAULT 'image-tree', first_seen REAL NOT NULL, last_seen REAL NOT NULL);
    CREATE TABLE captures (id INTEGER PRIMARY KEY, source_id INTEGER NOT NULL, relative_path TEXT NOT NULL,
      timestamp REAL NOT NULL, day_key TEXT NOT NULL, clock_key TEXT NOT NULL, display_id TEXT,
      byte_count INTEGER NOT NULL DEFAULT 0, modified_at REAL, present INTEGER NOT NULL DEFAULT 1,
      first_seen REAL NOT NULL, last_seen REAL NOT NULL, UNIQUE(source_id, relative_path));
    CREATE TABLE annotations (source_id INTEGER NOT NULL, relative_path TEXT NOT NULL,
      marked INTEGER NOT NULL DEFAULT 0, note TEXT NOT NULL DEFAULT '', updated_at REAL NOT NULL,
      PRIMARY KEY(source_id, relative_path));
    CREATE TABLE legacy_artifacts (source_id INTEGER NOT NULL, name TEXT NOT NULL, path TEXT NOT NULL,
      kind TEXT NOT NULL, row_count INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL,
      updated_at REAL NOT NULL, PRIMARY KEY(source_id, name));
    CREATE TABLE legacy_notes (source_id INTEGER NOT NULL, legacy_id INTEGER NOT NULL,
      timestamp REAL NOT NULL, note TEXT NOT NULL, PRIMARY KEY(source_id, legacy_id));
    CREATE TABLE legacy_usage (source_id INTEGER NOT NULL, legacy_id INTEGER NOT NULL,
      timestamp TEXT NOT NULL, identifier TEXT NOT NULL, name TEXT NOT NULL,
      PRIMARY KEY(source_id, legacy_id));
    CREATE TABLE scan_runs (id INTEGER PRIMARY KEY, source_id INTEGER NOT NULL,
      started_at REAL NOT NULL, completed_at REAL NOT NULL, indexed_count INTEGER NOT NULL, status TEXT NOT NULL);
    INSERT INTO sources VALUES (1, '/old/root', 'image-tree', 1, 2);
    INSERT INTO captures VALUES (1, 1, '2026/09/06/14/1788674400.png', 1788674400,
      '2026-09-06', '14:00:00', NULL, 3, NULL, 1, 1, 2);
    INSERT INTO annotations VALUES (1, '2026/09/06/14/1788674400.png', 1, 'legacy note', 2);
    PRAGMA user_version = 1;
    """
  #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
  let catalog = try CaptureCatalog(databaseURL: databaseURL)
  let status = try await catalog.schemaStatus()
  #expect(status.userVersion == 3)
  #expect(status.migrationVersions == [1, 2, 3])
  #expect(try await catalog.currentCaptureCount() == 1)
  #expect(try await catalog.ownershipSummary().sourceCount == 1)
  #expect(try await catalog.ownershipSummary().annotationCount == 1)
}

private func writeFixtureData(_ data: Data, to url: URL) throws {
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try data.write(to: url)
}
